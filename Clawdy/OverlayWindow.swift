//
//  OverlayWindow.swift
//  Clawdy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import SwiftUI

/// The single, central place to tune how many places the blue cursor points at in
/// one reply and how long it lingers on each. Grouped so the feel can be adjusted
/// during live testing without hunting through the prompt and the overlay.
///
/// - `maxPointsSoftCap` is interpolated into the coaching system prompt (the model
///   is asked to emit an ORDERED point for EACH distinct named place, up to this
///   many). There is NO hard cap in the parser or overlay — every emitted tag is
///   walked — so this soft cap is the only limit, kept sane so a reply doesn't turn
///   into an endless walk.
/// - The dwell scales DOWN as the sequence grows (`perPointDwellSeconds(forPointingTargetCount:)`)
///   so an 8-point UNTIMED walk (Apple TTS / degraded audio-sync) doesn't feel
///   endless. The audio-synced walk (ElevenLabs) is driven by the spoken clock, not
///   this dwell, except for the final target's fly-back.
enum PointingTuning {
    /// Soft cap on how many distinct places we ask the model to point at in one
    /// reply. Raised from the former ~3–4 so more of the named landmarks get a
    /// pointer. Pure guidance for the model; nothing enforces it in code.
    static let maxPointsSoftCap = 7

    /// Per-point dwell for the UNTIMED walk when the sequence is small (at or below
    /// `dwellScalingStartsAbovePointCount`). The former single value.
    static let basePerPointDwellSeconds: Double = 1.3

    /// The shortest per-point dwell we scale down to for the largest sequences, so a
    /// long untimed walk stays snappy instead of ballooning to ~15+ seconds.
    static let minPerPointDwellSeconds: Double = 0.7

    /// Sequences with this many targets or fewer keep the full `basePerPointDwellSeconds`.
    /// Above it, the dwell interpolates down toward `minPerPointDwellSeconds`, reaching
    /// the minimum at `maxPointsSoftCap`.
    static let dwellScalingStartsAbovePointCount = 3

    /// How long the pointing bubble fades before the buddy moves on to the next target.
    static let pointingBubbleFadeSeconds: Double = 0.4

    /// The per-point dwell for a sequence of `targetCount` targets on the UNTIMED walk.
    /// Full dwell for small sequences; linearly scaled down to `minPerPointDwellSeconds`
    /// as the count grows to `maxPointsSoftCap`, so more points doesn't mean a longer wait.
    /// Pure so it's unit-testable.
    static func perPointDwellSeconds(forPointingTargetCount targetCount: Int) -> Double {
        guard targetCount > dwellScalingStartsAbovePointCount else {
            return basePerPointDwellSeconds
        }
        let pointsOverThreshold = targetCount - dwellScalingStartsAbovePointCount
        let scalingRange = max(1, maxPointsSoftCap - dwellScalingStartsAbovePointCount)
        let scaledFraction = min(1.0, Double(pointsOverThreshold) / Double(scalingRange))
        let dwellReduction = (basePerPointDwellSeconds - minPerPointDwellSeconds) * scaledFraction
        return basePerPointDwellSeconds - dwellReduction
    }
}

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false
        // This cursor / annotation / thinking-cue overlay is ALWAYS `.readOnly` —
        // VISIBLE to external screen recorders (QuickTime/OBS/ScreenCaptureKit) so
        // Clawdy shows up in the user's demos/recordings. It NEVER leaks into
        // Clawdy's OWN model screenshots: those exclude all Clawdy windows at the
        // application level (`CompanionScreenCaptureUtility`), independent of this
        // `sharingType`, so annotation strokes still appear exactly once (from the
        // software compositor) and the model's view is unchanged.
        self.sharingType = .readOnly

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

/// The next move when the buddy finishes dwelling on a pointing target: either
/// ADVANCE to the next target in the ordered sequence, or RETURN to the cursor
/// because the last target was reached.
enum PointingSequenceStep: Equatable {
    /// Advance to the target at this index and point at it next.
    case advance(toIndex: Int)
    /// The sequence is exhausted — fly the buddy back to the cursor and clear.
    case returnToCursor
}

