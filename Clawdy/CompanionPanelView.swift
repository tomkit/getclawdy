//
//  CompanionPanelView.swift
//  Clawdy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""

    // TTS settings local UI state. The API key is only held transiently here
    // while the user types it; once saved it goes to the Keychain and this is
    // cleared. Fetched voices populate the voice picker.
    @State private var elevenLabsAPIKeyInput: String = ""
    @State private var manualVoiceIDInput: String = ""
    @State private var fetchedElevenLabsVoices: [ElevenLabsVoice] = []
    @State private var isFetchingElevenLabsVoices: Bool = false
    @State private var elevenLabsVoicesFetchFailed: Bool = false

    // Owns the single native History window. Held here (the menu-bar panel view is
    // created once and reused) so re-opening brings the existing window to the front
    // instead of spawning a duplicate.
    @State private var historyWindowController = ResearchHistoryWindowController()

    var body: some View {
        // The opaque dark panel wears the shared Clawdy red-aura glow so the menu reads
        // as distinctively Clawdy (the same red as the shadow cursor). The menu-bar window
        // is sized EXACTLY to its content (fixed 320pt wide, no transparent margin — see
        // `MenuBarPanelManager`), so an OUTER bloom applied to a full-width surface would be
        // clipped into a hard rectangle by the window bounds. To keep the aura a CLEAN soft
        // bloom we INSET the opaque surface (`MenuPanelMetrics.surfaceWidth`) and pad it back
        // out to the window's `windowWidth`; that padding is the transparent margin the glow
        // blooms into. The bloom (`glowRadius × ClawdyGlow.bloomFactor`) is kept ≤ that margin
        // (asserted in `MenuPanelMetrics`), so it never clips.
        //
        // The aura is cast by a SEPARATE rounded-rect layer BEHIND the surface (`auraLayer`),
        // sized SMALLER than the surface by `MenuPanelMetrics.auraEdgeInset` on every side so
        // the opaque surface fully OVERHANGS the aura shape's own crisp edge. Applying the glow
        // directly to the surface (the `.directOnSurface` composition) made the glow's solid
        // rounded-rect and the opaque surface share one identical antialiased boundary; their
        // edge pixels blended into a bright semi-transparent blue rim — a hard rectangular seam
        // sitting ON the edge, on top of the intended soft aura. With the aura tucked under the
        // surface's overhang (`.insetBeneathSurface`), that crisp rim (and the brightest
        // inner-halo pixels) hide beneath the opaque surface, so only the soft outer bloom
        // spills past the edge. No seam, just the aura.
        //
        // The composition is selected by the single `MenuPanelMetrics.glowComposition` constant
        // (live value `.insetBeneathSurface`), so the seam fix is one auditable switch: reverting
        // to the seam-prone direct glow means flipping that constant — which the tests assert
        // against. The `.directOnSurface` branch is retained ONLY as that negative case.
        switch MenuPanelMetrics.glowComposition {
        case .insetBeneathSurface:
            panelSurface
                .background(alignment: .center) { auraLayer }
                .padding(MenuPanelMetrics.glowMargin)
                .frame(width: MenuPanelMetrics.windowWidth)
        case .directOnSurface:
            panelSurface
                .clawdyGlow(
                    cornerRadius: MenuPanelMetrics.surfaceCornerRadius,
                    radius: MenuPanelMetrics.glowRadius
                )
                .padding(MenuPanelMetrics.glowMargin)
                .frame(width: MenuPanelMetrics.windowWidth)
        }
    }

    /// The soft blue aura, cast by a rounded-rect wearing the shared `clawdyGlow` and INSET
    /// beneath the opaque `panelSurface` by `MenuPanelMetrics.auraEdgeInset` on every side.
    /// Being smaller than the surface, the surface overhangs its edge: the aura shape's own
    /// crisp outline — and the coincident-edge antialiasing that produced the hard alpha seam —
    /// stay hidden under the surface, and only the soft shadow bloom that reaches past the
    /// surface edge shows. The rect is filled opaque (the same dark background as the surface)
    /// so the glow primitive's internal solid-blue fill can never peek through as a blue face.
    private var auraLayer: some View {
        RoundedRectangle(cornerRadius: MenuPanelMetrics.surfaceCornerRadius, style: .continuous)
            .fill(DS.Colors.background)
            .clawdyGlow(
                cornerRadius: MenuPanelMetrics.surfaceCornerRadius,
                radius: MenuPanelMetrics.glowRadius
            )
            .padding(MenuPanelMetrics.auraEdgeInset)
    }

    /// The opaque dark rounded panel itself — the full settings content on the dark surface.
    /// Sized to `surfaceWidth` (inset from the window edges) so the glow applied around it in
    /// `body` has a clear margin to bloom into instead of clipping against the window bounds.
    private var panelSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, DS.Spacing.lg)

            permissionsCopySection
                .padding(.top, DS.Spacing.lg)
                .padding(.horizontal, DS.Spacing.lg)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                settingsSectionsStack
                    .padding(.top, 18)
                    .padding(.horizontal, DS.Spacing.lg)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, DS.Spacing.lg)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, DS.Spacing.lg)
            }

            // Show Clawdy toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClawdyCursorToggleRow
            //         .padding(.horizontal, DS.Spacing.lg)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                historyButton
                    .padding(.horizontal, DS.Spacing.lg)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, DS.Spacing.lg)

            footerSection
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
        }
        .frame(width: MenuPanelMetrics.surfaceWidth)
        .background(panelBackground)
    }

    // MARK: - Settings Sections

    /// The fully-onboarded quick settings, grouped into two quiet sections — Engine and
    /// Voice — in the order and membership defined by the pure
    /// `CompanionSettingsLayout` (so the IA is unit-tested and can't silently drift).
    /// Sections are separated by whitespace plus a single hairline rule; no boxed cards,
    /// no accent chips — the same restraint as the recents list.
    private var settingsSectionsStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(CompanionSettingsLayout.orderedSections.enumerated()), id: \.element) { sectionIndex, section in
                if sectionIndex > 0 {
                    sectionDivider
                }
                settingsSection(for: section)
            }
        }
    }

    /// One settings group: a quiet header over its control(s). The controls it renders for
    /// a section mirror `CompanionSettingsLayout.controls(in:selectedEngineKind:)`.
    @ViewBuilder
    private func settingsSection(for section: CompanionSettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(section.title)

            switch section {
            case .engine:
                enginePickerRow
                // The "Use my Claude Code setup" toggle only affects the Claude engine,
                // so it appears in the Engine section only when Claude Code is selected.
                if CompanionSettingsLayout.showsClaudeCustomizationsRow(
                    selectedEngineKind: companionManager.selectedEngineKind
                ) {
                    claudeCustomizationsToggleRow
                }
            case .voice:
                ttsSettingsSection
            }
        }
    }

    /// A quiet section header — a small secondary-tone label, matching the recents list's
    /// restraint (no all-caps, no accent, no icon). The whitespace and hairline around it
    /// do the separating.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DS.Font.controlLabel)
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The hairline between settings sections — a faint, quiet rule, never a boxed card.
    private var sectionDivider: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle.opacity(0.5))
            .frame(height: 1)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Clawdy")
                    .font(DS.Font.title)
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(DS.Font.overlayBody)
                .foregroundColor(DS.Colors.textTertiary)

            headerTrailingControl
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.comfortable)
    }

    /// While the warm quick-answer is WORKING (processing) or SPEAKING (responding),
    /// the header shows a STOP control that cancels the in-flight turn + its TTS. When
    /// idle/listening it reverts to the normal panel-dismiss (×).
    @ViewBuilder
    private var headerTrailingControl: some View {
        if CompanionQuickAnswerControl.shouldShowStop(forVoiceState: companionManager.voiceState) {
            Button(action: {
                companionManager.cancelQuickAnswer()
            }) {
                Image(systemName: "stop.fill")
                    .font(DS.Font.iconGlyph)
                    .foregroundColor(DS.Colors.accent)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(DS.Colors.accent.opacity(0.16))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .menuButtonHover(Circle())
            .help("Stop")
        } else {
            Button(action: {
                NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(DS.Font.microCaptionEmphasized)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .menuButtonHover(Circle())
        }
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(DS.Font.overlayBody)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(DS.Font.overlayBody)
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(DS.Font.overlayCaptionRegular)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clawdy.")
                .font(DS.Font.overlayBody)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(DS.Font.overlayBodyBold)
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Clawdy.")
                    .font(DS.Font.overlayCaptionRegular)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Clawdy.")
                    .font(DS.Font.overlayBodyBold)
                    .foregroundColor(DS.Colors.textSecondary)

                Text("your little screen buddy — here to help you figure things out as you go.")
                    .font(DS.Font.overlayCaptionRegular)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("nothing runs in the background. Clawdy only takes a screenshot when you press the hot key, so you can grant that permission in peace.")
                    .font(DS.Font.overlayCaptionRegular)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(DS.Font.detailBodyRegular)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                        .menuFieldHover()

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(DS.Font.title)
                            .foregroundColor(DS.Colors.textOnAccent)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Spacing.control)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    // White label on a solid blue fill → use the AA-safe deeper blue.
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accentButtonFill.opacity(0.4)
                                          : DS.Colors.accentButtonFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    // Solid blue fill with a white label → DARKEN on hover so the white text
                    // keeps its AA contrast (a white wash would lighten the blue below AA).
                    .menuButtonHover(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous), wash: .accent)
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(DS.Font.title)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.control)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                // White label on a solid blue fill → use the AA-safe deeper blue.
                                .fill(DS.Colors.accentButtonFill)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .menuButtonHover(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous), wash: .accent)
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DS.Spacing.snug)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(DS.Font.overlayBody)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility")
                        .font(DS.Font.detailBody)
                        .foregroundColor(DS.Colors.textSecondary)

                    if !isGranted {
                        // AXIsProcessTrusted() caches inside the process, so a grant
                        // made in System Settings may not register until relaunch —
                        // especially for ad-hoc / locally signed builds.
                        Text("Quit and reopen after granting if this stays off")
                            .font(DS.Font.microCaption)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(DS.Font.overlayCaption)
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                        // Dismiss the floating menu panel so the system prompt /
                        // System Settings window isn't hidden behind it.
                        NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)
                    }) {
                        Text("Grant")
                            .font(DS.Font.overlayCaptionEmphasized)
                            .foregroundColor(DS.Colors.textOnAccent)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, DS.Spacing.control)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(
                                Capsule()
                                    // White "Grant" label on a solid blue fill → AA-safe deeper blue.
                                    .fill(DS.Colors.accentButtonFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .menuButtonHover(Capsule(), wash: .accent)

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                        // Dismiss the floating menu panel so Finder / System Settings
                        // isn't hidden behind it.
                        NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)
                    }) {
                        Text("Find App")
                            .font(DS.Font.overlayCaptionEmphasized)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, DS.Spacing.control)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .menuButtonHover(Capsule())
                }
            }
        }
        .padding(.vertical, DS.Spacing.snug)
    }

    private var screenRecordingPermissionRow: some View {
        // Key the row's granted/"Grant" display off the LIVE reading, not the
        // sticky `hasScreenRecordingPermission`. Otherwise a stale "previously
        // confirmed" flag (which a TCC reset does NOT clear) would show "Granted"
        // and hide the button, leaving the user unable to re-trigger the
        // SCShareableContent registration — the only path that registers Clawdy in
        // the Screen Recording list.
        let isGranted = companionManager.hasLiveScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(DS.Font.overlayBody)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(DS.Font.detailBody)
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(DS.Font.microCaption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(DS.Font.overlayCaption)
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // PRIMARY action: route through the shared state machine,
                        // which fires the SINGLE SCShareableContent registration —
                        // the only path that both registers Clawdy in the Screen
                        // Recording list AND raises the genuine system prompt — on the
                        // first attempt this launch, then falls back to the Settings
                        // deep-link once macOS has already shown its one-time alert. If
                        // the proactive at-launch registration already fired, this
                        // opens Settings, so exactly one prompt shows per launch.
                        WindowPositionManager.requestScreenRecordingPermission()
                        // Dismiss the floating menu panel so the system prompt /
                        // System Settings window isn't hidden behind it.
                        NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)
                    }) {
                        Text("Grant")
                            .font(DS.Font.overlayCaptionEmphasized)
                            .foregroundColor(DS.Colors.textOnAccent)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, DS.Spacing.control)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(
                                Capsule()
                                    // White "Grant" label on a solid blue fill → AA-safe deeper blue.
                                    .fill(DS.Colors.accentButtonFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .menuButtonHover(Capsule(), wash: .accent)

                    Button(action: {
                        // SECONDARY fallback only: deep-link to the Screen Recording
                        // pane for users who dismissed the prompt or need to toggle
                        // the row manually. Never the primary path — deep-linking
                        // never registers the app with TCC.
                        WindowPositionManager.openScreenRecordingSettings()
                        // Dismiss the floating menu panel so System Settings isn't
                        // hidden behind it.
                        NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)
                    }) {
                        Text("Settings")
                            .font(DS.Font.overlayCaptionEmphasized)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, DS.Spacing.control)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .menuButtonHover(Capsule())
                }
            }
        }
        .padding(.vertical, DS.Spacing.snug)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(DS.Font.overlayBody)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(DS.Font.detailBody)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(DS.Font.overlayCaption)
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                    // Dismiss the floating menu panel so the system prompt isn't
                    // hidden behind it.
                    NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)
                }) {
                    Text("Grant")
                        .font(DS.Font.overlayCaptionEmphasized)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, DS.Spacing.control)
                        .padding(.vertical, DS.Spacing.xs)
                        .background(
                            Capsule()
                                // White "Grant" label on a solid blue fill → AA-safe deeper blue.
                                .fill(DS.Colors.accentButtonFill)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .menuButtonHover(Capsule(), wash: .accent)
            }
        }
        .padding(.vertical, DS.Spacing.snug)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(DS.Font.overlayBody)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(DS.Font.detailBody)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(DS.Font.overlayCaption)
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    // Dismiss the floating menu panel so the system prompt /
                    // System Settings window isn't hidden behind it.
                    NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)
                }) {
                    Text("Grant")
                        .font(DS.Font.overlayCaptionEmphasized)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, DS.Spacing.control)
                        .padding(.vertical, DS.Spacing.xs)
                        .background(
                            Capsule()
                                // White "Grant" label on a solid blue fill → AA-safe deeper blue.
                                .fill(DS.Colors.accentButtonFill)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .menuButtonHover(Capsule(), wash: .accent)
            }
        }
        .padding(.vertical, DS.Spacing.snug)
    }

    // MARK: - Claude Code Customizations Toggle

    /// The single "Use my Claude Code setup" setting: ON (default) loads the user's
    /// own CLAUDE.md / skills / MCP / hooks on BOTH the quick-answer and research
    /// paths; OFF isolates both runs with `--safe-mode`. Only meaningful for the
    /// Claude engine, so the caller shows it only when Claude Code is selected.
    private var claudeCustomizationsToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .font(DS.Font.overlayBody)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Use my Claude Code setup")
                    .font(DS.Font.detailBody)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.useClaudeCustomizations },
                set: { companionManager.setUseClaudeCustomizations($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .menuRowHover()
    }

    // MARK: - Engine Picker

    /// Lets the user pick which locally-installed coaching CLI (Claude Code /
    /// Codex) powers responses. Shows ONLY the engines detected on this machine.
    /// When none is installed, shows a friendly install prompt instead.
    @ViewBuilder
    private var enginePickerRow: some View {
        if companionManager.hasAnyCoachEngineInstalled {
            // The "Engine" section header names this control, so the segment sits on its
            // own line rather than repeating the label.
            HStack(spacing: 0) {
                ForEach(companionManager.availableEngineKinds) { engineKind in
                    engineOptionButton(engineKind: engineKind)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        } else {
            noEngineInstalledNotice
        }
    }

    private func engineOptionButton(engineKind: CoachEngineKind) -> some View {
        MenuSegmentOptionButton(
            title: engineKind.displayName,
            isSelected: companionManager.selectedEngineKind == engineKind,
            action: { companionManager.setSelectedEngine(engineKind) }
        )
    }

    /// Shown when neither `claude` nor `codex` is installed. Clawdy needs one of
    /// them to think, so we explain what to install instead of failing silently.
    private var noEngineInstalledNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No coding assistant found")
                .font(DS.Font.controlLabel)
                .foregroundColor(DS.Colors.textPrimary)
            Text("Clawdy runs on your own Claude Code or Codex subscription. Install one below — it'll appear here automatically.")
                .font(DS.Font.overlayCaptionRegular)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(CoachEngineKind.allCases) { engineKind in
                Text(engineKind.installCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.control)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .padding(.vertical, DS.Spacing.xs)
    }

    // MARK: - TTS (Voice) Settings

    /// Lets the user choose the text-to-speech engine. Apple is the free,
    /// on-device default; ElevenLabs uses the user's own API key for
    /// higher-quality speech. When ElevenLabs is selected, exposes the key
    /// entry and voice picker.
    private var ttsSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The "Voice" section header names this control, so the provider segment sits
            // on its own line rather than repeating the label.
            HStack(spacing: 0) {
                ForEach(TTSEngineKind.allCases) { ttsEngineKind in
                    ttsEngineOptionButton(ttsEngineKind: ttsEngineKind)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )

            if companionManager.selectedTTSEngineKind == .elevenLabs {
                elevenLabsConfiguration
            }
        }
    }

    private func ttsEngineOptionButton(ttsEngineKind: TTSEngineKind) -> some View {
        MenuSegmentOptionButton(
            title: ttsEngineKind.displayName,
            isSelected: companionManager.selectedTTSEngineKind == ttsEngineKind,
            action: { companionManager.setSelectedTTSEngine(ttsEngineKind) }
        )
    }

    /// Key entry (when no key is saved) or the saved-key + voice picker UI.
    @ViewBuilder
    private var elevenLabsConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            if companionManager.hasElevenLabsAPIKey {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(DS.Font.overlayCaptionRegular)
                        .foregroundColor(DS.Colors.accent)
                    Text("API key saved")
                        .font(DS.Font.overlayCaptionRegular)
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    Button(action: {
                        companionManager.clearElevenLabsAPIKey()
                        fetchedElevenLabsVoices = []
                        elevenLabsVoicesFetchFailed = false
                    }) {
                        Text("Clear")
                            .font(DS.Font.overlayCaption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .menuTextHover()
                }
                voicePickerRow
            } else {
                SecureField("ElevenLabs API key", text: $elevenLabsAPIKeyInput)
                    .textFieldStyle(.plain)
                    .font(DS.Font.overlayBodyRegular)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, DS.Spacing.control)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .menuFieldHover()

                Button(action: {
                    companionManager.saveElevenLabsAPIKey(elevenLabsAPIKeyInput)
                    elevenLabsAPIKeyInput = ""
                }) {
                    Text("Save key")
                        .font(DS.Font.controlLabel)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                // White "Save key" label on a solid blue fill → AA-safe deeper blue.
                                .fill(elevenLabsAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      ? DS.Colors.accentButtonFill.opacity(0.4)
                                      : DS.Colors.accentButtonFill)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                // Solid blue fill with a white label → darken on hover to preserve AA contrast.
                .menuButtonHover(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous), wash: .accent)
                .disabled(elevenLabsAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("Stored in your macOS Keychain.")
                    .font(DS.Font.microCaption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Picks a voice. Offers a menu of the user's fetched voices, with a manual
    /// voice-id field as a fallback when the fetch fails or hasn't run yet.
    @ViewBuilder
    private var voicePickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Voice")
                    .font(DS.Font.overlayCaptionRegular)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Menu {
                    if fetchedElevenLabsVoices.isEmpty {
                        Text("No voices loaded yet")
                    }
                    ForEach(fetchedElevenLabsVoices) { voice in
                        Button(action: { companionManager.setElevenLabsVoiceID(voice.voiceID) }) {
                            Text(voice.name)
                        }
                    }
                    Divider()
                    Button(action: { refreshElevenLabsVoices() }) {
                        Text(isFetchingElevenLabsVoices ? "Loading…" : "Load my voices")
                    }
                } label: {
                    Text(currentVoiceDisplayName)
                        .font(DS.Font.overlayCaption)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
                .menuTextHover()
            }

            if elevenLabsVoicesFetchFailed || fetchedElevenLabsVoices.isEmpty {
                HStack(spacing: 6) {
                    TextField("Voice ID", text: $manualVoiceIDInput)
                        .textFieldStyle(.plain)
                        .font(DS.Font.overlayCaptionRegular)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.compact)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                        .menuFieldHover()
                    Button(action: {
                        companionManager.setElevenLabsVoiceID(manualVoiceIDInput)
                        manualVoiceIDInput = ""
                    }) {
                        Text("Use")
                            .font(DS.Font.overlayCaption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .menuTextHover()
                    .disabled(manualVoiceIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// The name of the currently selected voice when known, otherwise the raw
    /// voice id so the user always sees what's active.
    private var currentVoiceDisplayName: String {
        if let matchingVoice = fetchedElevenLabsVoices.first(where: { $0.voiceID == companionManager.elevenLabsVoiceID }) {
            return matchingVoice.name
        }
        return companionManager.elevenLabsVoiceID
    }

    /// Fetches the user's ElevenLabs voices for the picker. On failure flips to
    /// the manual voice-id fallback rather than blocking the user.
    private func refreshElevenLabsVoices() {
        guard !isFetchingElevenLabsVoices else { return }
        isFetchingElevenLabsVoices = true
        elevenLabsVoicesFetchFailed = false
        Task {
            do {
                let voices = try await companionManager.fetchElevenLabsVoices()
                fetchedElevenLabsVoices = voices
                elevenLabsVoicesFetchFailed = voices.isEmpty
            } catch {
                elevenLabsVoicesFetchFailed = true
            }
            isFetchingElevenLabsVoices = false
        }
    }

    // MARK: - History Button

    // Opens the native History window listing every past & present conversation
    // (root warm session + research runs) with its transcript and generated page.
    private var historyButton: some View {
        Button(action: {
            // Selecting History dismisses the menu-bar popover (like picking a menu
            // item closes the menu), then opens the History window in front.
            NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)
            // Route the History detail-pane follow-up composer through the research session
            // manager, so continuing a conversation from History reactivates its toast via
            // the same path a spoken follow-up uses.
            historyWindowController.followUpRouter = companionManager.researchFollowUpRouter
            // Wire the History "Resume in Terminal" action to the app's ALREADY-BUILT registry so
            // the resolved binary path is a cached read (never a fresh engine-detection scan on a
            // UI path). Read once per show, off the render path, and cached by the view model.
            historyWindowController.resolveResumeBinaryPath = { [registry = companionManager.coachEngineRegistry] engine in
                switch engine {
                case .claudeCode: return registry.detectedBinaryPath(for: .claudeCode)
                case .codex: return registry.detectedBinaryPath(for: .codex)
                }
            }
            historyWindowController.show()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(DS.Font.overlayBody)
                    // Brand-red accent so the History entry point reads as Clawdy's.
                    .foregroundColor(DS.Colors.accent)

                Text("History")
                    .font(DS.Font.controlLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(DS.Font.microCaptionEmphasized)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.control)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .menuButtonHover(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(DS.Font.overlayCaption)
                    Text("Quit Clawdy")
                        .font(DS.Font.overlayBody)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .menuTextHover()
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        // A subtle black drop shadow grounds the panel; kept within the glow margin
        // (radius ≤ `MenuPanelMetrics.glowMargin`) so it stays a soft depth shadow beneath
        // the blue aura instead of clipping into a hard dark rectangle at the window edge.
        RoundedRectangle(cornerRadius: MenuPanelMetrics.surfaceCornerRadius, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 5)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.accent
        case .processing, .responding:
            return DS.Colors.accent
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}

// MARK: - Menu Panel Metrics (pure)

/// Sizing for the menu-bar panel surface and its Clawdy red-aura glow. The menu window is
/// fixed at `windowWidth` and sized exactly to its content (no transparent margin), so the
/// opaque panel is inset to `surfaceWidth` and padded back out by `glowMargin` on every edge —
/// that padding is the clear margin the glow blooms into. Kept here as named constants so the
/// clip-safety relationship (`glowRadius × ClawdyGlow.bloomFactor ≤ glowMargin`) is unit-tested
/// and can't silently drift.
enum MenuPanelMetrics {
    /// The fixed panel window width (matches `MenuBarPanelManager.panelWidth`).
    static let windowWidth: CGFloat = 320

    /// The clear transparent margin on every edge of the opaque surface — the room the glow's
    /// outer bloom needs so it renders as a clean aura instead of clipping to the window bounds.
    static let glowMargin: CGFloat = 16

    /// The opaque dark panel width — inset from the window by `glowMargin` on both sides.
    static let surfaceWidth: CGFloat = windowWidth - glowMargin * 2

    /// Corner radius of the opaque panel and the aura silhouette that hugs it.
    static let surfaceCornerRadius: CGFloat = 12

    /// The glow (blur) radius applied to the panel. Its visible bloom
    /// (`glowRadius × ClawdyGlow.bloomFactor`) is kept within `glowMargin`.
    static let glowRadius: CGFloat = ClawdyGlow.defaultRadius

    /// How the menu panel's blue aura is composited relative to the opaque surface — the single
    /// switch behind the hard-alpha-seam fix.
    enum GlowComposition {
        /// The aura is cast from a SEPARATE rounded-rect layer inset BENEATH the surface
        /// (`auraEdgeInset`), so the surface overhangs the aura's crisp edge and only the soft
        /// bloom escapes. The correct, seam-free composition — the live value.
        case insetBeneathSurface
        /// The glow is applied DIRECTLY to the opaque surface, so the glow's solid rounded-rect
        /// and the surface share one antialiased boundary whose blended edge pixels form a bright
        /// semi-transparent blue rim — a hard alpha seam riding the edge. The seam-prone legacy
        /// composition; NEVER the live value, kept only as the negative case the tests assert against.
        case directOnSurface
    }

    /// Selects how the aura is composited (see `body`). MUST stay `.insetBeneathSurface`: that is
    /// the composition that hides the coincident-edge seam under the surface's overhang. Flipping
    /// this to `.directOnSurface` brings the hard alpha seam back — which the menu-panel glow tests
    /// assert against, so this constant is the one auditable seam-fix switch.
    static let glowComposition: GlowComposition = .insetBeneathSurface

    /// How far the aura's rounded-rect is inset BENEATH the opaque surface on every side.
    /// The surface overhangs the aura shape by this much, so the aura's own crisp edge — and
    /// the coincident-edge antialiasing that otherwise leaves a hard alpha seam — hide under
    /// the surface; only the soft outer bloom spills past the edge. Kept comfortably smaller
    /// than the visible bloom so a real aura still reaches past the surface edge.
    static let auraEdgeInset: CGFloat = 3

    /// The glow's visible bloom reach — used by tests to assert it fits inside `glowMargin`.
    /// The aura source is inset under the surface by `auraEdgeInset`, so the bloom actually
    /// reaches `visibleGlowBloom - auraEdgeInset` past the surface edge; using the un-inset
    /// bloom here keeps the clip-safety assertion conservative (worst case).
    static let visibleGlowBloom: CGFloat = glowRadius * ClawdyGlow.bloomFactor
}

// MARK: - Menu Panel Hover Affordances

/// Every interactive control in the menu panel gets a quiet, consistent hover affordance
/// (subtle highlight/emphasis + the pointing-hand cursor where it is a click target). The
/// treatment is tuned per control TYPE so it stays quiet and matches the sparse dark
/// aesthetic — never a heavy box:
///   • filled buttons / cards → a faint state-layer wash lifts on hover (`menuButtonHover`)
///   • bare-text buttons      → the label brightens on hover (`menuTextHover`)
///   • text fields            → the border brightens on hover (`menuFieldHover`)
///   • toggle rows            → a faint full-row highlight lifts on hover (`menuRowHover`)
///   • segmented options      → `MenuSegmentOptionButton` (its own hover fill + label tint)

/// Which state-layer wash a filled control lifts on hover. The wash COLOR is chosen so
/// contrast is preserved: neutral/transparent surfaces lighten (`.white`) to read as "lit up"
/// on the dark panel, while solid accent fills carrying white labels DARKEN (`.black`) so the
/// white-on-blue text keeps its WCAG-AA contrast on hover (a white wash would lighten the blue
/// and drop it below AA). Naming the two families (instead of passing a bare `Color`) makes the
/// per-control choice a testable value the app and its tests share.
enum MenuButtonHoverWash {
    /// Neutral / transparent surfaces lighten on hover.
    case neutral
    /// Solid accent fills with white labels darken on hover to preserve label contrast.
    case accent

    /// The overlay color this wash tints with (before the hover opacity is applied).
    var color: Color {
        switch self {
        case .neutral: return .white
        case .accent: return .black
        }
    }
}

/// Pure hover-mapping decisions for the menu panel's control families. Hover is `@State`
/// internal to each control and can't be driven headlessly, so the per-`isHovered` (and, for
/// segments, per-`isSelected`) treatment is resolved HERE and the production views route
/// through it — letting tests assert the SAME mapping the app renders. No SwiftUI state,
/// no AppKit.
enum MenuPanelHoverStyle {
    /// The state-layer wash opacity a filled button/card lifts on hover (0 at rest).
    static func buttonWashOpacity(isHovered: Bool) -> Double {
        isHovered ? DS.StateLayer.hover : 0
    }

    /// The text-field border opacity on hover (`borderStrong` shows at 1, hidden at 0 at rest).
    static func fieldBorderOpacity(isHovered: Bool) -> Double {
        isHovered ? 1 : 0
    }

    /// The full-row highlight fill opacity a toggle row lifts on hover (0 at rest).
    static func rowHighlightOpacity(isHovered: Bool) -> Double {
        isHovered ? 0.04 : 0
    }

    /// The label tint for one segmented-picker option, per selected + hovered. Selected reads
    /// Clawdy red; a hovered (unselected) option brightens toward the secondary tone.
    static func segmentLabelColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return DS.Colors.accentText }
        return isHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary
    }

    /// The background fill for one segmented-picker option, per selected + hovered.
    static func segmentBackgroundFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return DS.Colors.accentSelectedFill }
        return isHovered ? Color.white.opacity(0.06) : Color.clear
    }
}

/// A faint state-layer wash, clipped to the control's own shape, that lifts on hover.
private struct MenuButtonHoverModifier<HighlightShape: Shape>: ViewModifier {
    let highlightShape: HighlightShape
    let wash: MenuButtonHoverWash
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(
                highlightShape
                    .fill(wash.color.opacity(MenuPanelHoverStyle.buttonWashOpacity(isHovered: isHovered)))
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            // Report hover through the ONE shared hover primitive (the pointing-hand
            // cursor is applied by the call site / not applicable to these families).
            .trackingHover($isHovered, showsPointerCursor: false)
    }
}

/// Brightens a bare-text button's label on hover (no background box — the lowest-emphasis
/// affordance, for inline text actions like "Clear" / "Use" / the voice menu / footer links).
private struct MenuTextHoverModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovered ? 0.2 : 0)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            // Report hover through the ONE shared hover primitive (the pointing-hand
            // cursor is applied by the call site / not applicable to these families).
            .trackingHover($isHovered, showsPointerCursor: false)
    }
}

/// Brightens a text field's border on hover (`borderSubtle` → `borderStrong`) so an editable
/// field signals interactivity without changing its resting fill.
private struct MenuFieldHoverModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DS.Colors.borderStrong.opacity(MenuPanelHoverStyle.fieldBorderOpacity(isHovered: isHovered)), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            // Report hover through the ONE shared hover primitive (the pointing-hand
            // cursor is applied by the call site / not applicable to these families).
            .trackingHover($isHovered, showsPointerCursor: false)
    }
}

/// A faint full-row highlight that lifts behind a settings row (the toggle rows) on hover.
/// The highlight extends slightly past the row content into the section's padding so it reads
/// as a comfortable macOS-style row hover rather than a tight box around the label.
private struct MenuRowHoverModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(Color.white.opacity(MenuPanelHoverStyle.rowHighlightOpacity(isHovered: isHovered)))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            // Report hover through the ONE shared hover primitive (the pointing-hand
            // cursor is applied by the call site / not applicable to these families).
            .trackingHover($isHovered, showsPointerCursor: false)
    }
}

