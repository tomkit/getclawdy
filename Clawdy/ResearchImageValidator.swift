//
//  ResearchImageValidator.swift
//  Clawdy
//
//  The DETERMINISTIC image-validation pass for the research deliverable. The
//  execute phase writes a self-contained report.html that, for photo/gallery
//  tasks, embeds REMOTE `<img src="https://…">` URLs the model found while
//  researching. Those URLs are frequently BROKEN by the time the page renders:
//  dead links (404/410), non-image URLs, or hotlink-protected hosts. A rendered
//  page full of broken-image icons is the failure this pass exists to prevent.
//
//  We do NOT trust the model to only embed reachable images — instead, after the
//  execute (or an iterate follow-up) writes report.html, we PARSE every `<img>`
//  src, actually FETCH each remote one, and treat an image as VALID only when the
//  response is 200 with an `image/*` Content-Type and a non-empty body. Any image
//  that fails is swapped in-place for a tasteful inline "Image unavailable"
//  placeholder styled in Clawdy red — so the displayed page never shows a browser
//  broken-image icon. The rewritten page stays fully self-contained (the
//  placeholder is inline-styled, no CDN/JS/remote assets).
//
//  This is plain HTTP fetching from the app itself — NOT the CLI/subscription
//  billing path, no API keys, no `--bare`. It is TIME-BOUNDED (a per-image timeout
//  AND an overall budget) so it can never hang a research run: if validation runs
//  out of time, unverified images are dropped to placeholders (fail safe) rather
//  than blocking, and the rest of the page is left intact.
//
//  Everything HTML-shaped here (extraction, the validity predicate, the rewrite)
//  is a PURE static function so it is unit-tested with no network; the actual fetch
//  sits behind the injectable `ImageURLValidating` seam.
//

import Foundation

// MARK: - Validation seam (injectable so tests never touch the network)

/// The outcome of validating a single remote image URL.
enum ImageValidationResult: Equatable, Sendable {
    case valid
    case invalid
}

/// The injectable fetch seam. Production is `URLSessionImageURLValidator`; tests
/// inject a deterministic fake keyed by URL so no real network is used.
protocol ImageURLValidating: Sendable {
    func validate(imageURL: URL) async -> ImageValidationResult
}

/// Time / concurrency caps for the validation pass. Chosen so the pass can never
/// hang a research run: each image has its own timeout, and the whole pass is
/// bounded by `totalBudgetSeconds` after which any still-unverified image is
/// treated as invalid (dropped to a placeholder) rather than waited on.
struct ResearchImageValidationConfig: Sendable {
    /// Per-image request timeout. Many image hosts are slow or hang; this bounds
    /// each individual fetch.
    var perImageTimeoutSeconds: TimeInterval = 8
    /// Hard ceiling on the ENTIRE validation pass across all images. When it
    /// elapses, in-flight and not-yet-started fetches are cancelled and their
    /// images are treated as invalid (fail safe — drop, don't hang).
    var totalBudgetSeconds: TimeInterval = 30
    /// How many image fetches run at once. Bounds memory / socket use for a large
    /// gallery while still overlapping the (network-bound) requests.
    var maximumConcurrentValidations: Int = 6

    static let `default` = ResearchImageValidationConfig()
}

// MARK: - The validator (pure HTML logic + a time-bounded orchestrator)

enum ResearchImageValidator {

    // MARK: Pure HTML parsing

    /// Extracts the UNIQUE remote (http/https) image source URLs embedded in `html`,
    /// in first-seen order. `data:` URIs and relative/other-scheme sources are
    /// deliberately EXCLUDED — they are either already self-contained (data URIs) or
    /// not something we can fetch-validate, so the pass leaves them untouched.
    static func extractImageSourceURLs(fromHTML html: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for imgTag in imageTags(inHTML: html) {
            guard let source = imageSourceURL(inImgTag: imgTag),
                  isRemoteHTTPImageSource(source),
                  !seen.contains(source) else { continue }
            seen.insert(source)
            ordered.append(source)
        }
        return ordered
    }

    /// The validity predicate for a fetched image response: it counts as a real,
    /// renderable image ONLY when the server returned 200, an `image/*`
    /// Content-Type, and a non-empty body. A 404/410, an HTML error page served
    /// with 200, or an empty body all fail.
    static func isValidImageResponse(
        statusCode: Int,
        contentType: String?,
        bodyByteCount: Int
    ) -> Bool {
        guard statusCode == 200 else { return false }
        guard bodyByteCount > 0 else { return false }
        guard let contentType else { return false }
        // Content-Type may carry parameters (e.g. "image/jpeg; charset=binary");
        // match the leading media type case-insensitively.
        let normalized = contentType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("image/")
    }

