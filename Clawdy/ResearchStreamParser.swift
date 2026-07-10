//
//  ResearchStreamParser.swift
//  Clawdy
//
//  Pure parsing of the research subsystem's `claude ... --output-format
//  stream-json` output into the handful of things the app cares about for a
//  research run: the session id (to resume the plan phase into the execute
//  phase), a coarse PROGRESS event per tool call (to drive the single rotating
//  status line in the overlay), the running tool-use count, the model's
//  assistant text, and the terminal `result`.
//
//  The quick-answer warm session has its own minimal `ClaudeStreamEvent` parser
//  (textDelta / result only). Research needs the richer tool taxonomy that the
//  warm parser deliberately drops to `.other`, so it gets its own parser here
//  rather than detuning the fast path's.
//
//  Everything here is side-effect-free and unit-testable: string in, value out.
//

import Foundation

/// A coarse, human-facing progress step mapped from one research stream line.
/// Drives the SINGLE rotating status line shown in the progress overlay.
enum ResearchProgressEvent: Equatable {
    /// The model is searching the web (`WebSearch`); carries the query.
    case searchingWeb(query: String)
    /// The model is fetching a page (`WebFetch`); carries the URL.
    case readingPage(url: String)
    /// The model is writing the deliverable HTML (`Write`).
    case writingPage
    /// Some other tool ran; carries the tool name so the status can name it.
    case runningTool(name: String)
}

/// One meaningful thing parsed from a single research stream-json line.
enum ResearchStreamLine: Equatable {
    /// The `system`/`init` line — carries the session id we resume with.
    case sessionStarted(sessionID: String)
    /// A tool call started — mapped to a coarse progress event.
    case progress(ResearchProgressEvent)
    /// Assistant text (the plan / clarifying questions / narration).
    case assistantText(String)
    /// The terminal event for the turn: final text + error flag.
    case result(text: String?, isError: Bool)
    /// Anything else (tool_result, usage, partial deltas) — ignored for routing.
    case ignored
}

enum ResearchStreamParser {
    /// Parses one NDJSON line of the research stream. Returns `.ignored` for
    /// blank/unparseable lines so callers can treat "nothing actionable" uniformly.
    static func parse(line: String) -> ResearchStreamLine {
        guard let jsonObject = decodeJSONLine(line),
              let eventType = jsonObject["type"] as? String else {
            return .ignored
        }

        // The first line: { type: "system", subtype: "init", session_id: "..." }
        if eventType == "system",
           (jsonObject["subtype"] as? String) == "init",
           let sessionID = jsonObject["session_id"] as? String {
            return .sessionStarted(sessionID: sessionID)
        }

        // Terminal: { type: "result", result: "...", is_error: false, session_id }
        if eventType == "result" {
            let isError = (jsonObject["is_error"] as? Bool) ?? false
            return .result(text: jsonObject["result"] as? String, isError: isError)
        }

        // Assistant content blocks: { type: "assistant", message: { content: [ ... ] } }
        if eventType == "assistant",
           let message = jsonObject["message"] as? [String: Any],
           let contentBlocks = message["content"] as? [[String: Any]] {
            // A tool_use block drives a progress event; a text block is narration.
            for contentBlock in contentBlocks {
                let blockType = contentBlock["type"] as? String
                if blockType == "tool_use",
                   let toolName = contentBlock["name"] as? String {
                    let toolInput = contentBlock["input"] as? [String: Any] ?? [:]
                    return .progress(progressEvent(forToolNamed: toolName, input: toolInput))
                }
            }
            for contentBlock in contentBlocks {
                if (contentBlock["type"] as? String) == "text",
                   let text = contentBlock["text"] as? String {
                    return .assistantText(text)
                }
            }
            return .ignored
        }

        return .ignored
    }

    /// Maps a tool name + its input dictionary to a coarse progress event.
    static func progressEvent(forToolNamed toolName: String, input: [String: Any]) -> ResearchProgressEvent {
        switch toolName {
        case "WebSearch":
            let query = (input["query"] as? String) ?? ""
            return .searchingWeb(query: query)
        case "WebFetch":
            let url = (input["url"] as? String) ?? ""
            return .readingPage(url: url)
        case "Write":
            return .writingPage
        default:
            return .runningTool(name: toolName)
        }
    }
}
