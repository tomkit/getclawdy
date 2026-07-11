//
//  ResearchImageValidatorTests.swift
//  ClawdyTests
//
//  Covers the DETERMINISTIC image-LOCALIZATION pass that guarantees the research
//  deliverable never shows a broken remote image AND renders the exact bytes we
//  verified (no remote request at render time):
//   - the pure `<img src>` extraction (remote-only, deduped, in order),
//   - the validity predicate (200 + image/* + non-empty body → valid),
//   - the local filename + extension derivation (magic-byte sniff → Content-Type →
//     URL extension, stable per-source filename),
//   - the pure HTML rewrite (downloaded images → LOCAL `images/…` src, broken images
//     → inline placeholder, other markup untouched),
//   - and the time-bounded orchestrator driven through an INJECTED fake downloader so
//     no real network is used (download/fail mixes, budget fail-safe), including the
//     end-to-end on-disk localize (a good image is written to `images/` and its src is
//     rewritten to that local file).
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - Deterministic, network-free downloaders

/// A tiny valid-looking JPEG payload (real magic bytes) the fakes hand back for a
/// "good" image, so the pass writes a file whose extension sniffs to `jpg`.
private let fakeJPEGData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

/// A fake `ImageURLDownloading` that answers from a fixed map of absolute-string →
/// outcome, defaulting unknown URLs to `.failed`. Optionally records each URL it was
/// asked about and can simulate a slow response to exercise the overall budget.
private actor FakeImageDownloader: ImageURLDownloading {
    private let outcomesByAbsoluteString: [String: ImageDownloadOutcome]
    private let artificialDelayNanoseconds: UInt64
    private var requestedAbsoluteStrings: [String] = []

    init(
        outcomesByAbsoluteString: [String: ImageDownloadOutcome],
        artificialDelayNanoseconds: UInt64 = 0
    ) {
        self.outcomesByAbsoluteString = outcomesByAbsoluteString
        self.artificialDelayNanoseconds = artificialDelayNanoseconds
    }

    func downloadImage(from imageURL: URL) async -> ImageDownloadOutcome {
        if artificialDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: artificialDelayNanoseconds)
        }
        requestedAbsoluteStrings.append(imageURL.absoluteString)
        return outcomesByAbsoluteString[imageURL.absoluteString] ?? .failed
    }

    func requestedURLStrings() -> [String] { requestedAbsoluteStrings }
}

/// The adversary the budget fail-safe MUST defeat: a downloader that returns
/// `.downloaded` ONLY AFTER it observes its task was cancelled (i.e. its success
/// arrives just after the overall budget fires). Without the post-download
/// cancellation re-check + the collector seal, such a late payload would be recorded
/// and the image wrongly KEPT. It polls (swallowing cancellation on each sleep) so it
/// also models a non-cooperative downloader that ignores cancellation until it returns.
private actor ReturnsDownloadedAfterCancellationDownloader: ImageURLDownloading {
    func downloadImage(from imageURL: URL) async -> ImageDownloadOutcome {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms poll; swallows cancellation
        }
        // Cancellation observed — return a LATE payload, exactly what must be dropped.
        return .downloaded(data: fakeJPEGData, contentType: "image/jpeg")
    }
}

// MARK: - Pure `<img src>` extraction

struct ResearchImageExtractionTests {

    @Test func extractsRemoteImageSourcesInOrderAndDeduped() {
        let html = """
        <html><body>
          <img src="https://a.example/one.jpg" alt="one">
          <p>text</p>
          <img src='https://b.example/two.png'/>
          <img src="https://a.example/one.jpg">
          <img src="/local/relative.png">
          <img src="data:image/png;base64,AAAA">
        </body></html>
        """
        let sources = ResearchImageValidator.extractImageSourceURLs(fromHTML: html)
        // Only the two UNIQUE remote sources, in first-seen order; the duplicate, the
        // relative path, and the data URI are all excluded.
        #expect(sources == ["https://a.example/one.jpg", "https://b.example/two.png"])
    }

