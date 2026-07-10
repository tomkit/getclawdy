//
//  WindowPositionManager.swift
//  Clawdy
//
//  Manages positioning the app window on the right edge of the screen
//  and shrinking overlapping windows from other apps via the Accessibility API.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit

enum PermissionRequestPresentationDestination: Equatable {
    case alreadyGranted
    case systemPrompt
    case systemSettings
}

@MainActor
class WindowPositionManager {
    private static var hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = false
    private static var hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = false
    private static let hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"

    /// Returns true when the Mac currently has more than one connected display.
    /// Uses AppKit's screen list, which is available without ScreenCaptureKit's
    /// shareable-content permission prompt.
    static func currentMacHasMultipleDisplays() -> Bool {
        NSScreen.screens.count > 1
    }

    // MARK: - Accessibility Permission

    /// Source of the accessibility-trust reading. Defaults to the live
    /// `AXIsProcessTrusted()` call but is overridable so the re-check / transition
    /// logic can be exercised in unit tests without the real system call.
    static var accessibilityTrustProvider: () -> Bool = { AXIsProcessTrusted() }

    /// Returns true if the app has Accessibility permission.
    ///
    /// NOTE: `AXIsProcessTrusted()` caches the trust result inside the process and
    /// is only refreshed when libAccessibility receives the
    /// `com.apple.accessibility.api` distributed notification. For ad-hoc / locally
    /// signed builds that refresh can be unreliable, so a grant made in System
    /// Settings may not be reflected until the app is relaunched. CompanionManager
    /// therefore re-checks this on the accessibility notification and on app
    /// reactivation in addition to polling, and the UI tells the user to relaunch.
    static func hasAccessibilityPermission() -> Bool {
        accessibilityTrustProvider()
    }

    /// Pure decision: should the global push-to-talk hotkey monitor be running
    /// for the given accessibility-trust reading? Extracted so the re-check side
    /// effect is unit-testable independent of the live AX call.
    static func shouldRunPushToTalkMonitor(forAccessibilityTrusted isTrusted: Bool) -> Bool {
        isTrusted
    }

    /// Pure decision: does this reading represent a fresh accessibility grant
    /// (a false → true transition) that should be reported once to analytics?
    static func accessibilityPermissionWasJustGranted(
        previousIsTrusted: Bool,
        currentIsTrusted: Bool
    ) -> Bool {
        !previousIsTrusted && currentIsTrusted
    }

    /// Presents exactly one permission path per tap: the system prompt on the first
    /// attempt, then System Settings on later attempts after macOS has already shown
    /// its one-time alert.
    @discardableResult
    static func requestAccessibilityPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasAccessibilityPermission(),
            hasAttemptedSystemPrompt: hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .systemSettings:
            openAccessibilitySettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Accessibility pane.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveals the running app bundle in Finder so the user can drag it into
    /// the Accessibility list if it doesn't appear automatically.
    static func revealAppInFinder() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    // MARK: - Screen Recording Permission

