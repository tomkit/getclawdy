//
//  ResearchConversationUXEvidenceTests.swift
//  ClawdyTests
//
//  RUNTIME PNG EVIDENCE for the research conversation/toast UX slice. Each test renders a
//  real production view tree to a bitmap and, when `CLAWDY_PIXEL_DUMP_DIR` is set, writes a
//  PNG there so the visual changes can be eyeballed:
//    • stacked-full-width  — 3 stacked toasts, back cards the SAME WIDTH as the front,
//    • error-pill          — the persistent RED failed pill with its dismiss (×),
//    • detail-aura         — the per-session chat panel wearing the Clawdy aura,
//    • chat-bubbles        — Clawdy-left / user-right chat alignment,
//    • chat-window         — the full per-session chat window (input + stop + dismiss).
//  With no env var set the tests still run (proving the trees compose) but write nothing.
//

import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Clawdy

@MainActor
struct ResearchConversationUXEvidenceTests {

    // MARK: - Sample view models

    private func viewModel(phase: ResearchOverlayPhase, task: String, status: String) -> ResearchProgressOverlayViewModel {
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = phase
        viewModel.taskDescription = task
        viewModel.statusLine = status
        viewModel.isCancellable = phase == .running || phase == .needsInput
        return viewModel
    }

    private func conversationTurns() -> [TranscriptTurn] {
        [
            TranscriptTurn(id: 0, kind: .userMessage, text: "Compare the top three standing desks and build me a page.", detail: nil),
            TranscriptTurn(id: 1, kind: .assistantMessage, text: "On it — I'll research reviews and specs, then write a single page.", detail: nil),
            TranscriptTurn(id: 2, kind: .toolCall, text: "best standing desks 2026 review", detail: "WebSearch"),
            TranscriptTurn(id: 3, kind: .toolResult, text: "wirecutter.com, rtings.com, …", detail: "result"),
            TranscriptTurn(id: 4, kind: .assistantMessage, text: "The Uplift V2 is the quietest and raises in about nine seconds.", detail: nil),
            TranscriptTurn(id: 5, kind: .userMessage, text: "Which one is the cheapest?", detail: nil),
        ]
    }

    // MARK: - ITEM 2: stacked toasts, back cards FULL WIDTH

    @Test func stackedToastsAreFullWidthEvidence() {
        let cornerRadius = ResearchFullToastGeometry.cornerRadius
        let toastSize = ResearchFullToastGeometry.toastSize
        let renderPadding: CGFloat = 24
        let count = 3
        let stride = ResearchStackFanLayout.stackedCardPeek
        let composition = ZStack(alignment: .topLeading) {
            ForEach(0..<count, id: \.self) { index in
                let transform = ResearchStackFanLayout.stackedCardTransform(depthFromFront: index)
                let phases: [ResearchOverlayPhase] = [.running, .needsInput, .done]
                ResearchFullToastView(
                    viewModel: viewModel(
                        phase: phases[index],
                        task: ["aomori winter photos", "best espresso machines", "kyoto ryokan guide"][index],
                        status: ["Searching the web…", "I need a quick answer — click to reply", "View results ›"][index]
                    ),
                    reduceMotionEnabled: true
                )
                .clawdyGlow(cornerRadius: cornerRadius, radius: ClawdyGlow.maximumSafeRadius)
                .scaleEffect(transform.scale, anchor: .topLeading)
                .opacity(transform.opacity)
                .offset(y: transform.peekOffset)
                .zIndex(transform.zPosition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(renderPadding)

        let size = CGSize(width: toastSize.width + renderPadding * 2,
                          height: toastSize.height + stride * CGFloat(count - 1) + renderPadding * 2)
        dump(render(composition, pointSize: size), named: "stacked-full-width")
    }

    // MARK: - ITEM 5: the persistent RED failed pill with a dismiss (×)

    @Test func failedErrorPillEvidence() {
        let vm = viewModel(phase: .error, task: "compare standing desks", status: "Research failed")
        let padding: CGFloat = 24
        let toast = ResearchFullToastView(viewModel: vm, reduceMotionEnabled: true)
            .clawdyGlow(cornerRadius: ResearchFullToastGeometry.cornerRadius, radius: ClawdyGlow.maximumSafeRadius)
            .padding(padding)
        let size = CGSize(width: ResearchFullToastGeometry.toastSize.width + padding * 2,
                          height: ResearchFullToastGeometry.toastSize.height + padding * 2)
        dump(render(toast, pointSize: size), named: "error-pill")
    }

    // MARK: - ITEM 6: the per-session chat panel wearing the Clawdy aura

    @Test func perSessionChatPanelAuraEvidence() {
        let vm = viewModel(phase: .running, task: "compare standing desks and build a page", status: "Reading rtings.com…")
        vm.transcriptTurns = conversationTurns()
        let margin = ClawdyGlow.overlayPanelMargin
        let view = ResearchDetailOverlayView(viewModel: vm)
            .padding(margin)
        let size = CGSize(width: ResearchDetailOverlayView.contentSize.width + margin * 2,
                          height: ResearchDetailOverlayView.contentSize.height + margin * 2)
        dump(render(view, pointSize: size), named: "detail-aura")
    }

    // MARK: - ITEM 7: chat-aligned bubbles (Clawdy left / user right)

    @Test func chatAlignedBubblesEvidence() {
        let column = VStack(alignment: .leading, spacing: 12) {
            ForEach(conversationTurns()) { turn in
                ResearchChatBubbleView(turn: turn)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .background(DS.Colors.surface1)
        dump(render(column, pointSize: CGSize(width: 380, height: 360)), named: "chat-bubbles")
    }

    // MARK: - ITEM 8: the full per-session chat window (input + stop-lower-right + dismiss-upper-right)

    @Test func perSessionChatWindowEvidence() {
        let vm = viewModel(phase: .running, task: "compare standing desks and build a page", status: "Writing the page…")
        vm.transcriptTurns = conversationTurns()
        let view = ResearchDetailOverlayView(viewModel: vm)
        dump(render(view, pointSize: ResearchDetailOverlayView.contentSize), named: "chat-window")
    }

    // MARK: - Render + dump

    private func render<Content: View>(_ content: Content, pointSize: CGSize) -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: content.frame(width: pointSize.width, height: pointSize.height))
        hostingView.frame = CGRect(origin: .zero, size: pointSize)
        let window = makeOffscreenRenderWindow(width: hostingView.frame.width, height: hostingView.frame.height)
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)!
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func dump(_ rep: NSBitmapImageRep, named name: String, sourceFile: String = #filePath) {
        // Prefer an explicit dump dir; otherwise write next to this source file's worktree
        // under `evidence/` so the PNGs are easy to locate after a headless run.
        let dir = ProcessInfo.processInfo.environment["CLAWDY_PIXEL_DUMP_DIR"]
            ?? URL(fileURLWithPath: sourceFile) // …/ClawdyTests/ThisFile.swift
                .deletingLastPathComponent()      // …/ClawdyTests
                .deletingLastPathComponent()      // …/<worktree>
                .appendingPathComponent("evidence").path
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? png.write(to: outURL)
        print("CLAWDY_EVIDENCE_PNG \(outURL.path)")
    }
}
