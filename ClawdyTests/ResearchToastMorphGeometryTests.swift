//
//  ResearchToastMorphGeometryTests.swift
//  ClawdyTests
//
//  Unit tests for the FULL-TOAST geometry. The old resting⇄expanded morph is retired — an
//  active research run now always renders as the ONE full toast (`ResearchFullToastView`),
//  so there is exactly one footprint + corner radius. These assertions pin that single
//  geometry (the mini badge, its morph endpoints, and the halo-avoiding cross-fade it
//  needed are all gone).
//

import XCTest
@testable import Clawdy

final class ResearchToastMorphGeometryTests: XCTestCase {
    // Pin the CONCRETE full-toast footprint as a hard-coded literal (NOT by referencing the
    // same `ResearchStackFrameLayout` constant the geometry delegates to) so this fails if
    // the size is changed to a wrong value, rather than testing the implementation against
    // itself.
    func testFullToastSizeIsTheExpectedLiteralPixelValue() {
        XCTAssertEqual(ResearchFullToastGeometry.toastSize, CGSize(width: 320, height: 68))
    }

    func testFullToastCornerRadiusIsTheExpectedLiteralValue() {
        XCTAssertEqual(ResearchFullToastGeometry.cornerRadius, 12)
    }

    // The full toast is the full pill footprint (the retired mini badge's small resting
    // size is no longer a separate shape). Guards against accidentally shrinking the one
    // toast back to the old mini badge dimensions.
    func testFullToastMatchesTheFullPillFootprintNotTheOldMiniBadge() {
        XCTAssertEqual(ResearchFullToastGeometry.toastSize, ResearchStackFrameLayout.expandedPillSize)
        XCTAssertNotEqual(ResearchFullToastGeometry.toastSize, ResearchStackFrameLayout.restingPillSize)
        // It's genuinely the larger full footprint in both dimensions.
        XCTAssertGreaterThan(ResearchFullToastGeometry.toastSize.width, ResearchStackFrameLayout.restingPillSize.width)
        XCTAssertGreaterThan(ResearchFullToastGeometry.toastSize.height, ResearchStackFrameLayout.restingPillSize.height)
    }
}

/// The idle RECENTS badge's square→inline-list surface morph geometry. Unlike the active
/// toast above (one fixed footprint), the recents badge's ONE persistent surface GROWS from
/// the resting square to the full inline list — the dark fill and the Clawdy border-aura as
/// a single continuous layer, driven from `model.state` so SwiftUI interpolates it. These
/// assertions pin the two endpoints AND that a mid-progress value is STRICTLY between them
/// (the growth the old cross-fade — which popped straight to the final-size rect — could
/// never produce), so a regression back to a pop fails here.
final class ResearchRecentsSurfaceMorphGeometryTests: XCTestCase {

