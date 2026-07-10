//
//  ResearchStackedOverlay.swift
//  Clawdy
//
//  The manager-owned research overlay, ONE INDEPENDENT WINDOW PER TOAST.
//
//  Each active research session gets its OWN floating, non-activating, all-Spaces,
//  screenshot-excluded `NSPanel` (`ResearchToastPanel`), stacked vertically top-left,
//  one below the next. Each toast is a physically separate OS window with its OWN hover
//  tracking and its OWN expand state, so hovering, expanding, or collapsing one toast
//  cannot flip or steal hover from any sibling.
//
//  RESTING-vs-EXPANDED window sizing (the reconciled fix):
//
//   • AT REST each toast window — and its hover tracking region — is exactly the small
//     MINI/resting badge footprint (`miniWindowContentSize`). There is NO phantom hit
//     region over empty space, so the resting badges pack CLOSE together vertically
//     (`restingSlotStride`, based on the mini badge height, not the expanded pill).
//
//   • THE MOMENT the pointer enters the mini badge (`mouseEntered`), the toast's window
//     frame AND its tracking area grow SYNCHRONOUSLY (not animated) to the EXPANDED
//     footprint (`expandedWindowContentSize`), anchored at the slot's TOP-LEFT so the
//     badge stays put and the window only extends RIGHT and DOWN. Because the hit region
//     jumps to the full expanded rect at hover-START — before/independent of the visual
//     content morph — the cursor moving into the area the pill grows into stays IN-bounds,
//     so the toast never collapses mid-animation (the original dead-zone bug stays fixed).
//     Only the pill CONTENT (badge ⇄ full pill) animates inside the now-expanded window.
//     On `mouseExited` the window/tracking shrink back to the mini footprint.
//
//   • REFLOW: while a toast is expanded, the toasts BELOW it are pushed DOWN by the
//     expand delta (`expandDelta`) so the expanded window has room and never overlaps a
//     sibling's badge; they slide back when it collapses. The push is animated unless
//     Reduce Motion is on (then it snaps). Reflow shifts a sibling's POSITION only — it
//     never changes a sibling's hover/expand state.
//
//   • CLAWDY CURSOR: while the pointer is over a toast (badge, full pill, or its
//     controls) the app's blue Clawdy "shadow cursor" is shown instead of the system
//     arrow/pointing-hand, via a front, click-through `ClawdyCursorOverlayView` whose
//     cursor rect wins over the SwiftUI controls beneath it.
//
//  The vertical stack still collapses beyond `maximumVisiblePills` to a "+N more" /
//  "show less" control (its own small panel). The focused session's read-only detail
//  panel is shown beside the column. Every window here is `sharingType = .none` and has
//  an EXPLICIT non-zero frame (never a fitting-size race).
//

import AppKit
import Combine
import SwiftUI

// MARK: - Pill footprints (shared with ResearchFullToastView + the Recent Research badge)

/// The two pill footprints — the small RESTING badge and the larger hover-EXPANDED
/// pill — plus the inter-toast spacing. Pure and AppKit-free. The RESTING size is the
/// visible resting badge (and, at rest, the toast window + hit region); the EXPANDED
/// size is the visible full pill (and, on hover, the grown toast window + hit region).
enum ResearchStackFrameLayout {
    /// The small resting badge footprint. Widened from the original 48pt square just
    /// enough to fit the resting signals — the leading progress glyph, the one-word task
    /// label, and the step (icon + word) — without overflowing. Its width IS the resting
    /// hover hit region width (via `ResearchToastLayout.miniWindowContentSize` /
    /// `pillRect`), so growing it here grows the tight resting hitbox in lock-step.
    static let restingPillSize = CGSize(width: 168, height: 36)
    /// The full-toast footprint (title + status + controls). This is the ONE size every
    /// active research toast renders at (`ResearchFullToastView`) — the retired mini badge
    /// no longer had a separate resting size — and the Recent Research hover-expanded list
    /// reuses it too. Named `expandedPillSize` for continuity with the shared geometry.
    static let expandedPillSize = CGSize(width: 320, height: 68)
    /// Vertical gap between consecutive toast windows.
    static let pillSpacing: CGFloat = 8
}

// MARK: - Pure per-toast window layout (resting-vs-expanded hit region + reflow)

/// Pure, AppKit-free geometry for the per-toast windows: the resting MINI window size
/// and the hover-EXPANDED window size (each the pill footprint plus a shadow margin),
/// the COMPACT resting slot stride (mini-height based, so badges pack close), the
/// expand delta, the reflow offsets (push lower toasts down when one expands), and each
/// slot's on-screen origin. Keeping this pure guarantees every window is a NON-ZERO
/// explicit frame and makes the "tight-at-rest / expanded-on-hover" sizing, the compact
/// stride, and the reflow contracts unit-testable with no windows.
enum ResearchToastLayout {
    /// Transparent margin around the pill inside its window so the pill's own drop
    /// shadow renders without being clipped by the window bounds. Shared by both the
    /// mini and expanded windows so the pill's top-left inset is identical in either
    /// state — the badge's on-screen position doesn't jump as the window grows/shrinks.
    static let shadowMargin: CGFloat = 18

    /// The RESTING toast window content size — the small MINI/resting badge footprint
    /// plus the shadow margin. This is the tight window (and hit region) at rest: no
    /// phantom hitbox over empty space. Non-zero by construction.
    static var miniWindowContentSize: CGSize {
        CGSize(
            width: ResearchStackFrameLayout.restingPillSize.width + shadowMargin * 2,
            height: ResearchStackFrameLayout.restingPillSize.height + shadowMargin * 2
        )
    }

    /// The hover-EXPANDED toast window content size — the full expanded pill footprint
    /// plus the shadow margin. The window grows to this the instant hover begins (anchored
    /// top-left) and shrinks back on hover-out. Non-zero by construction.
    static var expandedWindowContentSize: CGSize {
        CGSize(
            width: ResearchStackFrameLayout.expandedPillSize.width + shadowMargin * 2,
            height: ResearchStackFrameLayout.expandedPillSize.height + shadowMargin * 2
        )
    }

    /// How much taller (and how far each lower toast is pushed down) when a toast expands
    /// from the mini to the expanded footprint. Equal to the difference in either the pill
    /// heights or the window heights (the shared shadow margin cancels).
    static var expandDelta: CGFloat {
        expandedWindowContentSize.height - miniWindowContentSize.height
    }

    /// The pill's rect inside a toast window of `contentSize`, anchored TOP-LEADING and
    /// inset by the shadow margin — the exact region the badge/pill occupies. It is BOTH
    /// the hover tracking rect and the Clawdy-cursor rect for the toast, so the hit region
    /// hugs the visible pill (mini at rest, expanded on hover) with no phantom padding.
    static func pillRect(inWindowOfSize contentSize: CGSize, pillSize: CGSize) -> CGRect {
        CGRect(
            x: shadowMargin,
            // Top-leading in the (unflipped, y-up) window: pin the pill's TOP `shadowMargin`
            // below the window's top edge, so it sits at the same on-screen spot regardless
            // of whether the window is the mini or the taller expanded size.
            y: contentSize.height - shadowMargin - pillSize.height,
            width: pillSize.width,
            height: pillSize.height
        )
    }

