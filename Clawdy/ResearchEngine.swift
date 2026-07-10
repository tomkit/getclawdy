//
//  ResearchEngine.swift
//  Clawdy
//
//  The engine seam for the autonomous research subsystem. Today there is exactly ONE
//  conforming engine — `ClaudeResearchEngine` (a dedicated `claude -p` process) — and
//  this protocol simply captures the surface `ResearchSession` already drives it
//  through. It exists so a second engine (a future `CodexResearchEngine`) can be
//  slotted in behind the same seam WITHOUT `ResearchSession` /
//  `ResearchSessionManager` learning a new type: they hold a `ResearchEngine`
//  existential and keep calling the same three phase methods.
//
//  This is a PURE-REFACTOR seam (Stage 2 of Codex research parity): it introduces NO
//  new behavior and NO new engine. The method signatures MIRROR EXACTLY what
//  `ClaudeResearchEngine` already implements — they were lifted, not redesigned — so
//  the existing Claude flow is unchanged. The two capability flags below are where the
//  engines will legitimately differ later (Codex has no pre-minted `--session-id` and
//  no separate plan phase), surfaced now so the seam is ready without acting on them
//  yet.
//

import Foundation

// MARK: - Engine selection (which CLI + binary a research run uses)

/// The concrete research engine a run should use: WHICH coaching-CLI kind
/// (`.claudeCode` / `.codex`) plus the resolved absolute path to that CLI's binary.
/// The `ResearchSessionManager` resolves this from the user's SELECTED coach engine
/// (falling back to whichever single CLI is installed) so a research run is driven by
/// the same engine the user picked for quick answers.
struct ResearchEngineSelection: Equatable {
    let kind: CoachEngineKind
    let binaryPath: String
}

// MARK: - Shared phase result types

/// The result of the plan/clarify phase: the resumable session id plus what to
/// do next (ask the user, or execute straight away).
///
/// MOVED OUT of `ClaudeResearchEngine` (it used to be nested there) so both the
/// protocol and every future conforming engine can return the SAME type. The shape is
/// unchanged from when it lived on the concrete engine.
struct PlanPhaseResult {
    let sessionID: String
    let outcome: ResearchPlanAnalyzer.Outcome
}

/// The result of a voice-native FOLLOW-UP turn on a finished session: the model's
/// concise spoken reply, whether it (re)wrote report.html this turn (so the results
/// window knows to reload the WKWebView), and the deliverable URL when present. A
/// PURE QUESTION follow-up writes nothing → `deliverableWasRewritten == false`; an
/// ITERATE follow-up replaces report.html in place → `true`.
///
/// MOVED OUT of `ClaudeResearchEngine` (previously nested) for the same reason as
/// `PlanPhaseResult`. Shape unchanged.
struct FollowUpPhaseResult {
    let spokenAnswer: String?
    let deliverableWasRewritten: Bool
    let deliverableURL: URL?
}

// MARK: - The engine seam

/// The surface `ResearchSession` drives a research run through: a plan phase, an
/// execute phase, and a voice follow-up phase, plus two capability flags the engines
/// will differ on later. Every member mirrors `ClaudeResearchEngine`'s existing
/// signatures verbatim — this protocol was extracted from the concrete engine, not
/// designed anew — so conforming is a no-op for the Claude engine and the flow is
/// byte-for-byte unchanged.
///
/// Class-bound (`AnyObject`): a research engine is a stateful reference type owning a
/// live subprocess, mirroring how `ClaudeResearchEngine` (a `final class`) is created
/// once per run and held by the session.
protocol ResearchEngine: AnyObject {
    /// Whether this engine can pre-mint the session id up front (Claude accepts a
    /// `--session-id <uuid>` and echoes it back). A future Codex engine cannot, so it
    /// will discover the id from the run instead. Not acted on in this stage.
    var supportsPreMintedSessionID: Bool { get }

    /// Whether this engine has a distinct PLAN phase (Claude's `--permission-mode plan`
    /// clarify pass). A future Codex engine may go straight to execution. Not acted on
    /// in this stage.
    var supportsPlanPhase: Bool { get }

