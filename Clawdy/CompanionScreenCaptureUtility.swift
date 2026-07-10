//
//  CompanionScreenCaptureUtility.swift
//  Clawdy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//
//  IMPORTANT (macOS Sequoia): the system prompt "Clawdy would like to record
//  this computer's screen and audio" is fired by macOS whenever an app accesses
//  SCShareableContent DIRECTLY (i.e. not through the SCContentSharingPicker).
//  On Sequoia that prompt can recur on every access. Clawdy intentionally does
//  NOT use the picker (faithful Clawdy behavior is a silent on-demand screenshot
//  of all displays), so the only way to keep captures silent after the one-time
//  Screen Recording grant is to enumerate SCShareableContent ONCE and reuse that
//  snapshot for subsequent captures, re-enumerating only when the set of
//  connected displays actually changes. Capturing pixels via
//  SCScreenshotManager.captureImage with a previously-obtained filter does not
//  re-trigger the prompt; re-enumerating SCShareableContent does.
//

import AppKit
import ScreenCaptureKit

/// A cheap, silent snapshot of one display's identity and geometry. Used as the
/// cache key for the shareable-content enumeration so the cache is invalidated
/// not just when displays are added/removed, but also when an existing display
/// changes resolution, origin/arrangement, rotation, or mirroring — any of which
/// would otherwise leave us capturing with stale geometry.
struct CompanionDisplayGeometry: Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
}

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    // MARK: - Encode tuning (sent to the LLM)

    /// Longest-edge pixel budget for the screenshots sent to the model. A round-2
    /// latency investigation proved the model reads the screen IDENTICALLY at
    /// 800px as at the old 1280px (it correctly identified the same on-screen
    /// app/content both ways), while the smaller image roughly thirds the base64
    /// payload (~264KB → ~81KB per display) and the upload latency that rides on
    /// it. We still encode EVERY display so multi-monitor context is preserved.
    static let screenshotMaxLongestEdgePixels = 800

    /// JPEG compression quality (0...1) for the screenshots sent to the model.
    /// Dropped from 0.8 to 0.5 alongside the smaller dimensions — the same
    /// investigation showed comprehension is unchanged at this quality.
    static let screenshotJPEGCompressionQuality: CGFloat = 0.5

    /// The last enumerated shareable content. Reused across captures so repeated
    /// push-to-talk presses don't re-enter the SCShareableContent enumeration
    /// that re-triggers the macOS Sequoia screen-recording prompt.
    private static var cachedShareableContent: SCShareableContent?

    /// The display identity + geometry at the time `cachedShareableContent` was
    /// enumerated. When the live geometry differs we must re-enumerate (and
    /// accept one prompt) because the cached SCDisplay objects are stale.
    private static var cachedShareableContentDisplayGeometry: [CompanionDisplayGeometry]?

    /// CGWindowIDs of THIS app's own windows that should REMAIN visible to the
    /// screenshot despite the blanket self-exclusion of own-app windows below.
    /// The only member is the research RESULTS window (the WKWebView showing the
    /// generated deliverable): it is content the user explicitly opened and wants
    /// Clawdy to look at when they hold push-to-talk to iterate on it, unlike the
    /// transient chrome (overlays, pills, panels) which must never leak. The
    /// `ResearchResultsWindowController` registers/unregisters its window here as
    /// the results window is shown/hidden.
    ///
    /// This is shared across actors: it's MUTATED on the main actor by
    /// `ResearchResultsWindowController` (register/unregister on show/hide/close)
    /// and READ off the main actor by the capture path while building the
    /// `SCContentFilter`. So it lives behind `capturableWindowsLock` and is only
    /// ever touched through the three synchronized accessors below — never
    /// directly. `nonisolated` so those accessors are reachable from the capture
    /// path without a main-actor hop (which could deadlock it).
    nonisolated(unsafe) private static var capturableOwnWindowNumbers: Set<CGWindowID> = []
    nonisolated private static let capturableWindowsLock = NSLock()

    /// Marks `windowNumber` as capturable (exempt from own-app exclusion). Safe to
    /// call from any thread/actor.
    nonisolated static func registerCapturableWindow(_ windowNumber: CGWindowID) {
        capturableWindowsLock.lock()
        defer { capturableWindowsLock.unlock() }
        capturableOwnWindowNumbers.insert(windowNumber)
    }

    /// Removes `windowNumber` from the capturable set. Safe to call from any
    /// thread/actor.
    nonisolated static func unregisterCapturableWindow(_ windowNumber: CGWindowID) {
        capturableWindowsLock.lock()
        defer { capturableWindowsLock.unlock() }
        capturableOwnWindowNumbers.remove(windowNumber)
    }

    /// Returns a point-in-time COPY of the capturable set. The capture path reads
    /// exactly one snapshot at the start of building its content filter and uses
    /// that immutable copy for the whole capture, so a concurrent register/
    /// unregister can never tear the read mid-capture. Safe to call from any
    /// thread/actor.
    nonisolated static func capturableWindowsSnapshot() -> Set<CGWindowID> {
        capturableWindowsLock.lock()
        defer { capturableWindowsLock.unlock() }
        return capturableOwnWindowNumbers
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await shareableContentReusingCacheWhenDisplaysUnchanged()

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude the app's own windows (overlays, pills, panels) so the AI sees
        // only the user's content — EXCEPT the research results window, which the
        // user explicitly opened and wants Clawdy to see. That window is exempted
        // via `capturableOwnWindowNumbers` so it stays in the screenshot.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        // Read ONE atomic snapshot of the capturable set for the whole capture, so a
        // concurrent register/unregister on the main actor can't tear this read.
        let capturableWindowsForThisCapture = capturableWindowsSnapshot()
        let ownAppWindows = content.windows.filter { window in
            shouldExcludeOwnAppWindowFromCapture(
                windowOwningBundleIdentifier: window.owningApplication?.bundleIdentifier,
                windowNumber: window.windowID,
                ownAppBundleIdentifier: ownBundleIdentifier,
                capturableOwnWindowNumbers: capturableWindowsForThisCapture
            )
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Resolve each display's AppKit-coordinate frame, then order the displays
        // so the cursor's screen comes first (primary focus for the AI).
        let displayFrames = content.displays.map { display -> CGRect in
            nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
        }
        let cursorFirstOrder = displayOrderPuttingCursorScreenFirst(
            displayFrames: displayFrames,
            mouseLocation: mouseLocation
        )
        let sortedDisplays = cursorFirstOrder.map { content.displays[$0] }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let targetDimensions = screenshotPixelDimensions(
                displayWidthInPixels: display.width,
                displayHeightInPixels: display.height,
                maxLongestEdgePixels: screenshotMaxLongestEdgePixels
            )
            configuration.width = targetDimensions.width
            configuration.height = targetDimensions.height

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: screenshotJPEGCompressionQuality]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Returns shareable content, reusing the cached snapshot when the set of
    /// connected displays is unchanged. Re-enumerating SCShareableContent is what
    /// re-triggers the macOS Sequoia screen-recording prompt, so we only do it
    /// when we have no cache or the display configuration has actually changed.
    private static func shareableContentReusingCacheWhenDisplaysUnchanged() async throws -> SCShareableContent {
        let currentDisplayGeometry = currentDisplayGeometry()

        if let cachedShareableContent,
           !shouldRefreshShareableContent(
               cachedDisplayGeometry: cachedShareableContentDisplayGeometry,
               currentDisplayGeometry: currentDisplayGeometry
           ) {
            return cachedShareableContent
        }

        let freshContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedShareableContent = freshContent
        // Record the geometry from the SAME silent NSScreen source we compare
        // against, so both sides of the cache check live in one coordinate space.
        cachedShareableContentDisplayGeometry = currentDisplayGeometry
        return freshContent
    }

    /// The identity + geometry of all currently-connected displays, read cheaply
    /// (and silently — no TCC prompt, no SCShareableContent enumeration) from
    /// AppKit's NSScreen list.
    private static func currentDisplayGeometry() -> [CompanionDisplayGeometry] {
        NSScreen.screens
            .compactMap { screen in
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    return nil
                }
                return CompanionDisplayGeometry(displayID: displayID, frame: screen.frame)
            }
    }

    // MARK: - Pure helpers (no system state; unit-tested)

    /// Computes the target screenshot pixel dimensions for a display, scaling its
    /// native pixel size down so the LONGEST edge equals `maxLongestEdgePixels`
    /// while preserving aspect ratio. Pulled out as a pure function so the encode
    /// sizing is unit-testable without a live capture.
    nonisolated static func screenshotPixelDimensions(
        displayWidthInPixels: Int,
        displayHeightInPixels: Int,
        maxLongestEdgePixels: Int
    ) -> (width: Int, height: Int) {
        let aspectRatio = CGFloat(displayWidthInPixels) / CGFloat(displayHeightInPixels)
        if displayWidthInPixels >= displayHeightInPixels {
            return (maxLongestEdgePixels, Int(CGFloat(maxLongestEdgePixels) / aspectRatio))
        } else {
            return (Int(CGFloat(maxLongestEdgePixels) * aspectRatio), maxLongestEdgePixels)
        }
    }

    /// Whether a window enumerated by ScreenCaptureKit belongs to this app and
    /// should therefore be excluded from the screenshot we send to the model.
    nonisolated static func windowBelongsToOwnApp(
        windowOwningBundleIdentifier: String?,
        ownAppBundleIdentifier: String?
    ) -> Bool {
        guard let ownAppBundleIdentifier else { return false }
        return windowOwningBundleIdentifier == ownAppBundleIdentifier
    }

    /// Whether a window enumerated by ScreenCaptureKit should be EXCLUDED from the
    /// screenshot sent to the model. We exclude the app's own transient chrome
    /// (overlays, pills, panels) so it never leaks into the image, but keep a
    /// window whose number is listed in `capturableOwnWindowNumbers` — the research
    /// results window the user opened and explicitly wants Clawdy to look at.
    /// Windows belonging to OTHER apps are never excluded here.
    nonisolated static func shouldExcludeOwnAppWindowFromCapture(
        windowOwningBundleIdentifier: String?,
        windowNumber: CGWindowID,
        ownAppBundleIdentifier: String?,
        capturableOwnWindowNumbers: Set<CGWindowID>
    ) -> Bool {
        guard windowBelongsToOwnApp(
            windowOwningBundleIdentifier: windowOwningBundleIdentifier,
            ownAppBundleIdentifier: ownAppBundleIdentifier
        ) else {
            return false
        }
        // Our own window — exclude it unless it's the exempted results window.
        return !capturableOwnWindowNumbers.contains(windowNumber)
    }

    /// Decides whether the cached SCShareableContent snapshot must be discarded
    /// and re-enumerated. We refresh when there is no recorded geometry yet, or
    /// when the live displays differ from the cached ones in identity OR geometry
    /// (count, resolution/size, origin/arrangement, rotation, or mirroring — all
    /// of which surface as a changed frame). Order is ignored because both sides
    /// are sorted by display ID before comparison.
    nonisolated static func shouldRefreshShareableContent(
        cachedDisplayGeometry: [CompanionDisplayGeometry]?,
        currentDisplayGeometry: [CompanionDisplayGeometry]
    ) -> Bool {
        guard let cachedDisplayGeometry else { return true }
        let sortedCached = cachedDisplayGeometry.sorted { $0.displayID < $1.displayID }
        let sortedCurrent = currentDisplayGeometry.sorted { $0.displayID < $1.displayID }
        return sortedCached != sortedCurrent
    }

    /// Returns indices into `displayFrames` ordered so that any display whose
    /// frame contains the cursor comes first (the AI's primary focus), with the
    /// relative order of the remaining displays preserved (stable).
    nonisolated static func displayOrderPuttingCursorScreenFirst(
        displayFrames: [CGRect],
        mouseLocation: CGPoint
    ) -> [Int] {
        let allDisplayIndices = Array(displayFrames.indices)
        let cursorScreenIndices = allDisplayIndices.filter { displayFrames[$0].contains(mouseLocation) }
        let otherScreenIndices = allDisplayIndices.filter { !displayFrames[$0].contains(mouseLocation) }
        return cursorScreenIndices + otherScreenIndices
    }
}
