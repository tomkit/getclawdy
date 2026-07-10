//
//  CodexResearchStreamParser.swift
//  Clawdy
//
//  Pure parsing of the Codex research path's `codex exec --json` JSONL output into
//  the EXISTING research vocabulary (`ResearchStreamLine` / `ResearchProgressEvent`)
//  the overlay + accumulator already speak — so the single rotating status line, the
//  session-id capture, and the terminal text all work identically to the Claude path
//  without any new UI types.
//
//  Codex's event stream (codex-cli 0.142.x JSONL) differs from Claude's stream-json
//  shape, so it needs its OWN parser (Claude's is `ResearchStreamParser`). The mapping:
//
//    thread.started{thread_id}                          → .sessionStarted(thread_id)
//    item.completed{item:{type:"web_search", query?}}   → .progress(.searchingWeb)
//    file_change                                        → .progress(.writingPage)
//    item.completed{item:{type:"agent_message", text}}  → .result(text) (assistant text
//                                                          / terminal reply for TTS)
//    turn.completed{usage}                              → .ignored (the process EXIT is
//                                                          the real done signal)
//    anything else / unparseable                        → .ignored
//
//  Everything here is side-effect-free and unit-testable: string in, value out.
//

import Foundation

enum CodexResearchStreamParser {
    /// Parses one JSONL line of the Codex research stream into the shared
    /// `ResearchStreamLine` vocabulary. Returns `.ignored` for blank/unparseable lines
    /// (and for events with no routing meaning) so callers treat "nothing actionable"
    /// uniformly.
    static func parse(line: String) -> ResearchStreamLine {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              let lineData = trimmedLine.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let eventType = jsonObject["type"] as? String else {
            return .ignored
        }

        switch eventType {
        // The first line: { type: "thread.started", thread_id: "..." }. The Codex
        // thread id IS this run's resumable session id (read POST-HOC — it cannot be
        // pre-minted the way Claude's --session-id can).
        case "thread.started":
            if let threadID = jsonObject["thread_id"] as? String {
                return .sessionStarted(sessionID: threadID)
            }
            return .ignored

        // A file was written/changed — the deliverable is being produced. Maps to the
        // same "Writing the page…" status the Claude Write tool drives.
        case "file_change":
            return .progress(.writingPage)

        // A completed item: a web_search (progress) or the agent_message (terminal
        // assistant text used for the spoken reply).
        case "item.completed":
            return parseCompletedItem(jsonObject["item"] as? [String: Any])

        // turn.completed carries usage but no text; the process exit is the authoritative
        // "done" signal, so this line routes to nothing (avoid clobbering the captured
        // agent_message text).
        default:
            return .ignored
        }
    }

    /// Maps a completed `item` object to a research stream line. A `web_search` item
    /// becomes a searching-web progress event (carrying its query when present); an
    /// `agent_message` item becomes the terminal result text (both the assistant's
    /// narration and the read-aloud reply). Any other item type is ignored.
    private static func parseCompletedItem(_ item: [String: Any]?) -> ResearchStreamLine {
        guard let item, let itemType = item["type"] as? String else {
            return .ignored
        }
        switch itemType {
        case "web_search":
            let query = (item["query"] as? String) ?? ""
            return .progress(.searchingWeb(query: query))
        case "agent_message":
            let text = item["text"] as? String
            return .result(text: text, isError: false)
        default:
            return .ignored
        }
    }
}
