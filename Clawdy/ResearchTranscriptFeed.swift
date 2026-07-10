//
//  ResearchTranscriptFeed.swift
//  Clawdy
//
//  Thin, READ-ONLY bridge that surfaces Claude Code's OWN session transcript
//  (`~/.claude/projects/<sanitized-cwd>/<sessionId>.jsonl`) as the research DETAIL
//  panel's activity log. Product principle: a research run IS just a `claude`
//  session, so the detail view leans on Claude Code's native transcript/session
//  infra rather than maintaining a parallel hand-rolled log. The compact pill keeps
//  its single rotating status line; the DETAIL view shows the real streamed
//  searches / fetches / writes / messages sourced from claude's own transcript.
//
//  Pure + side-effect-free: it delegates the disk read to the already-fenced
//  `TranscriptParser` (which maps the `.jsonl` into readable `TranscriptTurn`s and
//  rejects any path outside the allowed roots), so the transcript→detail mapping is
//  unit-testable against a temp `.jsonl`. It never mutates or blocks the run — the
//  run's own `claude` child writes the file; Clawdy only ever reads it.
//

import Foundation

enum ResearchTranscriptFeed {
    /// Loads the session's transcript turns for the live detail panel. Returns [] when
    /// the file isn't written yet, is unreadable, or is outside the security fence —
    /// in which case the detail view falls back to the synthetic status steps so it's
    /// never blank. Read-only; safe to call repeatedly (a poll) while a run is live.
    static func loadTurns(
        transcriptPath: String,
        allowedRoots: [String] = TranscriptParser.historyTranscriptAllowedRoots()
    ) -> [TranscriptTurn] {
        switch TranscriptParser.loadResult(forFileAtPath: transcriptPath, allowedRoots: allowedRoots) {
        case .fileMissing:
            return []
        case .parsed(let turns):
            return turns
        }
    }
}