    /// The pill's VISIBLE footprint inside a toast window when its content is scaled by
    /// `scale` with a TOP-LEADING anchor — exactly how a stacked back card recedes (it shrinks
    /// toward its own top-left corner). The top-left corner stays pinned at the same spot as
    /// the unscaled `pillRect`, and the width/height shrink by `scale`, so the hover/cursor
    /// tracking rect hugs the shrunken card instead of the full unscaled pill. `scale == 1`
    /// reproduces `pillRect` exactly, so the front card / fanned / list cases are unchanged.
    static func scaledPillRect(inWindowOfSize contentSize: CGSize, pillSize: CGSize, scale: CGFloat) -> CGRect {
        let scaledWidth = pillSize.width * scale
        let scaledHeight = pillSize.height * scale
        return CGRect(
            x: shadowMargin,
            // Keep the pill's TOP edge pinned (top-leading anchor): the card shrinks DOWNWARD
            // from that fixed top, so the rect's `y` (its bottom, in y-up coords) rises as the
            // scaled height shrinks.
            y: contentSize.height - shadowMargin - scaledHeight,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    /// The control ("+N more" / "show less") panel's fixed content size — the expanded
    /// pill width (so it lines up under the toasts) plus the shadow margin, and a short
    /// height for the single-row control.
    static var controlWindowContentSize: CGSize {
        CGSize(
            width: ResearchStackFrameLayout.expandedPillSize.width + shadowMargin * 2,
            height: 32 + shadowMargin * 2
        )
    }

    /// The COMPACT vertical distance between consecutive RESTING toast slots' top edges:
    /// the mini/resting badge height plus a one-margin bottom shadow allowance plus the
    /// inter-toast gap — deliberately based on the MINI badge, NOT the expanded footprint,
    /// so the resting badges sit close together (they used to be a full expanded-window
    /// apart). Windows only overlap within the transparent shadow band between badges
    /// (never over a sibling's pill/hit rect), so independence still holds. Still used by
    /// the single-badge Recent Research surface (index 0, so the stride is irrelevant to
    /// its position) and as the default `slotTopLeftOrigin` stride.
    static var restingSlotStride: CGFloat {
        ResearchStackFrameLayout.restingPillSize.height + shadowMargin + ResearchStackFrameLayout.pillSpacing
    }

    /// The vertical distance between consecutive FULL-TOAST slots' top edges when the
    /// active toasts are FANNED OUT into the vertical list. Based on the full toast
    /// footprint (every active run now renders as the full toast, not the retired mini
    /// badge) plus the inter-toast gap, so the full pills sit clear of each other with an
    /// `pillSpacing` gap and never overlap a sibling's pill rect.
    static var fullToastSlotStride: CGFloat {
        ResearchStackFrameLayout.expandedPillSize.height + ResearchStackFrameLayout.pillSpacing
    }

    /// How far the toast at `index` is pushed DOWN by the reflow: one `expandDelta` for
    /// every currently-expanded toast strictly ABOVE it. A toast never reflows itself or
    /// anything above the expanded one — only the toasts below make room. Pure so the
    /// reflow is unit-testable with no windows.
    static func reflowDownOffset(forIndex index: Int, expandedIndices: Set<Int>, expandDelta: CGFloat) -> CGFloat {
        let expandedAbove = expandedIndices.filter { $0 < index }.count
        return CGFloat(expandedAbove) * expandDelta
    }

    /// The TOP-LEFT origin (AppKit screen coordinates) of the slot at `index`, pinned to
    /// `corner` of `visibleFrame`, then pushed DOWN by `reflowDownOffset` (the reflow made
    /// when a toast above is expanded). With `reflowDownOffset == 0` the position depends
    /// ONLY on `index` and the screen — the geometric root of independence at rest.
    static func slotTopLeftOrigin(
        index: Int,
        corner: ResearchOverlayAnchor.Corner,
        visibleFrame: CGRect,
        edgeInset: CGFloat,
        stride: CGFloat = restingSlotStride,
        reflowDownOffset: CGFloat = 0
    ) -> CGPoint {
        // Down is smaller Y in AppKit's bottom-left coordinates, so a downward reflow
        // SUBTRACTS from the slot's Y.
        let topY = visibleFrame.maxY - edgeInset - CGFloat(index) * stride - reflowDownOffset
        let originX: CGFloat
        switch corner {
        case .topLeft:
            originX = visibleFrame.minX + edgeInset
        case .topRight:
            originX = visibleFrame.maxX - miniWindowContentSize.width - edgeInset
        }
        return CGPoint(x: originX, y: topY)
    }

    /// The bottom-left window origin (AppKit coordinates) for a window of `contentSize`
    /// whose slot top-left is `slotTopLeft`. The window hangs DOWN from the slot's top
    /// edge, so the slot's top stays fixed as the window grows/shrinks (the anchor that
    /// keeps the mini badge in place when the window expands right/down on hover).
    static func windowOrigin(slotTopLeft: CGPoint, contentSize: CGSize) -> CGPoint {
        CGPoint(x: slotTopLeft.x, y: slotTopLeft.y - contentSize.height)
    }
}

// MARK: - Pure user-drag offset (accumulate + on-screen clamp)

/// Pure, AppKit-free math for the SINGLE shared drag offset the user applies to the
/// upper-left research overlay cluster (the toast stack + the idle recents badge share
/// ONE offset, so dragging either moves both). Kept value-in / value-out so the
/// accumulation and the "keep the pill on screen" clamp are unit-testable with no windows.
enum ResearchOverlayDragOffset {
    /// Accumulates a live drag delta (how far the window moved past where layout placed it)
    /// into the running offset. Additive so many small drag steps sum to the total move.
    static func accumulate(current: CGVector, delta: CGVector) -> CGVector {
        CGVector(dx: current.dx + delta.dx, dy: current.dy + delta.dy)
    }

    /// Clamps `offset` so the draggable pill — whose rect at offset ZERO is
    /// `basePillScreenRect` — stays FULLY within `visibleFrame` once translated by the
    /// offset. This is what stops the user from dragging the cluster entirely off-screen:
    /// the visible pill always keeps its whole footprint on the screen's visible area.
    static func clamp(_ offset: CGVector, basePillScreenRect: CGRect, visibleFrame: CGRect) -> CGVector {
        // Allowed dx keeps the pill's [minX + dx, maxX + dx] inside the visible frame's
        // horizontal span; likewise for dy. The lower bound moves the pill left/down until
        // its leading/bottom edge touches the frame; the upper bound until its trailing/top
        // edge touches.
        let lowerBoundDX = visibleFrame.minX - basePillScreenRect.minX
        let upperBoundDX = visibleFrame.maxX - basePillScreenRect.maxX
        let lowerBoundDY = visibleFrame.minY - basePillScreenRect.minY
        let upperBoundDY = visibleFrame.maxY - basePillScreenRect.maxY
        return CGVector(
            dx: clampValue(offset.dx, lowerBound: lowerBoundDX, upperBound: upperBoundDX),
            dy: clampValue(offset.dy, lowerBound: lowerBoundDY, upperBound: upperBoundDY)
        )
    }

    /// Clamps `value` into `[lowerBound, upperBound]`. If the pill is somehow LARGER than the
    /// visible frame (lower > upper), pins to the lower bound so at least the pill's
    /// leading/bottom edge stays anchored on screen rather than producing an empty range.
    private static func clampValue(_ value: CGFloat, lowerBound: CGFloat, upperBound: CGFloat) -> CGFloat {
        guard lowerBound <= upperBound else { return lowerBound }
        return min(max(value, lowerBound), upperBound)
    }
}

// MARK: - Clawdy red "shadow cursor" for toast hover

/// Builds and caches the app's red Clawdy cursor (the same triangular "shadow cursor"
/// glyph `BlueCursorView`/`OverlayWindow` renders for the POINT feature) as an
/// `NSCursor`, so hovering a research toast shows Clawdy pointing at it instead of the
/// system arrow/pointing-hand. The glyph is rasterized to match `BlueCursorView`: the
/// `Triangle` shape filled with `openClawRed`, rotated -35°, with a soft red glow. The
/// hot spot sits at the triangle's tip.
enum ResearchToastCursor {
    /// The shared Clawdy cursor (built once — the raster + `NSCursor` are immutable).
    static let clawdy: NSCursor = makeClawdyCursor()

    private static func makeClawdyCursor() -> NSCursor {
        let imageDimension: CGFloat = 24
        let imageSize = NSSize(width: imageDimension, height: imageDimension)
        // Triangle geometry mirroring `Triangle.path(in:)`, drawn up-pointing and centered,
        // then rotated -35° like `BlueCursorView`'s `triangleRotationDegrees` default.
        let triangleSize: CGFloat = 15
        let centerX = imageDimension / 2
        let centerY = imageDimension / 2
        let triangleHeight = triangleSize * sqrt(3.0) / 2.0
        // AppKit is y-up, so the "top" vertex is the one with the LARGER y.
        let topVertex = CGPoint(x: centerX, y: centerY + triangleHeight / 1.5)
        let bottomLeftVertex = CGPoint(x: centerX - triangleSize / 2, y: centerY - triangleHeight / 3)
        let bottomRightVertex = CGPoint(x: centerX + triangleSize / 2, y: centerY - triangleHeight / 3)

        let rotationRadians = -35.0 * .pi / 180.0
        func rotatedAboutCenter(_ point: CGPoint) -> CGPoint {
            let deltaX = point.x - centerX
            let deltaY = point.y - centerY
            return CGPoint(
                x: centerX + deltaX * cos(rotationRadians) - deltaY * sin(rotationRadians),
                y: centerY + deltaX * sin(rotationRadians) + deltaY * cos(rotationRadians)
            )
        }
        let rotatedTop = rotatedAboutCenter(topVertex)
        let rotatedBottomLeft = rotatedAboutCenter(bottomLeftVertex)
        let rotatedBottomRight = rotatedAboutCenter(bottomRightVertex)

        let openClawRed = NSColor(DS.Colors.openClawRed)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: rotatedTop)
            path.line(to: rotatedBottomLeft)
            path.line(to: rotatedBottomRight)
            path.close()

            NSGraphicsContext.current?.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = openClawRed.withAlphaComponent(0.9)
            glow.shadowBlurRadius = 5
            glow.shadowOffset = .zero
            glow.set()
            openClawRed.setFill()
            path.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            return true
        }

        // `NSCursor` hot spots use a TOP-LEFT origin, so flip the (y-up) tip vertically.
        let hotSpot = NSPoint(x: rotatedTop.x, y: imageSize.height - rotatedTop.y)
        return NSCursor(image: image, hotSpot: hotSpot)
    }
}

// MARK: - Pure on-screen anchor

/// Pure placement corner for the toast column. Anchored TOP-LEFT by default to avoid
/// colliding with native macOS Notification Center banners (top-right, un-queryable via
/// any public API) — so we render on the opposite side rather than under them.
enum ResearchOverlayAnchor {
    /// Which screen corner the column pins to. Tune `ResearchStackedOverlayController`'s
    /// single `anchorCorner` constant to move it.
    enum Corner: Equatable {
        case topLeft
        case topRight
    }

    /// The top-left origin (AppKit bottom-left coordinates) for a panel of `size`
    /// pinned to `corner` of `visibleFrame`, inset by `inset` on all touched edges.
    static func stackOrigin(
        corner: Corner,
        visibleFrame: CGRect,
        size: CGSize,
        inset: CGFloat
    ) -> CGPoint {
        let originY = visibleFrame.maxY - size.height - inset
        switch corner {
        case .topLeft:
            return CGPoint(x: visibleFrame.minX + inset, y: originY)
        case .topRight:
            return CGPoint(x: visibleFrame.maxX - size.width - inset, y: originY)
        }
    }
}

// MARK: - Pure stack layout (collapse beyond N)

/// Pure, side-effect-free decision of which toasts are shown and whether a "+N more"
/// collapse row is needed. Value-in / value-out so the collapse-beyond-3 behavior is
/// unit-testable without any AppKit.
enum ResearchOverlayStackLayout {
    /// The most toasts shown before the stack collapses to a "+N more" row.
    static let maximumVisiblePills = 3

    /// The optional control row drawn UNDER the toasts. Its existence is NOT keyed on
    /// `hiddenCount > 0` — the expanded state also gets a row ("show less") so the
    /// collapse affordance stays reachable once the user has expanded the stack.
    enum ControlRow: Equatable {
        /// Collapsed with overflow: "+N more" — tapping expands.
        case showMore(hiddenCount: Int)
        /// Expanded past the visible cap: "show less" — tapping collapses.
        case showLess
    }

    struct Plan: Equatable {
        /// The session ids whose toasts are drawn, in order, top to bottom.
        let visibleSessionIDs: [ResearchSessionID]
        /// The control row to draw beneath the toasts, or nil when everything fits
        /// (`count <= maximumVisiblePills`) so no expand/collapse control is needed.
        let controlRow: ControlRow?

        /// How many sessions are folded behind a "+N more" row (0 when expanded or when
        /// everything fits).
        var hiddenCount: Int {
            if case .showMore(let hiddenCount) = controlRow { return hiddenCount }
            return 0
        }
    }

    /// Given the ordered active session ids and whether the user has expanded the stack,
    /// decide the visible toasts and which control row (if any) to draw.
    ///   - `count <= 3`           → all visible, NO control row.
    ///   - `count > 3`, collapsed → first 3 visible, "+(count-3) more".
    ///   - `count > 3`, expanded  → all visible, "show less".
    static func plan(orderedSessionIDs: [ResearchSessionID], isExpanded: Bool) -> Plan {
        if orderedSessionIDs.count <= maximumVisiblePills {
            return Plan(visibleSessionIDs: orderedSessionIDs, controlRow: nil)
        }
        if isExpanded {
            return Plan(visibleSessionIDs: orderedSessionIDs, controlRow: .showLess)
        }
        let visible = Array(orderedSessionIDs.prefix(maximumVisiblePills))
        return Plan(
            visibleSessionIDs: visible,
            controlRow: .showMore(hiddenCount: orderedSessionIDs.count - visible.count)
        )
    }
}

// MARK: - Pure native-stacking / fan-out layout

/// Pure, AppKit-free logic for the native macOS-style toast STACKING (like Notification
/// Center's stacked notifications) and its hover FAN-OUT. Kept value-in / value-out so the
/// ">= 3 collapses to a stack" threshold, the stacked ⇄ fanned state transitions, and the
/// per-card stacked transforms are all unit-testable with no windows.
///
/// The model has THREE presentations:
///   - `.list`    → fewer than `stackingThreshold` active toasts: a plain vertical list,
///                  no stacking (each toast shown normally).
///   - `.stacked` → `stackingThreshold`+ active toasts, at rest: they collapse into a
///                  compact overlapped stack (front toast on top; the ones behind peek
///                  out, offset down + scaled + dimmed).
///   - `.fanned`  → `stackingThreshold`+ active toasts, while the stack is hovered: they
///                  fan out into the full vertical list so each toast is individually
///                  visible and interactive (Stop, View results, …). A "collapse" control
///                  is offered to return to the stacked form.
enum ResearchStackFanLayout {
    /// The active-toast count at (or above) which the toasts collapse into the native
    /// stack. Below this they render as a normal vertical list with no stacking.
    static let stackingThreshold = 3