    @Test func extractsNothingFromAPageWithNoRemoteImages() {
        let html = "<html><body><img src=\"cat.png\"><img src=\"data:image/gif;base64,R0lGOD\"></body></html>"
        #expect(ResearchImageValidator.extractImageSourceURLs(fromHTML: html).isEmpty)
    }

    @Test func handlesUppercaseTagAndAttributeAndExtraWhitespace() {
        let html = "<BODY><IMG  SRC = \"https://x.example/pic.webp\"  width=\"200\"></BODY>"
        #expect(
            ResearchImageValidator.extractImageSourceURLs(fromHTML: html)
                == ["https://x.example/pic.webp"]
        )
    }

    @Test func handlesUnquotedSourceValues() {
        let html = "<div><img src=https://u.example/raw.jpg width=100><img src=https://u.example/two.png></div>"
        #expect(
            ResearchImageValidator.extractImageSourceURLs(fromHTML: html)
                == ["https://u.example/raw.jpg", "https://u.example/two.png"]
        )
    }
}

// MARK: - Validity predicate

struct ResearchImageValidityPredicateTests {

    @Test func twoHundredWithImageContentTypeAndNonEmptyBodyIsValid() {
        #expect(ResearchImageValidator.isValidImageResponse(
            statusCode: 200, contentType: "image/jpeg", bodyByteCount: 1234
        ))
        // Content-Type parameters are tolerated.
        #expect(ResearchImageValidator.isValidImageResponse(
            statusCode: 200, contentType: "image/png; charset=binary", bodyByteCount: 10
        ))
    }

    @Test func nonTwoHundredIsInvalid() {
        #expect(!ResearchImageValidator.isValidImageResponse(
            statusCode: 404, contentType: "image/jpeg", bodyByteCount: 1234
        ))
        #expect(!ResearchImageValidator.isValidImageResponse(
            statusCode: 403, contentType: "image/jpeg", bodyByteCount: 1234
        ))
    }

    @Test func nonImageContentTypeIsInvalid() {
        // A hotlink-block page served with 200 but as HTML must NOT count as an image.
        #expect(!ResearchImageValidator.isValidImageResponse(
            statusCode: 200, contentType: "text/html; charset=utf-8", bodyByteCount: 5000
        ))
        #expect(!ResearchImageValidator.isValidImageResponse(
            statusCode: 200, contentType: nil, bodyByteCount: 5000
        ))
    }

    @Test func emptyBodyIsInvalidEvenWith200AndImageType() {
        #expect(!ResearchImageValidator.isValidImageResponse(
            statusCode: 200, contentType: "image/jpeg", bodyByteCount: 0
        ))
    }
}

// MARK: - Local filename + extension derivation (pure)

struct ResearchImageLocalFileDerivationTests {

