//
//  ResearchHistoryWindow.swift
//  Clawdy
//
//  The native History window (SLICE D): a real, standard titled/resizable
//  `NSWindow` (NOT an on-screen overlay panel) that lets the user browse the
//  history of ALL Clawdy conversations — the warm quick-answer "root" thread AND
//  every present & past research session — and read each one's transcript, plus
//  open a finished research run's generated page.
//
//  Everything here is strictly READ-ONLY over the manifest and the transcripts:
//  the window loads `ResearchManifestStore.loadSessions()` and parses each entry's
//  Claude Code `.jsonl` transcript, but never writes or deletes either. It only
//  ever touches transcripts the manifest points at (by session id) — it does NOT
//  scan `~/.claude`, so the user's own unrelated Claude Code projects stay private.
//
//  The list/parse logic lives in the pure `ResearchHistoryModels`; this file is the
//  AppKit/SwiftUI shell (window lifecycle + view model + rendering).
//

import AppKit
import Combine
import SwiftUI

// MARK: - Follow-up routing seam

/// The narrow seam the History window uses to CONTINUE a selected conversation's session
/// (making its research toast active again) WITHOUT owning the research subsystem. It is
/// implemented by `ResearchSessionManager`, so a History follow-up routes through the
/// exact same reactivation path a spoken follow-up over a frontmost results window takes:
/// `followUpOnSession(id:prompt:)` reconstructs a finished session from the manifest if it
/// isn't live and flips its toast back to working; `stopSession(id:)` cancels a live run;
/// `liveOverlayPhase(forSessionID:)` drives the composer's Send↔Stop morph.
@MainActor
protocol ResearchHistoryFollowUpRouting: AnyObject {
    /// Continues `sessionID`'s thread with `prompt` (reconstructing it from the manifest if
    /// it isn't live) and reactivates its research toast. Returns whether it routed.
    @discardableResult
    func followUpOnSession(id sessionID: ResearchSessionID, prompt: String) -> Bool
    /// Stops `sessionID`'s live run (SIGTERM to its process), if it is live. No-op otherwise.
    func stopSession(id sessionID: ResearchSessionID)
    /// The live overlay phase of `sessionID` if it is currently live, else nil.
    func liveOverlayPhase(forSessionID sessionID: ResearchSessionID) -> ResearchOverlayPhase?
    /// Whether a NOT-live `sessionID` could actually be reconstructed from the manifest for a
    /// follow-up right now (a `.completed` research entry with a deliverable + a resolvable
    /// `claude`). Used to decide whether a not-live selected row presents an enabled Send.
    func canReconstructFinishedSession(forSessionID sessionID: ResearchSessionID) -> Bool
    /// Fires a session's id whenever its live lifecycle phase changes. The open History view
    /// model subscribes so the composer for a selected LIVE session reconciles to its true
    /// phase (never a stale enabled Send after an external transition).
    var sessionLifecycleChangedPublisher: AnyPublisher<ResearchSessionID, Never> { get }
}

// MARK: - Pure composer disposition (AppKit-free)

/// What the History detail pane's follow-up composer should present for the selected
/// conversation, decided PURELY from the TRUE resumability signals (never the possibly-stale
/// manifest status): the row kind, the session's LIVE overlay phase (nil if it isn't live),
/// and whether a not-live session can actually be reconstructed. Kept pure so the "never an
/// enabled Send that would be silently refused" invariant is unit-tested with no window.
enum HistoryComposerDisposition: Equatable {
    /// No composer — not a research row, or the session is not resumable (a stale/ended run
    /// with no live session, a live `.stopped`/`.error`/`.idle`, or a non-reconstructable one).
    case hidden
    /// An ENABLED Send — the session can take a follow-up now (a live run awaiting the user, a
    /// live done run, or a reconstructable finished run that will be reactivated).
    case send
    /// A Stop — the selected session is a LIVE, actively-working run; the one control cancels it.
    case stop
}

enum HistoryComposerAvailability {
    /// The composer disposition from the real signals. A LIVE session's phase is authoritative
    /// (so a just-stopped session is `.hidden`, never an enabled Send that `ResearchSession.
    /// followUp` would refuse); a not-live session is `.send` only if it can be reconstructed
    /// (`.completed`), else `.hidden`. Only research sessions qualify — never the warm root thread.
    static func disposition(
        kind: ResearchSessionKind,
        liveOverlayPhase: ResearchOverlayPhase?,
        canReconstruct: Bool
    ) -> HistoryComposerDisposition {
        guard kind == .research else { return .hidden }
        if let liveOverlayPhase {
            // Mirrors `ResearchSession.canAcceptFollowUp`: a working run enqueues (button is
            // Stop), an awaiting/done run sends, and idle/failed/stopped refuse (no composer).
            switch liveOverlayPhase {
            case .running:
                return .stop
            case .needsInput, .done:
                return .send
            case .idle, .error, .stopped:
                return .hidden
            }
        }
        return canReconstruct ? .send : .hidden
    }
}

