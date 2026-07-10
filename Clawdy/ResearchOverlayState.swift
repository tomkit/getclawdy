//
//  ResearchOverlayState.swift
//  Clawdy
//
//  The PURE, side-effect-free state machine behind the global research overlay.
//  It is the single source of truth for what the always-visible research
//  indicator (and its detail panel) should show at any moment during a run:
//  which phase the run is in, the single rotating status line, whether a Stop
//  control should be offered, whether tapping the compact indicator does
//  something, and the growing textual STEP LOG that the detail panel scrolls.
//
//  The AppKit presenter (`ResearchStackedOverlayController`) owns one of these
//  and simply re-renders whenever it changes; every transition here is a plain
//  value mutation with no windows, no timers, and no I/O, so the whole lifecycle
//  (idle → running → needs-input → executing → done / error / stopped) is
//  unit-testable without spinning up any UI.
//

import Foundation

/// One coarse phase of the research overlay's lifecycle. Distinct from the
/// engine's own phases — this is purely what the OVERLAY is showing.
enum ResearchOverlayPhase: Equatable {
    /// No run is active; the overlay is hidden.
    case idle
    /// A run is actively working (planning or executing). Cancellable; the
    /// compact indicator opens the detail log when tapped.
    case running
    /// The plan phase asked clarifying questions and is waiting on the user.
    /// Cancellable; tapping the compact indicator opens the clarify panel.
    case needsInput
    /// The run finished successfully and a deliverable is ready. Not cancellable;
    /// tapping the compact indicator opens the results window.
    case done
    /// The run failed. Terminal and dismissible.
    case error
    /// The user stopped the run. Terminal and dismissible.
    case stopped
}

/// One line in the detail panel's scrolling activity log.
struct ResearchStepLogEntry: Equatable, Identifiable {
    let id: Int
    let text: String
}

/// The set of secondary controls a research toast (compact pill + detail footer)
/// should expose for a given overlay phase. Pure and AppKit-free so the two intent
/// contracts are unit-testable with no windows:
///   - WHILE WORKING (running / needs-input) the ONLY way to end a run is Stop — the
///     dismiss (×) chrome-hide control is deliberately NOT offered, so the user can't
///     mistake "hide the pill" for "cancel the run" mid-flight.
///   - ONCE TERMINAL (done / error / stopped) Stop disappears and the dismiss (×)
///     appears; a DONE run additionally offers the "view results" affordance (its output
///     page). Its conversation history/transcript is reached via the default card click,
///     so it is no longer a separate control here.
struct ResearchToastControlSet: Equatable {
    /// The Stop control — cancels the underlying run (SIGTERM to its process). Offered
    /// ONLY while the run can still be cancelled (running / needs-input).
    let showsStop: Bool
    /// The dismiss (×) control — hides just this pill's chrome WITHOUT cancelling.
    /// Offered ONLY in terminal states; never while a run is working (Stop is the only
    /// way to end an active run).
    let showsDismiss: Bool
    /// The "View results" affordance — opens the finished deliverable page. Done only.
    let showsViewResults: Bool
    /// The "View history" affordance — opens this session's conversation transcript, a
    /// SECONDARY link alongside "View results". Done only.
    let showsViewHistory: Bool

    static func controls(forPhase phase: ResearchOverlayPhase) -> ResearchToastControlSet {
        switch phase {
        case .running, .needsInput:
            // Working: ONLY Stop. No × dismiss — that appears once the run is terminal.
            return ResearchToastControlSet(
                showsStop: true, showsDismiss: false, showsViewResults: false, showsViewHistory: false
            )
        case .done:
            // Done: the "view results" affordance (results page) plus a dismiss (×) to
            // clear the pill's chrome. The conversation history is reached via the
            // default card click (which opens the History window), so the redundant
            // "view history" icon is no longer offered here.
            return ResearchToastControlSet(
                showsStop: false, showsDismiss: true, showsViewResults: true, showsViewHistory: false
            )
        case .error, .stopped:
            // Terminal failure/stop: dismissible, nothing to view.
            return ResearchToastControlSet(
                showsStop: false, showsDismiss: true, showsViewResults: false, showsViewHistory: false
            )
        case .idle:
            // Hidden; no controls.
            return ResearchToastControlSet(
                showsStop: false, showsDismiss: false, showsViewResults: false, showsViewHistory: false
            )
        }
    }