extension View {
    /// Lifts a faint state-layer wash on hover, clipped to `shape`. Pass `wash: .accent` for
    /// solid accent fills with white labels (keeps AA), `.neutral` (default) for neutral surfaces.
    func menuButtonHover<HighlightShape: Shape>(_ shape: HighlightShape, wash: MenuButtonHoverWash = .neutral) -> some View {
        modifier(MenuButtonHoverModifier(highlightShape: shape, wash: wash))
    }

    /// Brightens a bare-text button's label on hover.
    func menuTextHover() -> some View {
        modifier(MenuTextHoverModifier())
    }

    /// Brightens a text field's border on hover.
    func menuFieldHover(cornerRadius: CGFloat = DS.CornerRadius.medium) -> some View {
        modifier(MenuFieldHoverModifier(cornerRadius: cornerRadius))
    }

    /// Lifts a faint full-row highlight behind a settings row on hover.
    func menuRowHover() -> some View {
        modifier(MenuRowHoverModifier())
    }
}

/// One option in the Engine / Voice segmented pickers. A dedicated view (not a builder func)
/// so it can carry its own `@State` hover: on hover a non-selected option gains a faint fill
/// and its label brightens toward `textSecondary`, giving a clear-but-quiet affordance. The
/// selected option keeps the Clawdy-red accent tint. Behavior is unchanged — the action
/// still just selects this option.
///
/// Internal (not `private`) so the pixel/layout tests can render it directly, mirroring how
/// the pure `CompanionSettingsLayout` IA types are exposed for testing.
struct MenuSegmentOptionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.overlayCaption)
                // Selected segment reads as Clawdy red; a hovered (unselected) option
                // brightens toward the secondary tone to signal it is clickable.
                .foregroundColor(labelColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, DS.Spacing.control)
                .padding(.vertical, DS.Spacing.compact)
                .background(
                    // Normalized to the design scale (5 → DS.CornerRadius.small, 6pt).
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(backgroundFill)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        // Route through the ONE shared hover primitive (reports hover + shows the
        // pointing-hand cursor) so a menu segment hovers like the rest of the app.
        .trackingHover($isHovered)
    }

    private var labelColor: Color {
        MenuPanelHoverStyle.segmentLabelColor(isSelected: isSelected, isHovered: isHovered)
    }

    private var backgroundFill: Color {
        MenuPanelHoverStyle.segmentBackgroundFill(isSelected: isSelected, isHovered: isHovered)
    }
}

