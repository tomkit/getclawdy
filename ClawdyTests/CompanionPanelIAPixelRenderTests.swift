//
//  CompanionPanelIAPixelRenderTests.swift
//  ClawdyTests
//
//  RUNTIME pixel evidence for the menu-bar panel's settings IA redesign. A headless unit
//  test can pin the grouping/order (`CompanionSettingsLayoutTests`) but only visible pixels
//  can settle whether the panel reads as calm, hand-crafted sections instead of a
//  flat, over-labelled, AI-generated list. So this renders — through a real `NSHostingView`
//  + `cacheDisplay` — an AFTER replica of the shipped two-section layout (Engine / Voice,
//  whose HEADERS + ORDER come from the production `CompanionSettingsLayout`,
//  not hardcoded) and, beside it, a BEFORE replica of the pre-change flat layout (every
//  control stacked with equal spacing, redundant inline labels, verbose helper lines). Both
//  dump to `CLAWDY_PIXEL_DUMP_DIR` as `panel-ia-before.png` / `panel-ia-after.png` for a
//  side-by-side eyeball. The replicas are test-only scaffolding, never shipped; the render
//  path itself is asserted to produce a non-nil bitmap.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct CompanionPanelIAPixelRenderTests {

    // The panel's fixed width, so the replicas lay out exactly as the real popover does.
    private let panelWidth: CGFloat = 320

    // MARK: - Render harness (mirrors ResearchRecentsIAPixelRenderTests)

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

    /// AFTER: the sparse, two-section layout, its section headers + order pulled from the
    /// production `CompanionSettingsLayout` so the render can't drift from shipped IA.
    @Test func rendersSparseTwoSectionPanelAfter() {
        let content = ZStack {
            DS.Colors.background
            NewSectionedSettingsReplica().padding(16)
        }
        let rep = renderToPNG(
            content,
            size: CGSize(width: panelWidth, height: 360),
            named: "panel-ia-after"
        )
        #expect(rep != nil)
        #expect((rep?.pixelsWide ?? 0) > 0 && (rep?.pixelsHigh ?? 0) > 0)
    }

    /// BEFORE: the pre-change flat layout — equal-spaced controls, repeated inline labels,
    /// verbose helper text, and a boxed History card with a descriptive subtitle.
    @Test func rendersFlatPanelBefore() {
        let content = ZStack {
            DS.Colors.background
            LegacyFlatSettingsReplica().padding(16)
        }
        let rep = renderToPNG(
            content,
            size: CGSize(width: panelWidth, height: 420),
            named: "panel-ia-before"
        )
        #expect(rep != nil)
    }
}

// MARK: - AFTER replica (test-only) — two quiet sections

/// A faithful copy of the shipped two-section settings stack: quiet secondary-tone
/// section headers (from `CompanionSettingsSection.title`), hairline separation, and
/// unlabelled segmented controls / toggles under each header. Not shipped.
private struct NewSectionedSettingsReplica: View {
    @State private var selectedEngine = "Claude Code"
    @State private var selectedVoice = "Apple"
    @State private var customizationsOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(CompanionSettingsLayout.orderedSections.enumerated()), id: \.element) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(DS.Colors.borderSubtle.opacity(0.5))
                        .frame(height: 1)
                }
                sectionBody(section)
            }
        }
    }

    @ViewBuilder
    private func sectionBody(_ section: CompanionSettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(section.title)
            switch section {
            case .engine:
                segment(["Claude Code", "Codex"], selection: selectedEngine)
                if CompanionSettingsLayout.showsClaudeCustomizationsRow(selectedEngineKind: .claudeCode) {
                    toggleRow(icon: "gearshape.2", label: "Use my Claude Code setup", isOn: customizationsOn)
                }
            case .voice:
                segment(["Apple", "ElevenLabs"], selection: selectedVoice)
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segment(_ options: [String], selection: String) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Text(option)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSelected ? DS.Colors.accentSelectedFill : Color.clear)
                    )
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
    }

    private func toggleRow(icon: String, label: String, isOn: Bool) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: .constant(isOn))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
        }
    }
}

// MARK: - BEFORE replica (test-only) — flat, over-labelled list

/// A faithful copy of the pre-change flat settings list: no section grouping, every
/// control spaced equally, inline labels repeated ("Engine", "Voice"), a verbose
/// customizations helper line, and a boxed History card with a descriptive subtitle. Not
/// shipped — kept only to render the before/after density PNG.
private struct LegacyFlatSettingsReplica: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            labelledSegment("Engine", options: ["Claude Code", "Codex"])
            customizationsRowWithHelper
            labelledSegment("Voice", options: ["Apple", "ElevenLabs"])
            historyCard
        }
    }

    private func labelledSegment(_ label: String, options: [String]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    Text(option)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(option == options.first ? DS.Colors.accentText : DS.Colors.textTertiary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(option == options.first ? DS.Colors.accentSelectedFill : .clear))
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
        }
        .padding(.vertical, 4)
    }

    private var customizationsRowWithHelper: some View {
        HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "gearshape.2").font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textTertiary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use my Claude Code setup").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                    Text("Loads your CLAUDE.md, skills, MCP, and hooks").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer()
            Toggle("", isOn: .constant(true)).toggleStyle(.switch).labelsHidden().tint(DS.Colors.accent).scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var historyCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("History").font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                Text("Browse past conversations and research pages.").font(.system(size: 10)).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
    }
}
