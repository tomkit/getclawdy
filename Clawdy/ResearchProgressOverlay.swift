//
//  ResearchProgressOverlay.swift
//  Clawdy
//
//  The reusable VISUALS for one research run's compact indicator ("pill") and its
//  larger detail panel. These are the per-run building blocks the manager's shared
//  STACKED overlay (`ResearchStackedOverlayController`) composes — one pill per
//  active session, with the tapped/focused session's detail panel shown alongside.
//
//  Each `ResearchSession` owns one `ResearchProgressOverlayViewModel` (the
//  observable bridge from its pure `ResearchOverlayState`) and drives it by mutating
//  state and pushing it here. The window/stack lifecycle — which pills are on
//  screen, which is focused, auto-hide — lives in the stacked controller, not here.
//
//  All windows that host these views set `sharingType = .readOnly` (visible to
//  external screen recorders); they are kept out of the screenshots a research run
//  might capture by application-level exclusion in the capture path, not by
//  `sharingType`.
//

import Combine
import SwiftUI

// MARK: - View model

/// Bridges the pure `ResearchOverlayState` into `@Published` values SwiftUI can
/// observe for ONE session's pill/detail, plus the click callbacks the owning
/// `ResearchSession` wires per phase.
@MainActor
final class ResearchProgressOverlayViewModel: ObservableObject {
    @Published var phase: ResearchOverlayPhase = .idle
    @Published var taskDescription: String = ""
    @Published var statusLine: String = ""
    @Published var stepLog: [ResearchStepLogEntry] = []
    @Published var isCancellable: Bool = false

    /// Claude Code's OWN session transcript turns (searches, fetches, writes, messages)
    /// for the DETAIL panel — read-only, sourced from the session's native `.jsonl` and
    /// refreshed by the owning `ResearchSession` while the run is live. Empty until the
    /// transcript is first written; the detail view falls back to `stepLog` then. The
    /// compact pill never renders this — it keeps its single rotating `statusLine`.
    @Published var transcriptTurns: [TranscriptTurn] = []

    /// Tapping the compact indicator's body. Wired by the session to the manager's
    /// pill-tap handler (focus / open clarify / view results, per phase).
    var onCompactTap: (() -> Void)?
    /// The Stop control (compact indicator and detail panel). STOP cancels the
    /// underlying research RUN (SIGTERM to its process) — it is NOT the same as the
    /// dismiss (×) affordance below, which only hides the pill's chrome.
    var onStop: (() -> Void)?
    /// The compact pill's dismiss (×) control. DISMISS hides just this pill's visual
    /// chrome (like closing a native notification banner); it must NEVER cancel/stop a
    /// live research run — the run keeps going and stays reachable via History. Kept
    /// deliberately distinct from `onStop` so the two intents can never be confused.
    var onDismiss: (() -> Void)?
    /// The detail panel's "View results ›" button (shown only when done).
    var onViewResults: (() -> Void)?
    /// Opens this session's conversation transcript (its History view). No longer surfaced
    /// as a control by this overlay — the DONE state's history is reached via the default
    /// card click — but the callback is retained for the session's wiring. Distinct from
    /// `onViewResults`, which opens the output page.
    var onViewHistory: (() -> Void)?
    /// The detail panel's close (X) button — closes the detail panel (clears focus);
    /// the run keeps going.
    var onCloseDetail: (() -> Void)?
    /// A TYPED follow-up turn submitted from the detail chat panel's text input. Wired by
    /// the session to its own `followUp(prompt:)`, so a typed message ENQUEUES onto THIS
    /// session's per-session FIFO (never a concurrent `--resume`), subscription-billed —
    /// exactly the path a spoken follow-up takes. Adds a typed path ALONGSIDE voice; voice
    /// keeps working unchanged.
    var onSubmitFollowUp: ((String) -> Void)?
}

// MARK: - Shared research-overlay surface appearance — pure, testable