// MARK: - Pure row signal (AppKit-free)

/// The SINGLE quiet trailing signal a History session row carries — the whole old
/// three-part metadata row (kind pill + status dot + status word + relative time)
/// collapsed to ONE token, so a row shows the session's title plus this one signal and
/// never a stack of descriptors. Mirrors the recents list's
/// `ResearchRecentsRowSecondarySignal`; kept as its own History-owned, AppKit-free type
/// so the trimmed IA is unit-tested with no window. The view maps `tone` to a DS colour.
struct HistorySessionRowSignal: Equatable {
    /// The colour ROLE for the token (mapped to a concrete colour by the view, kept
    /// colour-free here). `neutral` is the quiet tertiary text used for timestamps and
    /// ended runs; `active` is the quiet accent for a live run; `failure` flags a failed
    /// run in RED (matching the live progress overlay's error color) rather than the amber
    /// `warning` used for non-failure caution states.
    enum Tone: Equatable {
        case neutral
        case active
        case failure
        case warning
    }

    let text: String
    let tone: Tone

    /// Resolves the one signal for a row. A DISMISSED row collapses to a quiet
    /// "dismissed" tag (the view ALSO dims the row, so the two together are the preserved
    /// dismissed affordance). Otherwise the signal is the STATUS when the run is live or
    /// ended abnormally (running / failed / stopped) and the relative TIME when it simply
    /// completed or is the always-on grouped quick-answers row — never both, never stacked.
    static func forRow(_ row: HistoryRow) -> HistorySessionRowSignal {
        if row.isDismissed {
            return HistorySessionRowSignal(text: "dismissed", tone: .neutral)
        }
        switch row.status {
        case .running:
            return HistorySessionRowSignal(text: "running", tone: .active)
        case .failed:
            return HistorySessionRowSignal(text: "failed", tone: .failure)
        case .stopped:
            return HistorySessionRowSignal(text: "stopped", tone: .neutral)
        case .completed, .active:
            return HistorySessionRowSignal(text: row.relativeTimestamp, tone: .neutral)
        }
    }
}

// MARK: - Window controller

/// Owns the single History `NSWindow`. Reused across opens (bring-to-front rather
/// than spawning duplicates) and refreshed from the manifest every time it's shown.
@MainActor
final class ResearchHistoryWindowController {
    private var window: NSWindow?
    private let viewModel = ResearchHistoryViewModel()
    /// The window's close observer. Held so its lifetime matches the window; on close it
    /// suspends the view model's live-lifecycle subscription so no dangling sink lingers
    /// while the window is hidden (re-established on the next `show()`).
    private var closeObserver: HistoryWindowCloseObserver?

    /// The follow-up router (the `ResearchSessionManager`) the detail-pane composer submits
    /// through, so continuing a conversation reactivates its toast via the SAME path a
    /// spoken follow-up uses. Weak: the window controller never owns the manager. Forwarded
    /// to the view model on `show()` (and here, if set while open) so both History entry
    /// points (menu-bar button + toast "view history") wire the same continuation path.
    weak var followUpRouter: ResearchHistoryFollowUpRouting? {
        didSet { if window?.isVisible == true { viewModel.followUpRouter = followUpRouter } }
    }

    /// Resolves the app-RESOLVED absolute CLI binary path for a session's engine, used to
    /// build a "Resume in Terminal" command that embeds the full binary path (Terminal's
    /// login-shell PATH may differ from the app's augmented PATH). Injected the SAME way
    /// `followUpRouter` is — an owner points this at the app's ALREADY-BUILT
    /// `CoachEngineRegistry` (`detectedBinaryPath(for:)` just reads its cached detection result,
    /// so this NEVER runs an engine-detection scan). Defaults to a SAFE no-op that returns nil
    /// (the button simply stays hidden) so no UI/render path can ever trigger detection. The
    /// view model reads this ONCE per show (off the render path) and caches the result; nothing
    /// on the render path ever calls it.
    var resolveResumeBinaryPath: @MainActor (ResearchResumeEngine) -> String? = { _ in nil } {
        didSet { if window?.isVisible == true { viewModel.resolveResumeBinaryPath = resolveResumeBinaryPath } }
    }

    /// Opens the History window (creating it once), refreshes the session list from
    /// the manifest, and brings it to the front. If it's already open, this just
    /// re-lists and focuses it — never a second window.
    func show() {
        show(selectSessionID: nil)
    }

