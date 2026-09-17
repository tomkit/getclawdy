//
//  TurnDebugDump.swift
//  Clawdy
//
//  Writes what the model was actually given and what came back for the MOST RECENT
//  push-to-talk turn to `~/Library/Application Support/Clawdy/debug/last-turn/`
//  (overwritten every turn, so it never grows): the exact screenshot bytes sent
//  (`screen1.jpg`, …, with annotation strokes burned in), the user text, the reply,
//  and `points.json` — each parsed [POINT] tag alongside the screen location the
//  cursor was sent to. This is the evidence for "the claw landed in the wrong place":
//  open the image, find the model's pixel coordinate, and compare.
//

import Foundation

enum TurnDebugDump {
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Clawdy/debug/last-turn", isDirectory: true)
    }

    /// One parsed point with the coordinate spaces it passed through.
    struct PointRecord: Codable {
        let label: String?
        let screenNumber: Int?
        let screenshotPixel: [Double]
        let screenshotSize: [Int]
        let displayPoints: [Int]
        let globalScreenLocation: [Double]
    }

    static func write(
        screenCaptures: [CompanionScreenCapture],
        userText: String,
        replyText: String,
        points: [PointRecord]
    ) {
        let directory = directoryURL
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, capture) in screenCaptures.enumerated() {
            try? capture.imageData.write(to: directory.appendingPathComponent("screen\(index + 1).jpg"))
        }
        let labels = screenCaptures.enumerated().map { "screen\($0.offset + 1).jpg: \($0.element.label) (\($0.element.screenshotWidthInPixels)x\($0.element.screenshotHeightInPixels) px for \($0.element.displayWidthInPoints)x\($0.element.displayHeightInPoints) pt, frame \($0.element.displayFrame))" }
        try? (labels.joined(separator: "\n") + "\n\n" + userText).write(to: directory.appendingPathComponent("user.txt"), atomically: true, encoding: .utf8)
        try? replyText.write(to: directory.appendingPathComponent("reply.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(points) {
            try? data.write(to: directory.appendingPathComponent("points.json"))
        }
    }
}