    /// Rewrites `html`, replacing every `<img>` whose src is in `invalidSourceURLs`
    /// with an inline "Image unavailable" placeholder. Images NOT in the set (valid
    /// remote images, data URIs, relative sources) are left byte-for-byte untouched,
    /// as is all other markup — so layout and the rest of the content are preserved.
    /// The result stays self-contained (the placeholder is inline-styled only).
    static func rewriteHTMLReplacingInvalidImages(
        html: String,
        invalidSourceURLs: Set<String>
    ) -> String {
        guard !invalidSourceURLs.isEmpty else { return html }

        let nsHTML = html as NSString
        guard let regex = imageTagRegex else { return html }
        let matches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: nsHTML.length)
        )

        // Rewrite from the END backwards so earlier match ranges stay valid as we
        // splice in replacements of a different length.
        var rewritten = html
        for match in matches.reversed() {
            let imgTag = nsHTML.substring(with: match.range)
            guard let source = imageSourceURL(inImgTag: imgTag),
                  invalidSourceURLs.contains(source) else { continue }
            guard let swiftRange = Range(match.range, in: rewritten) else { continue }
            rewritten.replaceSubrange(swiftRange, with: brokenImagePlaceholderHTML)
        }
        return rewritten
    }

    /// The inline-styled placeholder that replaces a broken image. Styled in OpenClaw
    /// red (#E5342B border, #C42B22 deeper-red text on a light #FDECEA red tint) and
    /// entirely self-contained (inline style only) so the page needs no external assets.
    static let brokenImagePlaceholderHTML: String = """
    <span style="display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;min-width:140px;min-height:100px;max-width:100%;padding:14px 18px;margin:2px;border:1px solid #E5342B;border-radius:10px;background:#FDECEA;color:#C42B22;font-family:-apple-system,system-ui,'Segoe UI',sans-serif;font-size:12px;font-weight:600;line-height:1.35;text-align:center;">Image unavailable</span>
    """

    // MARK: Time-bounded orchestration (impure — reads/writes the file, uses the seam)

    /// Reads `fileURL` (report.html), validates every embedded remote image via
    /// `validator`, and — if any are broken — rewrites the file in place with the
    /// broken images replaced by placeholders. A no-op when the page has no remote
    /// images or the file can't be read. TIME-BOUNDED by `config` so it can never
    /// hang the research run; on the budget elapsing, unverified images are dropped
    /// to placeholders (fail safe) rather than waited on. Never throws — a failure
    /// to read/write leaves the on-disk page exactly as the model wrote it.
    static func validateAndRewriteDeliverable(
        fileURL: URL,
        validator: ImageURLValidating,
        config: ResearchImageValidationConfig = .default
    ) async {
        guard let originalHTML = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let sourceURLs = extractImageSourceURLs(fromHTML: originalHTML)
        guard !sourceURLs.isEmpty else { return }

        let invalidSourceURLs = await determineInvalidImageSourceURLs(
            sourceURLStrings: sourceURLs,
            validator: validator,
            config: config
        )
        guard !invalidSourceURLs.isEmpty else { return }

        let rewrittenHTML = rewriteHTMLReplacingInvalidImages(
            html: originalHTML,
            invalidSourceURLs: invalidSourceURLs
        )
        // Only rewrite the file if the transform actually changed something.
        guard rewrittenHTML != originalHTML else { return }
        try? rewrittenHTML.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Validates the given image source strings concurrently (bounded) under an
    /// overall time budget and returns the set that are INVALID (broken / could not
    /// be confirmed valid in time). Any source not positively confirmed `.valid`
    /// within the budget — because it failed, timed out, wasn't a fetchable URL, or
    /// the budget elapsed before it finished — is returned as invalid (fail safe).
    static func determineInvalidImageSourceURLs(
        sourceURLStrings: [String],
        validator: ImageURLValidating,
        config: ResearchImageValidationConfig
    ) async -> Set<String> {
        let confirmedValid = ConfirmedValidSourceCollector()

        // The bounded fetch loop records each confirmed-valid source into the actor
        // collector as it goes. It runs as an UNSTRUCTURED task so the overall-budget
        // path can stop WAITING on it without being forced (by structured concurrency)
        // to join a slow or non-cooperative validator — that is what makes the
        // wall-clock bound a hard guarantee rather than a best effort.
        let validationTask = Task {
            await runBoundedValidation(
                sourceURLStrings: sourceURLStrings,
                validator: validator,
                maximumConcurrentValidations: max(1, config.maximumConcurrentValidations),
                confirmedValid: confirmedValid
            )
        }

        // A timer that fires after the total budget. A watcher cancels the timer the
        // moment validation finishes, so the SOLE await below (`budgetTimer.value`)
        // returns as soon as EITHER validation completes OR the budget elapses —
        // whichever comes first — and never blocks on the slow path.
        let budgetNanoseconds = UInt64(max(0, config.totalBudgetSeconds) * 1_000_000_000)
        let budgetTimer = Task { try? await Task.sleep(nanoseconds: budgetNanoseconds) }
        let completionWatcher = Task {
            await validationTask.value
            budgetTimer.cancel()
        }

        await budgetTimer.value

        // Whichever won, stop the rest: cancel the fetch loop (real URLSession fetches
        // honor cancellation and stop promptly; a non-cooperative one is simply left to
        // drain un-awaited — we've already read what it confirmed) and the watcher.
        validationTask.cancel()
        completionWatcher.cancel()

        // Strictly ordered close of the late-valid window: `sealAndSnapshot()` is ONE
        // atomic actor operation that both seals the collector (so any `recordValid`
        // that runs afterward is ignored) and returns the set confirmed valid up to
        // that instant. Together with the child's post-validate cancellation re-check,
        // this guarantees that once the budget fires no late `.valid` can be recorded —
        // so every not-yet-confirmed image is dropped to a placeholder (fail safe).
        let validSources = await confirmedValid.sealAndSnapshot()
        // Invalid = every extracted source that was NOT positively confirmed valid
        // by the moment we stopped waiting (fail safe: unverified → dropped).
        return Set(sourceURLStrings).subtracting(validSources)
    }

    /// Runs the per-image fetches with bounded concurrency, recording each source
    /// that comes back `.valid` into `confirmedValid`. Honors cancellation (the
    /// overall-budget timer cancels this task) — the in-flight group is torn down
    /// and no further fetches start, so partial results are preserved.
    private static func runBoundedValidation(
        sourceURLStrings: [String],
        validator: ImageURLValidating,
        maximumConcurrentValidations: Int,
        confirmedValid: ConfirmedValidSourceCollector
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var sourceIterator = sourceURLStrings.makeIterator()
            var runningCount = 0

            func startNextValidationIfAvailable() {
                guard let sourceURLString = sourceIterator.next() else { return }
                runningCount += 1
                group.addTask {
                    guard !Task.isCancelled else { return }
                    guard let imageURL = fetchableURL(fromSource: sourceURLString) else { return }
                    let result = await validator.validate(imageURL: imageURL)
                    // Re-check cancellation AFTER the fetch returns and BEFORE recording:
                    // if the overall budget fired while this validate() was in flight (the
                    // task tree is now cancelled), a `.valid` that arrived late must NOT be
                    // recorded — the image is dropped instead. The collector's seal is the
                    // second half of this guarantee for a non-cooperative validator.
                    guard !Task.isCancelled else { return }
                    if result == .valid {
                        await confirmedValid.recordValid(sourceURLString: sourceURLString)
                    }
                }
            }

            for _ in 0..<maximumConcurrentValidations {
                startNextValidationIfAvailable()
            }
            while runningCount > 0 {
                await group.next()
                runningCount -= 1
                if Task.isCancelled { break }
                startNextValidationIfAvailable()
            }
            group.cancelAll()
        }
    }

    // MARK: Pure helpers

    /// Whether a raw `<img>` src string is a remote http/https source (the only kind
    /// this pass fetch-validates). Case-insensitive on the scheme.
    static func isRemoteHTTPImageSource(_ source: String) -> Bool {
        let lowered = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    /// Builds a fetchable `URL` from a raw src string, decoding the one HTML entity
    /// that routinely appears inside URLs (`&amp;` → `&`) so query strings parse.
    /// Returns nil for non-http(s) or unparseable sources.
    static func fetchableURL(fromSource source: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRemoteHTTPImageSource(trimmed) else { return nil }
        let decoded = trimmed.replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: decoded)
    }

    /// Extracts the raw `src` attribute value from a single `<img …>` tag string, or
    /// nil if there is none. Handles double-quoted, single-quoted, AND unquoted
    /// values (e.g. `src=https://…`). The RAW value is returned (not entity-decoded)
    /// so it matches the strings `extractImageSourceURLs` produced, which is how the
    /// rewrite keys off the invalid set.
    static func imageSourceURL(inImgTag imgTag: String) -> String? {
        guard let regex = sourceAttributeRegex else { return nil }
        let nsTag = imgTag as NSString
        guard let match = regex.firstMatch(
            in: imgTag,
            options: [],
            range: NSRange(location: 0, length: nsTag.length)
        ) else { return nil }
        // Group 2 = double-quoted value, group 3 = single-quoted value, group 4 =
        // unquoted value. Whichever matched is the src.
        for groupIndex in [2, 3, 4] {
            let range = match.range(at: groupIndex)
            if range.location != NSNotFound {
                return nsTag.substring(with: range)
            }
        }
        return nil
    }

    /// All `<img …>` tag substrings in `html`, in document order.
    private static func imageTags(inHTML html: String) -> [String] {
        guard let regex = imageTagRegex else { return [] }
        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: nsHTML.length)
        )
        return matches.map { nsHTML.substring(with: $0.range) }
    }

    /// Matches a whole `<img …>` tag (self-closing or not), case-insensitively.
    private static let imageTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
    }()

    /// Matches a `src="…"`, `src='…'`, or unquoted `src=…` attribute; group 2 =
    /// double-quoted value, group 3 = single-quoted value, group 4 = unquoted value
    /// (terminated by whitespace or the tag close).
    private static let sourceAttributeRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "\\bsrc\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))",
            options: [.caseInsensitive]
        )
    }()
}