    /// Whether `toastCount` active toasts are STACKABLE — i.e. the native stack / fan-out
    /// behavior applies at all (3 or more).
    static func isStackable(toastCount: Int) -> Bool {
        toastCount >= stackingThreshold
    }

    /// The three presentations of the active-toast cluster.
    enum Presentation: Equatable {
        /// Fewer than the threshold: a normal vertical list, no stacking.
        case list
        /// Threshold+ at rest: the compact overlapped stack.
        case stacked
        /// Threshold+ while hovered: the fanned-out full vertical list.
        case fanned
    }

    /// The presentation for `toastCount` toasts given whether the cluster is currently
    /// fanned out (hovered). Under the threshold it's always `.list` (the fan state is
    /// meaningless); at/above it, `.fanned` while fanned else `.stacked`.
    static func presentation(toastCount: Int, isFannedOut: Bool) -> Presentation {
        guard isStackable(toastCount: toastCount) else { return .list }
        return isFannedOut ? .fanned : .stacked
    }

    /// The "collapse back to the stack" control shows ONLY while the cluster is BOTH
    /// stackable (threshold+) AND currently fanned out — so the user can always return to
    /// the compact stack, and it never appears when there's nothing to re-stack.
    static func showsCollapseControl(toastCount: Int, isFannedOut: Bool) -> Bool {
        isStackable(toastCount: toastCount) && isFannedOut
    }

    /// The next fanned-out state from a hover/interaction signal. A non-stackable cluster
    /// is never fanned (it's a plain list); a stackable one fans out while hovered and
    /// collapses back to the stack when the hover ends. Pure so the stacked ⇄ fanned
    /// transition is unit-tested with no windows or timers (the controller owns the small
    /// debounce that decides WHEN `isHovered` flips, not this).
    static func nextFannedState(toastCount: Int, isHovered: Bool, currentlyFanned: Bool) -> Bool {
        guard isStackable(toastCount: toastCount) else { return false }
        return isHovered
    }

    // MARK: Stacked card transforms

    /// How many cards are visually distinguished in the collapsed stack — the front card
    /// plus the peeking ones behind it. Deeper cards clamp to the last transform so a tall
    /// stack stays visually tidy.
    static let maximumStackedCards = 3
    /// Vertical peek (points) each card behind the front is offset DOWNWARD, so the ones
    /// behind stay visible below the front card's bottom edge.
    static let stackedCardPeek: CGFloat = 11
    /// Opacity reduction applied per card of depth behind the front (depth 0 = fully
    /// opaque), so cards recede visually into the stack.
    static let stackedOpacityStep: Double = 0.18

    /// The visual transform for a stacked card at `depthFromFront` (0 = the front, fully
    /// sized/opaque card; larger = further back). Depth is clamped to
    /// `maximumStackedCards - 1` so a deep stack doesn't fade to nothing.
    ///
    /// NATIVE-NOTIFICATION STACKING: back cards are the SAME WIDTH (and height) as the front
    /// card — they are NOT scaled down. Exactly like macOS Notification Center's stacked
    /// notifications, a card behind the front is only offset DOWN by a small peek and dimmed;
    /// it never becomes a narrower card. `scale` is therefore always `1.0` (kept as a field so
    /// callers that map it to a `.scaleEffect` are unchanged and a future variant can reuse it),
    /// which also means a back card's hover/hit rect stays the full-width pill at its offset
    /// position (`ResearchToastLayout.scaledPillRect(scale: 1.0)` == the full `pillRect`).
    struct StackedCardTransform: Equatable {
        /// Downward offset (points) of this card's top from the front card's top.
        let peekOffset: CGFloat
        /// Scale factor applied to the card's pill. ALWAYS `1.0` — back cards match the
        /// front card's width (native macOS notification stacking), never scaled down.
        let scale: CGFloat
        /// Opacity (1.0 = fully opaque) applied to the card's pill.
        let opacity: Double
        /// Z-position — larger is drawn in FRONT. The front card (depth 0) has the highest.
        let zPosition: Double
    }

    /// The stacked transform for a card `depthFromFront` behind the front (0-based).
    static func stackedCardTransform(depthFromFront: Int) -> StackedCardTransform {
        let clampedDepth = max(0, min(depthFromFront, maximumStackedCards - 1))
        return StackedCardTransform(
            peekOffset: CGFloat(clampedDepth) * stackedCardPeek,
            // Full width, always — back cards match the front card's width (native stacking).
            scale: 1.0,
            opacity: 1.0 - Double(clampedDepth) * stackedOpacityStep,
            // Front card (depth 0) is frontmost; deeper cards sit further back.
            zPosition: Double(-depthFromFront)
        )
    }
}

// MARK: - Rendered pill model (from the manager)

/// One entry the manager hands the controller: a session's id, its live pill view model,
/// and whether it is the focused session (drawn with a highlight ring).
struct ResearchStackPillModel: Identifiable {
    let id: ResearchSessionID
    let viewModel: ResearchProgressOverlayViewModel
    let isFocused: Bool
}

// MARK: - Per-toast hover model (SwiftUI bridge)

/// The small observable bridge each toast window's SwiftUI content observes for its OWN
/// focus/motion/stack state — independent per toast. The toast no longer morphs between a
/// mini badge and a pill (every active run renders as the full toast); instead this carries
/// the NATIVE-STACK visual state: when the cluster is collapsed into the stack, back cards
/// are scaled/offset/dimmed via `stackScale` / `stackPeekOffset` / `stackOpacity`, and when
/// fanned out (or in list mode) they return to full size. Flipped by the controller.
@MainActor
final class ResearchToastHoverModel: ObservableObject {
    @Published var isFocused: Bool = false
    @Published var reduceMotionEnabled: Bool = false
    /// Scale factor of this toast's pill (1.0 in the fanned/list form; < 1.0 for a card
    /// behind the front while stacked).
    @Published var stackScale: CGFloat = 1.0
    /// Opacity of this toast's pill (1.0 in the fanned/list form; < 1.0 for a receding
    /// card while stacked).
    @Published var stackOpacity: Double = 1.0
    /// Whether the fan-out / collapse motion should animate (false honors Reduce Motion).
    @Published var animatesStackTransition: Bool = true
}

// MARK: - Per-toast window

/// ONE research toast: its own transparent `NSPanel`, always sized to the SINGLE full toast
/// footprint (`expandedWindowContentSize`). The retired resting-mini / hover-expand window
/// GROW is gone — every active run renders as the full toast, so the window is one fixed
/// size and its `NSTrackingArea` is the full pill rect throughout. Hover on the window is
/// reported to the controller, which uses it to FAN OUT the native stack (and to collapse
/// it again when the pointer leaves the whole cluster). The controller also drives this
/// toast's STACKED visual transform (scale/opacity/z + a downward peek offset via the
/// window position) so a card behind the front recedes into the stack.
@MainActor
final class ResearchToastPanel {
    let sessionID: ResearchSessionID
    let panel: NSPanel

    private let hoverModel = ResearchToastHoverModel()
    private let pillViewModel: ResearchProgressOverlayViewModel
    private let trackingView: ResearchToastHoverTrackingView
    /// Front, click-through view whose cursor rect shows the Clawdy red cursor over the
    /// pill (winning over the SwiftUI controls beneath it).
    private let cursorOverlayView: ClawdyCursorOverlayView

    /// The toast's current slot top-left (screen coords). The window hangs down from it.
    private var currentSlotTopLeft: CGPoint = .zero

    /// The toast's current stacked scale (1.0 when fanned/list; < 1.0 for a receding back
    /// card). Drives the hover/cursor tracking rect so the hit region hugs the VISIBLE scaled
    /// card footprint — a shrunken stacked card must NOT keep a full-pill phantom hitbox.
    private var currentStackScale: CGFloat = 1.0

    /// The controller's hook, called when the pointer enters/leaves THIS toast, so the
    /// controller can aggregate hover across the cluster and fan out / collapse the stack.
    var onHoverChanged: ((Bool) -> Void)?