    /// Returns true if Screen Recording permission is granted.
    static func hasScreenRecordingPermission() -> Bool {
        let hasScreenRecordingPermissionNow = CGPreflightScreenCaptureAccess()
        if hasScreenRecordingPermissionNow {
            UserDefaults.standard.set(true, forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        }
        return hasScreenRecordingPermissionNow
    }

    /// The LIVE, side-effect-free Screen Recording status straight from the
    /// system. Unlike `hasScreenRecordingPermission()` it does NOT write the
    /// sticky "previously confirmed" flag, and unlike
    /// `shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch()` it does
    /// NOT fall back to that flag.
    ///
    /// The permission panel's Screen Recording row keys its "Grant" affordance
    /// off this reading so the request that actually registers the app
    /// (the SCShareableContent registration) stays reachable whenever the
    /// permission is genuinely revoked — even if a stale sticky flag survives
    /// from a prior grant. Without this, after a TCC reset the row would read
    /// "Granted" from the stale flag, hide the button, and leave the user with
    /// no way to add Clawdy to the Screen Recording list (a catch-22, since the
    /// gate blocks the only other capture path too).
    static func hasLiveScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Pure decision for the permission panel: should the Screen Recording row
    /// present its "Grant" affordance (which fires the SCShareableContent registration)?
    /// Keys off the LIVE reading only, so a stale "previously confirmed" flag can
    /// never suppress the request when the permission is genuinely not granted.
    static func shouldOfferScreenRecordingRequest(hasLivePermission: Bool) -> Bool {
        !hasLivePermission
    }

    /// The SINGLE screen-recording registration/prompt trigger. Performing a real
    /// ScreenCaptureKit `SCShareableContent` enumeration BOTH raises the genuine
    /// "Clawdy would like to record this computer's screen" TCC prompt AND
    /// registers Clawdy in the Screen Recording list. This is the SOLE prompt
    /// path — the former `CGRequestScreenCaptureAccess()` request call has been
    /// removed (both `SCShareableContent` and `CGRequestScreenCaptureAccess()`
    /// map to the same `kTCCServiceScreenCapture` service, so calling both simply
    /// prompted the user twice at launch). `CGPreflightScreenCaptureAccess()`
    /// remains ONLY for the silent status read used by the panel row and the
    /// anti-flap gate; it never prompts and never registers the app.
    ///
    /// Overridable so tests can assert it fires exactly when expected (and never
    /// from the ~1.5s poll) with an injected spy, without touching the live
    /// system or needing a real display. The default performs a minimal
    /// `SCShareableContent` enumeration, which is enough to raise the prompt and
    /// list the app; CompanionManager overrides it at startup with its richer
    /// handler that additionally persists the grant and reveals the overlay.
    static var screenRecordingRegistrationTrigger: () -> Void = {
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Fires the ONE SCShareableContent registration request and records that the
    /// one-per-launch prompt has now been shown, so any later attempt this launch
    /// (e.g. the panel "Grant" button) routes to the Settings deep-link instead of
    /// re-prompting. This is the single shared entry point both the proactive
    /// at-launch registration and the panel "Grant" button funnel through, so
    /// EXACTLY ONE screen-recording prompt fires per launch across the whole app.
    static func triggerScreenRecordingRegistration() {
        hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = true
        screenRecordingRegistrationTrigger()
    }

    /// Pure decision: should the app proactively issue the interactive Screen
    /// Recording request at launch/onboarding? True only when the permission is
    /// genuinely ungranted AND the interactive request hasn't already been issued
    /// this launch — so a cold-reset install self-registers and pops the real
    /// prompt on its own, but the ~1.5s poll never re-issues it (which would spam
    /// the user with repeated interactive prompts).
    static func shouldProactivelyRequestScreenRecordingAtLaunch(
        hasLivePermission: Bool,
        hasAlreadyRequestedThisLaunch: Bool
    ) -> Bool {
        !hasLivePermission && !hasAlreadyRequestedThisLaunch
    }

    /// Returns true when the app should proceed with session launch without showing
    /// the permission gate again. This intentionally falls back to the last known
    /// granted state because CGPreflightScreenCaptureAccess() can sometimes return a
    /// false negative even though the user has already approved the app.
    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() -> Bool {
        shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: hasScreenRecordingPermission(),
            hasPreviouslyConfirmedScreenRecordingPermission: UserDefaults.standard.bool(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        )
    }

    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
        hasScreenRecordingPermissionNow: Bool,
        hasPreviouslyConfirmedScreenRecordingPermission: Bool
    ) -> Bool {
        hasScreenRecordingPermissionNow || hasPreviouslyConfirmedScreenRecordingPermission
    }

    static func clearPreviouslyConfirmedScreenRecordingPermission() {
        UserDefaults.standard.removeObject(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
    }

    /// Presents exactly one Screen Recording path per attempt: the SINGLE
    /// SCShareableContent registration prompt on the first attempt this launch,
    /// then the System Settings deep-link on later attempts (macOS shows its TCC
    /// alert only once per launch, so re-firing the enumeration afterward would
    /// silently do nothing useful and just fight the Settings window). Both the
    /// panel "Grant" button and the proactive at-launch registration funnel
    /// through the shared `triggerScreenRecordingRegistration()` on `.systemPrompt`.
    @discardableResult
    static func requestScreenRecordingPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasScreenRecordingPermission(),
            hasAttemptedSystemPrompt: hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch
        )

        presentScreenRecordingPermission(for: presentationDestination)
        return presentationDestination
    }