/// The single DARK background fill shared by every research-overlay surface — the mini
/// toast, the full/expanded toast, and the Recent Research badge + inline list — so the
/// whole research overlay reads as ONE dark system with the rest of the app. This is the
/// SAME `surface1` the app's other windows use (the menu-bar popover panel, the toast
/// detail panel, and the History window all fill with `surface1`).
///
/// The brand red (`openClawRed`) is deliberately RESERVED for accents and the Clawdy
/// CURSOR — it is never a toast/badge surface fill. Foregrounds on this surface use the
/// same white / AA-safe secondary tokens the other dark windows use, so text/icons stay legible.
/// No `.shadow()` / translucent stroke draws on these surfaces, so only the solid dark
/// shape renders with a hard edge and fully transparent surroundings (no alpha halo).
enum ResearchToastSurfaceAppearance {
    /// The one canonical dark surface fill for the research overlay's toasts and recents.
    static let background: Color = DS.Colors.surface1
}

// MARK: - Full-toast surface geometry — pure, testable

/// The single full-toast footprint and corner radius. The toast no longer morphs between
/// a resting mini badge and an expanded pill — an ACTIVE research run always renders as
/// the ONE full toast (`ResearchFullToastView`), so there is exactly one size/radius. Kept
/// pure so the full-toast geometry stays unit-testable with no AppKit.
enum ResearchFullToastGeometry {
    /// The full toast's corner radius (matches the `clawdyGlow` default silhouette).
    static let cornerRadius: CGFloat = DS.CornerRadius.extraLarge

    /// The full toast footprint — the one size every active toast renders at.
    static var toastSize: CGSize { ResearchStackFrameLayout.expandedPillSize }
}

// MARK: - Live-step signals (step glyph + word) — pure, testable

/// One compact "step" signal shown on the resting mini badge: an SF Symbol icon plus a
/// single word summarizing what the run is doing RIGHT NOW, so the user can follow along
/// without expanding the toast. Pure value type — the mapping from the research event
/// stream / phase to `(icon, word)` is unit-tested with no UI.
struct ResearchStepIndicator: Equatable {
    /// SF Symbol name for the step.
    let icon: String
    /// The single word label (e.g. "Search", "Read", "Write").
    let word: String

    /// The canonical mapping from a coarse `ResearchProgressEvent` (the same event stream
    /// `ResearchStatusLine` consumes) to the badge's icon + one word.
    static func forEvent(_ event: ResearchProgressEvent) -> ResearchStepIndicator {
        switch event {
        case .searchingWeb:
            return ResearchStepIndicator(icon: "magnifyingglass", word: "Search")
        case .readingPage:
            return ResearchStepIndicator(icon: "doc.text", word: "Read")
        case .writingPage:
            return ResearchStepIndicator(icon: "pencil", word: "Write")
        case .runningTool:
            return ResearchStepIndicator(icon: "gearshape", word: "Working")
        }
    }

    /// The phase-level step, for the states that aren't a live tool event: DONE and
    /// NEEDS-INPUT. Returns nil for phases where the live event (running) or nothing
    /// (idle / error / stopped) should drive the step instead.
    static func forPhase(_ phase: ResearchOverlayPhase) -> ResearchStepIndicator? {
        switch phase {
        case .done:
            return ResearchStepIndicator(icon: "checkmark", word: "Done")
        case .needsInput:
            return ResearchStepIndicator(icon: "questionmark", word: "Ask")
        case .running, .idle, .error, .stopped:
            return nil
        }
    }

    /// The step to show on the resting badge, given ONLY the data the view model actually
    /// carries (`phase` + the rotating `statusLine`) — no extra wiring from the session.
    /// Phase-level steps (done / needsInput) win; while running, the live tool is inferred
    /// from the status line's stable prefix and routed through `forEvent` (so the same
    /// event→(icon,word) mapping is honored). Idle / error / stopped show no step.
    static func current(phase: ResearchOverlayPhase, statusLine: String) -> ResearchStepIndicator? {
        if let phaseStep = forPhase(phase) {
            return phaseStep
        }
        switch phase {
        case .running:
            return forEvent(inferredEvent(fromStatusLine: statusLine))
        case .idle, .error, .stopped, .done, .needsInput:
            return nil
        }
    }