    init(
        sessionID: ResearchSessionID,
        pillViewModel: ResearchProgressOverlayViewModel,
        reduceMotionEnabled: Bool
    ) {
        self.sessionID = sessionID
        self.pillViewModel = pillViewModel
        hoverModel.reduceMotionEnabled = reduceMotionEnabled

        // The full toast footprint — one fixed window size (never a zero-size window).
        let size = ResearchToastLayout.expandedWindowContentSize
        // Draggable by its pill background so the user can move the cluster out of the way.
        panel = ResearchToastPanel.makeOverlayPanel(size: size, isMovableByWindowBackground: true)

        trackingView = ResearchToastHoverTrackingView(frame: CGRect(origin: .zero, size: size))
        let rootView = ResearchToastWindowRootView(
            pillViewModel: pillViewModel,
            hoverModel: hoverModel
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = trackingView.bounds
        hostingView.autoresizingMask = [.width, .height]
        // Force the hosting layer transparent so ONLY the pill shape (+ its blue aura)
        // draws — no opaque rectangle behind it.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        trackingView.addSubview(hostingView)

        // The Clawdy-cursor overlay sits IN FRONT of the SwiftUI content (added last), so
        // its cursor rect wins over the controls' pointing-hand rects, while its nil
        // hit-test lets clicks fall through to the buttons underneath.
        cursorOverlayView = ClawdyCursorOverlayView(frame: .zero)
        trackingView.addSubview(cursorOverlayView)

        panel.contentView = trackingView

        trackingView.onHoverChanged = { [weak self] hovering in
            self?.handleHover(hovering)
        }

        // Install the full-toast tracking + cursor region.
        applyTrackingRegion()
    }

    /// Updates the live focus/motion state (the pill view model is stable per session and
    /// observed directly, so it never needs rebinding).
    func update(isFocused: Bool, reduceMotionEnabled: Bool) {
        hoverModel.isFocused = isFocused
        hoverModel.reduceMotionEnabled = reduceMotionEnabled
    }

    /// Applies this toast's STACKED visual transform: `scale` / `opacity` for a card behind
    /// the front (both 1.0 when fanned out or in list mode), and whether the fan/collapse
    /// motion animates. The controller computes these from `ResearchStackFanLayout`.
    func applyStackPresentation(scale: CGFloat, opacity: Double, animatesTransition: Bool) {
        hoverModel.animatesStackTransition = animatesTransition
        hoverModel.stackScale = scale
        hoverModel.stackOpacity = opacity
        // Re-fit the hover/cursor hit region to the now-scaled visible card footprint so a
        // receding back card carries no phantom hitbox around its shrunken pill.
        currentStackScale = scale
        applyTrackingRegion()
    }

    /// Places the window at the given slot top-left (the window hangs down from it).
    /// `animated` smoothly slides it (the fan-out / collapse); pass `false` for an instant
    /// placement (a data-driven re-render).
    func place(slotTopLeft: CGPoint, animated: Bool) {
        currentSlotTopLeft = slotTopLeft
        let size = ResearchToastLayout.expandedWindowContentSize
        let origin = ResearchToastLayout.windowOrigin(slotTopLeft: currentSlotTopLeft, contentSize: size)
        let frame = CGRect(origin: origin, size: size)
        if animated {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Installs the hover tracking region and the Clawdy-cursor region over the VISIBLE pill
    /// footprint at the current stacked scale — the full pill when fanned/list (scale 1.0) and
    /// the shrunken card footprint when this is a receding back card in the stack, so the hit
    /// region always equals the visible rect (no phantom hitbox around a scaled card).
    private func applyTrackingRegion() {
        let size = ResearchToastLayout.expandedWindowContentSize
        let pillRect = ResearchToastLayout.scaledPillRect(
            inWindowOfSize: size,
            pillSize: ResearchStackFrameLayout.expandedPillSize,
            scale: currentStackScale
        )
        trackingView.setTrackingRect(pillRect)
        cursorOverlayView.frame = pillRect
        panel.invalidateCursorRects(for: cursorOverlayView)
    }

    func show() {
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Brings this toast's window to the front of the overlay's window stack — used so the
    /// stacked cluster's FRONT card sits above the cards peeking behind it.
    func orderFront() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// Hover entered/left THIS toast. Reported straight to the controller, which aggregates
    /// hover across the whole cluster to decide when to fan the stack out or collapse it.
    private func handleHover(_ hovering: Bool) {
        onHoverChanged?(hovering)
    }

    /// Builds a floating, non-activating, all-Spaces, screenshot-excluded panel. High
    /// window level so it sits above ordinary app windows; it must receive clicks (Stop /
    /// tap-to-focus), so it does NOT ignore mouse events.
    ///
    /// Parameterized so the forked panel constructors share this one setup:
    /// - `panelType` selects the concrete `NSPanel` subclass. The default is `NSPanel`
    ///   (the click-through toast/control windows); the keyable chat detail panel and the
    ///   clarification panel pass `KeyableResearchPanel` so they can become key and accept
    ///   typing. Constructed via the metatype so the returned value is the requested type.
    /// - `hasShadow` defaults to `false` (the toast/detail overlays draw their own aura);
    ///   the clarification panel passes `true` for a system drop shadow.
    /// - `includesStationaryCollectionBehavior` defaults to `true` (`.stationary` pins the
    ///   overlay so it doesn't slide during Space transitions); the clarification panel
    ///   passes `false` to keep its historical collection behavior exactly.
    /// - `isMovableByWindowBackground` defaults to `false`. The toast windows and the idle
    ///   recents badge pass `true` so the user can DRAG the upper-left cluster out of the
    ///   way by its dark pill background: AppKit moves the window on a background drag, while
    ///   a click (no movement) still reaches the SwiftUI content and the controls (Stop / × /
    ///   view results) consume their own mouse-down so they never start a drag. The control /
    ///   detail / clarification panels keep the default `false`.
    static func makeOverlayPanel<PanelType: NSPanel>(
        size: CGSize,
        panelType: PanelType.Type = NSPanel.self,
        hasShadow: Bool = false,
        includesStationaryCollectionBehavior: Bool = true,
        isMovableByWindowBackground: Bool = false
    ) -> PanelType {
        let panel = panelType.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = hasShadow
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = isMovableByWindowBackground
        // NB: do NOT set `isFloatingPanel` — it forces the level back to `.floating`,
        // sinking the overlay below other status-bar-level UI.
        var collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if includesStationaryCollectionBehavior {
            collectionBehavior.insert(.stationary)
        }
        panel.collectionBehavior = collectionBehavior
        panel.isExcludedFromWindowsMenu = true
        // Whether this research overlay panel is visible to EXTERNAL screen
        // recorders is governed by the "Show Clawdy in screen recordings"
        // (Recording Mode) setting — `.readOnly` when on, `.none` when off (the
        // default). It NEVER leaks into Clawdy's OWN model screenshots, which
        // exclude all Clawdy windows at the application level regardless of this
        // `sharingType`. New panels read the setting here; a live toggle reassigns
        // it on already-on-screen panels via `applyRecordingModeToLivePanels`.
        panel.sharingType = RecordingMode.overlaySharingType(
            recordingEnabled: UserDefaults.standard.bool(forKey: .recordingModeEnabled)
        )
        liveOverlayPanels.add(panel)
        return panel
    }

    /// Weakly tracks every research-overlay panel created via `makeOverlayPanel`
    /// (toasts, badge, +N control, clarification, detail) so a Recording Mode
    /// toggle can reassign their `sharingType` without a relaunch. Weak references
    /// so closed panels drop out automatically and are never resurrected. The
    /// results window is NOT created here (it stays `.readOnly` on its own), and
    /// the menu-bar panel is created elsewhere and stays `.none`.
    private static let liveOverlayPanels = NSHashTable<NSPanel>.weakObjects()

    /// Reassigns `sharingType` on every live research-overlay panel when the
    /// "Show Clawdy in screen recordings" (Recording Mode) setting changes, so the
    /// research chrome becomes visible-to-recorders (or hidden again) WITHOUT a
    /// relaunch. `sharingType` is mutable on a live NSPanel, so this fully reverts
    /// when toggled back off.
    static func applyRecordingModeToLivePanels(recordingEnabled: Bool) {
        let sharingType = RecordingMode.overlaySharingType(recordingEnabled: recordingEnabled)
        for panel in liveOverlayPanels.allObjects {
            panel.sharingType = sharingType
        }
    }

    // MARK: - Test hooks

    /// The current hover tracking rect (in window content coords) — the VISIBLE pill footprint
    /// at the current stacked scale (full pill when fanned/list, the shrunken card footprint
    /// while a receding back card) — so a test can prove the hit region hugs the visible pill.
    var trackingRectForTesting: CGRect { trackingView.trackingRectForTesting }
    /// The ACTUALLY-installed `NSTrackingArea` rect (what the OS hit-tests hover against), so a
    /// test proves the real hit region equals the visible (scaled) pill footprint.
    var installedTrackingRectForTesting: CGRect { trackingView.installedTrackingRectForTesting }
    /// Runs the REAL `hitTest` the OS uses for mouse-CLICK delivery, so a test can prove a point
    /// in the transparent aura margin is click-through (nil) while a point on the visible pill
    /// resolves to a real view.
    func hitTestForTesting(_ point: NSPoint) -> NSView? { trackingView.hitTest(point) }
    /// Drives the REAL hover handler (pointer enter/leave), so a test can exercise the
    /// controller's fan-out / collapse path through the real toast → controller hook.
    func setHoverForTesting(_ hovering: Bool) { handleHover(hovering) }
    /// This toast's current stacked scale/opacity, so a test can prove a card behind the
    /// front recedes while stacked and returns to full while fanned.
    var stackScaleForTesting: CGFloat { hoverModel.stackScale }
    var stackOpacityForTesting: Double { hoverModel.stackOpacity }
}

/// The AppKit view that hosts one toast's SwiftUI content and owns a TIGHT
/// `NSTrackingArea` over just the pill rect (NOT the whole window bounds), so there is no
/// phantom hover over the transparent shadow/aura margins. Enter/exit map straight to hover
/// on/off, which the toast forwards to the controller for the stack fan-out.
private final class ResearchToastHoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    /// The current tracking region — the full pill rect.
    private var trackingRect: CGRect = .zero
    var trackingRectForTesting: CGRect { trackingRect }
    /// The rect of the tracking area ACTUALLY installed on the view (as opposed to the
    /// stored `trackingRect` intent), so a test can prove the real hover hit region the
    /// OS uses — not just the value we meant to set — hugs the pill.
    var installedTrackingRectForTesting: CGRect { trackingAreas.first?.rect ?? .zero }

    /// Sets the tight tracking region (the pill rect) and rebuilds the tracking area.
    func setTrackingRect(_ rect: CGRect) {
        trackingRect = rect
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        guard trackingRect.width > 0, trackingRect.height > 0 else { return }
        let area = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    /// Makes the transparent aura/shadow margin around the pill CLICK-THROUGH: a mouse-down in
    /// the halo returns `nil` here so the event falls to whatever window sits behind the overlay,
    /// while a mouse-down anywhere on the VISIBLE pill still resolves to the real SwiftUI content
    /// (tap-to-open, Stop / × / view-results). Because this view is the panel's `contentView`,
    /// `point` arrives in window-content coordinates — the SAME space `trackingRect` (the visible
    /// pill footprint set by `setTrackingRect`) lives in, so the comparison needs no conversion.
    /// Hover-to-expand and the Clawdy cursor are unaffected: `NSTrackingArea` enter/exit and
    /// cursor rects are geometry-based and never route through `hitTest`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard trackingRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// A front, click-through view whose sole job is to show the Clawdy red "shadow cursor"
/// over the toast's pill. Placed IN FRONT of the SwiftUI hosting view, its cursor rect
/// wins over any pointing-hand rects the pill's controls register; `hitTest` returns nil
/// so clicks fall through to those controls unaffected.
private final class ClawdyCursorOverlayView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: ResearchToastCursor.clawdy)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The SwiftUI content of one toast window: the SINGLE full toast (`ResearchFullToastView`)
/// wrapped in the shared Clawdy red-aura glow so it reads as distinctively Clawdy, plus the
/// focus ring. The pill is positioned TOP-LEADING within the window (inset by the shadow /
/// aura margin) so its top-left is stable, and the surrounding window area stays transparent
/// (only the pill shape + its soft aura draw). While the cluster is stacked, a card behind
/// the front recedes via `stackScale` / `stackOpacity` (anchored top-leading so the stack
/// cascades down-left); fanning out (or list mode) returns it to full size/opacity.
private struct ResearchToastWindowRootView: View {
    @ObservedObject var pillViewModel: ResearchProgressOverlayViewModel
    @ObservedObject var hoverModel: ResearchToastHoverModel

    var body: some View {
        ResearchFullToastView(
            viewModel: pillViewModel,
            reduceMotionEnabled: hoverModel.reduceMotionEnabled
        )
        .overlay(
            RoundedRectangle(cornerRadius: ResearchFullToastGeometry.cornerRadius, style: .continuous)
                .stroke(DS.Colors.accent, lineWidth: hoverModel.isFocused ? 2 : 0)
        )
        // The shared Clawdy red-aura glow — kept at the safe radius ceiling so its bloom
        // fits inside the panel's clear margin and renders as a clean soft aura (never a
        // clipped hard rectangle). Applied HERE (not inside the toast surface) so the pill's
        // own surface stays a hard-edged `surface1` shape with no halo of its own.
        .clawdyGlow(
            cornerRadius: ResearchFullToastGeometry.cornerRadius,
            radius: ClawdyGlow.maximumSafeRadius
        )
        // Native-stack recede: scale/opacity for a card behind the front (both 1.0 when
        // fanned/list). Anchored top-leading so the left-aligned stack cascades downward.
        .scaleEffect(hoverModel.stackScale, anchor: .topLeading)
        .opacity(hoverModel.stackOpacity)
        .animation(
            hoverModel.animatesStackTransition ? .spring(response: 0.34, dampingFraction: 0.9) : nil,
            value: hoverModel.stackScale
        )
        .animation(
            hoverModel.animatesStackTransition ? .spring(response: 0.34, dampingFraction: 0.9) : nil,
            value: hoverModel.stackOpacity
        )
        .padding(ResearchToastLayout.shadowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Control ("+N more" / "show less") window

/// The "+N more" / "show less" collapse control as its OWN small panel, placed in the
/// slot beneath the last visible toast. Independent of the toast windows.
@MainActor
final class ResearchToastControlPanel {
    let panel: NSPanel
    private let model = ResearchToastControlModel()

    var onToggle: (() -> Void)? {
        get { model.onToggle }
        set { model.onToggle = newValue }
    }
    /// Reports pointer enter/leave over the control to the controller so hovering it counts
    /// as hovering the cluster (keeps the native-stack fan open).
    var onHoverChanged: ((Bool) -> Void)?

    init() {
        let size = ResearchToastLayout.controlWindowContentSize
        panel = ResearchToastPanel.makeOverlayPanel(size: size)
        let trackingView = ResearchToastHoverTrackingView(frame: CGRect(origin: .zero, size: size))
        trackingView.setTrackingRect(CGRect(origin: .zero, size: size))
        let hostingView = NSHostingView(rootView: ResearchToastControlRootView(model: model))
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        trackingView.addSubview(hostingView)
        panel.contentView = trackingView
        trackingView.onHoverChanged = { [weak self] hovering in self?.onHoverChanged?(hovering) }
    }

    /// Hides the control window without tearing it down (used while the cluster is stacked).
    func hide() {
        panel.orderOut(nil)
    }

    func update(controlRow: ResearchOverlayStackLayout.ControlRow) {
        model.controlRow = controlRow
    }

    func place(slotTopLeft: CGPoint, animated: Bool) {
        let size = ResearchToastLayout.controlWindowContentSize
        let origin = ResearchToastLayout.windowOrigin(slotTopLeft: slotTopLeft, contentSize: size)
        let frame = CGRect(origin: origin, size: size)
        if animated {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func show() {
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

@MainActor
private final class ResearchToastControlModel: ObservableObject {
    @Published var controlRow: ResearchOverlayStackLayout.ControlRow = .showLess
    var onToggle: (() -> Void)?
}

private struct ResearchToastControlRootView: View {
    @ObservedObject var model: ResearchToastControlModel

    var body: some View {
        let label: String = {
            switch model.controlRow {
            case .showMore(let hiddenCount): return "+\(hiddenCount) more"
            case .showLess: return "show less"
            }
        }()
        let help = model.controlRow == .showLess ? "Collapse the research list" : "Show all research runs"
        ControlRowButton(
            label: label,
            helpText: help,
            width: ResearchStackFrameLayout.expandedPillSize.width,
            action: { model.onToggle?() }
        )
        .padding(ResearchToastLayout.shadowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Collapse-to-stack control window

/// The "collapse back to the stack" affordance shown ONLY while a stackable cluster is
/// FANNED OUT (hovered), so the user can always return to the compact native stack. Its own
/// small panel, placed beneath the fanned list. It reports its OWN hover to the controller
/// so hovering it keeps the fan open (it's part of the cluster), and clicking it re-stacks.
@MainActor
final class ResearchStackCollapseControlPanel {
    let panel: NSPanel
    private let model = ResearchStackCollapseModel()

    var onCollapse: (() -> Void)? {
        get { model.onCollapse }
        set { model.onCollapse = newValue }
    }
    /// Reports pointer enter/leave over the collapse control to the controller so hovering
    /// it counts as hovering the cluster (keeps the fan open).
    var onHoverChanged: ((Bool) -> Void)?

    init() {
        let size = ResearchToastLayout.controlWindowContentSize
        panel = ResearchToastPanel.makeOverlayPanel(size: size)
        let trackingView = ResearchToastHoverTrackingView(frame: CGRect(origin: .zero, size: size))
        trackingView.onHoverChanged = { [weak self] hovering in self?.onHoverChanged?(hovering) }
        trackingView.setTrackingRect(CGRect(origin: .zero, size: size))
        let hostingView = NSHostingView(rootView: ResearchStackCollapseRootView(model: model))
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        trackingView.addSubview(hostingView)
        panel.contentView = trackingView
    }

    func place(slotTopLeft: CGPoint, animated: Bool) {
        let size = ResearchToastLayout.controlWindowContentSize
        let origin = ResearchToastLayout.windowOrigin(slotTopLeft: slotTopLeft, contentSize: size)
        let frame = CGRect(origin: origin, size: size)
        if animated {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func show() {
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }

    // MARK: - Test hooks

    /// Fires the control's hover closure exactly as its live tracking view would on a real
    /// pointer enter/leave, so a test can drive the collapse-control-hover path (and prove
    /// clicking it doesn't wedge the cluster hovered forever) through the real wiring.
    func simulateHoverForTesting(_ hovering: Bool) { onHoverChanged?(hovering) }
}

@MainActor
private final class ResearchStackCollapseModel: ObservableObject {
    var onCollapse: (() -> Void)?
}

private struct ResearchStackCollapseRootView: View {
    @ObservedObject var model: ResearchStackCollapseModel

    var body: some View {
        ControlRowButton(
            label: "Collapse",
            systemImage: "rectangle.stack",
            helpText: "Collapse the research toasts back into a stack",
            width: ResearchStackFrameLayout.expandedPillSize.width,
            action: { model.onCollapse?() }
        )
        .padding(ResearchToastLayout.shadowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Controller

@MainActor
final class ResearchStackedOverlayController {
    /// One window per visible session, keyed by id. Created once per id and reused across
    /// renders (never recreated per render — that would flicker) and torn down when the
    /// session leaves the visible set.
    private var toastPanelsByID: [ResearchSessionID: ResearchToastPanel] = [:]
    /// The visible order (top → bottom) from the last render, so we can position slots.
    private var orderedVisibleIDs: [ResearchSessionID] = []

    /// The NATIVE-STACK fan state, owned entirely in this overlay layer (never in the
    /// session manager / state machine): when 3+ toasts are active they collapse into a
    /// compact stack at rest, and hovering the stack fans them out into the full vertical
    /// list. `true` = fanned out. Reset to `false` whenever the cluster drops below the
    /// stacking threshold (a plain list has no fan state).
    private var isFannedOut = false
    /// The ids of toasts the pointer is currently inside, aggregated across the cluster so
    /// the stack stays fanned while the pointer is over ANY toast (or the controls below).
    private var hoveredToastIDs: Set<ResearchSessionID> = []
    /// Which control windows beneath the toasts the pointer is currently inside, tracked by
    /// IDENTITY rather than a single shared Bool. A single Bool wedged the cluster forever:
    /// when the collapse control re-stacks the cluster it is HIDDEN in the same layout pass,
    /// and hiding a window fires no `mouseExited`, so its "hovered" flag was never cleared —
    /// `isClusterHovered` stayed pinned true and every later collapse/leave was blocked. By
    /// identity we drop exactly the hidden/closed control's contribution when it goes away.
    private var hoveredControlIdentities: Set<HoverableControlIdentity> = []

    /// The control windows beneath the toast cluster whose hover counts as cluster-hover.
    private enum HoverableControlIdentity: Hashable {
        /// The manager's "+N more" / "show less" expand/collapse row.
        case expandCollapseRow
        /// The "collapse back to the stack" control (shown only while fanned out).
        case collapseToStack
    }
    /// A small debounce so briefly leaving all windows (e.g. crossing the transparent gap
    /// between two fanned toasts) doesn't flicker the stack collapsed and back.
    private var pendingCollapseWorkItem: DispatchWorkItem?
    /// How long the pointer must be off the whole cluster before it re-stacks.
    private let fanCollapseDelaySeconds: TimeInterval = 0.28

    private var controlPanel: ResearchToastControlPanel?
    /// The "collapse back to the stack" control, shown only while fanned out.
    private var collapseControlPanel: ResearchStackCollapseControlPanel?
    /// The per-session chat detail panel. It is a KEYABLE panel (unlike the click-through
    /// toast windows) so its text input can accept typing, and stays `sharingType = .none`.
    private var detailPanel: KeyableResearchPanel?
    /// The view model currently driving the detail panel (the focused session's), so we
    /// only rebuild the hosting view when the focused session actually changes.
    private var detailViewModel: ResearchProgressOverlayViewModel?
    /// Click-away monitors installed while the detail chat panel is on screen: a click
    /// anywhere outside the panel HIDES it (clears focus), like a chat window losing focus.
    private var detailGlobalClickMonitor: Any?
    private var detailLocalClickMonitor: Any?

    /// The last rendered control row, remembered for test hooks.
    private var currentControlRow: ResearchOverlayStackLayout.ControlRow?
    private var currentPillCount = 0

    /// The detail chat panel's CONTENT size (matches `ResearchDetailOverlayView`).
    private let detailContentSize = ResearchDetailOverlayView.contentSize
    /// Transparent margin the detail panel carries around its content so the shared Clawdy
    /// red-aura glow blooms into it instead of being clipped into a hard rectangle.
    private let detailPanelMargin = ClawdyGlow.overlayPanelMargin
    /// The detail panel's full window content size — the chat content plus the aura margin.
    private var detailPanelSize: CGSize {
        CGSize(width: detailContentSize.width + detailPanelMargin * 2,
               height: detailContentSize.height + detailPanelMargin * 2)
    }
    /// Inset from the anchor screen corner's visible frame.
    private let screenEdgeInset: CGFloat = 16
    /// WHERE the column pins on screen. TOP-LEFT deliberately, to render away from native
    /// macOS Notification Center banners (top-right by default, un-queryable via public
    /// API).
    private let anchorCorner: ResearchOverlayAnchor.Corner = .topLeft

    /// Test seam. An additive offset applied to the anchor screen's visible frame when this
    /// overlay positions its panels, so a test can anchor the REAL toast/control/detail
    /// windows far off-screen — they never flash in the top-left during `xcodebuild test` —
    /// while every window SIZE, tracking rect, scale/opacity, presentation, and teardown
    /// stays byte-for-byte identical (only the shared origin shifts). Production default is
    /// `.zero`, so on-screen positioning is completely unchanged — this is a positioning
    /// offset that defaults to production, never a behavior flag that could ship enabled.
    var testAnchorOriginOffset: CGVector = .zero

    /// The SINGLE shared user drag offset applied to the whole cluster (toasts + controls),
    /// added to the anchor's visible frame exactly like `testAnchorOriginOffset` so every
    /// window honors it and it survives every `refreshOverlay`. The manager owns the
    /// canonical value (persisted to UserDefaults) and pushes it here; a live drag reports a
    /// new value back via `onUserColumnDragged`.
    private(set) var userColumnDragOffset: CGVector = .zero

    /// Reports a NEW clamped drag offset (after the user dragged a toast window) up to the
    /// manager, which persists it and syncs it back to both this overlay and the badge.
    var onUserColumnDragged: ((CGVector) -> Void)?

    /// Non-zero while WE are moving windows programmatically (a render, a fan-out/collapse
    /// animation, or applying a synced drag offset). The `NSWindow.didMoveNotification`
    /// handler ignores moves while this is > 0 so our own `setFrame`s — including the
    /// intermediate frames of an animated move — are never mistaken for a user drag. A
    /// counter (not a Bool) so overlapping non-animated + animated layouts can't clear it early.
    private var programmaticFrameChangeDepth = 0

    /// A move smaller than this (points) is treated as noise / a settle, not a real drag.
    private let dragMovementEpsilon: CGFloat = 0.5

    init() {
        // Observe window moves so a user drag of any toast (via `isMovableByWindowBackground`)
        // is captured into the shared column offset. `object: nil` catches every window; the
        // handler filters to just this overlay's toast windows.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToastWindowMoved(_:)),
            name: NSWindow.didMoveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The manager's handler for tapping the "+N more" / "show less" control.
    var onToggleExpandRequested: (() -> Void)?

    /// The current system Reduce Motion setting (read fresh so a mid-session change is
    /// honored on the next render/hover).
    private var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The cluster's current presentation (list / stacked / fanned) from the pure
    /// `ResearchStackFanLayout`, using the live toast count + fan state.
    private var presentation: ResearchStackFanLayout.Presentation {
        ResearchStackFanLayout.presentation(toastCount: currentPillCount, isFannedOut: isFannedOut)
    }

    // MARK: - Rendering

    /// Renders the current set of toasts. `pills` are already ordered and marked with
    /// focus; `controlRow` (non-nil) shows the "+N more" / "show less" control beneath
    /// them; `detailViewModel` (the focused session's) drives the detail panel, or nil
    /// hides it. An empty `pills` tears the whole overlay down.
    func render(
        pills: [ResearchStackPillModel],
        controlRow: ResearchOverlayStackLayout.ControlRow?,
        detailViewModel: ResearchProgressOverlayViewModel?
    ) {
        currentPillCount = pills.count
        currentControlRow = controlRow

        // A cluster that fell below the stacking threshold has no fan state — it's a plain
        // list. Reset so a later re-cross of the threshold starts stacked, not fanned.
        if !ResearchStackFanLayout.isStackable(toastCount: currentPillCount) {
            isFannedOut = false
            cancelPendingCollapse()
        }

        reconcileToastPanels(pills: pills)
        ensureControlPanel(controlRow: controlRow)
        // A data-driven re-render places everything without animation (only a live hover
        // change animates the fan-out / collapse).
        layoutAllPanels(animated: false)
        renderDetail(detailViewModel)
    }

    /// Hides/tears down every window (app teardown). Closes each toast, both control
    /// panels, and the detail panel so no window leaks; cancels any pending collapse.
    func hide() {
        cancelPendingCollapse()
        for panel in toastPanelsByID.values {
            panel.close()
        }
        toastPanelsByID.removeAll()
        orderedVisibleIDs.removeAll()
        hoveredToastIDs.removeAll()
        hoveredControlIdentities.removeAll()
        isFannedOut = false
        controlPanel?.close()
        controlPanel = nil
        collapseControlPanel?.close()
        collapseControlPanel = nil
        hideDetailPanel()
    }

    // MARK: - Toast panels

    /// Creates a toast window for each newly-visible session, updates the ones that
    /// stayed, and closes the ones that left the visible set (dismiss / removal / collapse
    /// beyond "+N more"). Never recreates an existing panel.
    private func reconcileToastPanels(pills: [ResearchStackPillModel]) {
        let visibleIDs = Set(pills.map(\.id))

        // Close + drop toasts no longer visible (and forget any stale hover state).
        for (id, panel) in toastPanelsByID where !visibleIDs.contains(id) {
            panel.close()
            toastPanelsByID[id] = nil
            hoveredToastIDs.remove(id)
        }

        // Create/update the visible toasts.
        for pill in pills {
            if let existing = toastPanelsByID[pill.id] {
                existing.update(isFocused: pill.isFocused, reduceMotionEnabled: reduceMotionEnabled)
            } else {
                let panel = ResearchToastPanel(
                    sessionID: pill.id,
                    pillViewModel: pill.viewModel,
                    reduceMotionEnabled: reduceMotionEnabled
                )
                panel.update(isFocused: pill.isFocused, reduceMotionEnabled: reduceMotionEnabled)
                panel.onHoverChanged = { [weak self] hovering in
                    self?.handleToastHoverChanged(id: pill.id, hovering: hovering)
                }
                toastPanelsByID[pill.id] = panel
            }
        }

        orderedVisibleIDs = pills.map(\.id)
    }

    /// Positions every visible toast and its controls for the CURRENT presentation:
    ///   - `.list` / `.fanned` → the full vertical list, each toast at full size/opacity,
    ///     spaced by the full-toast stride so no pill overlaps a sibling.
    ///   - `.stacked` → the compact native stack: the front toast on top, each toast behind
    ///     it offset DOWN by the peek, scaled + dimmed, ordered front-to-back.
    /// The manager's "+N more" / "show less" control and the collapse-to-stack control are
    /// laid out beneath the toasts (visible only when fanned/list; hidden while stacked).
    /// The anchor screen's visible frame shifted by BOTH the test-only positioning offset
    /// (production default `.zero`) AND the user's shared drag offset, so every panel this
    /// overlay lays out honors a drag and it survives every `refreshOverlay`. Nil when no
    /// screen is available.
    private func effectiveVisibleFrame() -> CGRect? {
        guard let rawVisibleFrame = NSScreen.main?.visibleFrame else { return nil }
        return rawVisibleFrame.offsetBy(
            dx: testAnchorOriginOffset.dx + userColumnDragOffset.dx,
            dy: testAnchorOriginOffset.dy + userColumnDragOffset.dy
        )
    }

    /// The slot top-left (screen coords) for the toast at `index` under `presentation`,
    /// using the full-toast stride for the list/fanned forms and the compact peek stride for
    /// the stacked form. Shared by `layoutAllPanels`, the drag-capture handler, and the test
    /// hook so they can never disagree on where a toast "should" be.
    private func plannedSlotTopLeft(
        forIndex index: Int,
        visibleFrame: CGRect,
        presentation: ResearchStackFanLayout.Presentation
    ) -> CGPoint {
        let stride: CGFloat = presentation == .stacked
            ? ResearchStackFanLayout.stackedCardPeek
            : ResearchToastLayout.fullToastSlotStride
        return ResearchToastLayout.slotTopLeftOrigin(
            index: index,
            corner: anchorCorner,
            visibleFrame: visibleFrame,
            edgeInset: screenEdgeInset,
            stride: stride
        )
    }

    /// The window (bottom-left) origin a toast at `index` is placed at — the same value
    /// `place(slotTopLeft:)` computes — so the drag handler can measure how far the user
    /// dragged a window PAST where layout put it.
    private func plannedWindowOrigin(
        forIndex index: Int,
        visibleFrame: CGRect,
        presentation: ResearchStackFanLayout.Presentation
    ) -> CGPoint {
        let slotTopLeft = plannedSlotTopLeft(forIndex: index, visibleFrame: visibleFrame, presentation: presentation)
        return ResearchToastLayout.windowOrigin(
            slotTopLeft: slotTopLeft,
            contentSize: ResearchToastLayout.expandedWindowContentSize
        )
    }

    private func layoutAllPanels(animated: Bool) {
        guard let visibleFrame = effectiveVisibleFrame() else { return }
        let presentation = self.presentation
        let animatesTransition = animated && !reduceMotionEnabled

        // Guard the whole layout pass: every `setFrame` we issue here (including an animated
        // move's intermediate frames) must not be read back as a user drag. Keyed on the raw
        // `animated` flag (not `animatesTransition`) because the WINDOW frame still animates
        // under Reduce Motion — only the SwiftUI scale/opacity transition is suppressed — so
        // the group must wrap every animated `place` for the guard to cover its late frames.
        performProgrammaticFrameChanges(animated: animated) {
            for (index, id) in self.orderedVisibleIDs.enumerated() {
                guard let panel = self.toastPanelsByID[id] else { continue }
                let slotTopLeft = self.plannedSlotTopLeft(forIndex: index, visibleFrame: visibleFrame, presentation: presentation)
                switch presentation {
                case .list, .fanned:
                    panel.applyStackPresentation(scale: 1.0, opacity: 1.0, animatesTransition: animatesTransition)
                case .stacked:
                    let transform = ResearchStackFanLayout.stackedCardTransform(depthFromFront: index)
                    panel.applyStackPresentation(
                        scale: transform.scale,
                        opacity: transform.opacity,
                        animatesTransition: animatesTransition
                    )
                }
                panel.place(slotTopLeft: slotTopLeft, animated: animated)
                panel.show()
            }

            // In the stacked form, the FRONT card (index 0) must sit above the ones peeking
            // behind it — order back-to-front so index 0 ends up frontmost.
            if presentation == .stacked {
                for id in self.orderedVisibleIDs.reversed() {
                    self.toastPanelsByID[id]?.orderFront()
                }
            }

            self.layoutControls(visibleFrame: visibleFrame, presentation: presentation, animated: animated)
        }
    }

    /// Runs `body` (which issues `setFrame`s) with the programmatic-move guard raised, so the
    /// `didMoveNotification` handler ignores every frame WE set. For an animated pass the
    /// guard stays raised until the animation group's completion (covering the animation's
    /// intermediate frames); for an instant pass it drops as soon as `body` returns.
    private func performProgrammaticFrameChanges(animated: Bool, _ body: () -> Void) {
        programmaticFrameChangeDepth += 1
        if animated {
            NSAnimationContext.runAnimationGroup({ _ in
                body()
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.programmaticFrameChangeDepth = max(0, self.programmaticFrameChangeDepth - 1)
            })
        } else {
            body()
            programmaticFrameChangeDepth = max(0, programmaticFrameChangeDepth - 1)
        }
    }

    // MARK: - User drag capture

    /// A toast window moved. When it's one of OUR toast windows and the move wasn't ours
    /// (`programmaticFrameChangeDepth == 0`), measure how far the user dragged it past its
    /// laid-out origin, accumulate that into the shared column offset (clamped so the pill
    /// stays on screen), and report the new offset up to the manager.
    @objc private func handleToastWindowMoved(_ notification: Notification) {
        // BY DESIGN: a drag STARTED during a fan-out/collapse animation (while our own frames
        // are in flight) is dropped here rather than recorded, so an animation's intermediate
        // frames can never be mistaken for a user drag. The cost is only that a drag begun in
        // that brief (~0.25s) window may snap back; the user simply drags again. Accepting a
        // move mid-animation would require distinguishing it from our own animated frames,
        // which is exactly the ambiguity this guard exists to avoid — not worth destabilizing.
        guard programmaticFrameChangeDepth == 0 else { return }
        guard let movedWindow = notification.object as? NSWindow else { return }
        guard let movedEntry = toastPanelsByID.first(where: { $0.value.panel === movedWindow }) else { return }
        guard let index = orderedVisibleIDs.firstIndex(of: movedEntry.key) else { return }
        guard let effectiveFrame = effectiveVisibleFrame() else { return }

        let presentation = self.presentation
        let expectedOrigin = plannedWindowOrigin(forIndex: index, visibleFrame: effectiveFrame, presentation: presentation)
        let actualOrigin = movedWindow.frame.origin
        let dragDelta = CGVector(dx: actualOrigin.x - expectedOrigin.x, dy: actualOrigin.y - expectedOrigin.y)
        guard abs(dragDelta.dx) > dragMovementEpsilon || abs(dragDelta.dy) > dragMovementEpsilon else { return }

        guard let basePillScreenRect = baseAnchorPillScreenRect(presentation: presentation),
              let rawVisibleFrame = NSScreen.main?.visibleFrame else { return }
        // Clamp against the anchor screen's visible frame shifted ONLY by the test offset
        // (never the drag offset), so the clamp bound is the real screen in production.
        let clampVisibleFrame = rawVisibleFrame.offsetBy(dx: testAnchorOriginOffset.dx, dy: testAnchorOriginOffset.dy)
        let newOffset = ResearchOverlayDragOffset.clamp(
            ResearchOverlayDragOffset.accumulate(current: userColumnDragOffset, delta: dragDelta),
            basePillScreenRect: basePillScreenRect,
            visibleFrame: clampVisibleFrame
        )
        onUserColumnDragged?(newOffset)
    }

    /// The screen rect the TOP anchor toast's visible pill occupies at drag offset ZERO (only
    /// the test offset applied) — the reference the clamp keeps on screen. Nil when no screen.
    private func baseAnchorPillScreenRect(presentation: ResearchStackFanLayout.Presentation) -> CGRect? {
        guard let rawVisibleFrame = NSScreen.main?.visibleFrame else { return nil }
        let baseFrame = rawVisibleFrame.offsetBy(dx: testAnchorOriginOffset.dx, dy: testAnchorOriginOffset.dy)
        let windowOrigin = plannedWindowOrigin(forIndex: 0, visibleFrame: baseFrame, presentation: presentation)
        let pillRectInWindow = ResearchToastLayout.pillRect(
            inWindowOfSize: ResearchToastLayout.expandedWindowContentSize,
            pillSize: ResearchStackFrameLayout.expandedPillSize
        )
        return CGRect(
            x: windowOrigin.x + pillRectInWindow.minX,
            y: windowOrigin.y + pillRectInWindow.minY,
            width: pillRectInWindow.width,
            height: pillRectInWindow.height
        )
    }

    /// Adopts a new shared drag offset (from the manager syncing a drag, or restoring the
    /// persisted value) and re-lays out instantly so the whole cluster shifts to it.
    func applyUserColumnDragOffset(_ offset: CGVector) {
        userColumnDragOffset = offset
        layoutAllPanels(animated: false)
    }

    /// Clamps a CANDIDATE shared offset against the CURRENT display so the top anchor toast
    /// pill stays fully on screen, reusing the SAME pure `ResearchOverlayDragOffset.clamp`
    /// (and the SAME base pill rect + clamp frame) a live drag uses. Used at RESTORE time to
    /// heal a persisted offset saved on a larger / now-removed display (or a corrupted value)
    /// so a relaunch can never place the cluster off-screen. Presentation-independent because
    /// the index-0 slot origin is the same for every stride, so it's valid before any render.
    /// Returns the offset unchanged when no screen is available (nothing to clamp against).
    func clampOffsetToCurrentScreen(_ offset: CGVector) -> CGVector {
        guard let rawVisibleFrame = NSScreen.main?.visibleFrame,
              let basePillScreenRect = baseAnchorPillScreenRect(presentation: .list) else { return offset }
        let clampVisibleFrame = rawVisibleFrame.offsetBy(dx: testAnchorOriginOffset.dx, dy: testAnchorOriginOffset.dy)
        return ResearchOverlayDragOffset.clamp(
            offset,
            basePillScreenRect: basePillScreenRect,
            visibleFrame: clampVisibleFrame
        )
    }

    // MARK: - Native-stack fan-out hover

    /// A live hover change on one toast, aggregated across the cluster: while the pointer is
    /// over ANY toast (or the controls) a stackable cluster FANS OUT; when it leaves the
    /// whole cluster it collapses back to the stack (after a short debounce). Owned entirely
    /// here in the overlay layer.
    private func handleToastHoverChanged(id: ResearchSessionID, hovering: Bool) {
        if hovering {
            hoveredToastIDs.insert(id)
        } else {
            hoveredToastIDs.remove(id)
        }
        reconcileFanState()
    }

    /// A hover change over one of the control windows beneath the toasts — they're part of
    /// the cluster, so hovering them keeps the fan open. Tracked per-control by identity so a
    /// control that's hidden without a matching `mouseExited` can have its contribution
    /// cleared explicitly (see `hoveredControlIdentities`).
    private func handleControlHoverChanged(_ control: HoverableControlIdentity, hovering: Bool) {
        if hovering {
            hoveredControlIdentities.insert(control)
        } else {
            hoveredControlIdentities.remove(control)
        }
        reconcileFanState()
    }

    /// Whether the pointer is currently anywhere over the cluster (a toast or a control).
    private var isClusterHovered: Bool {
        !hoveredToastIDs.isEmpty || !hoveredControlIdentities.isEmpty
    }

    /// Fans the stack out immediately when the cluster becomes hovered, and schedules a
    /// debounced collapse when it's no longer hovered. A non-stackable cluster never fans.
    private func reconcileFanState() {
        let stackable = ResearchStackFanLayout.isStackable(toastCount: currentPillCount)
        if isClusterHovered && stackable {
            cancelPendingCollapse()
            if ResearchStackFanLayout.nextFannedState(
                toastCount: currentPillCount, isHovered: true, currentlyFanned: isFannedOut
            ) && !isFannedOut {
                isFannedOut = true
                layoutAllPanels(animated: true)
            }
        } else {
            scheduleCollapse()
        }
    }

    /// Collapses the stack after `fanCollapseDelaySeconds` off the whole cluster, unless the
    /// pointer returns first (the work item re-checks before acting).
    private func scheduleCollapse() {
        cancelPendingCollapse()
        guard isFannedOut else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCollapseWorkItem = nil
            guard !self.isClusterHovered, self.isFannedOut else { return }
            self.isFannedOut = false
            self.layoutAllPanels(animated: true)
        }
        pendingCollapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fanCollapseDelaySeconds, execute: work)
    }

    private func cancelPendingCollapse() {
        pendingCollapseWorkItem?.cancel()
        pendingCollapseWorkItem = nil
    }

    /// Collapses the fanned stack back to the compact stack immediately (the collapse
    /// control's click). No-op if not currently fanned.
    private func collapseToStack() {
        cancelPendingCollapse()
        guard isFannedOut else { return }
        // The collapse control is about to be HIDDEN by the re-layout below (it only shows
        // while fanned), and hiding a window fires no `mouseExited` — so drop its hover
        // contribution here explicitly, or the cluster would read as permanently hovered and
        // never collapse/leave again.
        hoveredControlIdentities.remove(.collapseToStack)
        isFannedOut = false
        layoutAllPanels(animated: true)
    }

    // MARK: - Control panels

    /// Creates/updates or tears down the "+N more" / "show less" control panel object.
    /// Positioning + visibility happen in `layoutControls`.
    private func ensureControlPanel(controlRow: ResearchOverlayStackLayout.ControlRow?) {
        guard let controlRow else {
            controlPanel?.close()
            controlPanel = nil
            // The window is gone with no `mouseExited`, so forget any stale hover it held.
            hoveredControlIdentities.remove(.expandCollapseRow)
            return
        }
        let panel = controlPanel ?? {
            let created = ResearchToastControlPanel()
            created.onToggle = { [weak self] in self?.onToggleExpandRequested?() }
            created.onHoverChanged = { [weak self] hovering in self?.handleControlHoverChanged(.expandCollapseRow, hovering: hovering) }
            controlPanel = created
            return created
        }()
        panel.update(controlRow: controlRow)
    }

    /// Lazily creates the collapse-to-stack control panel object (kept for the overlay's
    /// lifetime once made; shown/hidden by presentation in `layoutControls`).
    private func ensureCollapseControlPanel() {
        guard collapseControlPanel == nil else { return }
        let created = ResearchStackCollapseControlPanel()
        created.onCollapse = { [weak self] in self?.collapseToStack() }
        created.onHoverChanged = { [weak self] hovering in self?.handleControlHoverChanged(.collapseToStack, hovering: hovering) }
        collapseControlPanel = created
    }

    /// Positions + shows/hides the two control windows beneath the toasts, stacked one below
    /// the other under the toast cluster's VISUAL bottom (which differs between the compact
    /// stack and the fanned list). The manager's "+N more" / "show less" control shows
    /// whenever the manager supplied a control row (in any presentation); the
    /// collapse-to-stack control shows ONLY while the cluster is fanned out.
    private func layoutControls(
        visibleFrame: CGRect,
        presentation: ResearchStackFanLayout.Presentation,
        animated: Bool
    ) {
        let firstControlTopY = controlsStartTopY(visibleFrame: visibleFrame, presentation: presentation)
        let controlX = controlSlotOriginX(visibleFrame: visibleFrame)
        var controlOrder = 0

        // The "+N more" / "show less" control (only when the manager supplied one).
        if let controlPanel {
            if currentControlRow != nil {
                let slotTopLeft = CGPoint(
                    x: controlX,
                    y: firstControlTopY - CGFloat(controlOrder) * ResearchToastLayout.fullToastSlotStride
                )
                controlPanel.place(slotTopLeft: slotTopLeft, animated: animated)
                controlPanel.show()
                controlOrder += 1
            } else {
                controlPanel.hide()
                // Hidden without a `mouseExited` — drop its cluster-hover contribution.
                hoveredControlIdentities.remove(.expandCollapseRow)
            }
        }

        // The collapse-to-stack control, shown only while fanned out (created lazily the
        // first time it's needed so the common < 3 case never makes a hidden window).
        if ResearchStackFanLayout.showsCollapseControl(toastCount: currentPillCount, isFannedOut: isFannedOut) {
            ensureCollapseControlPanel()
            let slotTopLeft = CGPoint(
                x: controlX,
                y: firstControlTopY - CGFloat(controlOrder) * ResearchToastLayout.fullToastSlotStride
            )
            collapseControlPanel?.place(slotTopLeft: slotTopLeft, animated: animated)
            collapseControlPanel?.show()
        } else {
            collapseControlPanel?.hide()
            // Hidden without a `mouseExited` — drop its cluster-hover contribution so a
            // collapse that hid it can't leave the cluster wedged hovered.
            hoveredControlIdentities.remove(.collapseToStack)
        }
    }

    /// The top-left Y of the FIRST control slot — just below the toast cluster's visual
    /// bottom, which is the compact stack's extent when stacked and the full fanned list's
    /// extent when listed/fanned.
    private func controlsStartTopY(visibleFrame: CGRect, presentation: ResearchStackFanLayout.Presentation) -> CGFloat {
        let firstToastTop = visibleFrame.maxY - screenEdgeInset
        let count = CGFloat(max(currentPillCount, 0))
        switch presentation {
        case .list, .fanned:
            // Below the last full-stride toast slot (leaving one `pillSpacing` gap).
            return firstToastTop - count * ResearchToastLayout.fullToastSlotStride
        case .stacked:
            // Below the compact stack's lowest card (peek offsets + one toast height + gap).
            let stackDrop = max(count - 1, 0) * ResearchStackFanLayout.stackedCardPeek
                + ResearchStackFrameLayout.expandedPillSize.height
                + ResearchStackFrameLayout.pillSpacing
            return firstToastTop - stackDrop
        }
    }

    /// The X origin for a control slot (anchored like the toast column).
    private func controlSlotOriginX(visibleFrame: CGRect) -> CGFloat {
        switch anchorCorner {
        case .topLeft:
            return visibleFrame.minX + screenEdgeInset
        case .topRight:
            return visibleFrame.maxX - ResearchToastLayout.controlWindowContentSize.width - screenEdgeInset
        }
    }

    // MARK: - Detail panel

    private func renderDetail(_ viewModel: ResearchProgressOverlayViewModel?) {
        guard let viewModel else {
            hideDetailPanel()
            return
        }
        // Rebuild the hosting view only when the focused session changes.
        if detailViewModel !== viewModel {
            detailViewModel = viewModel
            createDetailPanel(for: viewModel)
        }
        showDetailPanel()
    }

    /// Hides the detail chat panel and removes its click-away monitors (so no monitor leaks
    /// once the panel is gone).
    private func hideDetailPanel() {
        detailPanel?.orderOut(nil)
        detailViewModel = nil
        removeDetailClickAwayMonitors()
    }

    private func createDetailPanel(for viewModel: ResearchProgressOverlayViewModel) {
        let panel = detailPanel ?? makeKeyableDetailPanel(size: detailPanelSize)
        // The content is inset by the aura margin so the Clawdy glow blooms into the
        // transparent surround instead of being clipped by the window bounds.
        let rootView = ResearchDetailOverlayView(viewModel: viewModel)
            .padding(detailPanelMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        detailPanel = panel
    }

    /// Builds the keyable, screenshot-excluded chat panel. It MUST become key (unlike the
    /// click-through toast windows) so its text input accepts typing — hence
    /// `KeyableResearchPanel` rather than `ResearchToastPanel.makeOverlayPanel`.
    private func makeKeyableDetailPanel(size: CGSize) -> KeyableResearchPanel {
        // Same floating/screenshot-excluded/`.stationary` setup as the toast windows —
        // only the concrete subclass differs (it must become key so its text input
        // accepts typing), so it flows through the shared factory with `KeyableResearchPanel`.
        return ResearchToastPanel.makeOverlayPanel(
            size: size,
            panelType: KeyableResearchPanel.self
        )
    }

    private func showDetailPanel() {
        guard let detailPanel else { return }
        let anchorScreen = NSScreen.main
        // Shift by the test-only offset (production default `.zero`) so the detail panel
        // anchors off-screen under tests alongside its toast column.
        let visibleFrame = (anchorScreen?.visibleFrame ?? detailPanel.frame)
            .offsetBy(dx: testAnchorOriginOffset.dx, dy: testAnchorOriginOffset.dy)
        // Anchor the detail panel to the RIGHT of the toast column (top-left anchor) or
        // to the LEFT (top-right anchor), kept fully on the same screen. Use the EXPANDED
        // toast width so a hover-expanded toast never slides under the detail panel. The
        // math positions the CONTENT rect; the panel is larger by `detailPanelMargin` on
        // every side (for the aura), so the final origin subtracts that margin.
        let toastWidth = ResearchToastLayout.expandedWindowContentSize.width
        var contentOriginX: CGFloat
        switch anchorCorner {
        case .topLeft:
            contentOriginX = visibleFrame.minX + screenEdgeInset + toastWidth + ResearchStackFrameLayout.pillSpacing
        case .topRight:
            contentOriginX = visibleFrame.maxX - screenEdgeInset - toastWidth - ResearchStackFrameLayout.pillSpacing - detailContentSize.width
        }
        contentOriginX = min(max(visibleFrame.minX + screenEdgeInset, contentOriginX),
                             visibleFrame.maxX - detailContentSize.width - screenEdgeInset)
        var contentOriginY = visibleFrame.maxY - screenEdgeInset - detailContentSize.height
        contentOriginY = max(visibleFrame.minY + screenEdgeInset,
                             min(contentOriginY, visibleFrame.maxY - detailContentSize.height - screenEdgeInset))
        let wasVisible = detailPanel.isVisible
        let panelOrigin = CGPoint(x: contentOriginX - detailPanelMargin, y: contentOriginY - detailPanelMargin)
        detailPanel.setFrame(CGRect(origin: panelOrigin, size: detailPanelSize), display: true)
        detailPanel.alphaValue = 1
        detailPanel.orderFrontRegardless()
        // Make the panel key ONLY on first show (so the text field can accept typing) — a
        // re-show on a live progress re-render must not re-steal focus or interrupt typing.
        if !wasVisible {
            detailPanel.makeKey()
        }
        installDetailClickAwayMonitors()
    }

    // MARK: - Detail click-away

    /// Installs the click-away monitors that HIDE the chat panel when the user clicks
    /// outside it (a chat window losing focus). A GLOBAL monitor catches clicks in other
    /// apps / the desktop; a LOCAL monitor catches clicks in our OWN other windows (e.g. a
    /// toast) — in both cases a click that isn't inside the detail panel clears focus.
    private func installDetailClickAwayMonitors() {
        removeDetailClickAwayMonitors()
        detailGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.handlePossibleClickAway(clickLocation: NSEvent.mouseLocation)
        }
        detailLocalClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // A click in our OWN windows: dismiss only if it's not inside the detail panel.
            if event.window !== self?.detailPanel {
                self?.handlePossibleClickAway(clickLocation: NSEvent.mouseLocation)
            }
            return event
        }
    }

    /// Hides the detail panel (via the focused session's close handler → the manager clears
    /// focus) when a click lands outside its frame.
    private func handlePossibleClickAway(clickLocation: CGPoint) {
        guard let detailPanel, detailPanel.isVisible else { return }
        if detailPanel.frame.contains(clickLocation) { return }
        // Route through the view model's close handler so the manager clears focus (which
        // re-renders and hides the panel) — keeping the single source of truth.
        detailViewModel?.onCloseDetail?()
    }

    private func removeDetailClickAwayMonitors() {
        if let detailGlobalClickMonitor {
            NSEvent.removeMonitor(detailGlobalClickMonitor)
            self.detailGlobalClickMonitor = nil
        }
        if let detailLocalClickMonitor {
            NSEvent.removeMonitor(detailLocalClickMonitor)
            self.detailLocalClickMonitor = nil
        }
    }

    // MARK: - Test hooks

    var detailPanelForTesting: NSPanel? { detailPanel }
    var detailPanelVisibleForTesting: Bool { detailPanel?.isVisible == true }
    var renderedPillCountForTesting: Int { currentPillCount }
    var renderedControlRowForTesting: ResearchOverlayStackLayout.ControlRow? { currentControlRow }
    var renderedHiddenCountForTesting: Int {
        if case .showMore(let hiddenCount) = currentControlRow { return hiddenCount }
        return 0
    }

    /// The per-toast windows, so tests can assert each toast's own frame / visibility /
    /// window contract independently.
    func toastPanelForTesting(id: ResearchSessionID) -> NSPanel? { toastPanelsByID[id]?.panel }
    func toastPanelObjectForTesting(id: ResearchSessionID) -> ResearchToastPanel? { toastPanelsByID[id] }
    var toastPanelCountForTesting: Int { toastPanelsByID.count }
    var anyToastPanelForTesting: NSPanel? { toastPanelsByID.values.first?.panel }
    var controlPanelForTesting: NSPanel? { controlPanel?.panel }
    var collapseControlPanelForTesting: NSPanel? { collapseControlPanel?.panel }

    /// The cluster's current presentation (list / stacked / fanned), so a test can prove
    /// the >= 3 stacking threshold and the stacked ⇄ fanned transitions through the REAL
    /// controller path.
    var presentationForTesting: ResearchStackFanLayout.Presentation { presentation }
    /// Whether the native stack is currently fanned out.
    var isFannedOutForTesting: Bool { isFannedOut }

    /// Drives the REAL hover path for one toast (pointer enter/leave) → the controller's
    /// fan-out aggregation, so a test can prove hovering a stacked cluster fans it out and
    /// leaving it re-stacks.
    func setToastHoverForTesting(id: ResearchSessionID, hovering: Bool) {
        toastPanelsByID[id]?.setHoverForTesting(hovering)
    }
    /// Runs the pending debounced collapse synchronously (production waits
    /// `fanCollapseDelaySeconds`), so a test can deterministically observe the re-stack
    /// after the pointer leaves the cluster.
    func flushPendingFanCollapseForTesting() {
        guard let work = pendingCollapseWorkItem else { return }
        work.cancel()
        pendingCollapseWorkItem = nil
        guard !isClusterHovered, isFannedOut else { return }
        isFannedOut = false
        layoutAllPanels(animated: false)
    }
    /// Drives the REAL collapse-to-stack control action, so a test can prove the collapse
    /// affordance re-stacks a fanned cluster.
    func collapseToStackForTesting() { collapseToStack() }
    /// Drives the REAL collapse-to-stack CONTROL hover (pointer enter/leave over that control
    /// window) through the same closure the live tracking view fires, so a test can prove
    /// hovering the collapse control keeps the cluster hovered — and, critically, that its
    /// hover contribution is cleared when the control is hidden by a collapse click (the
    /// wedged-hover regression guard). Only meaningful once the control exists (fanned out).
    func setCollapseControlHoverForTesting(_ hovering: Bool) {
        collapseControlPanel?.simulateHoverForTesting(hovering)
    }
    /// This toast's current stacked scale/opacity, so a test can prove a card behind the
    /// front recedes while stacked and returns to full while fanned/list.
    func toastStackScaleForTesting(id: ResearchSessionID) -> CGFloat? { toastPanelsByID[id]?.stackScaleForTesting }
    func toastStackOpacityForTesting(id: ResearchSessionID) -> Double? { toastPanelsByID[id]?.stackOpacityForTesting }

    /// The toast's current hover tracking rect (the full pill rect), so a test can prove
    /// the hit region hugs the pill.
    func toastTrackingRectForTesting(id: ResearchSessionID) -> CGRect? {
        toastPanelsByID[id]?.trackingRectForTesting
    }
    /// The ACTUALLY-installed `NSTrackingArea` rect for one toast — the real hover hit
    /// region the OS uses.
    func installedToastTrackingRectForTesting(id: ResearchSessionID) -> CGRect? {
        toastPanelsByID[id]?.installedTrackingRectForTesting
    }

    /// The DETERMINISTIC slot top-left (screen coords) a toast is currently laid out at for
    /// the current presentation, computed from the pure layout. Used to assert the fanned
    /// vs stacked positioning without depending on the animated window frame (which settles
    /// asynchronously).
    func slotTopLeftForTesting(id: ResearchSessionID) -> CGPoint? {
        guard let visibleFrame = effectiveVisibleFrame(),
              let index = orderedVisibleIDs.firstIndex(of: id) else { return nil }
        // `effectiveVisibleFrame()` already folds in BOTH the test-only anchor offset
        // (production `.zero`) AND the user's drag offset, so this reports the ACTUAL
        // laid-out slot origin `layoutAllPanels` uses — including after a drag.
        return plannedSlotTopLeft(forIndex: index, visibleFrame: visibleFrame, presentation: presentation)
    }

    /// The current shared drag offset, so a test can assert the manager synced it in.
    var userColumnDragOffsetForTesting: CGVector { userColumnDragOffset }
}