// MARK: - Settings IA (pure)

/// One control the fully-onboarded settings area renders, identified purely so the
/// grouping and top-to-bottom order can be unit-tested with no SwiftUI.
enum CompanionSettingsControl: Equatable {
    case enginePicker
    case claudeCustomizationsToggle
    case ttsProvider
}

/// The quiet groups the fully-onboarded panel organizes its settings into.
enum CompanionSettingsSection: CaseIterable, Equatable {
    case engine
    case voice

    /// The quiet header shown above the section's controls.
    var title: String {
        switch self {
        case .engine: return "Engine"
        case .voice: return "Voice"
        }
    }
}

/// Pure IA for the settings area: which sections show, in what order, and which controls
/// live in each — so the view's layout is driven by testable logic instead of hardcoded,
/// silently-drifting order.
enum CompanionSettingsLayout {
    /// The sections, top-to-bottom.
    static let orderedSections: [CompanionSettingsSection] = [.engine, .voice]

    /// Whether the "Use my Claude Code setup" toggle appears in the Engine section — it is
    /// only meaningful for the Claude engine, so it shows only when Claude Code is selected
    /// (never when no engine is selected yet).
    static func showsClaudeCustomizationsRow(selectedEngineKind: CoachEngineKind?) -> Bool {
        selectedEngineKind == .claudeCode
    }

    /// The controls a section renders, top-to-bottom, for the currently selected engine.
    static func controls(
        in section: CompanionSettingsSection,
        selectedEngineKind: CoachEngineKind?
    ) -> [CompanionSettingsControl] {
        switch section {
        case .engine:
            var controls: [CompanionSettingsControl] = [.enginePicker]
            if showsClaudeCustomizationsRow(selectedEngineKind: selectedEngineKind) {
                controls.append(.claudeCustomizationsToggle)
            }
            return controls
        case .voice:
            return [.ttsProvider]
        }
    }
}