// MARK: - Confirmed-valid collector (survives the budget-race cancellation)

/// A tiny actor accumulating the source strings positively confirmed as valid. It
/// lives OUTSIDE the racing tasks so that when the overall-budget timer cancels the
/// validation task, whatever was confirmed valid up to that moment is still readable
/// (everything else is then treated as invalid / dropped).
// Internal (not private) purely so the seal semantics — the core of the budget
// race fix — can be unit-tested directly and deterministically, without depending
// on task scheduling. Only used within this file in production.
actor ConfirmedValidSourceCollector {
    private var validSourceURLStrings: Set<String> = []
    /// Once sealed (at the moment the budget fires and we snapshot), no further
    /// `recordValid` is accepted — closing the window where a late `.valid` from a
    /// non-cooperative validator could slip in after the invalid set was computed.
    private var isSealed = false

    func recordValid(sourceURLString: String) {
        guard !isSealed else { return }
        validSourceURLStrings.insert(sourceURLString)
    }

    /// Atomically seals the collector and returns everything confirmed valid so far.
    /// Being one actor operation, it is strictly ordered against every `recordValid`:
    /// any record that runs after this returns is dropped by the seal.
    func sealAndSnapshot() -> Set<String> {
        isSealed = true
        return validSourceURLStrings
    }

    /// Test-only read of the current valid set that does NOT seal, so a test can
    /// observe whether a post-seal `recordValid` was (correctly) rejected. Inert in
    /// production — nothing calls it.
    func snapshotForTesting() -> Set<String> {
        validSourceURLStrings
    }
}

