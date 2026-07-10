//
//  ResearchHistoryIAPixelRenderTests.swift
//  ClawdyTests
//
//  RUNTIME pixel evidence for the History window's IA density redesign. A headless unit
//  test can assert the trimmed FIELDS (see `HistorySessionRowSignalTests`) but it cannot
//  confirm the session list "feels less AI / more hand-crafted" — that is a density
//  judgement only visible pixels can settle. So this renders the REAL production session
//  list column (the shipped `HistorySessionRowView`s on the same `surface1` surface the
//  window uses) through a real `NSHostingView` + `cacheDisplay`, and alongside it a
//  faithful REPLICA of the pre-change dense rows (title + dismissed capsule + kind pill +
//  status dot + status word + timestamp, on a filled/stroked selected card under a
//  three-part detail-style metadata row), dumping both to `CLAWDY_PIXEL_DUMP_DIR` as
//  `history-ia-before.png` / `history-ia-after.png` so the before/after density can be
//  eyeballed. The replica is intentionally a self-contained copy of the OLD row layout —
//  test-only scaffolding, never shipped.
//
//  Each render also `#expect`s a non-nil rasterized bitmap, so the test is a real
//  assertion (the tree renders) rather than a vacuous file dump.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ResearchHistoryIAPixelRenderTests {

    // MARK: - Sample rows shared by before/after

    private func sampleRows() -> [HistoryRow] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let now = base.addingTimeInterval(6 * 3600)

        func row(
            sessionId: String,
            title: String,
            kind: ResearchSessionKind,
            status: ResearchSessionStatus,
            updatedOffsetHours: Double,
            dismissed: Bool = false
        ) -> HistoryRow {
            let entry = ResearchManifestEntry(
                sessionId: sessionId,
                kind: kind,
                title: title,
                task: title,
                status: status,
                createdAt: base,
                updatedAt: base.addingTimeInterval(updatedOffsetHours * 3600),
                workingDir: "/tmp/\(sessionId)",
                transcriptPath: "/tmp/\(sessionId)/\(sessionId).jsonl",
                deliverablePath: nil,
                dismissed: dismissed ? true : nil
            )
            return HistoryRowBuilder.makeRow(from: entry, now: now)
        }

        return [
            row(sessionId: "r1", title: "Best winter photo spots in Aomori",
                kind: .research, status: .completed, updatedOffsetHours: 6),
            row(sessionId: "r2", title: "Compare standing desk converters under $200",
                kind: .research, status: .running, updatedOffsetHours: 5.9),
            row(sessionId: "root", title: "Quick answers",
                kind: .root, status: .active, updatedOffsetHours: 5.5),
            row(sessionId: "r3", title: "Grants for first-time documentary filmmakers",
                kind: .research, status: .completed, updatedOffsetHours: 3, dismissed: true),
            row(sessionId: "r4", title: "Latest on the EU AI Act timeline",
                kind: .research, status: .failed, updatedOffsetHours: 1),
        ]
    }

    // MARK: - Render harness (mirrors ResearchRecentsIAPixelRenderTests)

    /// Rasterizes `content` to a real bitmap via `cacheDisplay`, writes it to
    /// `CLAWDY_PIXEL_DUMP_DIR` (when set) as a PNG, and RETURNS the bitmap so the caller can
    /// assert it is non-nil (a genuine "the tree rendered" check, not a vacuous dump).
    @discardableResult
    private func renderToPNG<Content: View>(_ content: Content, size: CGSize, named name: String) -> NSBitmapImageRep? {
        let hostingView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = makeOffscreenRenderWindow(width: hostingView.frame.width, height: hostingView.frame.height)
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

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

    private let columnWidth: CGFloat = 300

    /// The AFTER: the real, shipped sparse session list column (single-line rows, one quiet
    /// trailing signal, no card at rest, a slim accent edge on the selected row).
    @Test func rendersSparseHistoryListAfter() {
        let rows = sampleRows()
        let content = ZStack {
            Color.black
            SparseHistoryListColumn(rows: rows, selectedSessionID: "r1")
                .frame(width: columnWidth)
        }
        let bitmap = renderToPNG(
            content,
            size: CGSize(width: columnWidth + 40, height: 300),
            named: "history-ia-after"
        )
        #expect(bitmap != nil)
        #expect((bitmap?.pixelsWide ?? 0) > 0)
    }

    /// The BEFORE: a faithful replica of the pre-change dense rows (dismissed capsule + kind
    /// pill + status dot + status word + timestamp, on a filled+stroked selected card), for
    /// side-by-side density comparison. Test-only scaffolding (never shipped).
    @Test func rendersDenseHistoryListBefore() {
        let rows = sampleRows()
        let content = ZStack {
            Color.black
            LegacyDenseHistoryListColumn(rows: rows, selectedSessionID: "r1")
                .frame(width: columnWidth)
        }
        let bitmap = renderToPNG(
            content,
            size: CGSize(width: columnWidth + 40, height: 360),
            named: "history-ia-before"
        )
        #expect(bitmap != nil)
        #expect((bitmap?.pixelsWide ?? 0) > 0)
    }
}

// MARK: - After: the real shipped rows in the list column chrome

/// Wraps the REAL `HistorySessionRowView`s in the same header + `surface1` surface the
/// window uses, so the render exercises the shipped row tree, not a copy.
private struct SparseHistoryListColumn: View {
    let rows: [HistoryRow]
    let selectedSessionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversations")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    HistorySessionRowView(
                        row: row,
                        isSelected: row.sessionId == selectedSessionID,
                        onSelect: {}
                    )
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.surface1)
    }
}

// MARK: - Before: pre-change dense layout replica (test-only)

/// A faithful copy of the OLD `sessionRow` list (title + "dismissed" capsule tag on line
/// one, then a kind pill + status dot + status word + timestamp metadata row, on a
/// filled+stroked selected card), preserved ONLY to render the before/after density PNG.
private struct LegacyDenseHistoryListColumn: View {
    let rows: [HistoryRow]
    let selectedSessionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversations")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            VStack(spacing: 4) {
                ForEach(rows) { row in
                    LegacyDenseHistoryRow(row: row, isSelected: row.sessionId == selectedSessionID)
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.surface1)
    }
}

private struct LegacyDenseHistoryRow: View {
    let row: HistoryRow
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                if row.isDismissed {
                    Text("dismissed")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(DS.Colors.textTertiary.opacity(0.16)))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(row.kindBadge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(row.kind == .root ? DS.Colors.accentText : DS.Colors.success)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill((row.kind == .root ? DS.Colors.accentText : DS.Colors.success).opacity(0.14)))
                HStack(spacing: 3) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(row.statusLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer(minLength: 0)
                Text(row.relativeTimestamp)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .opacity(row.isDismissed ? 0.55 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(isSelected ? DS.Colors.accent : Color.clear, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch row.status {
        case .running, .active: return DS.Colors.accent
        case .completed: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        case .stopped: return DS.Colors.textTertiary
        }
    }
}