    /// Opens the History window and, if `selectSessionID` is given, selects that
    /// session's row (loading its transcript) so the user lands directly on the
    /// conversation they asked to see — the destination of a research toast's "view
    /// history" affordance. An unknown id falls back to the normal (no-selection) open.
    func show(selectSessionID: ResearchSessionID?) {
        createWindowIfNeeded()
        guard let window else { return }

        // (Re)establish the live-lifecycle subscription for this open session — it may have
        // been suspended by a previous close. Setting the router re-subscribes via the view
        // model's `didSet`.
        viewModel.followUpRouter = followUpRouter
        viewModel.resolveResumeBinaryPath = resolveResumeBinaryPath

        viewModel.refresh()
        if let selectSessionID {
            viewModel.selectIfPresent(sessionID: selectSessionID)
        }

        if !window.isVisible, let screen = NSScreen.main {
            let windowSize = window.frame.size
            let visibleFrame = screen.visibleFrame
            let origin = CGPoint(
                x: visibleFrame.midX - windowSize.width / 2,
                y: visibleFrame.midY - windowSize.height / 2
            )
            window.setFrameOrigin(origin)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindowIfNeeded() {
        if window != nil { return }

        let historyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        historyWindow.title = "Clawdy History"
        historyWindow.titlebarAppearsTransparent = false
        historyWindow.isReleasedWhenClosed = false
        historyWindow.collectionBehavior = [.fullScreenPrimary]
        historyWindow.minSize = NSSize(width: 720, height: 420)

        let rootView = ResearchHistoryView(viewModel: viewModel)
        historyWindow.contentView = NSHostingView(rootView: rootView)

        // On close, suspend the view model's live-lifecycle subscription (and drop its router
        // reference) so no Combine sink lingers while the window is hidden. `show()`
        // re-establishes it. Not a retain-cycle fix (the sink already captures self weakly) —
        // it makes the "torn down on close" behavior real.
        let observer = HistoryWindowCloseObserver { [weak self] in
            self?.viewModel.followUpRouter = nil
        }
        historyWindow.delegate = observer
        closeObserver = observer

        window = historyWindow
    }
}

/// Bridges the History `NSWindow`'s close notification to a closure (the controller is a
/// plain `@MainActor` class, not an `NSObject`, so it can't be the window delegate itself).
/// Only observes the close — never alters the window's default close behavior.
private final class HistoryWindowCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        // AppKit calls window delegate methods on the main thread; assert that isolation so
        // the main-actor `onClose` can run without a hop.
        MainActor.assumeIsolated {
            onClose()
        }
    }
}

// MARK: - View model

/// Drives the History UI. Loads rows from the manifest (READ-ONLY), tracks the
/// selected session, and loads+parses that session's transcript off the main
/// thread (transcripts can be large). Owns its own results-window controller so
/// opening a past research page never disturbs the live research one.
@MainActor
final class ResearchHistoryViewModel: ObservableObject {
    @Published private(set) var rows: [HistoryRow] = []
    @Published var selectedRowID: String?
    /// The transcript load state for the selected row. `nil` means "nothing selected
    /// yet"; the view shows an empty-state prompt in that case.
    @Published private(set) var transcriptResult: TranscriptLoadResult?
    /// True while a transcript is being read/parsed on a background queue.
    @Published private(set) var isLoadingTranscript = false

    /// A brief, self-clearing note surfaced in the History UI (e.g. after a "Resume in
    /// Terminal" fall-back copied the command to the clipboard). `nil` when nothing to show.
    @Published private(set) var transientNote: String?

    /// Resolves the app-RESOLVED absolute CLI binary path for a session's engine so the
    /// "Resume in Terminal" command embeds the full path (Terminal's PATH may differ from the
    /// app's). Injected by the window controller from the app's ALREADY-BUILT registry (a plain
    /// cached read — no detection scan). Defaults to a SAFE no-op returning nil so a
    /// read-only/test/preview context resolves nothing (button hidden) and NEVER triggers
    /// detection. Assigning it re-primes the cache (assignment only ever happens off the render
    /// path, at `show()`/setup), so the render path reads ONLY the cache.
    var resolveResumeBinaryPath: @MainActor (ResearchResumeEngine) -> String? = { _ in nil } {
        didSet { refreshResumeBinaryPathCache() }
    }

    /// The RESOLVED absolute binary paths, computed ONCE (off the render path, when the provider
    /// is assigned at show/setup) and read by `canResumeInTerminal` / `resumeInTerminal`. Keyed
    /// by engine; a missing key means "not resolvable" (button hidden). This cache is the ONLY
    /// thing the render path consults — it never calls the provider (and so never a registry)
    /// during `body`/selection, which is what keeps engine detection off the main/render path.
    private var resumeBinaryPathCache: [ResearchResumeEngine: String] = [:]

