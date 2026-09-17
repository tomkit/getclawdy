//
//  ResearchImageValidator.swift
//  Clawdy
//
//  The DETERMINISTIC image-localization pass for the research deliverable. The
//  execute phase writes a self-contained report.html that, for photo/gallery
//  tasks, embeds REMOTE `<img src="https://…">` URLs the model found while
//  researching. Those remote URLs frequently DON'T render when the finished page
//  is later opened from a `file://` origin in the results WKWebView: hotlink /
//  Referer-protected hosts 403 the render-time request (the browser sends no
//  same-origin Referer), guessed thumbnail sizes 404, and so on. A rendered page
//  full of broken-image icons is the failure this pass exists to prevent.
//
//  The fix is DOWNLOAD-AND-LOCALIZE (not just "check and drop broken ones"):
//  after the execute (or an iterate follow-up) writes report.html, we PARSE every
//  `<img>` src, actually FETCH each remote one ONCE from the app (with a
//  browser-like User-Agent + same-origin Referer that gets past hotlink guards),
//  and — for every image that comes back a real, non-empty image — PERSIST the
//  downloaded bytes to an `images/` subdirectory next to report.html and REWRITE
//  that `<img src>` to the LOCAL relative file path. The page the user sees then
//  references LOCAL files and makes NO remote request at render time, so "we
//  verified it downloads" is literally the same bytes that render — eliminating
//  the hotlink/Referer, thumbnail-404, Content-Type, and per-view-timeout failure
//  modes at once. Any image that CAN'T be downloaded (dead link, non-image, empty
//  body, or the fetch times out) is swapped in-place for a tasteful inline "Image
//  unavailable" placeholder styled in Clawdy red, so the displayed page never
//  shows a browser broken-image icon. The rewritten page stays self-contained
//  within the session directory (only local `images/…` files + the inline
//  placeholder; no CDN/JS/remote assets). The results WKWebView already grants
//  read access to the output directory, and `images/` lives under it, so the local
//  paths resolve.
//
//  This is plain HTTP fetching from the app itself — NOT the CLI/subscription
//  billing path, no API keys, no `--bare`. It is TIME-BOUNDED (a per-image timeout
//  AND an overall budget) so it can never hang a research run: if localization runs
//  out of time, un-downloaded images are dropped to placeholders (fail safe) rather
//  than blocking, and the rest of the page is left intact.
//
//  Everything HTML/derivation-shaped here (extraction, the validity predicate, the
//  local filename + extension derivation, the rewrite) is a PURE static function so
//  it is unit-tested with no network; the actual fetch sits behind the injectable
//  `ImageURLDownloading` seam.
//

import Foundation

// MARK: - Download seam (injectable so tests never touch the network)

/// The outcome of downloading a single remote image URL. On success it carries the
/// downloaded bytes AND the response Content-Type, which the pass uses to persist
/// the image to disk with the correct file extension.
enum ImageDownloadOutcome: Sendable, Equatable {
    /// The URL returned a real, non-empty image; the bytes are ready to persist.
    case downloaded(data: Data, contentType: String?)
    /// The URL could not be downloaded as an image (dead link, non-image, empty
    /// body, timeout, or any error).
    case failed
}

/// The injectable fetch seam. Production is `URLSessionImageDownloader`; tests
/// inject a deterministic fake keyed by URL so no real network is used.
nonisolated protocol ImageURLDownloading: Sendable {
    func downloadImage(from imageURL: URL) async -> ImageDownloadOutcome
}

/// A successfully-downloaded image held in memory until the pass writes it to the
/// `images/` subdirectory. The Content-Type is retained so the on-disk file gets the
/// right extension even when the source URL has none.
struct DownloadedImagePayload: Sendable, Equatable {
    let data: Data
    let contentType: String?
}