    /// The two endpoints are the badge's own 44×44 square (r=12) and the full inline-list
    /// footprint (r=16) — pinned as literals where they're fixed, so a wrong value fails.
    func testEndpointsAreTheSquareAndTheFullList() {
        XCTAssertEqual(ResearchRecentsSurfaceMorph.restingSize, CGSize(width: 44, height: 44))
        XCTAssertEqual(ResearchRecentsSurfaceMorph.restingCornerRadius, 12)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.listOpenSize, ResearchRecentsLayout.inlineListSize)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.listOpenCornerRadius, 16)
        // The list endpoint is genuinely larger than the square in BOTH dimensions (it grows).
        XCTAssertGreaterThan(ResearchRecentsSurfaceMorph.listOpenSize.width, ResearchRecentsSurfaceMorph.restingSize.width)
        XCTAssertGreaterThan(ResearchRecentsSurfaceMorph.listOpenSize.height, ResearchRecentsSurfaceMorph.restingSize.height)
    }

    /// `metrics(for:)` returns the two endpoints the animation interpolates BETWEEN — the
    /// exact (size, cornerRadius) the surface holds at each discrete state.
    func testMetricsForStateReturnTheTwoEndpoints() {
        let resting = ResearchRecentsSurfaceMorph.metrics(for: .resting)
        XCTAssertEqual(resting.size, ResearchRecentsSurfaceMorph.restingSize)
        XCTAssertEqual(resting.cornerRadius, ResearchRecentsSurfaceMorph.restingCornerRadius)

        let listOpen = ResearchRecentsSurfaceMorph.metrics(for: .listOpen)
        XCTAssertEqual(listOpen.size, ResearchRecentsSurfaceMorph.listOpenSize)
        XCTAssertEqual(listOpen.cornerRadius, ResearchRecentsSurfaceMorph.listOpenCornerRadius)
    }

    /// The progress endpoints land EXACTLY on the square (0) and the full list (1) — the
    /// values a REDUCE-MOTION synchronous jump snaps straight to, with no interpolation.
    func testProgressEndpointsLandExactlyOnEachState() {
        XCTAssertEqual(ResearchRecentsSurfaceMorph.size(atListOpenProgress: 0), ResearchRecentsSurfaceMorph.restingSize)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.size(atListOpenProgress: 1), ResearchRecentsSurfaceMorph.listOpenSize)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.cornerRadius(atListOpenProgress: 0), 12)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.cornerRadius(atListOpenProgress: 1), 16)
    }

    /// The morph GROWS continuously: at mid-progress the surface size AND corner radius are
    /// STRICTLY between the square and the full list in every dimension. This is the crux of
    /// the fix — a cross-fade of two separately-backed subtrees would jump straight to the
    /// final-size rect (no intermediate), so this strictly-between value can only exist when
    /// one surface geometrically interpolates.
    func testMidProgressIsStrictlyBetweenTheSquareAndTheList() {
        let midSize = ResearchRecentsSurfaceMorph.size(atListOpenProgress: 0.5)
        XCTAssertGreaterThan(midSize.width, ResearchRecentsSurfaceMorph.restingSize.width)
        XCTAssertLessThan(midSize.width, ResearchRecentsSurfaceMorph.listOpenSize.width)
        XCTAssertGreaterThan(midSize.height, ResearchRecentsSurfaceMorph.restingSize.height)
        XCTAssertLessThan(midSize.height, ResearchRecentsSurfaceMorph.listOpenSize.height)
        // Exact linear midpoint in both dimensions.
        XCTAssertEqual(midSize.width,
                       (ResearchRecentsSurfaceMorph.restingSize.width + ResearchRecentsSurfaceMorph.listOpenSize.width) / 2,
                       accuracy: 0.001)
        XCTAssertEqual(midSize.height,
                       (ResearchRecentsSurfaceMorph.restingSize.height + ResearchRecentsSurfaceMorph.listOpenSize.height) / 2,
                       accuracy: 0.001)

        let midRadius = ResearchRecentsSurfaceMorph.cornerRadius(atListOpenProgress: 0.5)
        XCTAssertGreaterThan(midRadius, ResearchRecentsSurfaceMorph.restingCornerRadius)
        XCTAssertLessThan(midRadius, ResearchRecentsSurfaceMorph.listOpenCornerRadius)
        XCTAssertEqual(midRadius, 14, accuracy: 0.001)
    }

    /// Progress is clamped: a value below 0 / above 1 never overshoots past an endpoint, so a
    /// stray or overshooting value can't blow the surface past the list or below the square.
    func testProgressIsClampedToTheEndpoints() {
        XCTAssertEqual(ResearchRecentsSurfaceMorph.size(atListOpenProgress: -1), ResearchRecentsSurfaceMorph.restingSize)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.size(atListOpenProgress: 2), ResearchRecentsSurfaceMorph.listOpenSize)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.cornerRadius(atListOpenProgress: -1), 12)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.cornerRadius(atListOpenProgress: 2), 16)
    }

    /// The Clawdy glow stays a soft CONTAINED aura at EVERY interpolated size: the default
    /// glow radius (10pt, bloom ≈ 13pt) is within the panel's 18pt clear `shadowMargin`
    /// ceiling (`maximumSafeRadius`), and at no interpolated point does the corner radius
    /// exceed half the smallest surface dimension — so the rounded silhouette is always
    /// valid and the aura never becomes a clipped hard rectangle mid-grow.
    func testGlowBloomAndCornerRadiusStayWithinSafeBoundsAtEverySize() {
        XCTAssertLessThanOrEqual(ClawdyGlow.defaultRadius, ClawdyGlow.maximumSafeRadius)
        for progressTenths in 0...10 {
            let progress = CGFloat(progressTenths) / 10
            let size = ResearchRecentsSurfaceMorph.size(atListOpenProgress: progress)
            let cornerRadius = ResearchRecentsSurfaceMorph.cornerRadius(atListOpenProgress: progress)
            XCTAssertLessThanOrEqual(cornerRadius, min(size.width, size.height) / 2,
                                     "corner radius must never exceed half the smallest dimension at progress \(progress)")
        }
    }

    /// `listOpenProgress(forCurrentSize:)` is the exact INVERSE of `size(atListOpenProgress:)`:
    /// feeding a size back through it recovers the original progress. This is the mapping the
    /// live surface uses to turn the window's CURRENT animated content size into the corner
    /// radius, so it must round-trip or the radius would lag the fill.
    func testListOpenProgressIsTheInverseOfSize() {
        for progressTenths in 0...10 {
            let progress = CGFloat(progressTenths) / 10
            let size = ResearchRecentsSurfaceMorph.size(atListOpenProgress: progress)
            let recoveredProgress = ResearchRecentsSurfaceMorph.listOpenProgress(forCurrentSize: size)
            XCTAssertEqual(recoveredProgress, progress, accuracy: 0.0001,
                           "progress→size→progress must round-trip at \(progress)")
        }
        // Endpoints map back exactly to 0 and 1.
        XCTAssertEqual(ResearchRecentsSurfaceMorph.listOpenProgress(forCurrentSize: ResearchRecentsSurfaceMorph.restingSize), 0, accuracy: 0.0001)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.listOpenProgress(forCurrentSize: ResearchRecentsSurfaceMorph.listOpenSize), 1, accuracy: 0.0001)
    }

    /// Progress derived from a live size is clamped, so a window size momentarily outside the
    /// endpoints (rounding during the animation) never overshoots the radius past r=12…r=16.
    func testListOpenProgressIsClamped() {
        let belowResting = CGSize(width: 10, height: ResearchRecentsSurfaceMorph.restingSize.height - 50)
        let aboveList = CGSize(width: 999, height: ResearchRecentsSurfaceMorph.listOpenSize.height + 50)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.listOpenProgress(forCurrentSize: belowResting), 0, accuracy: 0.0001)
        XCTAssertEqual(ResearchRecentsSurfaceMorph.listOpenProgress(forCurrentSize: aboveList), 1, accuracy: 0.0001)
    }
}

