//
//  ResearchFollowUpComposer.swift
//  Clawdy
//
//  The SHARED typed/spoken follow-up composer: a text field plus a SINGLE morphing
//  trailing button, like a typical AI chat window's input. While the run is working the
//  button is a destructive STOP (`onStop`); when the session is awaiting the user it is
//  SEND (`arrow.up`), submitting the trimmed text via `onSubmit` and clearing the field.
//
//  It was extracted OUT of the per-research detail panel (`ResearchProgressOverlay`) so
//  BOTH surfaces that need a follow-up composer — the live per-session chat panel AND the
//  History window's transcript detail pane — reuse this one control instead of two
//  divergent send/stop implementations. The single pure `ResearchComposerPrimaryAction`
//  guard (`shouldSubmit`) gates BOTH the button tap and the Return key, so neither can
//  send while the composer is in STOP mode.
//
//  A SPOKEN follow-up is captured the same way it always was here: this is a plain
//  `TextField`, so macOS system dictation types the spoken text straight into the field —
//  Return / the Send button then submit it exactly like typed text. No separate mic path.
//

import SwiftUI

/// The shared follow-up composer. Owns its OWN input/focus `@State` so the draft survives
/// live progress re-renders of the parent while the same session stays selected/focused.
struct ResearchFollowUpComposer: View {
    /// Which intent the single trailing button carries right now (STOP while the run is
    /// working, SEND while the session awaits the user). Derived from the session phase by
    /// the parent (`ResearchComposerPrimaryAction.forPhase`).
    let primaryAction: ResearchComposerPrimaryAction
    /// The empty-field prompt text. Defaults to the per-research chat panel's wording; the
    /// History detail pane passes its own ("Ask a follow-up…").
    var placeholder: String = "Message this research…"
    /// Submits the trimmed follow-up. Returns whether it was actually ACCEPTED/routed: the
    /// composer clears its draft ONLY on `true`, so a refused submit (a session that turned
    /// out not to be resumable) keeps the user's text instead of silently losing it.
    let onSubmit: (String) -> Bool
    /// Cancels the underlying research run — invoked when the trailing button is in its STOP
    /// form (while the run is actively working).
    let onStop: () -> Void

    @State private var draftText: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField("", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Font.detailBodyRegular)
                .foregroundColor(DS.Colors.textPrimary)
                // The visible placeholder is a custom overlay, so the empty TextField title
                // leaves no programmatic label — restore it for VoiceOver.
                .accessibilityLabel(placeholder)
                .lineLimit(1...4)
                // Draw the placeholder ourselves: the native macOS placeholder renders in a
                // system dark tone that is invisible on this dark surface, so overlay it in a
                // muted-but-legible secondary token when the field is empty.
                .overlay(alignment: .topLeading) {
                    if draftText.isEmpty {
                        Text(placeholder)
                            .font(DS.Font.detailBodyRegular)
                            .foregroundColor(DS.Colors.textSecondary)
                            .allowsHitTesting(false)
                    }
                }
                .padding(DS.Spacing.sm)
                .background(
                    // Reconciled to the shared input-field radius (DS.CornerRadius.medium, 8)
                    // so this composer field and the clarification field match app-wide.
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(isFieldFocused ? DS.Colors.accent : DS.Colors.borderSubtle,
                                        lineWidth: 0.8)
                        )
                )
                .focused($isFieldFocused)
                .onSubmit(submit)

            trailingButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The ONE primary-action button at the composer's trailing edge. It morphs between STOP
    /// (destructive `stop.fill`, always enabled) while the run works and SEND (`arrow.up`,
    /// empty-draft disables + dims) while the session awaits the user — never both at once, so
    /// there is a single unambiguous primary control and no separate Stop capsule.
    @ViewBuilder
    private var trailingButton: some View {
        switch primaryAction {
        case .stop:
            // The send button, morphed into STOP: cancels the working run. Empty draft does
            // NOT disable it — stopping never depends on the text field.
            ResearchComposerStopButton(action: onStop)
        case .send:
            ResearchToastIconButton(
                systemName: "arrow.up",
                helpText: "Send follow-up",
                iconSize: 12,
                padding: 7,
                action: submit
            )
            .disabled(trimmedDraft.isEmpty)
            .opacity(trimmedDraft.isEmpty ? 0.4 : 1)
        }
    }

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Handles both the SEND button tap AND the Return key. Both route through the single pure
    /// `shouldSubmit` guard, so Return while the composer is in STOP mode (the run is working)
    /// never sends a follow-up even with a non-empty draft — it does nothing.
    private func submit() {
        let text = trimmedDraft
        guard ResearchComposerPrimaryAction.shouldSubmit(action: primaryAction, trimmedDraft: text) else { return }
        // Route the follow-up, then clear the field ONLY if it was actually ACCEPTED/routed —
        // a refused submit (a session that turned out non-resumable) keeps the draft so the
        // user never silently loses what they typed. `shouldClearDraft` is the pure decision.
        let routed = onSubmit(text)
        if ResearchComposerPrimaryAction.shouldClearDraft(action: primaryAction, trimmedDraft: text, routed: routed) {
            draftText = ""
        }
    }
}

/// The composer's trailing button in its STOP form — the SEND button morphed into a
/// destructive-tinted circular Stop (`stop.fill`) while the run is actively working. It keeps
/// the SAME compact circular footprint as the `arrow.up` send button so the single control
/// never jumps as it morphs, and wears the destructive tint (brightening on hover) so it
/// reads unmistakably as "cancel this run".
struct ResearchComposerStopButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(DS.Font.overlayBodyBold)
                .foregroundColor(DS.Colors.destructiveText)
                .padding(7)
                .background(
                    Circle().fill(DS.Colors.destructive.opacity(isHovering ? 0.28 : 0.16))
                )
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering)
        .help("Stop research")
    }
}