    /// Whether this engine can resume its session for a FOLLOW-UP turn right now. Claude
    /// always can once a session exists (it owns the session id); Codex can only resume
    /// if its execute turn captured a `thread_id`. A default of `true` keeps every
    /// non-Codex engine's follow-up behavior unchanged; Codex overrides it so a run that
    /// never captured a thread id is marked NON-FOLLOWABLE instead of offering a Send that
    /// would fail.
    var canResumeForFollowUp: Bool { get }

    /// Seeds the durable RESUME handle when a FINISHED session is RECONSTRUCTED from the
    /// manifest (e.g. a page opened from History, or after an app relaunch) into a
    /// freshly-built engine that never ran the original turns. Claude's resume handle is
    /// the session id it already owns, so it ignores this (the default no-op below); Codex's
    /// resume handle is the post-hoc `thread_id`, which a freshly-built `CodexResearchEngine`
    /// does NOT know — reconstruction seeds it here from the persisted (or path-recovered)
    /// value so the follow-up turn can `codex exec resume <thread_id>`. Only ever called on
    /// a reconstructed engine, before its first follow-up turn; a natively-live engine that
    /// captured its own handle during the run never needs it.
    func adoptResumeHandle(_ resumeHandle: String)

    /// Creates (if needed) and returns the STABLE, durable per-session working
    /// directory this engine's run executes in and writes its deliverable to.
    /// Promoted to the protocol in Stage 3 so each engine owns its OWN directory
    /// strategy: Claude keys the directory by its pre-minted session id; Codex keys it
    /// by the client-minted run id (its own thread id is only known post-hoc). Both
    /// resolve under `~/Library/Application Support/Clawdy/research/<id>/`.
    func makeSessionOutputDirectory(sessionID: String, applicationSupportDirectory: URL) throws -> URL

    /// The absolute path to this engine's on-disk session transcript, or nil when it
    /// is not yet resolvable. Claude derives it deterministically up front
    /// (`~/.claude/projects/<sanitized-cwd>/<sessionId>.jsonl`); Codex only learns its
    /// thread id AFTER the run starts, so it returns nil until then. Recorded in the
    /// manifest for the History UI.
    func transcriptPath(sessionID: String, outputDirectory: URL) -> String?

    /// Runs the plan/clarify phase and returns the session id plus whether the user
    /// must answer clarifying questions before executing.
    func runPlanPhase(
        task: String,
        sessionID: String,
        outputDirectory: URL,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> PlanPhaseResult

    /// Resumes the plan session and runs the autonomous execute phase, returning the
    /// file URL of the produced HTML deliverable.
    func runExecutePhase(
        sessionID: String,
        outputDirectory: URL,
        clarificationAnswers: String?,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> URL

    /// Continues a FINISHED session's own thread with a spoken follow-up: answers a
    /// question (writes nothing) or iterates on the page (rewrites report.html).
    func runFollowUpPhase(
        sessionID: String,
        outputDirectory: URL,
        followUpPrompt: String,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> FollowUpPhaseResult
}

extension ResearchEngine {
    /// Default: an engine can resume for a follow-up. Only Codex (whose resume handle is a
    /// post-hoc `thread_id`) overrides this. Declaring it a protocol REQUIREMENT above (not
    /// just an extension method) ensures the override is dynamically dispatched through the
    /// `ResearchEngine` existential the session holds.
    var canResumeForFollowUp: Bool { true }

    /// Default: seeding a resume handle is a no-op. Claude (and any engine that resumes by
    /// the session id it already owns) needs nothing seeded on reconstruction; only Codex
    /// overrides this to remember the `thread_id` its `codex exec resume` needs. Declaring
    /// it a protocol REQUIREMENT above ensures Codex's override is dispatched through the
    /// `ResearchEngine` existential the manager holds when reconstructing a finished run.
    func adoptResumeHandle(_ resumeHandle: String) {}
}