    /// The single trailing control the DETAIL panel header shows, kept in LOCKSTEP with
    /// the compact pill via the SAME control set so the two surfaces can't diverge:
    ///   - WORKING (running / needs-input) → `.stop` (never a dismiss-x — "hide" must not
    ///     be confusable with "cancel"). The panel still collapses via hover-out / the
    ///     click-toggle, so no x is needed.
    ///   - TERMINAL (done / error / stopped) → `.close` (the x is allowed).
    ///   - idle → nil (no header control).
    enum DetailHeaderControl: Equatable {
        /// A Stop control that cancels the run (shown while working).
        case stop
        /// The close-details (x) control (shown only in a terminal state).
        case close
    }

    var detailHeaderControl: DetailHeaderControl? {
        if showsStop { return .stop }
        if showsDismiss { return .close }
        return nil
    }
}

/// What the RESTING (mini) badge's small progress indicator should show for a
/// given overlay phase. This is the pure phase→indicator mapping behind the mini
/// toast's activity affordance, kept AppKit-free so the phase logic is unit-testable
/// without rendering any ring. The resting badge is tiny (48×36), so the states are
/// deliberately coarse — the goal is only to let a user glance at the mini badge and
/// tell whether a run is actively working, waiting on them, finished, or idle.
enum ResearchMiniProgressState: Equatable {
    /// A run is actively working AND motion is allowed: an animated (spinning) arc.
    case workingAnimated
    /// A run is actively working but Reduce Motion is on: a STATIC "in progress" arc
    /// (no spin) so the badge still reads as busy without any animation.
    case workingStatic
    /// The plan phase is waiting on the user: a steady, full attention ring (never
    /// spins — a spinner would wrongly read as "still working"). Distinct from the
    /// working states so "your turn" is visually different from "I'm busy".
    case needsInput
    /// The run finished successfully: a calm, faint complete ring behind the check.
    case done
    /// No active progress to show (terminal error/stopped, or idle): just the calm
    /// badge glyph, no ring.
    case none

    /// The single source of truth mapping an overlay phase (plus the Reduce Motion
    /// setting) to the resting badge's progress indicator. Reduce Motion only affects
    /// the WORKING case — it swaps the spinning arc for a static one; every other
    /// state is already motion-free.
    static func forPhase(_ phase: ResearchOverlayPhase, reduceMotion: Bool) -> ResearchMiniProgressState {
        switch phase {
        case .running:
            return reduceMotion ? .workingStatic : .workingAnimated
        case .needsInput:
            return .needsInput
        case .done:
            return .done
        case .error, .stopped, .idle:
            return .none
        }
    }

    /// Whether this state should be continuously animated (spinning). True ONLY for
    /// the motion-allowed working state; Reduce Motion and all non-working states are
    /// static.
    var isAnimated: Bool {
        self == .workingAnimated
    }
}

/// The complete, renderable state of the research overlay. A value type: the
/// presenter holds one and mutates it through the transition methods below,
/// re-rendering after each. Nothing here touches AppKit.
struct ResearchOverlayState: Equatable {
    private(set) var phase: ResearchOverlayPhase
    /// The originating research task, shown (truncated) as the compact indicator's
    /// title and used as the results window title.
    private(set) var taskDescription: String
    /// The single rotating status line (e.g. "Searching the web for X…").
    private(set) var statusLine: String
    /// The growing, ordered activity log the detail panel scrolls through.
    private(set) var stepLog: [ResearchStepLogEntry]
    /// Monotonic id source so each log entry is stably identifiable in SwiftUI.
    private var nextLogEntryID: Int

    init() {
        phase = .idle
        taskDescription = ""
        statusLine = ""
        stepLog = []
        nextLogEntryID = 0
    }

    // MARK: - Derived display flags