/// Time / concurrency caps for the localization pass. Chosen so the pass can never
/// hang a research run: each image has its own timeout, and the whole pass is
/// bounded by `totalBudgetSeconds` after which any not-yet-downloaded image is
/// dropped to a placeholder rather than waited on.
struct ResearchImageValidationConfig: Sendable {
    /// Per-image request timeout. Many image hosts are slow or hang; this bounds
    /// each individual fetch.
    var perImageTimeoutSeconds: TimeInterval = 8
    /// Hard ceiling on the ENTIRE localization pass across all images. When it
    /// elapses, in-flight and not-yet-started fetches are cancelled and their
    /// images are treated as broken (dropped to a placeholder — fail safe, don't hang).
    var totalBudgetSeconds: TimeInterval = 30
    /// How many image fetches run at once. Bounds memory / socket use for a large
    /// gallery while still overlapping the (network-bound) requests.
    var maximumConcurrentValidations: Int = 6

    static let `default` = ResearchImageValidationConfig()
}

// MARK: - The pass (pure HTML/derivation logic + a time-bounded orchestrator)

enum ResearchImageValidator {

    /// The subdirectory, relative to report.html, where downloaded images are
    /// written and referenced from (`images/<file>`). Lives UNDER the output
    /// directory the results WKWebView grants read access to, so the local paths
    /// resolve at render time.
    static let localImagesSubdirectoryName = "images"

    // MARK: Pure HTML parsing

    /// Extracts the UNIQUE remote (http/https) image source URLs embedded in `html`,
    /// in first-seen order. `data:` URIs and relative/other-scheme sources are
    /// deliberately EXCLUDED — they are either already self-contained (data URIs) or
    /// not something we can fetch, so the pass leaves them untouched.
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
    /// with 200, or an empty body all fail. (A host that mislabels an image as
    /// `application/octet-stream` is handled separately by byte-sniffing in the
    /// downloader, so a genuine image still localizes.)
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

