//
//  ResearchHistoryComposerPixelRenderTests.swift
//  ClawdyTests
//
//  RUNTIME pixel evidence for the History window's NEW bottom follow-up composer. A
//  headless test asserts the FIELDS/behavior (see `ResearchHistoryComposerTests`), but it
//  can't confirm the composer READS as a chat input pinned under the transcript. So this
//  renders a faithful History detail-pane column — the real shipped `ResearchChatBubbleView`
//  transcript plus the REAL shared `ResearchFollowUpComposer` (the exact control shipped in
//  the pane) — in BOTH the resting SEND state and the live-run STOP state, dumping them to
//  `CLAWDY_PIXEL_DUMP_DIR` as `history-composer-send.png` / `history-composer-stop.png` so
//  the composer can be eyeballed. Each render `#expect`s a non-nil bitmap (a real "it
//  rendered" assertion, not a vacuous file dump).
//
//  The header + surface chrome around the composer is a faithful replica of the shipped
//  detail pane (the pane's `ResearchHistoryView` is private); the composer and the chat
//  bubbles themselves are the REAL shipped views.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ResearchHistoryComposerPixelRenderTests {

    private let paneWidth: CGFloat = 600
    private let paneHeight: CGFloat = 460

    @discardableResult
    private func renderToPNG<Content: View>(_ content: Content, size: CGSize, named name: String) -> NSBitmapImageRep? {
        let hostingView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = makeOffscreenRenderWindow(width: hostingView.frame.width, height: hostingView.frame.height)
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            window.orderOut(nil)
            return nil
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        window.orderOut(nil)

        if let dir = ProcessInfo.processInfo.environment["CLAWDY_PIXEL_DUMP_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private func sampleTurns() -> [TranscriptTurn] {
        [
            TranscriptTurn(id: 0, kind: .userMessage,
                           text: "Best winter photo spots in Aomori — build me a page.", detail: nil),
            TranscriptTurn(id: 1, kind: .assistantMessage,
                           text: "Here's a page covering Hakkōda, Lake Towada, and the Hirosaki snow lanterns, with the best months and access notes for each.",
                           detail: nil),
            TranscriptTurn(id: 2, kind: .userMessage,
                           text: "Add a section on tripod-friendly spots.", detail: nil),
        ]
    }

    /// SEND state: a completed / not-live session — the resting composer with the `arrow.up`
    /// Send button, placeholder "Ask a follow-up…".
    @Test func rendersDetailPaneWithSendComposer() {
        let content = HistoryDetailPaneReplica(
            title: "Best winter photo spots in Aomori",
            turns: sampleTurns(),
            composerPrimaryAction: .send
        )
        let bitmap = renderToPNG(content, size: CGSize(width: paneWidth, height: paneHeight),
                                 named: "history-composer-send")
        #expect(bitmap != nil)
        #expect((bitmap?.pixelsWide ?? 0) > 0)
    }

    /// STOP state: the selected session is a live, actively-working run — the same one
    /// composer control morphed to the destructive Stop button.
    @Test func rendersDetailPaneWithStopComposer() {
        let content = HistoryDetailPaneReplica(
            title: "Compare standing desk converters under $200",
            turns: sampleTurns(),
            composerPrimaryAction: .stop
        )
        let bitmap = renderToPNG(content, size: CGSize(width: paneWidth, height: paneHeight),
                                 named: "history-composer-stop")
        #expect(bitmap != nil)
        #expect((bitmap?.pixelsWide ?? 0) > 0)
    }

    /// NON-RESUMABLE state (the fix): a stale/ended session (stale `.running` with no live
    /// session, `.failed`, `.stopped`, or the warm root) presents NO composer at all, so the
    /// detail pane is purely read-only with no enabled Send that would be silently refused.
    @Test func rendersDetailPaneWithNoComposerWhenNotResumable() {
        let content = HistoryDetailPaneReplica(
            title: "Latest on the EU AI Act timeline",
            turns: sampleTurns(),
            composerPrimaryAction: nil // nil → no composer row (the resting non-resumable state)
        )
        let bitmap = renderToPNG(content, size: CGSize(width: paneWidth, height: paneHeight),
                                 named: "history-composer-none")
        #expect(bitmap != nil)
        #expect((bitmap?.pixelsWide ?? 0) > 0)
    }
}

// MARK: - Faithful detail-pane replica hosting the REAL composer + REAL chat bubbles

/// Mirrors the shipped detail pane's chrome (header + divider + transcript scroll + a
/// bottom-pinned composer under a divider), wrapping the REAL `ResearchChatBubbleView`s and
/// the REAL shared `ResearchFollowUpComposer` so the render exercises the shipped composer,
/// not a copy. Test-only scaffolding (the pane's own `ResearchHistoryView` is private).
private struct HistoryDetailPaneReplica: View {
    let title: String
    let turns: [TranscriptTurn]
    /// nil renders the NON-RESUMABLE resting state — no composer row at all (a purely
    /// read-only detail pane), matching the shipped `showsComposer == false` case.
    let composerPrimaryAction: ResearchComposerPrimaryAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                    Text("2 hours ago")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().background(DS.Colors.borderSubtle)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(turns) { turn in
                        ResearchChatBubbleView(turn: turn)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let composerPrimaryAction {
                Divider().background(DS.Colors.borderSubtle)

                ResearchFollowUpComposer(
                    primaryAction: composerPrimaryAction,
                    placeholder: "Ask a follow-up…",
                    onSubmit: { _ in true },
                    onStop: {}
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(DS.Colors.surface1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.background)
    }
}
