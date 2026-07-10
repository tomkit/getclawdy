//
//  ResearchStatusLine.swift
//  Clawdy
//
//  Pure mapping from a research run's phase / progress events to the SINGLE
//  rotating status line shown on the cursor-following progress overlay (e.g.
//  "Searching the web for X…" → "Reading example.com…" → "Writing the page…" →
//  "View results ›"). Side-effect-free and unit-testable.
//

import Foundation

enum ResearchStatusLine {
    /// The very first line shown the instant a research run is dispatched, before
    /// any stream event has arrived.
    static let startingUp = "Starting research…"
    /// Shown while the plan/clarify phase is thinking (plan mode, no tools yet).
    static let planning = "Planning the research…"
    /// Shown when the plan agent needs answers before it can proceed. Clicking the
    /// overlay in this state opens the clarifying-question input panel.
    static let needsYourInput = "I need a quick answer — click to reply"
    /// Shown while a voice follow-up turn is continuing a finished session.
    static let workingOnFollowUp = "Working on your follow-up…"
    /// The terminal, tappable affordance once the deliverable HTML is ready.
    static let viewResults = "View results ›"
    /// Shown briefly if a run is cancelled via the Stop control.
    static let stopped = "Research stopped"
    /// Shown if the run fails.
    static let failed = "Research failed"

    /// The live status line for a coarse progress event.
    static func text(for progressEvent: ResearchProgressEvent) -> String {
        switch progressEvent {
        case .searchingWeb(let query):
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedQuery.isEmpty ? "Searching the web…" : "Searching the web for \(trimmedQuery)…"
        case .readingPage(let url):
            let host = displayHost(fromURLString: url)
            return host.isEmpty ? "Reading a page…" : "Reading \(host)…"
        case .writingPage:
            return "Writing the page…"
        case .runningTool(let name):
            return "Running \(name)…"
        }
    }

    /// Extracts a short, human-friendly host (no scheme, no "www.", no path) from a
    /// URL string for the "Reading <host>…" status. Falls back to the raw string
    /// (trimmed of a scheme) when it can't be parsed as a URL.
    static func displayHost(fromURLString urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let host = URL(string: trimmed)?.host {
            return stripWWWPrefix(host)
        }
        // Fall back: strip an obvious scheme and take the first path segment.
        var withoutScheme = trimmed
        if let schemeRange = withoutScheme.range(of: "://") {
            withoutScheme = String(withoutScheme[schemeRange.upperBound...])
        }
        let firstSegment = withoutScheme.split(separator: "/").first.map(String.init) ?? withoutScheme
        return stripWWWPrefix(firstSegment)
    }

    private static func stripWWWPrefix(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