    /// Rewrites `html`, LOCALIZING every `<img>` whose src was downloaded (its src is
    /// swapped for the local `images/…` relative path in `localRelativePathBySource`,
    /// preserving the rest of the tag — alt/width/etc.) and replacing every `<img>`
    /// whose src is in `invalidSourceURLs` with the inline "Image unavailable"
    /// placeholder. Images in NEITHER set (data URIs, relative sources) and all other
    /// markup are left byte-for-byte untouched, so layout and the rest of the content
    /// are preserved. The result stays self-contained (local files + inline placeholder).
    static func rewriteHTMLLocalizingImages(
        html: String,
        localRelativePathBySource: [String: String],
        invalidSourceURLs: Set<String>
    ) -> String {
        guard !localRelativePathBySource.isEmpty || !invalidSourceURLs.isEmpty else { return html }

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
            guard let source = imageSourceURL(inImgTag: imgTag) else { continue }
            guard let swiftRange = Range(match.range, in: rewritten) else { continue }
            if let localRelativePath = localRelativePathBySource[source] {
                let localizedTag = rewriteImageSource(inImgTag: imgTag, toLocalPath: localRelativePath)
                rewritten.replaceSubrange(swiftRange, with: localizedTag)
            } else if invalidSourceURLs.contains(source) {
                rewritten.replaceSubrange(swiftRange, with: brokenImagePlaceholderHTML)
            }
        }
        return rewritten
    }

    /// Rewrites a single `<img …>` tag so its `src` becomes `localPath`, preserving
    /// every other attribute (alt, width, class, style, …). Replaces the entire
    /// `src=…` region (however it was quoted) with a normalized double-quoted
    /// `src="localPath"`; `localPath` is our own filesystem-safe `images/…` string
    /// (no quotes or spaces), so no escaping is needed.
    static func rewriteImageSource(inImgTag imgTag: String, toLocalPath localPath: String) -> String {
        guard let regex = sourceAttributeRegex else { return imgTag }
        let nsTag = imgTag as NSString
        guard let match = regex.firstMatch(
            in: imgTag,
            options: [],
            range: NSRange(location: 0, length: nsTag.length)
        ) else { return imgTag }
        return nsTag.replacingCharacters(in: match.range, with: "src=\"\(localPath)\"")
    }

    /// The inline-styled placeholder that replaces a broken image. Styled in OpenClaw
    /// red (#E5342B border, #C42B22 deeper-red text on a light #FDECEA red tint) and
    /// entirely self-contained (inline style only) so the page needs no external assets.
    static let brokenImagePlaceholderHTML: String = """
    <span style="display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;min-width:140px;min-height:100px;max-width:100%;padding:14px 18px;margin:2px;border:1px solid #E5342B;border-radius:10px;background:#FDECEA;color:#C42B22;font-family:-apple-system,system-ui,'Segoe UI',sans-serif;font-size:12px;font-weight:600;line-height:1.35;text-align:center;">Image unavailable</span>
    """

    // MARK: Local filename + extension derivation (pure)

    /// A STABLE, filesystem-safe local filename for the image downloaded from
    /// `sourceURLString`: `img-<deterministic-hash>.<ext>`. Deterministic in the
    /// source URL (same URL → same filename across runs, so a re-localize overwrites
    /// rather than accumulating duplicates) and free of any characters that could
    /// escape the `images/` directory or break the `<img src>`.
    static func localImageFileName(forSourceURLString sourceURLString: String, fileExtension: String) -> String {
        "img-\(deterministicHashHex(ofString: sourceURLString)).\(fileExtension)"
    }

    /// A deterministic 64-bit FNV-1a hash of `string`, hex-encoded. Used to name the
    /// local image file stably from its source URL. NOT Swift's `hashValue` — that is
    /// randomized per process launch, which would give the same URL a different
    /// filename every run.
    static func deterministicHashHex(ofString string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV offset basis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x00000100000001B3 // FNV prime
        }
        return String(hash, radix: 16)
    }

    /// Derives the correct on-disk file extension for a downloaded image, most-reliable
    /// signal first: the actual bytes (magic-number sniff) → the response Content-Type
    /// → the source URL's own path extension → a `jpg` last resort. Getting this right
    /// matters because the results WKWebView infers a LOCAL file's type from its
    /// extension, so a PNG written as `.jpg` (or with no extension) may not render.
    static func localImageFileExtension(
        contentType: String?,
        sourceURLString: String,
        data: Data
    ) -> String {
        if let sniffed = sniffImageFileExtension(fromData: data) { return sniffed }
        if let fromContentType = imageFileExtension(forContentType: contentType) { return fromContentType }
        if let fromURL = knownImageFileExtension(inURLString: sourceURLString) { return fromURL }
        return "jpg"
    }

    /// Recognizes a known BINARY image format from its leading magic bytes and returns
    /// the canonical file extension, or nil if the bytes aren't a recognized image.
    /// Deliberately binary-only (no text-based SVG) so an HTML error page served as
    /// `octet-stream` can never be mistaken for an image and localized.
    static func sniffImageFileExtension(fromData data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        func startsWith(_ prefix: [UInt8]) -> Bool {
            guard bytes.count >= prefix.count else { return false }
            for index in 0..<prefix.count where bytes[index] != prefix[index] { return false }
            return true
        }
        if startsWith([0xFF, 0xD8, 0xFF]) { return "jpg" }                               // JPEG
        if startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" } // PNG
        if startsWith([0x47, 0x49, 0x46]) { return "gif" }                               // "GIF"
        if startsWith([0x42, 0x4D]) { return "bmp" }                                     // "BM"
        // WEBP: "RIFF" …4 size bytes… "WEBP"
        if bytes.count >= 12,
           startsWith([0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }
        // ISO-BMFF ("....ftyp<brand>") covers AVIF and HEIC/HEIF.
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("avif") || brand.hasPrefix("avis") { return "avif" }
            if brand.hasPrefix("heic") || brand.hasPrefix("heix")
                || brand.hasPrefix("heif") || brand.hasPrefix("mif1") { return "heic" }
        }
        if startsWith([0x00, 0x00, 0x01, 0x00]) { return "ico" }                         // ICO
        if startsWith([0x49, 0x49, 0x2A, 0x00]) || startsWith([0x4D, 0x4D, 0x00, 0x2A]) { // TIFF
            return "tiff"
        }
        return nil
    }

    /// Maps a response Content-Type to a canonical image file extension, or nil when
    /// it isn't an `image/*` type we recognize.
    static func imageFileExtension(forContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        let mediaType = String(
            contentType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(separator: ";")
                .first ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        switch mediaType {
        case "image/jpeg", "image/jpg", "image/pjpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml", "image/svg": return "svg"
        case "image/avif": return "avif"
        case "image/bmp", "image/x-ms-bmp", "image/x-bmp": return "bmp"
        case "image/x-icon", "image/vnd.microsoft.icon", "image/ico": return "ico"
        case "image/tiff", "image/x-tiff": return "tiff"
        case "image/heic", "image/heif": return "heic"
        default:
            // An unrecognized but declared `image/<subtype>` → use the leading
            // alphanumeric run of the subtype as a best-effort extension.
            guard mediaType.hasPrefix("image/") else { return nil }
            let subtype = mediaType.dropFirst("image/".count)
            let token = subtype.prefix { $0.isLetter || $0.isNumber }
            return token.isEmpty ? nil : String(token)
        }
    }

    /// The known-image file extension of a source URL's own path, normalized (`jpeg`
    /// → `jpg`, `tif` → `tiff`), or nil when the URL has no recognized image extension.
    static func knownImageFileExtension(inURLString urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let ext = url.pathExtension.lowercased()
        let known: Set<String> = [
            "jpg", "jpeg", "png", "gif", "webp", "svg", "avif", "bmp", "ico", "tiff", "tif", "heic", "heif"
        ]
        guard known.contains(ext) else { return nil }
        if ext == "jpeg" { return "jpg" }
        if ext == "tif" { return "tiff" }
        return ext
    }

    // MARK: Time-bounded orchestration (impure — reads/writes files, uses the seam)

    /// Reads `fileURL` (report.html), downloads every embedded remote image via
    /// `downloader`, PERSISTS each one that downloads to an `images/` subdirectory
    /// next to report.html, and rewrites the file in place so downloaded images point
    /// at their LOCAL path and un-downloadable ones become placeholders. A no-op when
    /// the page has no remote images or the file can't be read. TIME-BOUNDED by
    /// `config` so it can never hang the research run; on the budget elapsing,
    /// un-downloaded images are dropped to placeholders (fail safe) rather than waited
    /// on. Never throws — a failure to read/write leaves the on-disk page as-is.
    static func validateAndRewriteDeliverable(
        fileURL: URL,
        downloader: ImageURLDownloading,
        config: ResearchImageValidationConfig = .default
    ) async {
        guard let originalHTML = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let sourceURLs = extractImageSourceURLs(fromHTML: originalHTML)
        guard !sourceURLs.isEmpty else { return }

        let downloadsBySource = await downloadImageSources(
            sourceURLStrings: sourceURLs,
            downloader: downloader,
            config: config
        )

        // Persist each successfully-downloaded image next to report.html and build the
        // source → local-relative-path map that drives the rewrite. A source that
        // downloaded but can't be written to disk is treated as broken (placeholder).
        let imagesDirectory = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(localImagesSubdirectoryName, isDirectory: true)
        var localRelativePathBySource: [String: String] = [:]
        if !downloadsBySource.isEmpty {
            try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            for (sourceURLString, payload) in downloadsBySource {
                let fileExtension = localImageFileExtension(
                    contentType: payload.contentType,
                    sourceURLString: sourceURLString,
                    data: payload.data
                )
                let fileName = localImageFileName(
                    forSourceURLString: sourceURLString,
                    fileExtension: fileExtension
                )
                let imageFileURL = imagesDirectory.appendingPathComponent(fileName, isDirectory: false)
                do {
                    try payload.data.write(to: imageFileURL, options: .atomic)
                    localRelativePathBySource[sourceURLString] = "\(localImagesSubdirectoryName)/\(fileName)"
                } catch {
                    // Couldn't persist locally — leave this source for a placeholder.
                }
            }
        }

        // Every extracted remote source we did NOT localize (failed download OR failed
        // write) is broken → placeholder.
        let invalidSourceURLs = Set(sourceURLs).subtracting(localRelativePathBySource.keys)

        let rewrittenHTML = rewriteHTMLLocalizingImages(
            html: originalHTML,
            localRelativePathBySource: localRelativePathBySource,
            invalidSourceURLs: invalidSourceURLs
        )
        // Only rewrite the file if the transform actually changed something.
        guard rewrittenHTML != originalHTML else { return }
        try? rewrittenHTML.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Downloads the given image source strings concurrently (bounded) under an overall
    /// time budget and returns the map of source string → downloaded payload for every
    /// one that came back a real image. Any source NOT downloaded within the budget —
    /// because it failed, timed out, wasn't a fetchable URL, or the budget elapsed
    /// before it finished — is simply absent from the returned map (the caller drops it
    /// to a placeholder: fail safe).
    static func downloadImageSources(
        sourceURLStrings: [String],
        downloader: ImageURLDownloading,
        config: ResearchImageValidationConfig
    ) async -> [String: DownloadedImagePayload] {
        let collector = ConfirmedDownloadedImageCollector()

        // The bounded fetch loop records each downloaded source into the actor collector
        // as it goes. It runs as an UNSTRUCTURED task so the overall-budget path can stop
        // WAITING on it without being forced (by structured concurrency) to join a slow
        // or non-cooperative downloader — that is what makes the wall-clock bound a hard
        // guarantee rather than a best effort.
        let downloadTask = Task {
            await runBoundedDownloads(
                sourceURLStrings: sourceURLStrings,
                downloader: downloader,
                maximumConcurrentValidations: max(1, config.maximumConcurrentValidations),
                collector: collector
            )
        }

        // A timer that fires after the total budget. A watcher cancels the timer the
        // moment downloading finishes, so the SOLE await below (`budgetTimer.value`)
        // returns as soon as EITHER downloading completes OR the budget elapses —
        // whichever comes first — and never blocks on the slow path.
        let budgetNanoseconds = UInt64(max(0, config.totalBudgetSeconds) * 1_000_000_000)
        let budgetTimer = Task { try? await Task.sleep(nanoseconds: budgetNanoseconds) }
        let completionWatcher = Task {
            await downloadTask.value
            budgetTimer.cancel()
        }

        await budgetTimer.value

        // Whichever won, stop the rest: cancel the fetch loop (real URLSession fetches
        // honor cancellation and stop promptly; a non-cooperative one is simply left to
        // drain un-awaited — we've already read what it recorded) and the watcher.
        downloadTask.cancel()
        completionWatcher.cancel()

        // Strictly ordered close of the late-download window: `sealAndSnapshot()` is ONE
        // atomic actor operation that both seals the collector (so any `recordDownloaded`
        // that runs afterward is ignored) and returns the map recorded up to that
        // instant. Together with the child's post-download cancellation re-check, this
        // guarantees that once the budget fires no late download can be recorded — so
        // every not-yet-downloaded image is dropped to a placeholder (fail safe).
        return await collector.sealAndSnapshot()
    }

    /// Runs the per-image fetches with bounded concurrency, recording each source that
    /// comes back downloaded into `collector`. Honors cancellation (the overall-budget
    /// timer cancels this task) — the in-flight group is torn down and no further
    /// fetches start, so partial results are preserved.
    private static func runBoundedDownloads(
        sourceURLStrings: [String],
        downloader: ImageURLDownloading,
        maximumConcurrentValidations: Int,
        collector: ConfirmedDownloadedImageCollector
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var sourceIterator = sourceURLStrings.makeIterator()
            var runningCount = 0

            func startNextDownloadIfAvailable() {
                guard let sourceURLString = sourceIterator.next() else { return }
                runningCount += 1
                group.addTask {
                    guard !Task.isCancelled else { return }
                    guard let imageURL = fetchableURL(fromSource: sourceURLString) else { return }
                    let outcome = await downloader.downloadImage(from: imageURL)
                    // Re-check cancellation AFTER the fetch returns and BEFORE recording:
                    // if the overall budget fired while this download was in flight (the
                    // task tree is now cancelled), a payload that arrived late must NOT be
                    // recorded — the image is dropped instead. The collector's seal is the
                    // second half of this guarantee for a non-cooperative downloader.
                    guard !Task.isCancelled else { return }
                    if case let .downloaded(data, contentType) = outcome {
                        await collector.recordDownloaded(
                            sourceURLString: sourceURLString,
                            payload: DownloadedImagePayload(data: data, contentType: contentType)
                        )
                    }
                }
            }

            for _ in 0..<maximumConcurrentValidations {
                startNextDownloadIfAvailable()
            }
            while runningCount > 0 {
                await group.next()
                runningCount -= 1
                if Task.isCancelled { break }
                startNextDownloadIfAvailable()
            }
            group.cancelAll()
        }
    }

    // MARK: Pure helpers

    /// Whether a raw `<img>` src string is a remote http/https source (the only kind
    /// this pass fetches). Case-insensitive on the scheme.
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
    /// rewrite keys off the source.
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

// MARK: - Downloaded-image collector (survives the budget-race cancellation)

/// A tiny actor accumulating the source strings positively downloaded (source →
/// payload). It lives OUTSIDE the racing tasks so that when the overall-budget timer
/// cancels the download task, whatever was downloaded up to that moment is still
/// readable (everything else is then treated as broken / dropped to a placeholder).
// Internal (not private) purely so the seal semantics — the core of the budget race
// fix — can be unit-tested directly and deterministically, without depending on task
// scheduling. Only used within this file in production.
actor ConfirmedDownloadedImageCollector {
    private var downloadsBySource: [String: DownloadedImagePayload] = [:]
    /// Once sealed (at the moment the budget fires and we snapshot), no further
    /// `recordDownloaded` is accepted — closing the window where a late payload from a
    /// non-cooperative downloader could slip in after the map was computed.
    private var isSealed = false

    func recordDownloaded(sourceURLString: String, payload: DownloadedImagePayload) {
        guard !isSealed else { return }
        downloadsBySource[sourceURLString] = payload
    }

    /// Atomically seals the collector and returns everything downloaded so far. Being
    /// one actor operation, it is strictly ordered against every `recordDownloaded`:
    /// any record that runs after this returns is dropped by the seal.
    func sealAndSnapshot() -> [String: DownloadedImagePayload] {
        isSealed = true
        return downloadsBySource
    }

    /// Test-only read of the current map that does NOT seal, so a test can observe
    /// whether a post-seal `recordDownloaded` was (correctly) rejected. Inert in
    /// production — nothing calls it.
    func snapshotForTesting() -> [String: DownloadedImagePayload] {
        downloadsBySource
    }
}

// MARK: - Production downloader (real HTTP fetch, browser-like)

/// The production `ImageURLDownloading`: a plain, timeout-bounded HTTP GET with a
/// browser-like User-Agent and a same-origin Referer. GET (not HEAD) because many
/// image hosts 403/405 a HEAD or a bare request but serve a normal GET; the Referer
/// set to the image's own origin gets past the common "same-site hotlinks only"
/// protection. An image counts as downloaded on 200 + non-empty body when it is
/// either an `image/*` response (`ResearchImageValidator.isValidImageResponse`) OR its
/// bytes sniff as a known binary image format (so a host mislabeling an image as
/// `application/octet-stream` still localizes). Any error/timeout → `.failed`.
struct URLSessionImageDownloader: ImageURLDownloading {
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

    func downloadImage(from imageURL: URL) async -> ImageDownloadOutcome {
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
            guard let httpResponse = response as? HTTPURLResponse else { return .failed }
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
            guard httpResponse.statusCode == 200, !data.isEmpty else { return .failed }
            // Accept a proper `image/*` response OR bytes that sniff as a known binary
            // image (covers hosts that mislabel images as `application/octet-stream`).
            let looksLikeImage = ResearchImageValidator.isValidImageResponse(
                statusCode: httpResponse.statusCode,
                contentType: contentType,
                bodyByteCount: data.count
            ) || ResearchImageValidator.sniffImageFileExtension(fromData: data) != nil
            return looksLikeImage ? .downloaded(data: data, contentType: contentType) : .failed
        } catch {
            return .failed
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
