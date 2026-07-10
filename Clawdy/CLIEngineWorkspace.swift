//
//  CLIEngineWorkspace.swift
//  Clawdy
//
//  Manages the per-request temp directory the CLI engines use: a private,
//  short-lived folder that holds the screenshots handed to the CLI. The folder
//  is the only directory the CLI is granted access to, and it is deleted as soon
//  as the request finishes.
//

import Foundation

enum CLIEngineWorkspace {
    /// Creates a fresh private temp directory for one coaching request.
    static func makeRequestDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdy-engine", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Removes a request directory and everything in it. Best-effort.
    static func removeDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes each captured screenshot to `directory` as screen1.jpg, screen2.jpg,
    /// … and returns descriptors (path, file name, label) for use in prompts and
    /// `-i` image attachments.
    static func writeScreenshots(
        _ images: [(data: Data, label: String)],
        into directory: URL
    ) throws -> [CLIPromptComposer.WrittenScreenshotFile] {
        var writtenFiles: [CLIPromptComposer.WrittenScreenshotFile] = []
        for (screenIndex, image) in images.enumerated() {
            let fileName = CLIPromptComposer.screenshotFileName(forScreenIndex: screenIndex)
            let fileURL = directory.appendingPathComponent(fileName)
            try image.data.write(to: fileURL)
            writtenFiles.append(CLIPromptComposer.WrittenScreenshotFile(
                absolutePath: fileURL.path,
                fileName: fileName,
                label: image.label
            ))
        }
        return writtenFiles
    }
}
