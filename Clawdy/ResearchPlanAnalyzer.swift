//
//  ResearchPlanAnalyzer.swift
//  Clawdy
//
//  Pure decision for the research PLAN/CLARIFY phase. The plan phase runs
//  `claude -p --permission-mode plan`, in which the model does NOT execute tools:
//  it either asks clarifying questions and ends the turn, or it decides it has
//  enough to proceed straight to execution. The empirical signal (see the
//  AUTONOMOUS_RESEARCH_FINDINGS investigation) is:
//
//    - The plan-phase turn ends in plan mode WITHOUT running tools, AND its final
//      text asks clarifying questions  →  surface those questions to the user.
//    - It proceeds (a plan, no questions) — or it ran tools                       →  go straight to execution.
//
//  Side-effect-free and unit-testable: it never spawns a process.
//

import Foundation

enum ResearchPlanAnalyzer {
    /// What the app should do after the plan phase finishes.
    enum Outcome: Equatable {
        /// The plan agent needs answers before it can proceed. Carries the
        /// (already-trimmed) question text to show the user in the clarify panel.
        case needsClarification(questions: String)
        /// The plan agent is ready — proceed directly to the execute phase.
        case readyToExecute
    }

    /// Decides the outcome from the plan phase's terminal `result` text and how
    /// many tools the plan agent actually executed.
    ///
    /// - If the plan agent executed ANY tools, it has already begun acting on the
    ///   task, so we proceed to execution rather than interrupting it for input.
    /// - Otherwise, if the final text asks at least one question, that is the
    ///   "needs input" signal — surface the questions.
    /// - Otherwise it presented a plan with no questions — proceed.
    static func analyze(planResultText: String, toolUseCount: Int) -> Outcome {
        if toolUseCount > 0 {
            return .readyToExecute
        }
        let trimmedPlanText = planResultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if textAsksQuestions(trimmedPlanText) {
            return .needsClarification(questions: trimmedPlanText)
        }
        return .readyToExecute
    }

    /// Heuristic for "this text asks the user something": it contains a question
    /// mark and at least some non-question content. A bare empty string or a plan
    /// statement with no "?" is treated as not asking.
    static func textAsksQuestions(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("?")
    }
}