// MARK: - Production validator (real HTTP fetch, browser-like)

/// The production `ImageURLValidating`: a plain, timeout-bounded HTTP GET with a
/// browser-like User-Agent and a same-origin Referer. GET (not HEAD) because many
/// image hosts 403/405 a HEAD or a bare request but serve a normal GET; the Referer
/// set to the image's own origin gets past the common "same-site hotlinks only"
/// protection. An image counts as valid only on 200 + `image/*` + non-empty body
/// (`ResearchImageValidator.isValidImageResponse`). Any error/timeout → invalid.
struct URLSessionImageURLValidator: ImageURLValidating {
    private let perImageTimeoutSeconds: TimeInterval
    private let urlSession: URLSession

    /// A current desktop-Safari User-Agent so hosts that vary behavior by client
    /// serve the real image rather than a block page.
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    init(perImageTimeoutSeconds: TimeInterval = ResearchImageValidationConfig.default.perImageTimeoutSeconds) {
        self.perImageTimeoutSeconds = perImageTimeoutSeconds
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = perImageTimeoutSeconds
        configuration.timeoutIntervalForResource = perImageTimeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = true
        self.urlSession = URLSession(configuration: configuration)
    }

    func validate(imageURL: URL) async -> ImageValidationResult {
        var request = URLRequest(
            url: imageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: perImageTimeoutSeconds
        )
        request.httpMethod = "GET"
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        // A same-origin Referer (scheme://host/) satisfies the common hotlink guard
        // that only allows a host's own pages to embed its images.
        if let referer = Self.sameOriginReferer(forImageURL: imageURL) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return .invalid }
            let isValid = ResearchImageValidator.isValidImageResponse(
                statusCode: httpResponse.statusCode,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                bodyByteCount: data.count
            )
            return isValid ? .valid : .invalid
        } catch {
            return .invalid
        }
    }

    /// The image's own origin (`scheme://host[:port]/`) used as the Referer.
    private static func sameOriginReferer(forImageURL imageURL: URL) -> String? {
        guard var components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        if let port = components.port {
            return "\(scheme)://\(host):\(port)/"
        }
        return "\(scheme)://\(host)/"
    }
}