    @Test func sniffsCommonBinaryImageFormats() {
        #expect(ResearchImageValidator.sniffImageFileExtension(fromData: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(ResearchImageValidator.sniffImageFileExtension(
            fromData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ) == "png")
        #expect(ResearchImageValidator.sniffImageFileExtension(fromData: Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) == "gif")
        let webp = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
        #expect(ResearchImageValidator.sniffImageFileExtension(fromData: webp) == "webp")
    }

    @Test func sniffDoesNotMistakeAnHTMLBlockPageForAnImage() {
        // A text/HTML error page (even one that leads with "<") must NOT sniff as an
        // image, so an octet-stream-labeled block page is never localized.
        #expect(ResearchImageValidator.sniffImageFileExtension(fromData: Data("<!DOCTYPE html><html>…".utf8)) == nil)
        #expect(ResearchImageValidator.sniffImageFileExtension(fromData: Data("not an image at all".utf8)) == nil)
    }

    @Test func extensionPrefersTheSniffedBytesOverContentTypeAndURL() {
        // PNG bytes mislabeled as jpeg with a .gif URL → the sniff wins → png (so the
        // local file gets the extension that actually matches the bytes, which is what
        // lets the WKWebView render it).
        let fileExtension = ResearchImageValidator.localImageFileExtension(
            contentType: "image/jpeg",
            sourceURLString: "https://x.example/pic.gif",
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        )
        #expect(fileExtension == "png")
    }

    @Test func extensionFallsBackToContentTypeThenURLThenJpg() {
        // Unsniffable bytes → Content-Type mapping (parameters tolerated).
        #expect(ResearchImageValidator.localImageFileExtension(
            contentType: "image/webp; charset=binary",
            sourceURLString: "https://x.example/p",
            data: Data([0x01, 0x02, 0x03])
        ) == "webp")
        // Unsniffable + non-image Content-Type (octet-stream) → the URL's own extension.
        #expect(ResearchImageValidator.localImageFileExtension(
            contentType: "application/octet-stream",
            sourceURLString: "https://x.example/photo.PNG",
            data: Data([0x01, 0x02])
        ) == "png")
        // Nothing usable anywhere → a `jpg` last resort.
        #expect(ResearchImageValidator.localImageFileExtension(
            contentType: nil,
            sourceURLString: "https://x.example/noext",
            data: Data([0x01, 0x02])
        ) == "jpg")
    }

    @Test func contentTypeMappingCoversCommonImageTypes() {
        #expect(ResearchImageValidator.imageFileExtension(forContentType: "image/jpeg") == "jpg")
        #expect(ResearchImageValidator.imageFileExtension(forContentType: "image/svg+xml") == "svg")
        #expect(ResearchImageValidator.imageFileExtension(forContentType: "image/gif") == "gif")
        // A non-image type maps to nil.
        #expect(ResearchImageValidator.imageFileExtension(forContentType: "text/html") == nil)
    }

    @Test func localFileNameIsStableForTheSameSourceAndDiffersAcrossSources() {
        let first = ResearchImageValidator.localImageFileName(
            forSourceURLString: "https://x.example/a.jpg", fileExtension: "jpg"
        )
        let firstAgain = ResearchImageValidator.localImageFileName(
            forSourceURLString: "https://x.example/a.jpg", fileExtension: "jpg"
        )
        let second = ResearchImageValidator.localImageFileName(
            forSourceURLString: "https://x.example/b.jpg", fileExtension: "jpg"
        )
        #expect(first == firstAgain)   // deterministic per source URL
        #expect(first != second)       // distinct sources get distinct files
        #expect(first.hasPrefix("img-"))
        #expect(first.hasSuffix(".jpg"))
        // Filesystem-safe: no path separators that could escape the images/ directory.
        #expect(!first.contains("/"))
    }
}

// MARK: - Pure HTML rewrite (localize + placeholder)

struct ResearchImageRewriteTests {

    @Test func replacesOnlyTheInvalidImagesWithPlaceholders() {
        let html = """
        <div><img src="https://good.example/ok.jpg"><img src="https://bad.example/dead.png"></div>
        """
        let rewritten = ResearchImageValidator.rewriteHTMLLocalizingImages(
            html: html,
            localRelativePathBySource: [:],
            invalidSourceURLs: ["https://bad.example/dead.png"]
        )
        // The un-listed image survives verbatim.
        #expect(rewritten.contains("<img src=\"https://good.example/ok.jpg\">"))
        // The bad image is gone, replaced by the placeholder.
        #expect(!rewritten.contains("https://bad.example/dead.png"))
        #expect(rewritten.contains("Image unavailable"))
    }

    @Test func leavesHTMLUntouchedWhenNothingIsLocalizedOrInvalid() {
        let html = "<div><img src=\"https://good.example/ok.jpg\"></div>"
        let rewritten = ResearchImageValidator.rewriteHTMLLocalizingImages(
            html: html,
            localRelativePathBySource: [:],
            invalidSourceURLs: []
        )
        #expect(rewritten == html)
    }

