//
//  ResearchChatBubbleView.swift
//  Clawdy
//
//  The ONE shared chat-bubble view for a research session's conversation transcript,
//  used in BOTH the Clawdy History window (`ResearchHistoryWindow`) and the per-session
//  chat detail panel (`ResearchDetailOverlayView`) so the two render a conversation
//  identically.
//
//  CHAT ALIGNMENT: a conversation reads like a chat — CLAWDY (assistant) messages are
//  LEFT-aligned with one bubble treatment, and USER messages are RIGHT-aligned with a
//  distinct (accent-tinted) bubble, so it's obvious at a glance who said what. Tool calls
//  and tool results are plumbing, not conversation, so they stay compact muted one-liners
//  on the leading edge (never a chat bubble).
//
//  The source of truth is the read-only `TranscriptTurn` (`kind`/`text`/`detail`) parsed
//  from Claude Code's own `.jsonl` by `TranscriptParser` / surfaced by
//  `ResearchTranscriptFeed`. The leading/trailing decision is factored into the pure,
//  AppKit-free `ResearchChatBubbleSide` so the who-said-what alignment mapping
//  (isUser → trailing, assistant → leading) is unit-tested with no UI.
//

import SwiftUI

// MARK: - Pure alignment mapping (AppKit/SwiftUI-free)

/// Which side of the chat column a transcript turn sits on. Pure + `Equatable` so the
/// alignment contract (user → trailing/right, assistant + tool plumbing → leading/left)
/// is unit-testable with no view.
enum ResearchChatBubbleSide: Equatable {
    /// Left-aligned: Clawdy (assistant) messages and the muted tool-call / tool-result
    /// plumbing lines.
    case leading
    /// Right-aligned: the USER's own messages.
    case trailing

    /// The side for a turn of `kind`. Only a `userMessage` sits on the trailing (right)
    /// edge; assistant prose and tool plumbing sit on the leading (left) edge.
    static func side(for kind: TranscriptTurnKind) -> ResearchChatBubbleSide {
        switch kind {
        case .userMessage:
            return .trailing
        case .assistantMessage, .toolCall, .toolResult:
            return .leading
        }
    }

    /// Whether a turn renders as a full chat BUBBLE (a real message) vs. a compact muted
    /// plumbing line (a tool call / result). Only conversation messages get a bubble.
    static func rendersAsBubble(kind: TranscriptTurnKind) -> Bool {
        switch kind {
        case .userMessage, .assistantMessage:
            return true
        case .toolCall, .toolResult:
            return false
        }
    }
}

// MARK: - Shared chat-bubble view

/// One transcript turn rendered chat-style. Clawdy (assistant) bubbles hug the LEFT; the
/// user's bubbles hug the RIGHT with a distinct accent-tinted treatment; tool activity
/// renders as a compact muted one-liner on the left. Read-only — it renders a
/// `TranscriptTurn` and never mutates anything.
struct ResearchChatBubbleView: View {
    let turn: TranscriptTurn

    /// The maximum fraction of the column width a chat bubble may occupy, so a message
    /// clearly reads as a left/right bubble rather than a full-width block.
    private let maximumBubbleWidthFraction: CGFloat = 0.82

    var body: some View {
        switch turn.kind {
        case .assistantMessage:
            messageBubble(
                roleLabel: "Clawdy",
                roleColor: DS.Colors.success,
                bubbleFill: DS.Colors.surface2,
                side: .leading
            )
        case .userMessage:
            messageBubble(
                roleLabel: "You",
                roleColor: DS.Colors.accentText,
                bubbleFill: DS.Colors.surface3,
                side: .trailing
            )
        case .toolCall:
            toolLine(icon: "wrench.and.screwdriver", prefix: turn.detail ?? "tool")
        case .toolResult:
            toolLine(icon: "arrow.turn.down.right", prefix: "result")
        }
    }

    /// A left- or right-aligned message bubble. The `HStack` + `Spacer` on the opposite
    /// side pushes the bubble to its chat side; the bubble itself caps its width so it
    /// never spans the whole column.
    private func messageBubble(
        roleLabel: String,
        roleColor: Color,
        bubbleFill: Color,
        side: ResearchChatBubbleSide
    ) -> some View {
        let bubbleAlignment: HorizontalAlignment = side == .trailing ? .trailing : .leading
        return HStack(spacing: 0) {
            if side == .trailing { Spacer(minLength: 24) }
            VStack(alignment: bubbleAlignment, spacing: 4) {
                Text(roleLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(roleColor)
                Text(turn.text)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: side == .trailing ? .trailing : .leading)
                    .multilineTextAlignment(side == .trailing ? .trailing : .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(bubbleFill)
            )
            .frame(maxWidth: bubbleMaximumWidth, alignment: side == .trailing ? .trailing : .leading)
            if side == .leading { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity, alignment: side == .trailing ? .trailing : .leading)
    }

    /// The compact, muted tool-activity line — leading-aligned plumbing, not a bubble.
    private func toolLine(icon: String, prefix: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Text(prefix)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            if !turn.text.isEmpty {
                Text(turn.text)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }

    /// A soft cap on the bubble width via a `GeometryReader`-free heuristic: SwiftUI's
    /// `.frame(maxWidth:)` clamps the bubble, and the opposite `Spacer` pushes it to its
    /// side. We use a generous fixed max so short messages hug their side tightly while a
    /// long message still wraps well within the column.
    private var bubbleMaximumWidth: CGFloat {
        // A comfortable reading width; the enclosing column is narrower than this in the
        // toast detail panel and wider in the History window, and `.frame(maxWidth:)`
        // simply takes the smaller of the two, so one constant serves both surfaces.
        320
    }
}
