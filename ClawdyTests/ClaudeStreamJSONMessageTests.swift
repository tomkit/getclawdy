//
//  ClaudeStreamJSONMessageTests.swift
//  ClawdyTests
//
//  Headless unit tests for the NDJSON stream-json input lines fed to the warm
//  `claude` process: the user-message line (text block + inline base64 image
//  blocks) and the interrupt control line. The lines are parsed back into JSON
//  and asserted structurally, since JSONSerialization does not guarantee key
//  order.
//

import Testing
import Foundation
@testable import Clawdy

struct ClaudeStreamJSONMessageTests {

    /// Decodes one NDJSON line back into a dictionary for structural assertions.
    private func decode(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @Test func userMessageLineHasTextBlockThenInlineBase64ImageBlocks() {
        let line = ClaudeStreamJSONMessage.makeUserMessageLine(
            text: "what is on my screen",
            images: [
                ClaudeStreamJSONMessage.InlineImage(base64EncodedData: "QUJD", mediaType: "image/jpeg"),
                ClaudeStreamJSONMessage.InlineImage(base64EncodedData: "REVG", mediaType: "image/jpeg")
            ]
        )

        // Newline-delimited so the CLI treats it as one complete message.
        #expect(line.hasSuffix("\n"))

        guard let object = decode(line) else { Issue.record("not valid JSON"); return }
        #expect(object["type"] as? String == "user")

        guard let message = object["message"] as? [String: Any] else { Issue.record("no message"); return }
        #expect(message["role"] as? String == "user")

        guard let content = message["content"] as? [[String: Any]] else { Issue.record("no content array"); return }
        // 1 text block + 2 image blocks, in order.
        #expect(content.count == 3)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "what is on my screen")

        #expect(content[1]["type"] as? String == "image")
        let firstSource = content[1]["source"] as? [String: Any]
        #expect(firstSource?["type"] as? String == "base64")
        #expect(firstSource?["media_type"] as? String == "image/jpeg")
        #expect(firstSource?["data"] as? String == "QUJD")

        #expect(content[2]["type"] as? String == "image")
        let secondSource = content[2]["source"] as? [String: Any]
        #expect(secondSource?["data"] as? String == "REVG")
    }

    @Test func userMessageLineWithNoImagesHasOnlyTextBlock() {
        let line = ClaudeStreamJSONMessage.makeUserMessageLine(text: "hi", images: [])
        guard let object = decode(line),
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            Issue.record("bad shape"); return
        }
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
    }

    @Test func interruptControlLineCarriesSubtypeAndRequestID() {
        let line = ClaudeStreamJSONMessage.makeInterruptControlLine(requestID: "abc-123")
        #expect(line.hasSuffix("\n"))

        guard let object = decode(line) else { Issue.record("not valid JSON"); return }
        #expect(object["type"] as? String == "control_request")
        #expect(object["request_id"] as? String == "abc-123")
        let request = object["request"] as? [String: Any]
        #expect(request?["subtype"] as? String == "interrupt")
    }
}