/// Pure, testable decision for walking an ordered pointing sequence: given the
/// index just finished and the total number of targets, decide whether to advance
/// to the next target (and to which index) or to return to the cursor. Isolated
/// from AppKit so the walk order is unit-tested without a live screen.
///
/// FORWARD-COMPAT: the overlay calls this from a fixed per-point dwell today; the
/// upcoming audio-sync stage will drive the same advance from a scheduled word
/// time. The decision of what comes next is deliberately independent of WHEN.
func nextPointingSequenceStep(currentIndex: Int, targetCount: Int) -> PointingSequenceStep {
    let nextIndex = currentIndex + 1
    if nextIndex < targetCount {
        return .advance(toIndex: nextIndex)
    }
    return .returnToCursor
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. At rest this is -45°, which
    /// composes with `clawBaseOrientationOffsetDegrees` (+90°) to a total of +45° —
    /// a clockwise-from-west rotation that aims the claw's pincer tip to the
    /// NORTHWEST (up-and-to-the-left), mirroring the real macOS arrow cursor.
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -45.0

    /// The claw art in `CursorClaw` points to the LEFT (its pincer opens toward -x),
    /// whereas the old triangle pointed UP (apex toward -y) at rotation 0. The whole
    /// flight/rotation pipeline (`triangleRotationDegrees`) was tuned for an
    /// up-pointing shape, so we add this fixed +90° so the claw's pincer points the
    /// same way the triangle apex did. That lets the pincer track the direction of
    /// travel during the bezier flight with ZERO change to the animation math.
    private let clawBaseOrientationOffsetDegrees: Double = 90.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// The pending "dwell then advance/return" work while the buddy is pointing at a
    /// target. Held so a new navigation (advancing to the next target, or a whole new
    /// sequence replacing this one) can CANCEL it cleanly — no overlapping timers.
    @State private var pointingDwellWorkItem: DispatchWorkItem?

    /// How long the bubble fades before the buddy moves on. Lives in `PointingTuning`
    /// (the single place all the pointing feel-tunables are grouped); mirrored here so
    /// the existing call sites read the same as before.
    private static let pointingBubbleFadeSeconds: Double = PointingTuning.pointingBubbleFadeSeconds

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    /// Approximate width of the "thinking" cue pill, used to offset it beside the
    /// cursor (the pill itself sizes to its content; this is just for placement).
    private let thinkingCueBubbleWidth: CGFloat = 90

    private let fullWelcomeMessage = "hey! i'm clawdy"

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(DS.Font.overlayCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding prompt — "press control + option and say hi" streamed after the welcome bubble
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(DS.Font.overlayCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(DS.Font.overlayCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Annotation overlay — freehand strokes the user draws on the cursor display
            // while holding PTT. Rendered BELOW the cursor so the triangle stays above
            // the drawing. Only shown on the cursor's screen; strokes on other displays
            // are not supported. Hit testing is disabled — the overlay window's local
            // mouse monitor handles the stroke input, not SwiftUI's event pipeline.
            // Gated on isCursorOnThisScreen only (not isAnnotationModeActive) so strokes
            // are never leaked to secondary-display overlay views — all stored strokes
            // carry displayIndex=0 and only the cursor display should show them.
            if isCursorOnThisScreen {
                AnnotationOverlayView(
                    annotationStrokeStore: companionManager.annotationStrokeStore,
                    displayIndex: 0,
                    screenHeightInPoints: screenFrame.height
                )
                .opacity(companionManager.annotationStrokeOpacity)
                .frame(width: screenFrame.width, height: screenFrame.height)
                .position(x: screenFrame.width / 2, y: screenFrame.height / 2)
                .allowsHitTesting(false)
            }

            // "Draw to annotate" affordance pill — fades in when annotation mode is
            // active to remind the user they can draw on screen while holding PTT.
            // Positioned near the cursor. Uses easeOut(0.3) for the fade transition.
            if isCursorOnThisScreen && companionManager.isAnnotationModeActive {
                VStack(spacing: 1) {
                    Text("Draw to annotate")
                        .font(DS.Font.overlayCaption)
                        .foregroundColor(DS.Colors.textSecondary)
                    // Secondary escape-hatch hint — reassures the user there's always
                    // a way out even if the modifier release is ever missed. Clawdy
                    // blue so it reads as an interactive affordance.
                    Text("esc to exit")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(DS.Colors.surface1.opacity(0.95))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 1)
                            )
                    )
                    .fixedSize()
                    .position(x: cursorPosition.x + 10, y: cursorPosition.y + 36)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
                    .allowsHitTesting(false)
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // All three states (triangle, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            // The pointing cursor is the OpenClaw lobster claw (template silhouette from
            // the `CursorClaw` asset, tinted with the `openClawRed` token so a later hex
            // change is one line). Everything else about the cursor is unchanged from the
            // old triangle: same 16×16 frame, same `.position(cursorPosition)` anchor, the
            // same bezier-flight rotation (`triangleRotationDegrees`, plus the fixed claw
            // orientation offset), scale, opacity gating, and animations.
            Image("CursorClaw")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(DS.Colors.openClawRed)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees + clawBaseOrientationOffsetDegrees))
                .shadow(color: DS.Colors.openClawRed, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && (companionManager.voiceState == .idle || companionManager.voiceState == .responding) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Blue waveform — replaces the triangle while listening
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing (transcription + Claude + waiting for TTS)
            BlueCursorSpinnerView()
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Visual "thinking" cue — a small pill beside the cursor that fades in
            // only when a turn has run slow (past ThinkingCueState.appearanceDelaySeconds)
            // with no audio/answer yet, so a slow turn doesn't feel dead. Purely
            // cosmetic: the request keeps running, and this hides the instant the
            // first audio/answer arrives or the turn ends. It lives in this overlay
            // window (sharingType = .readOnly — visible to recorders) but is kept out
            // of Clawdy's OWN model screenshots by app-level exclusion, not sharingType.
            if isCursorOnThisScreen && companionManager.isShowingThinkingCue {
                BlueCursorThinkingCueView()
                    .position(x: cursorPosition.x + 10 + (thinkingCueBubbleWidth / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .transition(.opacity)
            }

        }
        .animation(.easeInOut(duration: 0.3), value: companionManager.isShowingThinkingCue)
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            pointingDwellWorkItem?.cancel()
            pointingDwellWorkItem = nil
        }
        .onChange(of: companionManager.currentPointingTargetIndex) { newIndex in
            // The pointing sequence advanced (or started). Drive the buddy to the
            // CURRENT target. Only the screen the target is on animates, so the
            // single buddy hands off across monitors as the sequence walks.
            handlePointingTargetIndexChange(newIndex)
        }
    }

    /// Reacts to a change in `currentPointingTargetIndex` — a new sequence starting,
    /// an advance to the next target, or a hand-off to a target on another screen.
    private func handlePointingTargetIndexChange(_ newIndex: Int?) {
        guard let index = newIndex,
              companionManager.detectedElementTargets.indices.contains(index) else {
            // The index cleared. This is NOT where the fly-back happens — the buddy
            // is sent back to the cursor from the last target's dwell completion, and
            // the manager is cleared only AFTER it lands. Nothing to do here.
            return
        }

        let target = companionManager.detectedElementTargets[index]
        let targetIsOnThisScreen = screenFrame.contains(CGPoint(x: target.displayFrame.midX, y: target.displayFrame.midY))
            || target.displayFrame == screenFrame

        if targetIsOnThisScreen {
            startNavigatingToElement(screenLocation: target.screenLocation)
        } else if buddyNavigationMode != .followingCursor {
            // The active target moved to a DIFFERENT screen. Release this screen's
            // buddy (it re-appears on the target's screen) so only one is ever
            // visible. Local-only reset — the sequence continues over there, so we
            // must NOT clear the manager's pointing state.
            resetLocalNavigationState()
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When a pointing
    /// sequence is active on some screen (but this screen isn't the one
    /// animating), hide the cursor so only one buddy is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If a pointing sequence is active (its buddy lives on the current
            // target's screen), hide the following-cursor buddy everywhere else so
            // there's never a duplicate.
            if companionManager.isPointingSequenceActive {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Cancel any pending dwell/advance from a previous target so navigating to a
        // new one (the next in the sequence, or a fresh sequence) never overlaps.
        pointingDwellWorkItem?.cancel()
        pointingDwellWorkItem = nil
        navigationAnimationTimer?.invalidate()

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to the default northwest-pointing angle now that we've arrived
        // (-45° + 90° base offset = +45° = up-left, mirroring the macOS arrow cursor)
        triangleRotationDegrees = -45.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // The bubble now shows the NAME of the place/landmark being pointed at (the
        // POINT tag's `label`), so it's clear what the cursor is referencing — instead
        // of a generic "found it!"-style phrase. The onboarding demo still overrides
        // with its own custom text via `detectedElementBubbleText`. If there's no name
        // to show (an empty/absent label), we degrade gracefully: no bubble at all,
        // never a placeholder.
        let onboardingCustomText = companionManager.detectedElementBubbleText
        let currentTargetLabel = companionManager.currentPointingTarget?.elementLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pointerLabel: String? = {
            if let onboardingCustomText, !onboardingCustomText.isEmpty {
                return onboardingCustomText
            }
            if let currentTargetLabel, !currentTargetLabel.isEmpty {
                return currentTargetLabel
            }
            return nil
        }()

        guard let pointerLabel else {
            // No place name to show — leave the bubble empty (the body gates on
            // non-empty text) and just dwell, then advance.
            schedulePointingDwellThenAdvance()
            return
        }

        streamNavigationBubbleCharacter(phrase: pointerLabel, characterIndex: 0) {
            // All characters streamed — dwell on this target, then advance to the
            // next one (or fly back if it was the last).
            self.schedulePointingDwellThenAdvance()
        }
    }

    /// Schedules the per-point dwell, then fades the bubble and advances the
    /// sequence (or flies the buddy back to the cursor after the last target).
    ///
    /// The dwell is held in `pointingDwellWorkItem` so a new navigation can cancel
    /// it cleanly.
    ///
    /// Stage 4 (audio-sync): when `pointingAdvanceIsAudioSynced` is set, the manager's
    /// audio-sync scheduler drives `advanceToNextPointingTarget` at each element's spoken
    /// word time. In that mode this FIXED dwell must NOT also advance to the next target
    /// (that would double-drive the walk and race the audio) — so we skip scheduling for
    /// any non-final target and let the scheduled advance (observed via
    /// `currentPointingTargetIndex`) move the buddy on. We STILL run the dwell for the LAST
    /// target, whose only remaining move is to fly BACK to the cursor: nothing external
    /// drives that, so the fixed dwell → returnToCursor still owns it. When NOT audio-synced
    /// (Apple TTS, ElevenLabs failed/empty alignment) this is the unchanged Stage 1–3 walk.
    private func schedulePointingDwellThenAdvance() {
        pointingDwellWorkItem?.cancel()

        let targetCount = companionManager.detectedElementTargets.count
        let currentIndex = companionManager.currentPointingTargetIndex ?? (targetCount - 1)
        let isLastTarget = nextPointingSequenceStep(currentIndex: currentIndex, targetCount: targetCount) == .returnToCursor
        if companionManager.pointingAdvanceIsAudioSynced && !isLastTarget {
            // The audio-sync scheduler owns the advance to the next target.
            return
        }

        let dwellWork = DispatchWorkItem { [self] in
            guard buddyNavigationMode == .pointingAtTarget else { return }
            navigationBubbleOpacity = 0.0

            let advanceWork = DispatchWorkItem { [self] in
                guard buddyNavigationMode == .pointingAtTarget else { return }
                advanceOrReturnAfterPointing()
            }
            pointingDwellWorkItem = advanceWork
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.pointingBubbleFadeSeconds,
                execute: advanceWork
            )
        }
        pointingDwellWorkItem = dwellWork
        // Scale the dwell DOWN as the sequence grows so a large untimed walk (Apple TTS
        // or degraded audio-sync) stays snappy instead of ballooning.
        let perPointDwellSeconds = PointingTuning.perPointDwellSeconds(forPointingTargetCount: targetCount)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + perPointDwellSeconds,
            execute: dwellWork
        )
    }

    /// The CALLABLE ADVANCE STEP: after dwelling on the current target, either move
    /// on to the next target in the sequence or, if this was the last, fly the buddy
    /// back to the cursor. Kept separate from the dwell timer so the audio-sync stage
    /// can drive it from a scheduled word time instead.
    private func advanceOrReturnAfterPointing() {
        let targetCount = companionManager.detectedElementTargets.count
        let currentIndex = companionManager.currentPointingTargetIndex ?? (targetCount - 1)

        switch nextPointingSequenceStep(currentIndex: currentIndex, targetCount: targetCount) {
        case .advance:
            // Publish the next index — the manager owns the index so every screen's
            // BlueCursorView observes the same advance and the right one animates.
            companionManager.advanceToNextPointingTarget()
        case .returnToCursor:
            startFlyingBackToCursor()
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        finishNavigationAndResumeFollowing()
    }

    /// Resets THIS screen's buddy to cursor-following and tears down its local
    /// animation state (timers, dwell, bubble) WITHOUT touching the manager's
    /// pointing sequence. Used when the active target crosses to another monitor, so
    /// the sequence continues over there while this screen quietly releases its buddy.
    private func resetLocalNavigationState() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        pointingDwellWorkItem?.cancel()
        pointingDwellWorkItem = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        // Return to the default northwest-pointing angle (-45° + 90° base offset = +45°)
        triangleRotationDegrees = -45.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
    }

    /// Returns the buddy to normal cursor-following mode after the WHOLE sequence
    /// completes (or is cancelled) and clears the manager's pointing state. Called
    /// once the buddy has flown back to the cursor after the last target.
    private func finishNavigationAndResumeFollowing() {
        resetLocalNavigationState()
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Guide the user to try push-to-talk right after the welcome text
                    // disappears (the intro video/music were removed).
                    self.companionManager.startOnboardingPromptStream()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// MARK: - Blue Cursor Thinking Cue

/// A small blue pill with the word "thinking" and three pulsing dots, shown
/// beside the cursor only when a turn runs slow (past the thinking-cue
/// threshold) with no audio/answer yet. Reassures the user the request is still
/// alive without implying it failed. Purely visual — it never affects the request.
private struct BlueCursorThinkingCueView: View {
    /// Drives the staggered dot pulse. A repeating animation phase 0→1.
    @State private var animationPhase: CGFloat = 0

    private let dotCount = 3

    var body: some View {
        HStack(spacing: 4) {
            Text("thinking")
                .font(DS.Font.overlayCaption)
                .foregroundColor(.white)

            HStack(spacing: 2) {
                ForEach(0..<dotCount, id: \.self) { dotIndex in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 3, height: 3)
                        .opacity(dotOpacity(for: dotIndex))
                }
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.overlayCursorBlue)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
        )
        .fixedSize()
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                animationPhase = 1
            }
        }
    }

    /// Each dot brightens in turn so the three dots read as an ongoing "…" pulse.
    private func dotOpacity(for dotIndex: Int) -> Double {
        let staggeredPhase = (animationPhase + CGFloat(dotIndex) / CGFloat(dotCount)).truncatingRemainder(dividingBy: 1)
        // A smooth up/down curve over the phase so each dot fades in and out.
        let pulse = (sin(staggeredPhase * 2 * .pi) + 1) / 2
        return 0.35 + Double(pulse) * 0.65
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    // MARK: - Annotation mode

    /// Token returned by NSEvent.addLocalMonitorForEvents for the annotation
    /// mouse monitor. Stored so it can be removed when annotation mode ends.
    private var annotationMouseEventMonitor: Any? = nil

    /// Reference to the stroke store fed by the annotation mouse monitor.
    /// Using nonisolated(unsafe) so the local monitor closure can access it
    /// without a main-actor hop — the callback is already on the main thread.
    nonisolated(unsafe) private var annotationStrokeStoreForMonitorCallback: AnnotationStrokeStore? = nil

    /// The cursor display's screen frame captured when annotation mode is
    /// activated, used to convert global AppKit mouse coords to display-relative
    /// coords that the stroke store uses.
    /// Using nonisolated(unsafe) for the same reason as the store reference above.
    nonisolated(unsafe) private var annotationCursorScreenFrameForMonitorCallback: CGRect? = nil

    /// Enters or exits annotation mode on the cursor display's overlay window.
    ///
    /// When `active` is true:
    ///   - The cursor display's overlay window stops ignoring mouse events so
    ///     clicks don't fall through to windows below, preventing accidental taps
    ///     on UI behind the overlay while the user is drawing.
    ///   - A local NSEvent monitor is installed to track left-click-drag strokes
    ///     and feed them into `annotationStrokeStore`.
    ///
    /// When `active` is false:
    ///   - The local monitor is removed (no more strokes can be added).
    ///   - All overlay windows revert to click-through (ignoresMouseEvents = true).
    ///   - `annotationStrokeStore` may be nil when deactivating — the reference is
    ///     cleared regardless.
    func setAnnotationMode(_ active: Bool, annotationStrokeStore: AnnotationStrokeStore?) {
        if active {
            guard let strokeStore = annotationStrokeStore else { return }

            // Record the cursor screen frame at activation time so the monitor
            // can convert global AppKit coords to display-relative coords.
            let mouseLocationAtActivation = NSEvent.mouseLocation
            let cursorScreenAtActivation = NSScreen.screens.first {
                $0.frame.contains(mouseLocationAtActivation)
            } ?? NSScreen.screens.first
            annotationCursorScreenFrameForMonitorCallback = cursorScreenAtActivation?.frame
            annotationStrokeStoreForMonitorCallback = strokeStore

            // Make the cursor display's overlay stop being click-through so the
            // user's left-clicks draw strokes instead of hitting windows behind.
            if let cursorScreenFrame = cursorScreenAtActivation?.frame {
                for window in overlayWindows where window.frame == cursorScreenFrame {
                    window.ignoresMouseEvents = false
                }
            }

            // Install a LOCAL monitor for left-click-drag events. A global monitor
            // does NOT receive events delivered to the app's own windows; when
            // ignoresMouseEvents=false the overlay intercepts clicks as app-local events
            // and a global monitor would silently miss them. The closure returns the
            // event unchanged so other handlers in the responder chain can still see it.
            annotationMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handleAnnotationMouseEvent(event)
                return event
            }
        } else {
            // Remove the local monitor — no more stroke input after PTT release.
            if let monitorToken = annotationMouseEventMonitor {
                NSEvent.removeMonitor(monitorToken)
                annotationMouseEventMonitor = nil
            }
            // Restore click-through on all overlay windows.
            for window in overlayWindows {
                window.ignoresMouseEvents = true
            }
            annotationStrokeStoreForMonitorCallback = nil
            annotationCursorScreenFrameForMonitorCallback = nil
        }
    }

    /// Converts the current global mouse position to display-relative AppKit
    /// coordinates and feeds it into the stroke store based on the event type.
    /// Called on the main thread by the global NSEvent monitor.
    nonisolated private func handleAnnotationMouseEvent(_ event: NSEvent) {
        guard let strokeStore = annotationStrokeStoreForMonitorCallback,
              let cursorScreenFrame = annotationCursorScreenFrameForMonitorCallback else { return }

        let globalMouseLocation = NSEvent.mouseLocation
        // Convert from global AppKit coords (origin = bottom-left of primary screen)
        // to display-relative AppKit coords (origin = bottom-left of cursor screen).
        let displayRelativePoint = CGPoint(
            x: globalMouseLocation.x - cursorScreenFrame.origin.x,
            y: globalMouseLocation.y - cursorScreenFrame.origin.y
        )

        switch event.type {
        case .leftMouseDown:
            strokeStore.beginStroke(displayIndex: 0)
            strokeStore.addPoint(displayRelativePoint)
        case .leftMouseDragged:
            strokeStore.addPoint(displayRelativePoint)
        case .leftMouseUp:
            strokeStore.endStroke()
        default:
            break
        }
    }

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

