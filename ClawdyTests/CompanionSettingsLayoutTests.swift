//
//  CompanionSettingsLayoutTests.swift
//  ClawdyTests
//
//  Pins the pure IA of the menu-bar panel's settings area: the two quiet sections
//  (Engine / Voice), their top-to-bottom order, and which controls live
//  in each — including the engine-dependent "Use my Claude Code setup" toggle. Keeping the
//  grouping/order in a pure type (`CompanionSettingsLayout`) means the panel's IA can't
//  silently drift back into a flat, ungrouped list.
//

import Testing
@testable import Clawdy

@MainActor
struct CompanionSettingsLayoutTests {

    // MARK: - Section order + titles

    @Test func sectionsAreEngineThenVoice() {
        #expect(CompanionSettingsLayout.orderedSections == [.engine, .voice])
    }

    @Test func sectionTitlesAreQuietAndConcrete() {
        #expect(CompanionSettingsSection.engine.title == "Engine")
        #expect(CompanionSettingsSection.voice.title == "Voice")
    }

    // MARK: - Engine section membership (engine-dependent)

    @Test func claudeEngineShowsModelAndEffortInEngineSection() {
        #expect(CompanionSettingsLayout.showsQuickAnswerModelRow(selectedEngineKind: .claudeCode))
        #expect(
            CompanionSettingsLayout.controls(in: .engine, selectedEngineKind: .claudeCode)
                == [.enginePicker, .quickAnswerModel, .quickAnswerEffort]
        )
    }

    @Test func codexEngineShowsOnlyEffort() {
        #expect(!CompanionSettingsLayout.showsQuickAnswerModelRow(selectedEngineKind: .codex))
        #expect(
            CompanionSettingsLayout.controls(in: .engine, selectedEngineKind: .codex)
                == [.enginePicker, .quickAnswerEffort]
        )
    }

    @Test func noEngineShowsOnlyThePicker() {
        #expect(CompanionSettingsLayout.controls(in: .engine, selectedEngineKind: nil) == [.enginePicker])
    }

    // MARK: - Voice membership (engine-independent)

    @Test func voiceSectionHoldsOnlyTheTTSProvider() {
        for engineKind in CoachEngineKind.allCases {
            #expect(
                CompanionSettingsLayout.controls(in: .voice, selectedEngineKind: engineKind)
                    == [.ttsProvider]
            )
        }
    }

    // MARK: - Every control has exactly one home

    @Test func everyControlBelongsToExactlyOneSectionForClaude() {
        let allControls = CompanionSettingsLayout.orderedSections.flatMap {
            CompanionSettingsLayout.controls(in: $0, selectedEngineKind: .claudeCode)
        }
        #expect(allControls == [.enginePicker, .quickAnswerModel, .quickAnswerEffort, .ttsProvider])
        // No control appears twice.
        #expect(Set(allControls).count == allControls.count)
    }
}