    /// Recomputes `resumeBinaryPathCache` by asking the provider for every engine once. Called
    /// only when the provider is (re)assigned — i.e. at `show()`/setup, off the render path. The
    /// provider is a cached registry read, so this is cheap and never a detection scan.
    private func refreshResumeBinaryPathCache() {
        var freshCache: [ResearchResumeEngine: String] = [:]
        for engine in [ResearchResumeEngine.claudeCode, .codex] {
            if let resolvedPath = resolveResumeBinaryPath(engine),
               !resolvedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                freshCache[engine] = resolvedPath
            }
        }
        resumeBinaryPathCache = freshCache
    }

    /// Token so an older transient-note auto-clear can't wipe a newer note.
    private var transientNoteToken = 0

    /// The follow-up router (`ResearchSessionManager`) the detail-pane composer submits
    /// through. Weak — the view model never owns the manager. Nil in read-only contexts
    /// (e.g. a pure render test), where the composer degrades to hidden. Setting it re-derives
    /// the composer disposition AND (re)subscribes to the router's lifecycle-change publisher so
    /// the composer stays reactive to the selected live session's true phase.
    weak var followUpRouter: ResearchHistoryFollowUpRouting? {
        didSet { subscribeToLifecycleChanges() }
    }

    /// Live subscription to the router's per-session lifecycle-change publisher. Held so the
    /// open History composer reconciles when the SELECTED live session transitions phase
    /// (running → done/needsInput/error/stopped). Released when the router is cleared or the
    /// view model deallocates (window close), so there's no retain cycle or leak.
    private var lifecycleChangeSubscription: AnyCancellable?

    private let manifestStore: ResearchManifestStore
    /// A dedicated controller instance so viewing a HISTORICAL page does NOT steal
    /// or disturb the live research run's own results window.
    private let historyResultsWindow = ResearchResultsWindowController()
    /// Increments per selection so a slow background parse for a previously-selected
    /// row can't clobber the transcript of the row the user has since moved to.
    private var transcriptLoadToken = 0

    init(manifestStore: ResearchManifestStore = .shared) {
        self.manifestStore = manifestStore
    }

    /// The currently selected row, if any.
    var selectedRow: HistoryRow? {
        guard let selectedRowID else { return nil }
        return rows.first { $0.sessionId == selectedRowID }
    }

    /// Reloads the session list from the manifest (newest first) and, if a selection
    /// is still present, reloads its transcript. Called every time the window shows.
    func refresh() {
        rows = HistoryRowBuilder.makeRows(from: manifestStore.loadSessions(), now: Date())

        // Drop a selection whose session vanished; otherwise refresh its transcript.
        if let selectedRowID, rows.contains(where: { $0.sessionId == selectedRowID }) {
            loadTranscriptForSelectedRow()
        } else {
            self.selectedRowID = nil
            transcriptResult = nil
        }
        recomputeComposerDisposition()
    }

    /// Selects a row and loads its transcript.
    func select(rowID: String) {
        selectedRowID = rowID
        loadTranscriptForSelectedRow()
        recomputeComposerDisposition()
    }

    /// Selects the row for `sessionID` if it exists in the freshly-loaded list (so a
    /// research toast's "view history" affordance lands on that exact conversation).
    /// A no-op when the id isn't present, leaving whatever selection `refresh()` kept.
    func selectIfPresent(sessionID: String) {
        guard rows.contains(where: { $0.sessionId == sessionID }) else { return }
        select(rowID: sessionID)
    }

    /// Loads+parses the selected row's transcript off the main thread. The file may
    /// be missing (rolled away / never written) — that's surfaced as `.fileMissing`
    /// so the view can show a friendly placeholder rather than an error.
    private func loadTranscriptForSelectedRow() {
        guard let selectedRow else {
            transcriptResult = nil
            return
        }

        transcriptLoadToken += 1
        let thisLoadToken = transcriptLoadToken
        let transcriptPath = selectedRow.transcriptPath
        isLoadingTranscript = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Existence check → read → parse, all off the main thread (transcripts
            // can be large). Missing/unreadable files return `.fileMissing`.
            let result = TranscriptParser.loadResult(forFileAtPath: transcriptPath)
            DispatchQueue.main.async {
                guard let self else { return }
                // Ignore a stale load whose selection has since changed.
                guard thisLoadToken == self.transcriptLoadToken else { return }
                self.transcriptResult = result
                self.isLoadingTranscript = false
            }
        }
    }

    /// Opens the selected research run's generated page in a dedicated results
    /// window. Only valid when the deliverable is fenced to Clawdy's research root
    /// (the manifest is user-writable, so its `deliverablePath` is untrusted) AND
    /// exists on disk. An out-of-fence path is a silent no-op — never opened.
    func openDeliverable(for row: HistoryRow) {
        guard hasViewablePage(for: row), let deliverablePath = row.deliverablePath else {
            return
        }
        let htmlFileURL = URL(fileURLWithPath: (deliverablePath as NSString).expandingTildeInPath)
        // Bind this History-opened page to its originating research session so a spoken
        // follow-up while it's frontmost continues THAT session's thread (the manager
        // reconstructs the session from the manifest if it isn't live), rather than
        // starting a brand-new research run.
        historyResultsWindow.show(htmlFileURL: htmlFileURL, title: row.displayTitle, sessionID: row.sessionId)
    }

    /// Whether the selected row has an on-disk page to show a "View page" button
    /// for. Requires the deliverable to resolve WITHIN Clawdy's research root — an
    /// out-of-fence path (tampered manifest) offers no button and cannot be opened.
    func hasViewablePage(for row: HistoryRow) -> Bool {
        guard let deliverablePath = row.deliverablePath,
              TranscriptParser.isPathWithinAllowedRoots(
                deliverablePath,
                roots: TranscriptParser.historyDeliverableAllowedRoots()
              ) else {
            return false
        }
        let expandedPath = (deliverablePath as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expandedPath)
    }

    // MARK: - Resume in Terminal

    /// The engine whose NATIVE resume command a row should use — the engine that actually
    /// PRODUCED the session (carried on the row from the manifest's `engineKind`): Claude Code
    /// resumes with `claude --resume <id>`, Codex with `codex resume <thread_id>`. Not hardcoded:
    /// a Codex row builds the Codex command via the codex binary even while Claude is the
    /// currently-selected engine.
    func resumeEngine(for row: HistoryRow) -> ResearchResumeEngine {
        switch row.engineKind {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        }
    }

    /// Whether the selected row can be resumed in Terminal: it must have a non-empty working
    /// directory (the dir to `cd` into), a durable RESUME identifier for its engine (Claude's
    /// session id / Codex's thread id — nil means no resumable handle, so we never offer a dead
    /// resume), AND a resolvable engine binary (so the command embeds a real absolute path, not
    /// a bare name). The detail header shows the button only when true. Reads ONLY the
    /// pre-resolved `resumeBinaryPathCache` — never the provider/registry — so it is safe to call
    /// during SwiftUI rendering with zero risk of an engine-detection scan.
    func canResumeInTerminal(for row: HistoryRow) -> Bool {
        let trimmedWorkingDir = row.workingDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkingDir.isEmpty else { return false }
        guard let resumeIdentifier = row.resumeIdentifier,
              !resumeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return resumeBinaryPathCache[resumeEngine(for: row)] != nil
    }

    /// Opens the user's Terminal and resumes `row`'s session with the engine's native resume
    /// command, run in the session's working directory. Builds the shell command via the pure
    /// `ResearchResumeCommandBuilder`, wraps it in the Terminal AppleScript, and executes it
    /// with `NSAppleScript`. If Automation is denied (`errAEEventNotPermitted`, -1743) or any
    /// other error occurs, it FALLS BACK gracefully: the resume shell command is copied to the
    /// clipboard and a brief note tells the user (and how to grant Automation). Never crashes;
    /// never leaves the user with nothing.
    func resumeInTerminal(for row: HistoryRow) {
        let engine = resumeEngine(for: row)
        // Read the PRE-RESOLVED path from the cache — never the provider — so this stays off the
        // detection path just like the render-time gate.
        guard let binaryPath = resumeBinaryPathCache[engine] else {
            return
        }
        // Resume by the engine's DURABLE handle: Claude's session id / Codex's thread id (carried
        // on the row). Nil means no resumable handle — the render-time gate hides the button, but
        // guard here too so a stray call can never build a dead `resume ''`.
        guard let resumeIdentifier = row.resumeIdentifier,
              !resumeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let shellCommand = ResearchResumeCommandBuilder.shellCommand(
            engine: engine,
            binaryPath: binaryPath,
            workingDir: row.workingDir,
            sessionId: resumeIdentifier
        )
        let appleScriptSource = ResearchResumeCommandBuilder.terminalAppleScript(shellCommand: shellCommand)

        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            copyResumeCommandToClipboardAsFallback(shellCommand)
            return
        }
        var executionError: NSDictionary?
        appleScript.executeAndReturnError(&executionError)
        if let executionError {
            // Distinguish "Automation denied" (the common first-run / declined case) so the note
            // can point the user at System Settings, from any other AppleScript failure.
            let errorNumber = (executionError[NSAppleScript.errorNumber] as? Int) ?? 0
            let automationDeniedErrorNumber = -1743  // errAEEventNotPermitted
            if errorNumber == automationDeniedErrorNumber {
                copyResumeCommandToClipboardAsFallback(
                    shellCommand,
                    note: "Terminal automation is off — resume command copied. Enable Clawdy under System Settings ▸ Privacy & Security ▸ Automation, then paste it."
                )
            } else {
                copyResumeCommandToClipboardAsFallback(shellCommand)
            }
        }
    }

    /// Copies the resume shell command to the clipboard and shows a brief note — the graceful
    /// fall-back when Terminal can't be driven (Automation denied or any AppleScript error).
    private func copyResumeCommandToClipboardAsFallback(
        _ shellCommand: String,
        note: String = "Couldn't open Terminal — resume command copied to the clipboard."
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(shellCommand, forType: .string)
        showTransientNote(note)
    }

    /// Shows `note` in the History UI and auto-clears it after a few seconds (unless a newer
    /// note replaces it first).
    private func showTransientNote(_ note: String) {
        transientNoteToken += 1
        let thisNoteToken = transientNoteToken
        transientNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.transientNoteToken == thisNoteToken else { return }
            self.transientNote = nil
        }
    }

    // MARK: - Follow-up composer (continue the selected conversation)

    /// The composer disposition for the current selection, derived from the TRUE resumability
    /// signals (live phase + reconstructability) rather than the possibly-stale manifest row
    /// status. Stored (not recomputed per render) so it never reads the manifest file on every
    /// SwiftUI body pass; recomputed on every event that can change it: selection, refresh,
    /// submit, and stop. This is what guarantees the composer never presents an enabled Send
    /// that would be silently refused (BLOCKING #1/#2).
    @Published private(set) var composerDisposition: HistoryComposerDisposition = .hidden

    /// Whether the detail pane offers a follow-up composer for the current selection.
    var showsComposer: Bool { composerDisposition != .hidden }

    /// The morph for the composer's single trailing button: STOP while the selected session is
    /// a LIVE, actively-working run, SEND otherwise. Only ever consulted when `showsComposer`
    /// is true, so a `.hidden` disposition never reaches an enabled control.
    var composerPrimaryAction: ResearchComposerPrimaryAction {
        composerDisposition == .stop ? .stop : .send
    }

    /// (Re)subscribes to the router's lifecycle-change publisher and re-derives the disposition
    /// for the current selection. When ANY live session changes phase, if it's the currently
    /// SELECTED session the composer is reconciled to its true phase — so an open History pane
    /// never shows a stale Stop/Send after an external transition. A nil router drops the
    /// subscription (read-only context).
    private func subscribeToLifecycleChanges() {
        lifecycleChangeSubscription = followUpRouter?.sessionLifecycleChangedPublisher
            .sink { [weak self] changedSessionID in
                // The publisher only ever fires from the manager's @MainActor
                // `handleSessionLifecycleChanged`, so the sink runs synchronously on the main
                // actor — assert that isolation to recompute immediately (deterministic; no
                // deferred runloop hop) while staying main-actor-correct.
                MainActor.assumeIsolated {
                    guard let self, changedSessionID == self.selectedRowID else { return }
                    self.recomputeComposerDisposition()
                }
            }
        recomputeComposerDisposition()
    }

    /// Recomputes `composerDisposition` from the router's live-phase + reconstructability for
    /// the selected row. Call after any event that can change the selected session's true
    /// resumability (selection, refresh, submit, stop, live lifecycle change).
    private func recomputeComposerDisposition() {
        guard let selectedRow else {
            composerDisposition = .hidden
            return
        }
        let livePhase = followUpRouter?.liveOverlayPhase(forSessionID: selectedRow.sessionId)
        let canReconstruct = followUpRouter?.canReconstructFinishedSession(forSessionID: selectedRow.sessionId) ?? false
        composerDisposition = HistoryComposerAvailability.disposition(
            kind: selectedRow.kind,
            liveOverlayPhase: livePhase,
            canReconstruct: canReconstruct
        )
    }

    /// Submits a typed OR spoken (dictated-into-the-field) follow-up for the SELECTED session,
    /// routing through the manager's existing `followUpOnSession` reactivation path so the
    /// conversation continues and its research toast goes active again. Returns whether it was
    /// actually ROUTED — the composer keeps the user's draft on a `false` so it's never
    /// silently lost. Empty input is ignored (and reported as not-routed). Recomputes the
    /// disposition afterwards so the button reflects the now-live phase (SEND → STOP).
    @discardableResult
    func submitFollowUp(_ text: String) -> Bool {
        guard let selectedRow else { return false }
        let trimmedPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return false }
        let routed = followUpRouter?.followUpOnSession(id: selectedRow.sessionId, prompt: trimmedPrompt) ?? false
        recomputeComposerDisposition()
        return routed
    }

    /// Stops the selected session's live run — invoked when the composer's one button is in its
    /// STOP form (the run is actively working). Routes through the manager's `stopSession` (the
    /// SAME cancel a toast's own Stop control uses), then reconciles the composer with the now
    /// `.stopped` live phase so it no longer presents a Send that would be silently refused.
    func stopSelectedSession() {
        guard let selectedRow else { return }
        followUpRouter?.stopSession(id: selectedRow.sessionId)
        recomputeComposerDisposition()
    }
}

