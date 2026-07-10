//
//  AnnotationStrokeStore.swift
//  Clawdy
//
//  Pure value/state type for freehand annotation strokes.
//  No AppKit drawing — just data storage and mutation.
//

import Combine
import Foundation
import CoreGraphics

/// A single continuous freehand stroke drawn by the user.
/// Points are in display-point space: AppKit logical coordinates,
/// NSScreen.frame-relative, with the origin at the bottom-left of
/// the display and y increasing upward.
struct AnnotationStroke {
    /// Index of the display (in the capture loop's sorted order, cursor
    /// screen first) this stroke belongs to. Currently only displayIndex 0
    /// (the cursor display) is used.
    let displayIndex: Int
    /// Ordered sequence of control points in display-point space.
    var points: [CGPoint]
}

/// Mutable store for in-progress and completed annotation strokes.
/// Owned by CompanionManager and observed by AnnotationOverlayView.
final class AnnotationStrokeStore: ObservableObject {
    /// All strokes — both completed and the in-progress one at the tail.
    @Published private(set) var strokes: [AnnotationStroke] = []

    /// Index of the stroke currently being drawn (tail of `strokes`).
    /// nil when no stroke is in progress.
    private var currentStrokeIndex: Int? = nil

    /// Begins a new stroke on the given display. Adds an empty stroke to
    /// `strokes` and marks it as the in-progress one.
    func beginStroke(displayIndex: Int) {
        strokes.append(AnnotationStroke(displayIndex: displayIndex, points: []))
        currentStrokeIndex = strokes.count - 1
    }

    /// Appends a point to the in-progress stroke. No-op if no stroke is in progress.
    func addPoint(_ point: CGPoint) {
        guard let currentStrokeIndex,
              currentStrokeIndex < strokes.count else { return }
        strokes[currentStrokeIndex].points.append(point)
    }

    /// Finalizes the in-progress stroke. Points can no longer be appended to it.
    func endStroke() {
        currentStrokeIndex = nil
    }

    /// Removes all strokes and resets in-progress state.
    func clearAll() {
        strokes = []
        currentStrokeIndex = nil
    }

    /// Returns only the strokes belonging to the given display index.
    func strokes(forDisplayIndex displayIndex: Int) -> [AnnotationStroke] {
        strokes.filter { $0.displayIndex == displayIndex }
    }

    /// Returns only the strokes from `strokes` that have ≥ 2 points — i.e., strokes
    /// that produce a visible line segment worth compositing. A single-click creates a
    /// 1-point stroke that draws nothing visible, so it is excluded.
    static func drawableStrokes(from strokes: [AnnotationStroke]) -> [AnnotationStroke] {
        strokes.filter { $0.points.count >= 2 }
    }

    /// Returns true if `strokes` contains at least one drawable stroke (≥ 2 points).
    /// Convenience wrapper over `drawableStrokes(from:)` for guard conditions.
    static func containsDrawableStrokes(_ strokes: [AnnotationStroke]) -> Bool {
        strokes.contains { $0.points.count >= 2 }
    }
}