    /// Recovers the coarse tool event from the rotating status line's stable leading
    /// phrase (`ResearchStatusLine`'s output), so the running step reads the same live
    /// activity the expanded pill shows. Falls back to the generic "Working" tool when the
    /// line is a non-tool status (planning / starting up / follow-up).
    static func inferredEvent(fromStatusLine statusLine: String) -> ResearchProgressEvent {
        let lowercased = statusLine.lowercased()
        if lowercased.hasPrefix("searching the web") {
            return .searchingWeb(query: "")
        }
        if lowercased.hasPrefix("reading") {
            return .readingPage(url: "")
        }
        if lowercased.hasPrefix("writing the page") {
            return .writingPage
        }
        if lowercased.hasPrefix("running") {
            return .runningTool(name: "")
        }
        // Planning / starting / follow-up and any other non-tool line: generic working.
        return .runningTool(name: "")
    }
}

// MARK: - Reusable hover-aware toast controls

/// A compact circular icon control used across the research toast (Stop, dismiss,
/// view history, close detail) AND the shared follow-up composer's Send button. It
/// shows a CLEAR hover affordance — a brightened icon + background and the
/// pointing-hand cursor — so it obviously reads as clickable. Each instance owns its
/// own hover state. Not `private` so the extracted `ResearchFollowUpComposer` (which
/// the History detail pane also reuses) can share this exact control.
struct ResearchToastIconButton: View {
    let systemName: String
    let helpText: String
    var iconSize: CGFloat = 10
    var padding: CGFloat = 5
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundColor(isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(padding)
                .background(Circle().fill(isHovering ? DS.Colors.surface3 : DS.Colors.surface2))
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering)
        .help(helpText)
    }
}

/// A text link used in the detail footer (e.g. "view results ›", "view history").
/// Underlines on hover and shows the pointing-hand cursor for a clear affordance.
private struct ResearchToastTextButton: View {
    let title: String
    var color: Color = DS.Colors.accent
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.linkLabel)
                .foregroundColor(color)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering)
    }
}

// MARK: - Full toast view

/// The ONE full toast an active research run renders as, reused as one toast in the
/// manager's stacked overlay. The old resting mini badge / hover-expanded pill MORPH is
/// gone — every active run now always shows this full form (the mini badge, its task-word
/// truncation, its step-display fits logic, and the morph geometry were all retired). The
/// glanceable signals the mini badge used to carry are FOLDED IN here so nothing is lost:
///   - the phase-driven PROGRESS RING wraps the leading glyph (spinning arc while working,
///     steady ring awaiting input, calm complete ring when done),
///   - the current STEP (SF Symbol glyph + one word) leads the status line while working,
///   - the task label + rotating status line, the Stop control (while cancellable), the
///     dismiss (×) + "view history" controls (terminal), and a clear hover-affordant
///     "View results ›" control when done.
///
/// It has ONE explicit size (`ResearchFullToastGeometry.toastSize`), so the hosting toast
/// window is always given a non-zero frame (never a zero-size, invisible window). The
/// Clawdy red-aura glow is applied by the hosting window's root wrapper (not here) so this
/// view's surface stays a clean, hard-edged `surface1` shape with no halo of its own.
struct ResearchFullToastView: View {
    @ObservedObject var viewModel: ResearchProgressOverlayViewModel

    /// Honor the system Reduce Motion setting: suppresses the progress ring's spin.
    var reduceMotionEnabled: Bool = false