    /// Performs the presentation for an already-decided destination: fires the
    /// SINGLE SCShareableContent registration trigger on `.systemPrompt`, opens the
    /// Settings deep-link on `.systemSettings`, and does nothing when already
    /// granted. Split out from the CGPreflight-reading
    /// `requestScreenRecordingPermission()` so the trigger/Settings routing is
    /// unit-testable with an injected registration spy and no live status read.
    static func presentScreenRecordingPermission(for destination: PermissionRequestPresentationDestination) {
        switch destination {
        case .alreadyGranted:
            break
        case .systemPrompt:
            triggerScreenRecordingRegistration()
        case .systemSettings:
            openScreenRecordingSettings()
        }
    }

    /// Opens System Settings to the Screen Recording pane.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func permissionRequestPresentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        if hasPermissionNow {
            return .alreadyGranted
        }

        if hasAttemptedSystemPrompt {
            return .systemSettings
        }

        return .systemPrompt
    }

    // MARK: - Window Positioning

    /// Positions the app's main window pinned to the right edge of the screen
    /// that contains the given display ID, vertically centered.
    static func pinMainWindowToRight(onDisplayID displayID: CGDirectDisplayID?) {
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }

        // Find the NSScreen matching the selected display, or fall back to the screen
        // the window is currently on, or finally the main screen.
        let targetScreen: NSScreen
        if let displayID,
           let matchingScreen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            targetScreen = matchingScreen
        } else if let currentScreen = mainWindow.screen {
            targetScreen = currentScreen
        } else if let mainScreen = NSScreen.main {
            targetScreen = mainScreen
        } else {
            return
        }

        let visibleFrame = targetScreen.visibleFrame
        let windowSize = mainWindow.frame.size

        let x = visibleFrame.maxX - windowSize.width
        let y = visibleFrame.minY + (visibleFrame.height - windowSize.height) / 2.0

        mainWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Shrink Overlapping Windows

    /// Checks if the frontmost (non-self) app's focused window overlaps our app window
    /// on the same monitor and, if so, shrinks it so it no longer overlaps.
    /// Only operates if both windows are on the same screen as `targetDisplayID`.
    static func shrinkOverlappingFocusedWindow(targetDisplayID: CGDirectDisplayID?) {
        guard hasAccessibilityPermission() else { return }
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        guard let mainScreen = mainWindow.screen else { return }

        // Only operate if the main window is on the target display
        if let targetDisplayID, mainScreen.displayID != targetDisplayID {
            return
        }

        // Get the frontmost application that isn't us
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get the focused window of the front app
        var focusedWindowValue: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)
        guard focusedResult == .success, let focusedWindow = focusedWindowValue else { return }

        // Get position and size of the focused window
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return
        }

        var otherPosition = CGPoint.zero
        var otherSize = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &otherPosition),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &otherSize) else {
            return
        }

        // The other window's frame in screen coordinates (top-left origin from AX API).
        // Convert to check if it's on the same screen as our window.
        let otherRight = otherPosition.x + otherSize.width
        let ourLeft = mainWindow.frame.origin.x

        // Check that the other window is on the same screen by verifying its origin
        // falls within the target screen's bounds.
        let screenFrame = mainScreen.frame
        let otherCenterX = otherPosition.x + otherSize.width / 2
        // AX uses top-left origin, NSScreen uses bottom-left. Convert AX Y to NSScreen Y.
        let otherNSScreenY = screenFrame.maxY - otherPosition.y - otherSize.height
        let otherCenterY = otherNSScreenY + otherSize.height / 2
        let otherCenter = NSPoint(x: otherCenterX, y: otherCenterY)

        guard screenFrame.contains(otherCenter) else { return }

        // If the other window's right edge extends past our window's left edge, shrink it.
        if otherRight > ourLeft {
            let newWidth = ourLeft - otherPosition.x
            guard newWidth > 200 else { return } // Don't shrink too small

            var newSize = CGSize(width: newWidth, height: otherSize.height)
            guard let newSizeValue = AXValueCreate(.cgSize, &newSize) else { return }
            AXUIElementSetAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, newSizeValue)
        }
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
