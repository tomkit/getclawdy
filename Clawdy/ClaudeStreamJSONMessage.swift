//
//  ClaudeStreamJSONMessage.swift
//  Clawdy
//
//  Pure constructors for the newline-delimited JSON (NDJSON) lines fed to the
//  `claude` CLI on stdin when it runs with `--input-format stream-json`. Each
//  push-to-talk turn is sent as a single `user` message whose content is a text
//  block followed by one base64 `image` block per screenshot — so Claude sees
//  the screens DIRECTLY in the first model turn instead of reading them off disk
//  with the Read tool (which cost a whole extra model turn). A cancellation is
//  sent as a `control_request` interrupt so the in-flight turn stops without
//  killing the warm process.
//
//  Everything here is side-effect-free and unit-testable: it only serializes
//  dictionaries to JSON strings.
//

import Foundation

enum ClaudeStreamJSONMessage {
    /// One screenshot ready to embed inline as a base64 image content block.
    struct InlineImage {
        /// The image bytes already base64-encoded (standard, no line breaks).
        let base64EncodedData: String
        /// The MIME type, e.g. "image/jpeg".
        let mediaType: String
    }

    /// Builds the NDJSON line for one user turn: a text block plus an inline
    /// base64 image block per screenshot. The returned string already ends with
    /// the trailing newline the CLI uses as the message delimiter.
    static func makeUserMessageLine(text: String, images: [InlineImage]) -> String {
        var contentBlocks: [[String: Any]] = [
            ["type": "text", "text": text]
        ]
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.base64EncodedData
                ]
            ])
        }
        let messageEnvelope: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": contentBlocks
            ]
        ]
        return encodeJSONLine(messageEnvelope)
    }

    /// Builds the NDJSON line that interrupts the currently streaming turn. The
    /// CLI replies with a `control_response` and a terminal `result` for the
    /// interrupted turn, then stays alive to serve the next message — so the warm
    /// process survives a user re-press.
    static func makeInterruptControlLine(requestID: String) -> String {
        let controlEnvelope: [String: Any] = [
            "type": "control_request",
            "request_id": requestID,
            "request": [
                "subtype": "interrupt"
            ]
        ]
        return encodeJSONLine(controlEnvelope)
    }

    /// Serializes a JSON object to a single line terminated by "\n". Returns an
    /// empty string if serialization somehow fails (it never does for these
    /// fixed-shape dictionaries, but we avoid force-unwrapping regardless).
    private static func encodeJSONLine(_ jsonObject: [String: Any]) -> String {
        guard let lineData = try? JSONSerialization.data(withJSONObject: jsonObject),
              let lineString = String(data: lineData, encoding: .utf8) else {
            return ""
        }
        return lineString + "\n"
    }
}