    @Test func localizesADownloadedImageSourceToItsLocalPathPreservingOtherAttributes() {
        let html = "<div><img src=\"https://good.example/ok.jpg\" alt=\"a cat\" width=\"200\"></div>"
        let rewritten = ResearchImageValidator.rewriteHTMLLocalizingImages(
            html: html,
            localRelativePathBySource: ["https://good.example/ok.jpg": "images/img-abc123.jpg"],
            invalidSourceURLs: []
        )
        // The remote URL is gone; the src now points at the LOCAL file.
        #expect(!rewritten.contains("https://good.example/ok.jpg"))
        #expect(rewritten.contains("src=\"images/img-abc123.jpg\""))
        // The other attributes on the tag are preserved.
        #expect(rewritten.contains("alt=\"a cat\""))
        #expect(rewritten.contains("width=\"200\""))
    }

    @Test func localizesAndPlaceholdersInTheSamePass() {
        let html = """
        <div><img src="https://good.example/ok.jpg"><img src="https://bad.example/dead.png"></div>
        """
        let rewritten = ResearchImageValidator.rewriteHTMLLocalizingImages(
            html: html,
            localRelativePathBySource: ["https://good.example/ok.jpg": "images/img-ok.jpg"],
            invalidSourceURLs: ["https://bad.example/dead.png"]
        )
        #expect(rewritten.contains("src=\"images/img-ok.jpg\""))
        #expect(!rewritten.contains("https://good.example/ok.jpg"))
        #expect(!rewritten.contains("https://bad.example/dead.png"))
        #expect(rewritten.contains("Image unavailable"))
    }

    @Test func localizesAllOccurrencesOfARepeatedSource() {
        let html = """
        <img src="https://good.example/x.png"><p>mid</p><img src="https://good.example/x.png">
        """
        let rewritten = ResearchImageValidator.rewriteHTMLLocalizingImages(
            html: html,
            localRelativePathBySource: ["https://good.example/x.png": "images/img-x.png"],
            invalidSourceURLs: []
        )
        #expect(!rewritten.contains("https://good.example/x.png"))
        #expect(rewritten.contains("<p>mid</p>"))
        let localizedCount = rewritten.components(separatedBy: "src=\"images/img-x.png\"").count - 1
        #expect(localizedCount == 2)
    }

    @Test func localizesAnUnquotedSource() {
        let html = "<div><img src=https://good.example/raw.jpg width=100></div>"
        let rewritten = ResearchImageValidator.rewriteHTMLLocalizingImages(
            html: html,
            localRelativePathBySource: ["https://good.example/raw.jpg": "images/img-raw.jpg"],
            invalidSourceURLs: []
        )
        // The unquoted remote src is normalized to a quoted local src; width preserved.
        #expect(!rewritten.contains("https://good.example/raw.jpg"))
        #expect(rewritten.contains("src=\"images/img-raw.jpg\""))
        #expect(rewritten.contains("width=100"))
    }

    @Test func placeholderIsSelfContainedInlineOnly() {
        let placeholder = ResearchImageValidator.brokenImagePlaceholderHTML
        #expect(placeholder.contains("style="))
        #expect(!placeholder.lowercased().contains("http://"))
        #expect(!placeholder.lowercased().contains("https://"))
        #expect(!placeholder.lowercased().contains("<script"))
    }
}

// MARK: - Collector seal semantics (deterministic, scheduler-independent)

struct ConfirmedDownloadedImageCollectorSealTests {

    /// The core of the budget race fix, proven WITHOUT any scheduling dependency:
    /// a record made BEFORE the seal is returned by `sealAndSnapshot()`, and a record
    /// made AFTER the seal is REJECTED. Against a collector lacking the `isSealed`
    /// guard, the post-seal record would wrongly appear.
    @Test func sealRejectsPostSealRecordsAndReturnsExactlyThePreSealMap() async {
        let collector = ConfirmedDownloadedImageCollector()

        // Recorded BEFORE the seal → must be in the sealed snapshot.
        await collector.recordDownloaded(
            sourceURLString: "https://a.example/pre.jpg",
            payload: DownloadedImagePayload(data: fakeJPEGData, contentType: "image/jpeg")
        )

        let sealedSnapshot = await collector.sealAndSnapshot()
        #expect(Set(sealedSnapshot.keys) == ["https://a.example/pre.jpg"])

        // Recorded AFTER the seal → must be ignored.
        await collector.recordDownloaded(
            sourceURLString: "https://b.example/post.jpg",
            payload: DownloadedImagePayload(data: Data([0x01]), contentType: nil)
        )

        let afterSeal = await collector.snapshotForTesting()
        #expect(afterSeal.keys.contains("https://a.example/pre.jpg"))
        #expect(!afterSeal.keys.contains("https://b.example/post.jpg"))
        // The map is unchanged by the rejected post-seal record.
        #expect(Set(afterSeal.keys) == Set(sealedSnapshot.keys))
    }
}

