//
//  ResearchRecentsIAPixelRenderTests.swift
//  ClawdyTests
//
//  RUNTIME pixel evidence for the "Recent Research" IA density redesign. A headless unit
//  test can assert the trimmed FIELDS (see `ResearchRecentsRowSecondarySignalTests`) but it
//  cannot confirm the surface "feels less AI / more hand-crafted" — that is a density
//  judgement only visible pixels can settle. So this renders the REAL production recents
//  list content (`ResearchRecentsInlineListContent` on the live `ResearchRecentsMorphingSurface`)
//  through a real `NSHostingView` + `cacheDisplay`
//  and, alongside it, a faithful REPLICA of the pre-change dense row layout, dumping both to
//  `CLAWDY_PIXEL_DUMP_DIR` as `recents-ia-before.png` / `recents-ia-after.png` so the
//  before/after density can be eyeballed. The replica is intentionally a self-contained copy
//  of the OLD view code (kind pill + status dot + status word + timestamp + two labelled
//  buttons, per-row card) — it is test-only scaffolding, never shipped.
//
//  The overlay panels are `sharingType = .readOnly` (visible to external recorders), so a
//  live screencapture is not a reliable pixel source here; `cacheDisplay` rasterizes the
//  true SwiftUI tree regardless.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ResearchRecentsIAPixelRenderTests {

    // MARK: - Sample rows shared by before/after

    private func sampleRows() -> [ResearchRecentsRowModel] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let now = base.addingTimeInterval(6 * 3600)

        func model(
            sessionId: String,
            title: String,
            status: ResearchSessionStatus,
            updatedOffsetHours: Double,
            hasPage: Bool,
            dismissed: Bool = false
        ) -> ResearchRecentsRowModel {
            let deliverablePath = hasPage
                ? ClaudeResearchEngine.researchSupportDirectory()
                    .appendingPathComponent("\(sessionId)/report.html").path
                : nil
            let entry = ResearchManifestEntry(
                sessionId: sessionId,
                kind: sessionId == "root" ? .root : .research,
                title: title,
                task: title,
                status: status,
                createdAt: base,
                updatedAt: base.addingTimeInterval(updatedOffsetHours * 3600),
                workingDir: "/tmp/\(sessionId)",
                transcriptPath: "/tmp/\(sessionId)/\(sessionId).jsonl",
                deliverablePath: deliverablePath,
                dismissed: dismissed ? true : nil
            )
            let row = HistoryRowBuilder.makeRow(from: entry, now: now)
            // Resolve actions with a stub that treats any fenced page path as present, so the
            // render exercises the real BOTH-outputs affordance without touching disk.
            let actions = ResearchRecentsRowActions.resolve(for: row) { _ in hasPage }
            return ResearchRecentsRowModel(row: row, isDismissed: dismissed, actions: actions)
        }

        return [
            model(sessionId: "r1", title: "Best winter photo spots in Aomori",
                  status: .completed, updatedOffsetHours: 6, hasPage: true),
            model(sessionId: "r2", title: "Compare standing desk converters under $200",
                  status: .running, updatedOffsetHours: 5.9, hasPage: false),
            model(sessionId: "root", title: HistoryRowBuilder.quickAnswersGroupTitle,
                  status: .active, updatedOffsetHours: 5.5, hasPage: false),
            model(sessionId: "r3", title: "Grants for first-time documentary filmmakers",
                  status: .completed, updatedOffsetHours: 3, hasPage: true, dismissed: true),
            model(sessionId: "r4", title: "Latest on the EU AI Act timeline",
                  status: .failed, updatedOffsetHours: 1, hasPage: false),
        ]
    }

    // MARK: - Render harness (mirrors ResearchOverlayDarkSurfacePixelRenderTests)

    private func renderToPNG<Content: View>(_ content: Content, size: CGSize, named name: String) {
        let hostingView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = makeOffscreenRenderWindow(width: hostingView.frame.width, height: hostingView.frame.height)
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            window.orderOut(nil)
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        window.orderOut(nil)

        guard let dir = ProcessInfo.processInfo.environment["CLAWDY_PIXEL_DUMP_DIR"],
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// The AFTER: the real, shipped sparse recents list.
    @Test func rendersSparseRecentsListAfter() {
        let model = ResearchRecentsBadgeModel()
        model.state = .listOpen
        model.rows = sampleRows()

        // Render on the dark app backdrop so the surface1 panel reads as it does live. The
        // real inline-list content drawn on the live shared morphing surface at the list-open
        // endpoint (the exact body the deleted standalone wrapper rendered).
        let content = ZStack {
            Color.black
            ResearchRecentsMorphingSurface(
                size: ResearchRecentsSurfaceMorph.listOpenSize,
                cornerRadius: ResearchRecentsSurfaceMorph.listOpenCornerRadius
            ) {
                ResearchRecentsInlineListContent(model: model)
            }
        }
        renderToPNG(
            content,
            size: CGSize(width: ResearchRecentsLayout.inlineListSize.width + 40,
                         height: ResearchRecentsLayout.inlineListSize.height + 40),
            named: "recents-ia-after"
        )
    }

    /// The BEFORE: a faithful replica of the pre-change dense recents list, for side-by-side
    /// density comparison. Test-only scaffolding (never shipped).
    @Test func rendersDenseRecentsListBefore() {
        let content = ZStack {
            Color.black
            LegacyDenseRecentsListReplica(rows: sampleRows())
        }
        renderToPNG(
            content,
            // The old panel footprint (320 × 360) before the trim.
            size: CGSize(width: ResearchRecentsLayout.inlineListSize.width + 40, height: 360 + 40),
            named: "recents-ia-before"
        )
    }
}

// MARK: - Pre-change dense layout replica (test-only)

/// A faithful copy of the OLD `ResearchRecentsInlineListView` + `ResearchRecentsRowView`
/// (accent clock header, divider, three-line rows with a kind pill + status dot + status
/// word + timestamp + two labelled action buttons, per-row filled card, accent footer),
/// preserved here ONLY to render the before/after density PNG. Not shipped.
private struct LegacyDenseRecentsListReplica: View {
    let rows: [ResearchRecentsRowModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundColor(DS.Colors.accent)
                Text("Recent research")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(5)
                    .background(Circle().fill(DS.Colors.surface2))
            }
            Divider().overlay(DS.Colors.borderSubtle.opacity(0.4))
            VStack(spacing: 6) {
                ForEach(rows) { rowModel in
                    LegacyDenseRow(rowModel: rowModel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Text("Show all history ›")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
            }
        }
        .padding(18)
        .frame(width: ResearchRecentsLayout.inlineListSize.width, height: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ResearchToastSurfaceAppearance.background)
        )
    }
}

private struct LegacyDenseRow: View {
    let rowModel: ResearchRecentsRowModel
    private var row: HistoryRow { rowModel.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                if rowModel.isDismissed {
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
            HStack(spacing: 12) {
                if rowModel.actions.page != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.richtext").font(.system(size: 10, weight: .semibold))
                        Text("View page ›").font(.system(size: 11, weight: .semibold))
                    }.foregroundColor(DS.Colors.accent)
                }
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble").font(.system(size: 10, weight: .semibold))
                    Text("View conversation").font(.system(size: 11, weight: .semibold))
                }.foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.5))
        )
        .opacity(rowModel.isDismissed ? 0.55 : 1.0)
    }

    private var statusColor: Color {
        switch row.status {
        case .running, .active: return DS.Colors.accent
        case .completed: return DS.Colors.success
        case .failed: return DS.Colors.warning
        case .stopped: return DS.Colors.textTertiary
        }
    }
}