    var body: some View {
        let size = ResearchFullToastGeometry.toastSize
        let cornerRadius = ResearchFullToastGeometry.cornerRadius
        return ZStack(alignment: .topLeading) {
            // The ONE opaque dark surface. A single solid fill (never two cross-fading
            // per-state fills) so the shape is hard-edged with no translucent halo.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(ResearchToastSurfaceAppearance.background)
                .frame(width: size.width, height: size.height)

            fullBody
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: Full toast body

    private var fullBody: some View {
        HStack(spacing: DS.Spacing.control) {
            // Leading glyph wrapped by the phase-driven progress ring (folded in from the
            // retired mini badge — the ring + its Reduce-Motion logic are reused verbatim).
            ZStack {
                badgeGlyph
                progressRing
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                Text(viewModel.taskDescription.isEmpty ? "Research" : viewModel.taskDescription)
                    .font(DS.Font.overlayCaption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                statusRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.onCompactTap?() }
            .pointerCursor()

            trailingControls
        }
        .padding(.horizontal, DS.Spacing.comfortable)
        .padding(.vertical, DS.Spacing.control)
        .frame(width: ResearchFullToastGeometry.toastSize.width,
               height: ResearchFullToastGeometry.toastSize.height)
    }

    /// The status row under the task label. A DONE run shows the hover-affordant
    /// "View results ›" control (requirement: a clear hover highlight on the completed
    /// toast). Otherwise it shows the current STEP glyph (folded in from the mini badge)
    /// leading the single rotating status line.
    @ViewBuilder
    private var statusRow: some View {
        if viewModel.phase == .done {
            ResearchViewResultsButton(action: { viewModel.onViewResults?() })
        } else {
            HStack(spacing: DS.Spacing.compact) {
                if let step = ResearchStepIndicator.current(phase: viewModel.phase, statusLine: viewModel.statusLine) {
                    Image(systemName: step.icon)
                        .font(DS.Font.iconGlyph)
                        .foregroundColor(statusIsActionable ? DS.Colors.accent : DS.Colors.textSecondary)
                }
                Text(viewModel.statusLine)
                    .font(.system(size: 13, weight: statusRowFontWeight))
                    .foregroundColor(statusRowTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// The status line's text color: distinctly RED for a FAILED (.error) run (so the
    /// failure is unmistakable — never the muted `textSecondary`/`textPrimary` shared with a
    /// stopped run), the accent for an actionable prompt (needs input), else primary text.
    private var statusRowTextColor: Color {
        if viewModel.phase == .error { return DS.Colors.destructiveText }
        return statusIsActionable ? DS.Colors.accent : DS.Colors.textPrimary
    }

    /// The status line's weight: semibold for the actionable/failed states so they read as
    /// a call to action; regular otherwise.
    private var statusRowFontWeight: Font.Weight {
        (statusIsActionable || viewModel.phase == .error) ? .semibold : .regular
    }

    /// The leading glyph inside the progress ring — a cursor arrow while working, a
    /// checkmark when done, and a distinctly RED warning triangle for a FAILED (.error) run
    /// so a failure reads unmistakably as a failure (not the muted white mark a stopped run
    /// shows). A user-stopped run keeps the calm white exclamation.
    @ViewBuilder
    private var badgeGlyph: some View {
        switch viewModel.phase {
        case .running, .needsInput:
            Image(systemName: "cursorarrow")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
        case .done:
            Image(systemName: "checkmark")
                .font(DS.Font.titleBold)
                .foregroundColor(.white)
        case .error:
            // Clearly-red failure — the destructive tone marks it apart from a stopped run.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Font.titleBold)
                .foregroundColor(DS.Colors.destructiveText)
        case .stopped, .idle:
            Image(systemName: "exclamationmark")
                .font(DS.Font.titleBold)
                .foregroundColor(.white)
        }
    }

    /// The phase-driven progress ring wrapped around the leading glyph. The pure
    /// `ResearchMiniProgressState.forPhase` decides WHAT to show (and, honoring Reduce
    /// Motion, whether it animates); `ResearchMiniProgressRing` renders it. Nothing is
    /// drawn for terminal/idle states.
    @ViewBuilder
    private var progressRing: some View {
        let progressState = ResearchMiniProgressState.forPhase(
            viewModel.phase,
            reduceMotion: reduceMotionEnabled
        )
        if progressState != .none {
            ResearchMiniProgressRing(state: progressState)
        }
    }

    /// The trailing controls, driven by the pure `ResearchToastControlSet` so each phase
    /// shows exactly the right set:
    ///   - WORKING → ONLY Stop (no × dismiss, so "hide" can't be mistaken for "cancel").
    ///   - DONE    → the × dismiss ("View results ›" is its own hover-affordant control in
    ///               the status row; the conversation history opens via the default card click).
    ///   - TERMINAL error/stopped → just the × dismiss.
    /// Every control shows a hover highlight + pointing-hand cursor (via the shared
    /// `CircularIconButton`).
    @ViewBuilder
    private var trailingControls: some View {
        let controls = ResearchToastControlSet.controls(forPhase: viewModel.phase)
        HStack(spacing: DS.Spacing.snug) {
            if controls.showsStop {
                // STOP cancels the underlying run — deliberately the ONLY end-run control
                // while working (no × dismiss appears until the run is terminal).
                CircularIconButton(
                    systemName: "stop.fill",
                    helpText: "Stop research",
                    iconSize: 11,
                    padding: 6,
                    action: { viewModel.onStop?() }
                )
            }
            if controls.showsDismiss {
                // DISMISS (×): hides this pill's chrome only — never stops a run. Only
                // ever shown in a terminal state, so it can't be confused with Stop.
                CircularIconButton(
                    systemName: "xmark",
                    helpText: "Dismiss",
                    action: { viewModel.onDismiss?() }
                )
            }
        }
    }

    /// Whether the status line should read as a call to action (needs input / done).
    private var statusIsActionable: Bool {
        viewModel.phase == .needsInput || viewModel.phase == .done
    }
}

/// The completed toast's "View results ›" control with a CLEAR hover affordance — a
/// LEADING page glyph (`doc.richtext`, matching the History window's "View page" control
/// for app consistency) sits alongside the label so it obviously reads as a "view the
/// results page" button rather than a bare text link. The text + glyph brighten to
/// `textPrimary` and gain an accent-tinted rounded background on hover (plus the
/// pointing-hand cursor). The Clawdy red cursor (owned by the hosting window's front
/// cursor overlay) still wins over the pointing-hand while the toast is on screen, so the
/// brand cursor stays over the control.
private struct ResearchViewResultsButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.snug) {
                Image(systemName: "doc.richtext")
                    .font(DS.Font.linkLabel)
                Text("View results ›")
                    .font(DS.Font.linkLabel)
            }
            .foregroundColor(isHovering ? DS.Colors.textPrimary : DS.Colors.accent)
            // Padding is always present so the button frame never changes on hover;
            // only the background highlight fades in/out.
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.accent.opacity(isHovering ? 0.22 : 0))
            )
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering)
        .help("View results page")
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// The resting badge's small progress ring. Its shape is driven entirely by the pure
/// `ResearchMiniProgressState` so the badge reads its run state at a glance:
///   - `.workingAnimated` → a short brand-red arc that spins continuously ("working").
///   - `.workingStatic`   → the SAME short arc, frozen (Reduce Motion) — still reads as
///                          in-progress, just without motion.
///   - `.needsInput`      → a steady, brighter FULL ring ("your turn"), never spinning.
///   - `.done`            → a faint, calm full ring behind the checkmark ("complete").
///
/// It sits INSIDE the existing 48×36 badge footprint (a ~28pt ring, well within the
/// 36pt height) so it never changes the window's size — that's the layout agent's
/// domain. Self-contained: the spin only runs while on screen and only when the state
/// says to animate.
private struct ResearchMiniProgressRing: View {
    let state: ResearchMiniProgressState

    /// Ring diameter — kept comfortably inside the 36pt badge height with margin.
    private let ringDiameter: CGFloat = 28
    private let lineWidth: CGFloat = 2.4

    /// The current rotation of the spinning arc. Its motion is bound to the CURRENT
    /// state — NOT to `.onAppear` — via `syncSpin(for:)` below, so a phase change on an
    /// already-visible badge starts, stops, or resets the spin correctly (no leaked
    /// forever-animation, and Reduce Motion always freezes it).
    @State private var spinAngle: Double = 0

    var body: some View {
        ZStack {
            switch state {
            case .workingAnimated, .workingStatic:
                // A short leading arc reads as an indeterminate progress spinner. It
                // spins only in the animated variant; the static (Reduce Motion) variant
                // shows the same arc frozen so it still reads as "in progress".
                Circle()
                    .trim(from: 0.0, to: 0.3)
                    .stroke(
                        Color.white.opacity(0.95),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(spinAngle))
            case .needsInput:
                // A steady, brighter FULL ring — a calm "waiting for you" attention state
                // that is deliberately NOT spinning so it can't be mistaken for working.
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: lineWidth)
            case .done:
                // A faint, calm full ring behind the checkmark to read as "complete"
                // without drawing attention.
                Circle()
                    .stroke(Color.white.opacity(0.4), lineWidth: lineWidth)
            case .none:
                EmptyView()
            }
        }
        .frame(width: ringDiameter, height: ringDiameter)
        // Bind the spin to the CURRENT state, on first appearance AND on every state
        // change — so toggling Reduce Motion, or moving working → needsInput/done/none,
        // reliably starts/stops/resets the animation instead of leaking a forever-spin.
        .onAppear { syncSpin(for: state) }
        .onChange(of: state) { newState in syncSpin(for: newState) }
    }

    /// Starts, stops, or resets the arc's rotation to match `state`. ONLY
    /// `.workingAnimated` runs the repeating spin; every other state (including the
    /// Reduce-Motion `.workingStatic`) explicitly cancels any attached forever-animation
    /// and freezes the arc at angle 0 via a transaction that disables animations — this
    /// is the removal path the pure `.onAppear` version lacked.
    private func syncSpin(for state: ResearchMiniProgressState) {
        if state.isAnimated {
            // Restart from a known angle so the loop is consistent across restarts.
            spinAngle = 0
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spinAngle = 360
            }
        } else {
            // Reassigning the animated value inside a disables-animations transaction
            // detaches the running repeatForever animation and freezes the arc.
            var stopSpinTransaction = Transaction()
            stopSpinTransaction.disablesAnimations = true
            withTransaction(stopSpinTransaction) {
                spinAngle = 0
            }
        }
    }
}

// MARK: - Detail chat panel view

/// The per-session CHAT window (the expanded toast detail panel). It reads the session's
/// conversation CHAT-STYLE (Clawdy left / user right, via the shared `ResearchChatBubbleView`)
/// and lets the user ENQUEUE a typed follow-up turn onto this session's own claude thread,
/// alongside the existing voice follow-up. Layout, per the chat-window spec:
///   - a DISMISS (×) control in the UPPER-RIGHT that hides the window (`onCloseDetail`),
///   - the scrolling chat transcript (falling back to the synthetic status steps until the
///     native `.jsonl` transcript is first written, so it's never blank),
///   - the STOP control in the LOWER-RIGHT (while the run is cancellable) — cancels the run,
///   - a TEXT INPUT area at the very bottom that submits a typed follow-up
///     (`onSubmitFollowUp`, per-session FIFO, subscription-billed).
/// The whole surface wears the shared Clawdy red-aura glow so it matches the other Clawdy
/// surfaces; the hosting panel is `sharingType = .readOnly` (visible to external
/// recorders; kept out of Clawdy's own model screenshots by app-level exclusion).
struct ResearchDetailOverlayView: View {
    @ObservedObject var viewModel: ResearchProgressOverlayViewModel