// MARK: - Time-bounded orchestrator (through the injected fake)

struct ResearchImageLocalizationOrchestratorTests {

    @Test func downloadedMapIsEveryConfirmedSource() async {
        let fake = FakeImageDownloader(outcomesByAbsoluteString: [
            "https://good.example/a.jpg": .downloaded(data: fakeJPEGData, contentType: "image/jpeg"),
            "https://bad.example/b.jpg": .failed,
        ])
        let downloads = await ResearchImageValidator.downloadImageSources(
            sourceURLStrings: [
                "https://good.example/a.jpg",
                "https://bad.example/b.jpg",
                "https://unknown.example/c.jpg", // defaults to .failed
            ],
            downloader: fake,
            config: .default
        )
        // Only the single confirmed download; the failed + unknown are absent (the
        // caller drops them to placeholders).
        #expect(Set(downloads.keys) == ["https://good.example/a.jpg"])
    }

    @Test func ampersandEntitiesAreDecodedWhenFetching() async {
        // The raw src carries `&amp;`; the fetch must decode it to `&` so the real URL
        // is downloaded, but the map key stays the RAW src (so the rewrite matches).
        let rawSource = "https://img.example/p?a=1&amp;b=2"
        let decodedAbsolute = "https://img.example/p?a=1&b=2"
        let fake = FakeImageDownloader(outcomesByAbsoluteString: [
            decodedAbsolute: .downloaded(data: fakeJPEGData, contentType: "image/jpeg"),
        ])
        let downloads = await ResearchImageValidator.downloadImageSources(
            sourceURLStrings: [rawSource],
            downloader: fake,
            config: .default
        )
        #expect(Set(downloads.keys) == [rawSource])
        let asked = await fake.requestedURLStrings()
        #expect(asked == [decodedAbsolute])
    }

    @Test func budgetFailSafeDropsUnverifiedImages() async {
        // A downloader that never returns within the budget → the image is dropped
        // (absent from the map) rather than hanging the run.
        let fake = FakeImageDownloader(
            outcomesByAbsoluteString: [
                "https://slow.example/z.jpg": .downloaded(data: fakeJPEGData, contentType: "image/jpeg"),
            ],
            artificialDelayNanoseconds: 5_000_000_000 // 5s, far past the 100ms budget
        )
        var config = ResearchImageValidationConfig.default
        config.totalBudgetSeconds = 0.1
        let downloads = await ResearchImageValidator.downloadImageSources(
            sourceURLStrings: ["https://slow.example/z.jpg"],
            downloader: fake,
            config: config
        )
        #expect(downloads.isEmpty)
    }

    @Test func lateDownloadAfterBudgetIsDroppedNotKept() async {
        // A downloader whose payload arrives only AFTER the budget cancels the run. The
        // post-download cancellation re-check + the collector seal must ensure that late
        // payload is NOT recorded, so all these images are DROPPED.
        let adversary = ReturnsDownloadedAfterCancellationDownloader()
        var config = ResearchImageValidationConfig.default
        config.totalBudgetSeconds = 0.1
        let sources = [
            "https://a.example/1.jpg",
            "https://a.example/2.jpg",
            "https://a.example/3.jpg",
            "https://a.example/4.jpg",
            "https://a.example/5.jpg",
            "https://a.example/6.jpg",
        ]
        let downloads = await ResearchImageValidator.downloadImageSources(
            sourceURLStrings: sources,
            downloader: adversary,
            config: config
        )
        // NONE of the late payloads survived.
        #expect(downloads.isEmpty)
    }

