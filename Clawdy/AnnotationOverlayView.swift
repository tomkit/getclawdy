//
//  AnnotationOverlayView.swift
//  Clawdy
//
//  SwiftUI Canvas that renders in-progress and completed freehand annotation
//  strokes on the cursor display overlay. Inserted below the cursor layer
//  in BlueCursorView's ZStack so the cursor stays above the drawing.
//
//  Coordinate convention: strokes are stored in display-point space
//  (AppKit logical coords, NSScreen.frame-relative, bottom-left origin,
//  y increasing upward). The Canvas uses SwiftUI coordinates (top-left
//  origin, y increasing downward), so each point's y is flipped:
//    canvasY = screenHeightInPoints - appKitDisplayRelativeY
//

import SwiftUI

struct AnnotationOverlayView: View {
    @ObservedObject var annotationStrokeStore: AnnotationStrokeStore
    /// The display index to render — should match the displayIndex stored
    /// in each AnnotationStroke. Currently always 0 (cursor display).
    let displayIndex: Int
    /// Height of the screen in points, used to flip AppKit y-coordinates
    /// (bottom-left origin) into SwiftUI canvas y-coordinates (top-left origin).
    let screenHeightInPoints: CGFloat

    /// Line width in points for the rendered strokes.
    private let strokeLineWidthInPoints: CGFloat = 4.0

    var body: some View {
        Canvas { context, size in
            let strokesToRender = annotationStrokeStore.strokes(forDisplayIndex: displayIndex)

            for stroke in strokesToRender {
                // Need at least two points to draw a visible line segment.
                guard stroke.points.count >= 2 else { continue }

                var path = Path()
                for (pointIndex, appKitDisplayRelativePoint) in stroke.points.enumerated() {
                    // Flip y from AppKit display-relative (bottom-left) to SwiftUI canvas (top-left).
                    let canvasPoint = CGPoint(
                        x: appKitDisplayRelativePoint.x,
                        y: screenHeightInPoints - appKitDisplayRelativePoint.y
                    )
                    if pointIndex == 0 {
                        path.move(to: canvasPoint)
                    } else {
                        path.addLine(to: canvasPoint)
                    }
                }

                context.stroke(
                    path,
                    with: .color(DS.Colors.openClawRed),
                    style: StrokeStyle(
                        lineWidth: strokeLineWidthInPoints,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        // This view is purely visual — hit testing is handled by the window's
        // global mouse monitor, not SwiftUI's input pipeline.
        .allowsHitTesting(false)
    }
}