    /// The fixed content size (the hosting panel adds a transparent margin around this for
    /// the aura). Kept as constants so the controller can size/position the panel to match.
    static let contentSize = CGSize(width: 380, height: 460)
    private let cornerRadius: CGFloat = DS.CornerRadius.detailPanel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            header
            Divider().overlay(DS.Colors.borderSubtle.opacity(0.4))
            chatScroll
            bottomBar
        }
        .padding(18)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DS.Colors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 1)
                )
        )
        // The SHARED Clawdy red-aura glow — the SAME outer aura the toasts and other
        // surfaces wear, so the per-session chat reads as one Clawdy system. Applied on the
        // opaque `surface1` shape (occludes the aura's interior → no inner flood); the
        // hosting panel carries a transparent margin so the bloom isn't clipped into a hard
        // rectangle.
        .clawdyGlow(cornerRadius: cornerRadius, radius: ClawdyGlow.maximumSafeRadius)
    }

    /// The task label with the DISMISS (×) control pinned UPPER-RIGHT — hides the window
    /// (clears focus); the run keeps going. Distinct from Stop (lower-right), which cancels.
    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundColor(DS.Colors.accent)
            VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                Text("research")
                    .font(DS.Font.overlayCaptionEmphasized)
                    .foregroundColor(DS.Colors.textSecondary)
                Text(viewModel.taskDescription.isEmpty ? "Research" : viewModel.taskDescription)
                    .font(DS.Font.linkLabel)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // UPPER-RIGHT dismiss (×): hide the chat window (never stops the run).
            CircularIconButton(
                systemName: "xmark",
                helpText: "Hide",
                iconSize: 11,
                padding: 6,
                action: { viewModel.onCloseDetail?() }
            )
        }
    }

    private var chatScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.control) {
                    if viewModel.transcriptTurns.isEmpty {
                        // The transcript hasn't been written yet (very start of a run):
                        // fall back to the synthetic status steps so the panel isn't blank.
                        ForEach(viewModel.stepLog) { entry in
                            statusStepRow(text: entry.text)
                                .id("step-\(entry.id)")
                        }
                    } else {
                        // Claude Code's OWN session activity, chat-style (Clawdy left / user
                        // right), via the SAME shared bubble the History window uses.
                        ForEach(viewModel.transcriptTurns) { turn in
                            ResearchChatBubbleView(turn: turn)
                                .id("turn-\(turn.id)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.transcriptTurns.count) { _ in
                if let lastID = viewModel.transcriptTurns.last?.id {
                    withAnimation { proxy.scrollTo("turn-\(lastID)", anchor: .bottom) }
                }
            }
            .onChange(of: viewModel.stepLog.count) { _ in
                if viewModel.transcriptTurns.isEmpty, let lastID = viewModel.stepLog.last?.id {
                    withAnimation { proxy.scrollTo("step-\(lastID)", anchor: .bottom) }
                }
            }
        }
    }

    /// One synthetic status-step row (the pre-transcript fallback) — matches the
    /// original accent-dot style.
    private func statusStepRow(text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Circle()
                .fill(DS.Colors.accent.opacity(0.6))
                .frame(width: 5, height: 5)
                .padding(.top, DS.Spacing.snug)
            Text(text)
                .font(DS.Font.overlayBodyRegular)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The bottom of the chat window: a SINGLE composer whose one trailing button carries both
    /// the SEND and the STOP intents (like a standard AI chat window — the send button becomes
    /// a stop button while the run works). There is no longer a separate Stop capsule row. A
    /// DONE run (if it is ever shown here) offers its "view" affordances instead of the composer.
    @ViewBuilder
    private var bottomBar: some View {
        let controls = ResearchToastControlSet.controls(forPhase: viewModel.phase)
        VStack(alignment: .trailing, spacing: DS.Spacing.control) {
            // The done-state "view results" affordance (kept for completeness if a done
            // session is ever surfaced here) — otherwise the typed-follow-up composer. The
            // conversation history is reached via the default card click, so there is no
            // longer a separate "view history" affordance here.
            if controls.showsViewResults {
                HStack(spacing: DS.Spacing.comfortable) {
                    Spacer()
                    ResearchToastTextButton(
                        title: "view results ›",
                        action: { viewModel.onViewResults?() }
                    )
                }
            } else if showsComposer {
                // TEXT INPUT with the ONE morphing primary button: STOP while working (cancels
                // this run), SEND while awaiting the user (enqueues a typed follow-up onto this
                // session's own thread). Stop stays additionally reachable via the compact toast.
                // The SAME `ResearchFollowUpComposer` the History detail pane reuses.
                ResearchFollowUpComposer(
                    primaryAction: ResearchComposerPrimaryAction.forPhase(viewModel.phase),
                    onSubmit: { typedText in
                        // The live per-session composer is only shown for a resumable session,
                        // so a typed turn always enqueues onto its FIFO — always clear the field.
                        viewModel.onSubmitFollowUp?(typedText)
                        return true
                    },
                    onStop: { viewModel.onStop?() }
                )
            }
        }
    }

    /// Whether the typed-follow-up composer is offered: only when the session can actually
    /// take a follow-up turn (a live run enqueues it FIFO). Terminal error/stopped/idle
    /// sessions can't be resumed, so no composer is shown.
    private var showsComposer: Bool {
        switch viewModel.phase {
        case .running, .needsInput, .done:
            return true
        case .idle, .error, .stopped:
            return false
        }
    }
}

/// The single morphing intent the detail composer's ONE trailing button carries, like a
/// standard AI chat window where the send button becomes a stop button while the assistant
/// works. Pure and AppKit-free so the phase→intent mapping is unit-testable with no view.
enum ResearchComposerPrimaryAction: Equatable {
    /// The run is actively WORKING — the trailing button is a destructive STOP (`stop.fill`)
    /// that cancels the run via `onStop`. An empty draft does NOT disable it (you can always
    /// stop a working run).
    case stop
    /// The session is AWAITING the user — the trailing button is SEND (`arrow.up`), which
    /// submits the typed follow-up via `onSubmitFollowUp`. Disabled + dimmed on an empty draft.
    case send

    /// The phase→intent mapping for the composer's single trailing button:
    ///   - `.running` (actively working, plan or execute) → STOP.
    ///   - every other phase the composer is ever shown for (`.needsInput` awaiting the
    ///     user's typed answer, and `.done` should it be surfaced) → SEND.
    /// Stop stays reachable during `.needsInput` via the compact toast's own Stop control
    /// (unchanged), so folding the composer button to SEND there does not remove the only
    /// way to cancel a still-cancellable run.
    static func forPhase(_ phase: ResearchOverlayPhase) -> ResearchComposerPrimaryAction {
        switch phase {
        case .running:
            return .stop
        case .needsInput, .done, .idle, .error, .stopped:
            return .send
        }
    }

    /// Whether a submit attempt (the SEND button OR the Return key) should actually fire the
    /// follow-up. Send happens ONLY in SEND mode with a non-empty trimmed draft. In STOP mode
    /// (the run is working) this is always false — so pressing Return while the button is a
    /// Stop never silently sends a follow-up. This is the single source of truth both the
    /// button's `action` and the text field's `onSubmit` route through, so they can't diverge.
    static func shouldSubmit(action: ResearchComposerPrimaryAction, trimmedDraft: String) -> Bool {
        action == .send && !trimmedDraft.isEmpty
    }

    /// Whether the composer should CLEAR its draft after a submit attempt: only when the submit
    /// was permitted (`shouldSubmit`) AND the follow-up actually ROUTED (`routed == true`). A
    /// refused route (a session that turned out non-resumable) keeps the draft so the user never
    /// silently loses their text; a STOP-mode Return (blocked by `shouldSubmit`) never clears
    /// either. The single source of truth the composer's `submit()` uses for clearing.
    static func shouldClearDraft(
        action: ResearchComposerPrimaryAction,
        trimmedDraft: String,
        routed: Bool
    ) -> Bool {
        shouldSubmit(action: action, trimmedDraft: trimmedDraft) && routed
    }
}

// NB: the typed/spoken follow-up composer (`ResearchFollowUpComposer`) and its STOP-form
// button (`ResearchComposerStopButton`) were EXTRACTED to the shared
// `ResearchFollowUpComposer.swift` so the History window's detail pane reuses the exact
// same control (one morphing Send/Stop button + the single `shouldSubmit` Return guard)
// rather than a second implementation. The full-toast body above uses it unchanged.