    @Test func validateAndRewriteLocalizesGoodImagesAndPlaceholdersBrokenOnDisk() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-imgval-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let reportURL = temporaryDirectory.appendingPathComponent("report.html")
        let goodSource = "https://good.example/ok.jpg"
        let badSource = "https://bad.example/dead.png"
        let html = """
        <html><body>
          <img src="\(goodSource)">
          <img src="\(badSource)">
        </body></html>
        """
        try html.write(to: reportURL, atomically: true, encoding: .utf8)

        let downloader = FakeImageDownloader(outcomesByAbsoluteString: [
            goodSource: .downloaded(data: fakeJPEGData, contentType: "image/jpeg"),
            badSource: .failed,
        ])
        await ResearchImageValidator.validateAndRewriteDeliverable(
            fileURL: reportURL,
            downloader: downloader,
            config: .default
        )

        let rewritten = try String(contentsOf: reportURL, encoding: .utf8)

        // The good image was LOCALIZED: the remote URL is gone and the src now points at
        // the stable local file under images/.
        #expect(!rewritten.contains(goodSource))
        let expectedLocalName = ResearchImageValidator.localImageFileName(
            forSourceURLString: goodSource, fileExtension: "jpg"
        )
        #expect(rewritten.contains("images/\(expectedLocalName)"))

        // …and that local file actually exists on disk under the read-access output dir,
        // with the downloaded bytes.
        let imagesDirectory = temporaryDirectory.appendingPathComponent("images", isDirectory: true)
        let localImageURL = imagesDirectory.appendingPathComponent(expectedLocalName)
        #expect(FileManager.default.fileExists(atPath: localImageURL.path))
        let writtenBytes = try Data(contentsOf: localImageURL)
        #expect(writtenBytes == fakeJPEGData)

        // The broken image is gone, replaced by the inline placeholder.
        #expect(!rewritten.contains(badSource))
        #expect(rewritten.contains("Image unavailable"))
    }

    @Test func validateAndRewriteDerivesTheExtensionFromContentTypeWhenBytesAreUnsniffable() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-imgval-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let reportURL = temporaryDirectory.appendingPathComponent("report.html")
        // A source with no image extension; the bytes don't sniff → extension must come
        // from the Content-Type (webp).
        let source = "https://cdn.example/asset?id=42"
        try "<img src=\"\(source)\">".write(to: reportURL, atomically: true, encoding: .utf8)

        let downloader = FakeImageDownloader(outcomesByAbsoluteString: [
            source: .downloaded(data: Data([0x01, 0x02, 0x03, 0x04]), contentType: "image/webp"),
        ])
        await ResearchImageValidator.validateAndRewriteDeliverable(
            fileURL: reportURL,
            downloader: downloader,
            config: .default
        )

        let expectedLocalName = ResearchImageValidator.localImageFileName(
            forSourceURLString: source, fileExtension: "webp"
        )
        let rewritten = try String(contentsOf: reportURL, encoding: .utf8)
        #expect(rewritten.contains("images/\(expectedLocalName)"))
        #expect(expectedLocalName.hasSuffix(".webp"))
        let localImageURL = temporaryDirectory
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(expectedLocalName)
        #expect(FileManager.default.fileExists(atPath: localImageURL.path))
    }

    @Test func validateAndRewriteIsANoOpWhenNoRemoteImages() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-imgval-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let reportURL = temporaryDirectory.appendingPathComponent("report.html")
        let html = "<html><body><p>No images here.</p></body></html>"
        try html.write(to: reportURL, atomically: true, encoding: .utf8)

        let downloader = FakeImageDownloader(outcomesByAbsoluteString: [:])
        await ResearchImageValidator.validateAndRewriteDeliverable(
            fileURL: reportURL,
            downloader: downloader,
            config: .default
        )
        let after = try String(contentsOf: reportURL, encoding: .utf8)
        #expect(after == html)
        // No images/ directory is created when there's nothing to localize.
        #expect(!FileManager.default.fileExists(
            atPath: temporaryDirectory.appendingPathComponent("images").path
        ))
    }
}