    /// True while a Stop/Cancel control should be offered (the run can still be
    /// cancelled). Only the actively-working and awaiting-input phases qualify.
    var isCancellable: Bool {
        switch phase {
        case .running, .needsInput:
            return true
        case .idle, .done, .error, .stopped:
            return false
        }
    }

    /// True when tapping the COMPACT indicator should trigger the phase's primary
    /// action (open clarify panel when awaiting input; open results when done).
    /// While merely running, the compact tap opens the detail log instead, which
    /// the presenter always allows — so this stays false there.
    var compactTapOpensPrimaryAction: Bool {
        switch phase {
        case .needsInput, .done:
            return true
        case .idle, .running, .error, .stopped:
            return false
        }
    }

    /// True once the overlay has reached a terminal state that should auto-hide after a
    /// short delay. Only `.stopped` (a user-cancelled run) auto-hides. `.error` (a FAILED
    /// run) and `.done` are both terminal but intentionally PERSIST — `.done` so the user
    /// can still open the results, `.error` so a failure is never silently swept away and
    /// stays readable + dismissible.
    var isAutoHidingTerminalState: Bool {
        phase == .stopped
    }

    /// True whenever the overlay should be on screen at all.
    var isVisible: Bool { phase != .idle }

    // MARK: - Transitions (pure)

    /// Begins a run: moves to `.running`, records the task, seeds the first status
    /// line, and starts the log with the planning entry.
    mutating func startRun(taskDescription: String) {
        phase = .running
        self.taskDescription = taskDescription
        statusLine = ResearchStatusLine.planning
        stepLog = []
        nextLogEntryID = 0
        appendLogEntry(ResearchStatusLine.planning)
    }

    /// Records a coarse progress event while the run is working. Updates the
    /// rotating status line and appends a log entry — but only in the `.running`
    /// phase, so late events after a stop/completion are ignored (mirrors the
    /// coordinator's own late-event guard). Consecutive identical status lines are
    /// collapsed in the log so a burst of the same step doesn't spam it.
    mutating func recordProgress(_ progressEvent: ResearchProgressEvent) {
        guard phase == .running else { return }
        let line = ResearchStatusLine.text(for: progressEvent)
        statusLine = line
        if stepLog.last?.text != line {
            appendLogEntry(line)
        }
    }

    /// The plan phase asked clarifying questions: move to `.needsInput`, show the
    /// "needs your input" prompt, and log it.
    mutating func markNeedsInput() {
        phase = .needsInput
        statusLine = ResearchStatusLine.needsYourInput
        appendLogEntry("Waiting for your answer…")
    }

    /// The user answered and the run resumed into execution: back to `.running`.
    mutating func resumeExecuting() {
        phase = .running
        statusLine = ResearchStatusLine.text(for: .writingPage)
        appendLogEntry("Continuing the research…")
    }

    /// A voice follow-up turn started on a finished session: move back to `.running`
    /// so the pill shows activity while THIS session's own thread answers/iterates.
    mutating func beginFollowUp() {
        phase = .running
        statusLine = ResearchStatusLine.workingOnFollowUp
        appendLogEntry(ResearchStatusLine.workingOnFollowUp)
    }

    /// The deliverable is ready: move to `.done` and offer the view-results action.
    mutating func markCompleted() {
        phase = .done
        statusLine = ResearchStatusLine.viewResults
        appendLogEntry("Research complete — report ready.")
    }

    /// The run failed: move to `.error`.
    mutating func markFailed() {
        phase = .error
        statusLine = ResearchStatusLine.failed
        appendLogEntry(ResearchStatusLine.failed)
    }

    /// The user cancelled the run: move to `.stopped`.
    mutating func markStopped() {
        phase = .stopped
        statusLine = ResearchStatusLine.stopped
        appendLogEntry(ResearchStatusLine.stopped)
    }

    /// Returns the overlay to its hidden, empty baseline.
    mutating func reset() {
        self = ResearchOverlayState()
    }

    // MARK: - Private

    private mutating func appendLogEntry(_ text: String) {
        stepLog.append(ResearchStepLogEntry(id: nextLogEntryID, text: text))
        nextLogEntryID += 1
    }
}