/// The FIXED-ANCHOR invariant behind the hover-jitter fix: the recents badge's visible surface
/// (the resting square that grows into the list) must NEVER translate — its on-screen top-left
/// corner is identical at rest, fully open, and at EVERY intermediate size during the grow. Only
/// width/height/cornerRadius change. This is the geometric guarantee that replaced the old two
/// competing animations (AppKit window frame vs a SwiftUI `.frame`+`.easeInOut` on `model.state`)
/// which drifted apart mid-transition and shifted the square down+right.
///
/// It ties together the two pure pieces the live badge relies on: the window is TOP-LEFT anchored
/// (`ResearchToastLayout.windowOrigin` hangs the window DOWN from a fixed slot top-left) and the
/// surface is pinned TOP-LEADING inside it inset by the shadow margin (`ResearchToastLayout.pillRect`).
/// Their composition puts the surface's on-screen top-left at a fixed point for any surface size.
final class ResearchRecentsFixedAnchorGeometryTests: XCTestCase {

    /// A fixed idle slot the badge hangs from (screen coords; y-up, AppKit convention).
    private let slotTopLeft = CGPoint(x: 216, y: 900)

    /// The surface's on-screen TOP-LEFT corner for a surface of `surfaceSize`, composing the
    /// exact two transforms the live controller applies: the window hangs down from the fixed
    /// slot (`windowOrigin`), and the surface sits top-leading inside it inset by the shadow
    /// margin (`pillRect`). Returns the point in screen coords with the surface's TOP as `.y`.
    private func surfaceTopLeftOnScreen(surfaceSize: CGSize) -> CGPoint {
        let windowContentSize = CGSize(
            width: surfaceSize.width + ResearchToastLayout.shadowMargin * 2,
            height: surfaceSize.height + ResearchToastLayout.shadowMargin * 2
        )
        let windowOrigin = ResearchToastLayout.windowOrigin(slotTopLeft: slotTopLeft, contentSize: windowContentSize)
        let pillRect = ResearchToastLayout.pillRect(inWindowOfSize: windowContentSize, pillSize: surfaceSize)
        // On-screen: x = window origin + pill minX; the surface's TOP edge (y-up) = window origin
        // + pill maxY. Both are the surface's top-left corner in screen coordinates.
        return CGPoint(x: windowOrigin.x + pillRect.minX, y: windowOrigin.y + pillRect.maxY)
    }

    /// The square's top-left is identical at the resting square, the fully-open list, AND at
    /// every intermediate grow size — i.e. the surface never translates, it only grows.
    func testSurfaceTopLeftIsInvariantAcrossTheWholeGrow() {
        let restingAnchor = surfaceTopLeftOnScreen(surfaceSize: ResearchRecentsSurfaceMorph.restingSize)

        // The fixed anchor is exactly the slot's top-left inset by the shadow margin (x shifts
        // right by the margin; the top y stays pinned to the slot's top). Pin the concrete value.
        XCTAssertEqual(restingAnchor.x, slotTopLeft.x + ResearchToastLayout.shadowMargin, accuracy: 0.0001)
        XCTAssertEqual(restingAnchor.y, slotTopLeft.y - ResearchToastLayout.shadowMargin, accuracy: 0.0001)

        // Fully-open list endpoint: same on-screen top-left.
        let listOpenAnchor = surfaceTopLeftOnScreen(surfaceSize: ResearchRecentsSurfaceMorph.listOpenSize)
        XCTAssertEqual(listOpenAnchor.x, restingAnchor.x, accuracy: 0.0001)
        XCTAssertEqual(listOpenAnchor.y, restingAnchor.y, accuracy: 0.0001)

        // Every intermediate grow size (the frames the window frame animation passes through):
        // the top-left must not move at any of them.
        for progressTenths in 0...10 {
            let progress = CGFloat(progressTenths) / 10
            let midSize = ResearchRecentsSurfaceMorph.size(atListOpenProgress: progress)
            let midAnchor = surfaceTopLeftOnScreen(surfaceSize: midSize)
            XCTAssertEqual(midAnchor.x, restingAnchor.x, accuracy: 0.0001,
                           "surface top-left x must not move at progress \(progress)")
            XCTAssertEqual(midAnchor.y, restingAnchor.y, accuracy: 0.0001,
                           "surface top-left y must not move at progress \(progress)")
        }
    }
}
