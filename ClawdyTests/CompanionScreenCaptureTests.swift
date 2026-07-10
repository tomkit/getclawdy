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

    // MARK: - shouldReincludeOwnAppWindowInCapture (results-window re-inclusion)
    //
    // The filter now excludes Clawdy's whole application, then RE-INCLUDES the
    // registered results window(s) via `exceptingWindows`. This predicate computes
    // that `exceptingWindows` set: it returns true ONLY for an own-app window whose
    // number is registered as capturable, and false for everything else (our own
    // chrome stays excluded by the app-level exclusion; other apps are already
    // captured and need no exception).

    private let ownBundle = "com.getclawdy.app"

    @Test func ownChromeWindowIsNotReincludedWhenNotInCapturableSet() {
        // The transient chrome (overlays, pills, panels) must never leak: an
        // own-app window whose number is NOT registered stays excluded (the
        // app-level exclusion removes it) — it is never re-included.
        let shouldReinclude = CompanionScreenCaptureUtility.shouldReincludeOwnAppWindowInCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 42,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: []
        )
        #expect(shouldReinclude == false)
    }

    @Test func resultsWindowIsReincludedDespiteAppExclusion() {
        // The research results window registers its number as capturable, so it is
        // re-included and stays IN the screenshot even though the whole Clawdy app
        // is excluded.
        let shouldReinclude = CompanionScreenCaptureUtility.shouldReincludeOwnAppWindowInCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 42,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: [42]
        )
        #expect(shouldReinclude == true)
    }

    @Test func otherAppWindowIsNeverReincludedRegardlessOfCapturableSet() {
        // Another app's window is the user's content — it's captured by default and
        // is never part of our own re-inclusion set, even if a number matches.
        let shouldReinclude = CompanionScreenCaptureUtility.shouldReincludeOwnAppWindowInCapture(
            windowOwningBundleIdentifier: "com.apple.Safari",
            windowNumber: 42,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: [42]
        )
        #expect(shouldReinclude == false)
    }

    @Test func onlyTheRegisteredResultsWindowIsReincludedAmongOwnWindows() {
        // With the results window (7) registered, a sibling own-app chrome window
        // (8) is NOT re-included — the exemption is per-window, not app-wide.
        let capturable: Set<CGWindowID> = [7]
        let resultsReincluded = CompanionScreenCaptureUtility.shouldReincludeOwnAppWindowInCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 7,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: capturable
        )
        let chromeReincluded = CompanionScreenCaptureUtility.shouldReincludeOwnAppWindowInCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 8,
            ownAppBundleIdentifier: ownBundle,
            capturableOwnWindowNumbers: capturable
        )
        #expect(resultsReincluded == true)
        #expect(chromeReincluded == false)
    }

    @Test func nothingIsReincludedWhenOwnBundleUnknownEvenIfCapturableSet() {
        // If we can't determine our own bundle id we can't classify a window as
        // ours, so we never re-include it (mirrors windowBelongsToOwnApp).
        let shouldReinclude = CompanionScreenCaptureUtility.shouldReincludeOwnAppWindowInCapture(
            windowOwningBundleIdentifier: ownBundle,
            windowNumber: 42,
            ownAppBundleIdentifier: nil,
            capturableOwnWindowNumbers: []
        )
        #expect(shouldReinclude == false)
    }

    // MARK: - cachedShareableContentSatisfiesOwnWindowNeeds (fresh-vs-cached enumeration)
    //
    // The model-capture filter is built from a REUSED SCShareableContent cache (to
    // avoid re-triggering the Sequoia prompt). But that cache can build a WRONG
    // filter when it predates Clawdy's own overlay/results windows. These pin the
    // pure decision for when the cache is safe vs when a FRESH enumeration is
    // required — i.e. when a `.readOnly` overlay would otherwise leak (BLOCKING 1)
    // or a just-opened results window would otherwise be excluded (BLOCKING 2).

    /// Recording Mode OFF and no results window registered → all overlays are `.none`
    /// (excluded by ScreenCaptureKit inherently) and nothing needs re-inclusion, so
    /// ANY cache is safe to reuse — even one that doesn't contain our app.
    @Test func cacheReusedWhenRecordingOffAndNoResultsRegistered() {
        let satisfies = CompanionScreenCaptureUtility.cachedShareableContentSatisfiesOwnWindowNeeds(
            recordingModeEnabled: false,
            registeredCapturableWindowNumbers: [],
            cachedContentContainsOwnApplication: false,
            cachedWindowNumbers: []
        )
        #expect(satisfies == true)
    }

    /// BLOCKING 1 — Recording Mode ON but the cache was enumerated when Clawdy had no
    /// shareable window (own app absent). App-level exclusion couldn't resolve our
    /// app, so a `.readOnly` overlay would LEAK. The cache is NOT safe → refresh.
    @Test func freshEnumerationRequiredWhenRecordingOnAndCacheLacksOwnApp() {
        let satisfies = CompanionScreenCaptureUtility.cachedShareableContentSatisfiesOwnWindowNeeds(
            recordingModeEnabled: true,
            registeredCapturableWindowNumbers: [],
            cachedContentContainsOwnApplication: false,
            cachedWindowNumbers: []
        )
        #expect(satisfies == false)
    }

    /// Recording Mode ON with the cache already containing our app → app-exclusion can
    /// resolve and exclude every Clawdy overlay, so the cache is safe to reuse (no
    /// re-prompt on subsequent captures once the app is present).
    @Test func cacheReusedWhenRecordingOnAndCacheHasOwnApp() {
        let satisfies = CompanionScreenCaptureUtility.cachedShareableContentSatisfiesOwnWindowNeeds(
            recordingModeEnabled: true,
            registeredCapturableWindowNumbers: [],
            cachedContentContainsOwnApplication: true,
            cachedWindowNumbers: []
        )
        #expect(satisfies == true)
    }

    /// BLOCKING 2 — a results window (7) is registered as capturable but the cache
    /// (enumerated before it opened) has no SCWindow for it. `exceptingWindows`
    /// couldn't re-include it, so it would be excluded from the MODEL capture. Even
    /// with Recording Mode off, the cache is NOT safe → refresh.
    @Test func freshEnumerationRequiredWhenResultsWindowMissingFromCache() {
        let satisfies = CompanionScreenCaptureUtility.cachedShareableContentSatisfiesOwnWindowNeeds(
            recordingModeEnabled: false,
            registeredCapturableWindowNumbers: [7],
            cachedContentContainsOwnApplication: true,
            cachedWindowNumbers: [] // results window 7 not yet enumerated
        )
        #expect(satisfies == false)
    }

    /// A registered results window (7) that IS present in the cache (along with our
    /// app) can be re-included → the cache is safe to reuse.
    @Test func cacheReusedWhenResultsWindowPresentInCache() {
        let satisfies = CompanionScreenCaptureUtility.cachedShareableContentSatisfiesOwnWindowNeeds(
            recordingModeEnabled: false,
            registeredCapturableWindowNumbers: [7],
            cachedContentContainsOwnApplication: true,
            cachedWindowNumbers: [7, 42]
        )
        #expect(satisfies == true)
    }

    /// If ANY registered results window is missing from the cache, refresh — the
    /// subset check must cover every registered number, not just one.
    @Test func freshEnumerationRequiredWhenAnyRegisteredResultsWindowMissing() {
        let satisfies = CompanionScreenCaptureUtility.cachedShareableContentSatisfiesOwnWindowNeeds(
            recordingModeEnabled: true,
            registeredCapturableWindowNumbers: [7, 8],
            cachedContentContainsOwnApplication: true,
            cachedWindowNumbers: [7] // 8 missing
        )
        #expect(satisfies == false)
    }

    /// A registered results window with the app also present, under Recording Mode
    /// ON, is fully satisfiable → reuse.
    @Test func cacheReusedWhenRecordingOnAndResultsWindowPresent() {
        let satisfies = CompanionScreenCaptureUtility.cachedShareableContentSatisfiesOwnWindowNeeds(
            recordingModeEnabled: true,
            registeredCapturableWindowNumbers: [7],
            cachedContentContainsOwnApplication: true,
            cachedWindowNumbers: [7]
        )
        #expect(satisfies == true)
    }

    // MARK: - Model-capture filter-input derivation (app-excluded + results re-included)

    /// The full filter-input derivation over an enumerated window list: given Clawdy's
    /// own chrome window, the registered results window, and another app's window, the
    /// `exceptingWindows` set (from `shouldReincludeOwnAppWindowInCapture`) must be
    /// EXACTLY the results window — our chrome stays excluded by the app-level
    /// exclusion, and the other app's window is captured without needing an exception.
    /// This is the pure stand-in for the (un-unit-testable) live SCK filter build.
    @Test func filterInputReincludesOnlyRegisteredResultsWindowAmongEnumeratedWindows() {
        // (owningBundleID, windowNumber) — simulates an SCShareableContent.windows list.
        let enumeratedWindows: [(String?, CGWindowID)] = [
            (ownBundle, 100),           // our transient chrome (overlay/pill) — must stay excluded
            (ownBundle, 200),           // our results window — registered, must be re-included
            ("com.apple.Safari", 300),  // another app's window — captured, no exception needed
            (nil, 400),                 // unknown owner — never ours
        ]
        let registeredCapturableWindowNumbers: Set<CGWindowID> = [200]

        let exceptingWindowNumbers = Set(
            enumeratedWindows
                .filter { owningBundleID, windowNumber in
                    CompanionScreenCaptureUtility.shouldReincludeOwnAppWindowInCapture(
                        windowOwningBundleIdentifier: owningBundleID,
                        windowNumber: windowNumber,
                        ownAppBundleIdentifier: ownBundle,
                        capturableOwnWindowNumbers: registeredCapturableWindowNumbers
                    )
                }
                .map { _, windowNumber in windowNumber }
        )

        // Only the registered results window (200) is re-included.
        #expect(exceptingWindowNumbers == [200])
        // Our chrome (100) is NOT re-included → it stays excluded by app-exclusion.
        #expect(exceptingWindowNumbers.contains(100) == false)
        // Another app's window (300) is never part of our own re-inclusion set.
        #expect(exceptingWindowNumbers.contains(300) == false)

        // And the enumeration contains our app (so app-level exclusion can resolve it),
        // which is the precondition the cache-sufficiency check enforces.
        let ownAppIsPresent = enumeratedWindows.contains { owningBundleID, _ in
            CompanionScreenCaptureUtility.windowBelongsToOwnApp(
                windowOwningBundleIdentifier: owningBundleID,
                ownAppBundleIdentifier: ownBundle
            )
        }
        #expect(ownAppIsPresent == true)
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
