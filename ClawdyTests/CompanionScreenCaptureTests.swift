//
//  CompanionScreenCaptureTests.swift
//  ClawdyTests
//
//  Tests for the pure helpers behind the silent companion screenshot path.
//  These cover the logic that lets repeated push-to-talk captures reuse a single
//  SCShareableContent enumeration (so macOS Sequoia doesn't re-prompt for screen
//  recording on every capture), plus cursor-first display ordering and own-app
//  window exclusion.
//

import Testing
import CoreGraphics
@testable import Clawdy

@MainActor
struct CompanionScreenCaptureTests {

    // MARK: - shouldRefreshShareableContent

    /// Convenience for building a display geometry snapshot in tests.
    private func geometry(_ id: CGDirectDisplayID, _ frame: CGRect) -> CompanionDisplayGeometry {
        CompanionDisplayGeometry(displayID: id, frame: frame)
    }

    private var displayA: CGRect { CGRect(x: 0, y: 0, width: 1920, height: 1080) }
    private var displayB: CGRect { CGRect(x: 1920, y: 0, width: 1920, height: 1080) }

    @Test func refreshesWhenNoCachedDisplaysYet() {
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: nil,
            currentDisplayGeometry: [geometry(1, displayA), geometry(2, displayB)]
        )
        #expect(shouldRefresh == true)
    }

    @Test func reusesCacheWhenGeometryUnchanged() {
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: [geometry(1, displayA), geometry(2, displayB)],
            currentDisplayGeometry: [geometry(1, displayA), geometry(2, displayB)]
        )
        #expect(shouldRefresh == false)
    }

    @Test func reusesCacheWhenGeometryUnchangedButReordered() {
        // Displays may come back in a different order; only identity+geometry matter.
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: [geometry(2, displayB), geometry(1, displayA)],
            currentDisplayGeometry: [geometry(1, displayA), geometry(2, displayB)]
        )
        #expect(shouldRefresh == false)
    }

    @Test func refreshesWhenDisplayAdded() {
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: [geometry(1, displayA)],
            currentDisplayGeometry: [geometry(1, displayA), geometry(2, displayB)]
        )
        #expect(shouldRefresh == true)
    }

    @Test func refreshesWhenDisplayRemoved() {
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: [geometry(1, displayA), geometry(2, displayB)],
            currentDisplayGeometry: [geometry(2, displayB)]
        )
        #expect(shouldRefresh == true)
    }

    @Test func refreshesWhenDisplayReplaced() {
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: [geometry(1, displayA), geometry(2, displayB)],
            currentDisplayGeometry: [geometry(1, displayA), geometry(3, displayB)]
        )
        #expect(shouldRefresh == true)
    }

    @Test func refreshesWhenResolutionChanges() {
        // Same display ID, but the display switched to a lower resolution.
        let highResolution = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let lowResolution = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: [geometry(1, highResolution)],
            currentDisplayGeometry: [geometry(1, lowResolution)]
        )
        #expect(shouldRefresh == true)
    }

    @Test func refreshesWhenDisplayRotated() {
        // Rotation swaps width and height for the same display ID.
        let landscape = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: [geometry(1, landscape)],
            currentDisplayGeometry: [geometry(1, portrait)]
        )
        #expect(shouldRefresh == true)
    }

    @Test func refreshesWhenArrangementOriginChanges() {
        // The second monitor was moved from the right side to the left side.
        let secondMonitorOnRight = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let secondMonitorOnLeft = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: [geometry(1, displayA), geometry(2, secondMonitorOnRight)],
            currentDisplayGeometry: [geometry(1, displayA), geometry(2, secondMonitorOnLeft)]
        )
        #expect(shouldRefresh == true)
    }

    @Test func refreshesWhenMirroringCollapsesFrames() {
        // Turning on mirroring makes the second display report the primary's frame.
        let unmirrored = [geometry(1, displayA), geometry(2, displayB)]
        let mirrored = [geometry(1, displayA), geometry(2, displayA)]
        let shouldRefresh = CompanionScreenCaptureUtility.shouldRefreshShareableContent(
            cachedDisplayGeometry: unmirrored,
            currentDisplayGeometry: mirrored
        )
        #expect(shouldRefresh == true)
    }

    // MARK: - screenshotPixelDimensions (LLM encode sizing)

    @Test func landscapeDisplayScalesLongestEdgeToTarget() {
        // A 1512x982 Retina display encodes to 800px on its longest (width) edge.
        let dimensions = CompanionScreenCaptureUtility.screenshotPixelDimensions(
            displayWidthInPixels: 1512,
            displayHeightInPixels: 982,
            maxLongestEdgePixels: CompanionScreenCaptureUtility.screenshotMaxLongestEdgePixels
        )
        #expect(dimensions.width == 800)
        // Height preserves aspect ratio: 800 / (1512/982) ≈ 519.
        #expect(dimensions.height == 519)
        #expect(max(dimensions.width, dimensions.height) == 800)
    }

    @Test func portraitDisplayScalesLongestEdgeToTarget() {
        // A rotated/portrait display: the longest edge is the height.
        let dimensions = CompanionScreenCaptureUtility.screenshotPixelDimensions(
            displayWidthInPixels: 1080,
            displayHeightInPixels: 1920,
            maxLongestEdgePixels: CompanionScreenCaptureUtility.screenshotMaxLongestEdgePixels
        )
        #expect(dimensions.height == 800)
        #expect(dimensions.width == 450)
        #expect(max(dimensions.width, dimensions.height) == 800)
    }

    @Test func squareDisplayScalesBothEdgesToTarget() {
        let dimensions = CompanionScreenCaptureUtility.screenshotPixelDimensions(
            displayWidthInPixels: 1000,
            displayHeightInPixels: 1000,
            maxLongestEdgePixels: CompanionScreenCaptureUtility.screenshotMaxLongestEdgePixels
        )
        #expect(dimensions.width == 800)
        #expect(dimensions.height == 800)
    }

    @Test func encodeTargetsAreTheSmallerRound2Values() {
        // Lock in the round-2 reduction: 800px longest edge at JPEG quality 0.5,
        // smaller than the original 1280px / 0.8.
        #expect(CompanionScreenCaptureUtility.screenshotMaxLongestEdgePixels == 800)
        #expect(CompanionScreenCaptureUtility.screenshotJPEGCompressionQuality == 0.5)
        #expect(CompanionScreenCaptureUtility.screenshotMaxLongestEdgePixels < 1280)
        #expect(CompanionScreenCaptureUtility.screenshotJPEGCompressionQuality < 0.8)
    }

    // MARK: - windowBelongsToOwnApp

    @Test func ownWindowIsExcluded() {
        let isOwn = CompanionScreenCaptureUtility.windowBelongsToOwnApp(
            windowOwningBundleIdentifier: "com.getclawdy.app",
            ownAppBundleIdentifier: "com.getclawdy.app"
        )
        #expect(isOwn == true)
    }

    @Test func otherAppWindowIsNotExcluded() {
        let isOwn = CompanionScreenCaptureUtility.windowBelongsToOwnApp(
            windowOwningBundleIdentifier: "com.apple.Safari",
            ownAppBundleIdentifier: "com.getclawdy.app"
        )
        #expect(isOwn == false)
    }

    @Test func windowWithUnknownOwnerIsNotExcluded() {
        let isOwn = CompanionScreenCaptureUtility.windowBelongsToOwnApp(
            windowOwningBundleIdentifier: nil,
            ownAppBundleIdentifier: "com.getclawdy.app"
        )
        #expect(isOwn == false)
    }

    @Test func nothingIsExcludedWhenOwnBundleUnknown() {
        // If we can't determine our own bundle identifier we must not accidentally
        // exclude another app's window from the screenshot.
        let isOwn = CompanionScreenCaptureUtility.windowBelongsToOwnApp(
            windowOwningBundleIdentifier: "com.getclawdy.app",
            ownAppBundleIdentifier: nil
        )
        #expect(isOwn == false)
    }

    // MARK: - shouldExcludeOwnAppWindowFromCapture (results-window exemption)

    private let ownBundle = "com.getclawdy.app"

    @Test func ownChromeWindowIsExcludedWhenNotInCapturableSet() {
        // The transient chrome (overlays, pills, panels) must never leak: an
        // own-app window whose number is NOT exempted is excluded from capture.
        let shouldExclude = CompanionScreenCaptureUtility.shouldExcludeOwnAppWindowFromCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 42,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: []
        )
        #expect(shouldExclude == true)
    }

    @Test func resultsWindowIsExemptedFromOwnAppExclusion() {
        // The research results window registers its number as capturable, so it
        // stays IN the screenshot even though it belongs to our own app.
        let shouldExclude = CompanionScreenCaptureUtility.shouldExcludeOwnAppWindowFromCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 42,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: [42]
        )
        #expect(shouldExclude == false)
    }

    @Test func otherAppWindowIsNeverExcludedRegardlessOfCapturableSet() {
        // Another app's window is the user's content — never excluded, and an
        // unrelated capturable entry must not change that.
        let shouldExclude = CompanionScreenCaptureUtility.shouldExcludeOwnAppWindowFromCapture(
            windowOwningBundleIdentifier: "com.apple.Safari",
            windowNumber: 42,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: [42]
        )
        #expect(shouldExclude == false)
    }

    @Test func onlyTheRegisteredResultsWindowIsExemptedAmongOwnWindows() {
        // With the results window (7) registered, a sibling own-app chrome window
        // (8) is still excluded — the exemption is per-window, not app-wide.
        let capturable: Set<CGWindowID> = [7]
        let resultsExcluded = CompanionScreenCaptureUtility.shouldExcludeOwnAppWindowFromCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 7,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: capturable
        )
        let chromeExcluded = CompanionScreenCaptureUtility.shouldExcludeOwnAppWindowFromCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 8,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: capturable
        )
        #expect(resultsExcluded == false)
        #expect(chromeExcluded == true)
    }

    @Test func nothingIsExcludedWhenOwnBundleUnknownEvenIfCapturableSet() {
        // If we can't determine our own bundle id we can't classify a window as
        // ours, so we never exclude it (mirrors windowBelongsToOwnApp).
        let shouldExclude = CompanionScreenCaptureUtility.shouldExcludeOwnAppWindowFromCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 42,
            ownAppBundleIdentifier: nil,
            capturableOwnWindowNumbers: []
        )
        #expect(shouldExclude == false)
    }

    // MARK: - capturable-set thread safety

    /// The capturable set is MUTATED on the main actor (register/unregister as the
    /// results window shows/hides) and READ off the main actor by the capture path.
    /// Hammer register/unregister and snapshot reads concurrently from many tasks
    /// and assert it never crashes or tears — the lock-guarded accessors must
    /// serialize all access. Every snapshot must also be internally consistent (a
    /// plain `Set`, never a half-mutated value).
    @Test func concurrentRegisterUnregisterAndSnapshotNeverRacesOrTears() async {
        // Use a window-number range that can't collide with any real window so this
        // test never perturbs a live capture, and clean up at the end.
        let windowNumbers: [CGWindowID] = (900_000..<900_064).map { CGWindowID($0) }
        defer { windowNumbers.forEach { CompanionScreenCaptureUtility.unregisterCapturableWindow($0) } }

        await withTaskGroup(of: Void.self) { group in
            // Writers: repeatedly register then unregister each number.
            for windowNumber in windowNumbers {
                group.addTask {
                    for _ in 0..<200 {
                        CompanionScreenCaptureUtility.registerCapturableWindow(windowNumber)
                        CompanionScreenCaptureUtility.unregisterCapturableWindow(windowNumber)
                    }
                }
            }
            // Readers: repeatedly snapshot and use the copy. Reading `.count` and
            // iterating exercises the snapshot as an immutable, consistent value —
            // if the read were unsynchronized against the writers this would trip
            // the runtime's exclusivity/collection checks.
            for _ in 0..<16 {
                group.addTask {
                    for _ in 0..<400 {
                        let snapshot = CompanionScreenCaptureUtility.capturableWindowsSnapshot()
                        var seen = 0
                        for windowNumber in snapshot where windowNumber >= 900_000 {
                            seen += 1
                        }
                        #expect(seen <= windowNumbers.count)
                    }
                }
            }
        }

        // After all writers finish, every test window has been unregistered, so the
        // set contains none of them (a real results window, if any, is untouched).
        let finalSnapshot = CompanionScreenCaptureUtility.capturableWindowsSnapshot()
        for windowNumber in windowNumbers {
            #expect(!finalSnapshot.contains(windowNumber))
        }
    }

    /// The synchronized accessors round-trip through the same lock-guarded set the
    /// capture path snapshots, so a registered window shows up in the snapshot and
    /// an unregistered one drops out.
    @Test func registerAndUnregisterAreReflectedInTheSnapshot() {
        let windowNumber: CGWindowID = 900_777
        defer { CompanionScreenCaptureUtility.unregisterCapturableWindow(windowNumber) }

        CompanionScreenCaptureUtility.registerCapturableWindow(windowNumber)
        #expect(CompanionScreenCaptureUtility.capturableWindowsSnapshot().contains(windowNumber))

        CompanionScreenCaptureUtility.unregisterCapturableWindow(windowNumber)
        #expect(!CompanionScreenCaptureUtility.capturableWindowsSnapshot().contains(windowNumber))
    }

    // MARK: - displayOrderPuttingCursorScreenFirst

    @Test func singleDisplayOrderIsUnchanged() {
        let frames = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let order = CompanionScreenCaptureUtility.displayOrderPuttingCursorScreenFirst(
            displayFrames: frames,
            mouseLocation: CGPoint(x: 100, y: 100)
        )
        #expect(order == [0])
    }

    @Test func cursorScreenIsMovedFirst() {
        // Cursor is on the second display; it should be ordered first.
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        ]
        let order = CompanionScreenCaptureUtility.displayOrderPuttingCursorScreenFirst(
            displayFrames: frames,
            mouseLocation: CGPoint(x: 2000, y: 500)
        )
        #expect(order == [1, 0])
    }

    @Test func cursorScreenAlreadyFirstKeepsOrder() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        ]
        let order = CompanionScreenCaptureUtility.displayOrderPuttingCursorScreenFirst(
            displayFrames: frames,
            mouseLocation: CGPoint(x: 100, y: 100)
        )
        #expect(order == [0, 1])
    }

    @Test func remainingDisplaysKeepStableOrderWhenCursorOffscreen() {
        // Cursor is not inside any display frame; original order is preserved.
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
            CGRect(x: 400, y: 0, width: 100, height: 100)
        ]
        let order = CompanionScreenCaptureUtility.displayOrderPuttingCursorScreenFirst(
            displayFrames: frames,
            mouseLocation: CGPoint(x: 9999, y: 9999)
        )
        #expect(order == [0, 1, 2])
    }

    @Test func cursorScreenFirstThenStableRemainder() {
        // Cursor on the third display: it leads, the other two keep their order.
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
            CGRect(x: 400, y: 0, width: 100, height: 100)
        ]
        let order = CompanionScreenCaptureUtility.displayOrderPuttingCursorScreenFirst(
            displayFrames: frames,
            mouseLocation: CGPoint(x: 450, y: 50)
        )
        #expect(order == [2, 0, 1])
    }
}
