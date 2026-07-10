//
//  ResearchClarificationPanel.swift
//  Clawdy
//
//  The small focusable text-input panel shown when the research PLAN phase needs
//  clarifying answers before it can proceed. It displays the plan agent's
//  question(s), a text field for the user's typed reply, and a Submit button.
//  Submitting resumes the research process into its EXECUTE phase.
//
//  Unlike the click-through cursor overlays, this panel MUST take keyboard focus
//  so the user can type — so it's a key-able borderless NSPanel. Its window is
//  `sharingType = .none` so it never leaks into screenshots. Voice answering is a
//  later phase; Slice 1 is text input only.
//

import AppKit
import Combine
import SwiftUI

/// A borderless NSPanel that is allowed to become key (so its text field accepts
/// typing) while still floating above other apps. The standard NSPanel refuses key
/// status for borderless masks, which would make the text field uneditable.
final class KeyableResearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ResearchClarificationPanelManager {
    private var panel: KeyableResearchPanel?

    /// Called with the user's typed answer when they submit. Cleared after use.
    private var onSubmit: ((String) -> Void)?
    /// Called when the user dismisses without answering (Cancel / Escape).
    private var onCancel: (() -> Void)?

    private let viewModel = ResearchClarificationViewModel()

    /// Shows the panel with the given question text, centered on the main screen.
    /// `onSubmit` receives the trimmed answer; `onCancel` runs if the user backs out.
    func show(
        questions: String,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        viewModel.questionText = questions
        viewModel.answerText = ""

        createPanelIfNeeded()
        guard let panel else { return }

        // Center on the screen that currently has the mouse, falling back to main.
        if let screen = screenContainingCursor() ?? NSScreen.main {
            let panelSize = panel.frame.size
            let visibleFrame = screen.visibleFrame
            let origin = CGPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.midY - panelSize.height / 2
            )
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
        onSubmit = nil
        onCancel = nil
    }

    // MARK: - Private

    private func createPanelIfNeeded() {
        if panel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: 420, height: 220)
        // Reuses the shared overlay-panel factory: a keyable subclass (so the text
        // field accepts typing), WITH a system drop shadow, and WITHOUT the
        // `.stationary` collection-behavior flag the toast overlays use — matching this
        // panel's historical setup exactly.
        let clarificationPanel = ResearchToastPanel.makeOverlayPanel(
            size: initialFrame.size,
            panelType: KeyableResearchPanel.self,
            hasShadow: true,
            includesStationaryCollectionBehavior: false
        )

        let hostingView = NSHostingView(
            rootView: ResearchClarificationView(
                viewModel: viewModel,
                onSubmit: { [weak self] answer in self?.handleSubmit(answer) },
                onCancel: { [weak self] in self?.handleCancel() }
            )
        )
        hostingView.frame = initialFrame
        clarificationPanel.contentView = hostingView
        panel = clarificationPanel
    }

    private func handleSubmit(_ answer: String) {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return }
        let submitHandler = onSubmit
        hide()
        submitHandler?(trimmedAnswer)
    }

    private func handleCancel() {
        let cancelHandler = onCancel
        hide()
        cancelHandler?()
    }

    private func screenContainingCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }
}

@MainActor
final class ResearchClarificationViewModel: ObservableObject {
    @Published var questionText: String = ""
    @Published var answerText: String = ""
}

private struct ResearchClarificationView: View {
    @ObservedObject var viewModel: ResearchClarificationViewModel
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isAnswerFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundColor(DS.Colors.accent)
                Text("quick question before i research")
                    .font(DS.Font.linkLabel)
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Text(viewModel.questionText)
                .font(DS.Font.detailBodyRegular)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("type your answer…", text: $viewModel.answerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Font.detailBodyRegular)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .padding(DS.Spacing.sm)
                .background(
                    // Shared input-field radius (DS.CornerRadius.medium, 8) — the same token
                    // the follow-up composer field now uses, so text inputs match app-wide.
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                // Focus ring reads as Clawdy red; resting stays a subtle border.
                                .stroke(isAnswerFieldFocused ? DS.Colors.accent : DS.Colors.borderSubtle,
                                        lineWidth: 0.8)
                        )
                )
                .focused($isAnswerFieldFocused)
                .onSubmit { onSubmit(viewModel.answerText) }

            HStack {
                // Routed through the shared TextLinkButton so both footer actions gain the
                // hover feedback (opacity lift) + pointing-hand cursor they previously lacked,
                // with no frame change on hover.
                TextLinkButton(title: "cancel", color: DS.Colors.textSecondary) { onCancel() }
                Spacer()
                TextLinkButton(title: "research it ›") { onSubmit(viewModel.answerText) }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.clarificationCard, style: .continuous)
                .fill(DS.Colors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.clarificationCard, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
        )
        .frame(width: 420)
        .onAppear { isAnswerFieldFocused = true }
    }
}