// MARK: - SwiftUI content

/// The window's content: a master list of sessions on the left, the selected
/// session's transcript on the right.
private struct ResearchHistoryView: View {
    @ObservedObject var viewModel: ResearchHistoryViewModel

    var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(width: 300)
            Divider()
                .background(DS.Colors.borderSubtle)
            transcriptDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
    }

    // MARK: List

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversations")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if viewModel.rows.isEmpty {
                emptyListState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.rows) { row in
                            HistorySessionRowView(
                                row: row,
                                isSelected: viewModel.selectedRowID == row.sessionId,
                                onSelect: { viewModel.select(rowID: row.sessionId) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.surface1)
    }

    private var emptyListState: some View {
        // Quiet single line — no accent-ish glyph, no stacked caption. The whitespace of
        // the empty column carries it (mirrors the recents list's one-line empty state).
        Text("No conversations yet")
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 4)
    }

    // MARK: Detail

    @ViewBuilder
    private var transcriptDetail: some View {
        if let selectedRow = viewModel.selectedRow {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(selectedRow)
                if let transientNote = viewModel.transientNote {
                    historyTransientNote(transientNote)
                }
                Divider().background(DS.Colors.borderSubtle)
                transcriptBody(selectedRow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The follow-up composer, pinned to the BOTTOM under the transcript — the one
                // WRITABLE affordance in the otherwise read-only History window. Only for a
                // resumable research session (see `HistoryComposerAvailability`).
                if viewModel.showsComposer {
                    Divider().background(DS.Colors.borderSubtle)
                    historyComposer(selectedRow)
                }
            }
        } else {
            noSelectionState
        }
    }

    /// The bottom-pinned follow-up composer. It reuses the SHARED `ResearchFollowUpComposer`
    /// (the exact one morphing Send↔Stop control the live per-session chat panel uses), so
    /// there is no second send/stop implementation. Submitting (Return or the Send button, or
    /// a dictated utterance typed into the field) CONTINUES the selected conversation's session
    /// and makes its research toast active again via the manager's reactivation path.
    private func historyComposer(_ selectedRow: HistoryRow) -> some View {
        ResearchFollowUpComposer(
            primaryAction: viewModel.composerPrimaryAction,
            placeholder: "Ask a follow-up…",
            onSubmit: { typedOrSpokenText in viewModel.submitFollowUp(typedOrSpokenText) },
            onStop: { viewModel.stopSelectedSession() }
        )
        // Key by the selected session so the composer's local draft @State RESETS when the
        // user switches conversations — a draft typed for one session can never carry into (or
        // be submitted to) another.
        .id(selectedRow.sessionId)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(DS.Colors.surface1)
    }

    /// A brief, quiet note bar under the header (e.g. after a "Resume in Terminal" fall-back
    /// copied the command to the clipboard). Matches the History window's calm surface style.
    private func historyTransientNote(_ note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
            Text(note)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface2.opacity(0.6))
    }

    private func detailHeader(_ row: HistoryRow) -> some View {
        let signal = HistorySessionRowSignal.forRow(row)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                // ONE quiet secondary signal — the same single token the list rows carry
                // (relative time, or a status word for a live/ended-abnormally run), never
                // the old kind · status · time triple.
                Text(signal.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(signal.tone.swatch)
            }

            Spacer(minLength: 0)

            // A "Resume in Terminal" primary beside "View page", shown only when the session
            // is resumable (has a working dir + a resolvable engine binary). Opens Terminal and
            // resumes the session with the engine's native resume command in its working dir.
            if viewModel.canResumeInTerminal(for: row) {
                HistoryResumeInTerminalButton {
                    viewModel.resumeInTerminal(for: row)
                }
            }

            if viewModel.hasViewablePage(for: row) {
                // A single quiet primary — accent glyph + label, transparent at rest with a
                // faint surface fill only on hover, replacing the always-on solid blue
                // capsule. The on-disk deliverable fence (`hasViewablePage` /
                // `openDeliverable`) is unchanged; only its presentation is quieter.
                HistoryViewPageButton {
                    viewModel.openDeliverable(for: row)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func transcriptBody(_ row: HistoryRow) -> some View {
        switch viewModel.transcriptResult {
        case .none:
            if viewModel.isLoadingTranscript {
                loadingState
            } else {
                placeholderState(
                    icon: "text.bubble",
                    title: "Loading conversation…",
                    subtitle: nil
                )
            }
        case .fileMissing:
            placeholderState(
                icon: "doc.questionmark",
                title: "Transcript unavailable",
                subtitle: "This conversation's transcript is no longer on disk."
            )
        case .parsed(let turns):
            if turns.isEmpty {
                placeholderState(
                    icon: "text.bubble",
                    title: "No conversation recorded yet",
                    subtitle: "This session hasn't produced any messages so far."
                )
            } else {
                ScrollView {
                    // Chat-style: CLAWDY/assistant messages LEFT, USER messages RIGHT, via the
                    // SAME shared `ResearchChatBubbleView` the per-session chat panel uses, so a
                    // conversation reads identically in both surfaces. Read-only here.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(turns) { turn in
                            ResearchChatBubbleView(turn: turn)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading conversation…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSelectionState: some View {
        placeholderState(
            icon: "sidebar.left",
            title: "Select a conversation",
            subtitle: "Pick a session on the left to read its transcript."
        )
    }

    private func placeholderState(icon: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(DS.Colors.textTertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Session list row

/// One row in the History session list, trimmed to the minimum that IDENTIFIES a
/// session: the title in one line plus ONE quiet trailing signal (a relative time, or a
/// short status word for a live/failed/stopped run — never the old kind pill + status
/// dot + status word + timestamp stack). No filled card at rest: selection is a calm
/// fill plus a slim faint-accent edge, and an unselected row shows only a faint highlight
/// on hover, so the list reads as one calm column separated by whitespace. A DISMISSED
/// session is dimmed and its single signal reads "dismissed".
///
/// Not `private` so the IA pixel-render test can rasterize the REAL production row tree.
struct HistorySessionRowView: View {
    let row: HistoryRow
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    private var signal: HistorySessionRowSignal { HistorySessionRowSignal.forRow(row) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text(row.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(signal.text)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(signal.tone.swatch)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            // Dismissed sessions read as muted (the run was hidden by the user), while
            // still being fully selectable/reopenable.
            .opacity(row.isDismissed ? 0.5 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(rowFill)
            )
            // A slim, faint blue edge marks the SELECTED row — the only accent in the list,
            // replacing the old filled-card + full stroke border.
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.accent)
                        .frame(width: 2.5, height: 16)
                        .padding(.leading, 3)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .trackingHover($isHovering)
        .help(row.displayTitle)
    }

    /// No card at rest: a calm fill for the selected row, a fainter highlight on hover,
    /// and nothing otherwise.
    private var rowFill: Color {
        if isSelected {
            return DS.Colors.surface2
        }
        if isHovering {
            return DS.Colors.surface2.opacity(0.5)
        }
        return Color.clear
    }
}

/// The detail pane's single quiet "View page" primary: an accent glyph + label that is
/// transparent at rest and shows only a faint surface fill on hover — the calm
/// replacement for the always-on solid-blue capsule. Purely presentation; the caller
/// keeps the on-disk deliverable fence.
private struct HistoryViewPageButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 11, weight: .semibold))
                Text("View page")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(DS.Colors.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isHovering ? DS.Colors.surface2 : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering)
        .help("Open this research run's page")
    }
}

/// The detail pane's quiet "Resume in Terminal" primary, styled to match `HistoryViewPageButton`:
/// an accent glyph + label, transparent at rest with a faint surface fill only on hover. Purely
/// presentation; the caller (`resumeInTerminal`) owns building + running the Terminal AppleScript
/// and the clipboard fall-back.
private struct HistoryResumeInTerminalButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                Text("Resume in Terminal")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(DS.Colors.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isHovering ? DS.Colors.surface2 : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering)
        .help("Open Terminal and resume this session in your CLI")
        .accessibilityLabel("Resume in Terminal")
        .accessibilityHint("Opens Terminal and resumes this session in your CLI")
    }
}

/// Maps a row-signal tone to its DS colour. Kept in the SwiftUI layer (not on the pure
/// `HistorySessionRowSignal`) so the signal type stays AppKit-free; shared by the list
/// rows and the detail header.
private extension HistorySessionRowSignal.Tone {
    var swatch: Color {
        switch self {
        case .neutral: return DS.Colors.textTertiary
        case .active: return DS.Colors.accent
        case .failure: return DS.Colors.destructiveText
        case .warning: return DS.Colors.warning
        }
    }
}

// NB: a session's transcript now renders chat-style via the shared
// `ResearchChatBubbleView` (CLAWDY left / USER right), so the old History-local
// `TranscriptTurnRow` was retired in favor of that one shared bubble.
