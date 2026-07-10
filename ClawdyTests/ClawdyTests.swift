//
//  ClawdyTests.swift
//  ClawdyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
@testable import Clawdy

@MainActor
struct ClawdyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    // The panel's "Grant" affordance must key off the LIVE reading, never the
    // sticky "previously confirmed" flag. This is what breaks the post-TCC-reset
    // catch-22: after a reset the live reading is false but the sticky flag can
    // still be true, and if the button were hidden the user could never re-trigger
    // the SCShareableContent registration to add the app to the list.
    @Test func genuinelyRevokedScreenRecordingStillOffersTheRequest() async throws {
        #expect(WindowPositionManager.shouldOfferScreenRecordingRequest(hasLivePermission: false))
    }

    @Test func liveGrantedScreenRecordingHidesTheRequest() async throws {
        #expect(!WindowPositionManager.shouldOfferScreenRecordingRequest(hasLivePermission: true))
    }

    // A genuinely-ungranted reading, on the first attempt of the session, must
    // route to the system prompt — i.e. actually fire the SCShareableContent
    // registration — regardless of any stale sticky state, so the app registers
    // itself in the Screen Recording list from a cold TCC reset.
    // `requestScreenRecordingPermission()` feeds the LIVE reading into this same
    // decision, so `.systemPrompt` here means the request path fires the
    // registration rather than being skipped.
    @Test func ungrantedFirstAttemptRequestsScreenCaptureAccess() async throws {
        let ungrantedLiveReading = false
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: ungrantedLiveReading,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    // The SOLE prompt path is the SCShareableContent registration seam: the
    // `.systemPrompt` destination must fire it exactly once, and never on
    // `.alreadyGranted`. Together with the removal of the CGRequestScreenCaptureAccess()
    // requester, this proves the ScreenCaptureKit seam is the single trigger and
    // the CoreGraphics prompt path is gone.
    @Test func systemPromptDestinationFiresTheSingleSCKRegistrationTrigger() async throws {
        let originalTrigger = WindowPositionManager.screenRecordingRegistrationTrigger
        defer { WindowPositionManager.screenRecordingRegistrationTrigger = originalTrigger }

        var registrationTriggerCount = 0
        WindowPositionManager.screenRecordingRegistrationTrigger = {
            registrationTriggerCount += 1
        }

        WindowPositionManager.presentScreenRecordingPermission(for: .systemPrompt)
        #expect(registrationTriggerCount == 1)

        // Already granted never re-fires the registration.
        WindowPositionManager.presentScreenRecordingPermission(for: .alreadyGranted)
        #expect(registrationTriggerCount == 1)
    }

    // MARK: - Proactive Screen Recording Registration

    // The pure once-at-launch decision: proactively register only when the
    // permission is genuinely ungranted AND we haven't already asked this launch.
    @Test func proactiveRequestFiresOnlyWhenUngrantedAndNotYetAsked() async throws {
        #expect(WindowPositionManager.shouldProactivelyRequestScreenRecordingAtLaunch(
            hasLivePermission: false, hasAlreadyRequestedThisLaunch: false))
        #expect(!WindowPositionManager.shouldProactivelyRequestScreenRecordingAtLaunch(
            hasLivePermission: true, hasAlreadyRequestedThisLaunch: false))
        #expect(!WindowPositionManager.shouldProactivelyRequestScreenRecordingAtLaunch(
            hasLivePermission: false, hasAlreadyRequestedThisLaunch: true))
        #expect(!WindowPositionManager.shouldProactivelyRequestScreenRecordingAtLaunch(
            hasLivePermission: true, hasAlreadyRequestedThisLaunch: true))
    }

    // End-to-end guard: when ungranted, the proactive path fires the SINGLE
    // SCShareableContent registration EXACTLY ONCE, and a later poll-driven attempt
    // (same ungranted reading) is a no-op — proving it never loops. The registration
    // runs through the injectable SCK seam, never a CoreGraphics prompt.
    @Test func proactiveRegistrationFiresOnceAndNeverLoops() async throws {
        let originalTrigger = WindowPositionManager.screenRecordingRegistrationTrigger
        defer { WindowPositionManager.screenRecordingRegistrationTrigger = originalTrigger }

        var registrationTriggerCount = 0
        WindowPositionManager.screenRecordingRegistrationTrigger = {
            registrationTriggerCount += 1
        }

        let companionManager = CompanionManager()

        // First launch/onboarding pass, ungranted: fires the SCK registration.
        let firstIssued = companionManager.requestScreenRecordingRegistrationIfUngranted(hasLivePermission: false)
        #expect(firstIssued)
        #expect(registrationTriggerCount == 1)

        // Simulated subsequent poll tick, still ungranted: must NOT fire again.
        let secondIssued = companionManager.requestScreenRecordingRegistrationIfUngranted(hasLivePermission: false)
        #expect(!secondIssued)
        #expect(registrationTriggerCount == 1)
    }

    // When the permission is already granted, the proactive path never issues a
    // registration request at all.
    @Test func proactiveRegistrationDoesNothingWhenAlreadyGranted() async throws {
        let originalTrigger = WindowPositionManager.screenRecordingRegistrationTrigger
        defer { WindowPositionManager.screenRecordingRegistrationTrigger = originalTrigger }

        var registrationTriggerCount = 0
        WindowPositionManager.screenRecordingRegistrationTrigger = {
            registrationTriggerCount += 1
        }

        let companionManager = CompanionManager()
        let issued = companionManager.requestScreenRecordingRegistrationIfUngranted(hasLivePermission: true)

        #expect(!issued)
        #expect(registrationTriggerCount == 0)
    }

    // Under XCTest the proactive launch path must SKIP the real system-prompting
    // side effect (the SCShareableContent registration that pops the Screen
    // Recording TCC prompt), because the test bundle hosts the real app and runs
    // this launch path on every `xcodebuild test`. Not under tests, the request
    // must still fire when the permission is ungranted (production is unchanged).
    // Injected here rather than read from the ambient `TestEnvironment` because
    // that detector is unconditionally true inside the test process.
    @Test func proactiveRegistrationIsSuppressedUnderTestsButFiresInProduction() async throws {
        let originalTrigger = WindowPositionManager.screenRecordingRegistrationTrigger
        defer { WindowPositionManager.screenRecordingRegistrationTrigger = originalTrigger }

        var registrationTriggerCount = 0
        WindowPositionManager.screenRecordingRegistrationTrigger = {
            registrationTriggerCount += 1
        }

        // Under tests, ungranted: the interactive request is NOT invoked (no prompt).
        let underTestsManager = CompanionManager()
        let issuedUnderTests = underTestsManager.proactivelyRequestScreenRecordingAccessIfNeeded(
            isRunningUnderTests: true,
            hasLivePermission: false
        )
        #expect(!issuedUnderTests)
        #expect(registrationTriggerCount == 0)

        // Not under tests, ungranted: the interactive request IS invoked exactly once.
        let productionManager = CompanionManager()
        let issuedInProduction = productionManager.proactivelyRequestScreenRecordingAccessIfNeeded(
            isRunningUnderTests: false,
            hasLivePermission: false
        )
        #expect(issuedInProduction)
        #expect(registrationTriggerCount == 1)
    }

    // The ambient detector itself: the test process is XCTest-hosted, so it must
    // read true here. This is what wires the production launch path to skip the
    // real screen-recording side effect during `xcodebuild test`.
    @Test func isRunningUnderTestsIsTrueInsideTheTestHost() async throws {
        #expect(TestEnvironment.isRunningUnderTests)
    }

    // MARK: - Accessibility Re-check Logic

    @Test func pushToTalkMonitorRunsOnlyWhenAccessibilityTrusted() async throws {
        #expect(WindowPositionManager.shouldRunPushToTalkMonitor(forAccessibilityTrusted: true))
        #expect(!WindowPositionManager.shouldRunPushToTalkMonitor(forAccessibilityTrusted: false))
    }

    @Test func accessibilityGrantIsReportedOnlyOnFalseToTrueTransition() async throws {
        // Fresh grant: previously untrusted, now trusted.
        #expect(WindowPositionManager.accessibilityPermissionWasJustGranted(
            previousIsTrusted: false,
            currentIsTrusted: true
        ))
        // Already trusted on both reads — not a fresh grant.
        #expect(!WindowPositionManager.accessibilityPermissionWasJustGranted(
            previousIsTrusted: true,
            currentIsTrusted: true
        ))
        // Still untrusted — not a grant.
        #expect(!WindowPositionManager.accessibilityPermissionWasJustGranted(
            previousIsTrusted: false,
            currentIsTrusted: false
        ))
        // Revoked — not a grant.
        #expect(!WindowPositionManager.accessibilityPermissionWasJustGranted(
            previousIsTrusted: true,
            currentIsTrusted: false
        ))
    }

    @Test func hasAccessibilityPermissionReadsThroughTheInjectableProvider() async throws {
        let originalProvider = WindowPositionManager.accessibilityTrustProvider
        defer { WindowPositionManager.accessibilityTrustProvider = originalProvider }

        WindowPositionManager.accessibilityTrustProvider = { true }
        #expect(WindowPositionManager.hasAccessibilityPermission())

        WindowPositionManager.accessibilityTrustProvider = { false }
        #expect(!WindowPositionManager.hasAccessibilityPermission())
    }

    // MARK: - Permission Monitor Lifecycle

    @Test func startingPermissionPollingTwiceDoesNotLeakRegistrations() async throws {
        let companionManager = CompanionManager()
        #expect(companionManager.livePermissionMonitorRegistrationCount == 0)

        // One start registers the poll timer + the two re-check observers.
        companionManager.startPermissionPolling()
        #expect(companionManager.livePermissionMonitorRegistrationCount == 3)

        // A second start must tear down the first set before registering again —
        // otherwise the earlier timer/observers leak and the count climbs to 6.
        companionManager.startPermissionPolling()
        #expect(companionManager.livePermissionMonitorRegistrationCount == 3)

        // Tearing down once releases everything, leaving nothing registered.
        companionManager.stopPermissionMonitoring()
        #expect(companionManager.livePermissionMonitorRegistrationCount == 0)
    }

    @Test func stoppingPermissionMonitoringIsIdempotent() async throws {
        let companionManager = CompanionManager()
        companionManager.startPermissionPolling()
        #expect(companionManager.livePermissionMonitorRegistrationCount == 3)

        // Repeated teardown must not drive the count negative or double-release.
        companionManager.stopPermissionMonitoring()
        companionManager.stopPermissionMonitoring()
        #expect(companionManager.livePermissionMonitorRegistrationCount == 0)
    }

    // MARK: - Push-To-Talk Start Gating

    @Test func pushToTalkProceedsToRecordingWhenAllPermissionsGranted() async throws {
        let decision = CompanionManager.pushToTalkStartDecision(
            hasAccessibilityPermission: true,
            hasScreenRecordingPermission: true,
            hasMicrophonePermission: true,
            hasScreenContentPermission: true
        )

        // All granted: go straight to recording, never re-run the grant flow.
        #expect(decision == .proceedToRecording)
    }

    @Test func pushToTalkRoutesToOnboardingWhenAnySinglePermissionMissing() async throws {
        // Each permission individually missing must route to onboarding, never record.
        let missingAccessibility = CompanionManager.pushToTalkStartDecision(
            hasAccessibilityPermission: false,
            hasScreenRecordingPermission: true,
            hasMicrophonePermission: true,
            hasScreenContentPermission: true
        )
        let missingScreenRecording = CompanionManager.pushToTalkStartDecision(
            hasAccessibilityPermission: true,
            hasScreenRecordingPermission: false,
            hasMicrophonePermission: true,
            hasScreenContentPermission: true
        )
        let missingMicrophone = CompanionManager.pushToTalkStartDecision(
            hasAccessibilityPermission: true,
            hasScreenRecordingPermission: true,
            hasMicrophonePermission: false,
            hasScreenContentPermission: true
        )
        let missingScreenContent = CompanionManager.pushToTalkStartDecision(
            hasAccessibilityPermission: true,
            hasScreenRecordingPermission: true,
            hasMicrophonePermission: true,
            hasScreenContentPermission: false
        )

        #expect(missingAccessibility == .routeToPermissionOnboarding)
        #expect(missingScreenRecording == .routeToPermissionOnboarding)
        #expect(missingMicrophone == .routeToPermissionOnboarding)
        #expect(missingScreenContent == .routeToPermissionOnboarding)
    }

    @Test func pushToTalkRoutesToOnboardingWhenNothingGranted() async throws {
        let decision = CompanionManager.pushToTalkStartDecision(
            hasAccessibilityPermission: false,
            hasScreenRecordingPermission: false,
            hasMicrophonePermission: false,
            hasScreenContentPermission: false
        )

        #expect(decision == .routeToPermissionOnboarding)
    }

    // MARK: - Onboarding Completion (Start button → main panel)

    /// The intro video + onboarding music were removed. This guards the invariant
    /// the panel relies on: `triggerOnboarding()` (the "Start" button action) must
    /// still flip `hasCompletedOnboarding` to true and reveal the cursor overlay,
    /// so the panel transitions from the welcome/permissions view to the main panel.
    @Test func triggerOnboardingCompletesOnboardingAndShowsOverlay() async throws {
        let onboardingDefaultsKey = "hasCompletedOnboarding"
        let previousOnboardingFlag = UserDefaults.standard.object(forKey: onboardingDefaultsKey)
        defer {
            if let previousOnboardingFlag {
                UserDefaults.standard.set(previousOnboardingFlag, forKey: onboardingDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: onboardingDefaultsKey)
            }
        }

        let companionManager = CompanionManager()
        // Start from a genuine first-run state so we prove the flip happens here.
        companionManager.hasCompletedOnboarding = false
        #expect(companionManager.isOverlayVisible == false)

        companionManager.triggerOnboarding()

        // The flag is set synchronously at the top of triggerOnboarding(), before any
        // (now-removed) video/music work, and the overlay is revealed — so the Start →
        // main-panel transition survives with the video/music gone.
        #expect(companionManager.hasCompletedOnboarding == true)
        #expect(companionManager.isOverlayVisible == true)
    }

}
