//
//  ResearchImageValidatorTests.swift
//  ClawdyTests
//
//  Covers the DETERMINISTIC image-validation pass that guarantees the research
//  deliverable never shows a broken remote image:
//   - the pure `<img src>` extraction (remote-only, deduped, in order),
//   - the validity predicate (200 + image/* + non-empty body → valid),
//   - the pure HTML rewrite (broken images → inline placeholder, valid ones + other
//     markup untouched),
//   - and the time-bounded orchestrator driven through an INJECTED fake validator so
//     no real network is used (valid/invalid mixes, budget fail-safe).
//
//  The render-time WKWebView JS net (layer B) is not exercised here — it needs a live
//  eyeball in the running app.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - A deterministic, network-free validator

/// A fake `ImageURLValidating` that answers from a fixed map of absolute-string →
/// result, defaulting unknown URLs to `.invalid`. Optionally records each URL it was
/// asked about and can simulate a slow response to exercise the overall budget.
private actor FakeImageURLValidator: ImageURLValidating {
    private let resultsByAbsoluteString: [String: ImageValidationResult]
    private let artificialDelayNanoseconds: UInt64
    private var validatedAbsoluteStrings: [String] = []

    init(
        resultsByAbsoluteString: [String: ImageValidationResult],
        artificialDelayNanoseconds: UInt64 = 0
    ) {
        self.resultsByAbsoluteString = resultsByAbsoluteString
        self.artificialDelayNanoseconds = artificialDelayNanoseconds
    }

    func validate(imageURL: URL) async -> ImageValidationResult {
        if artificialDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: artificialDelayNanoseconds)
        }
        // Record via a nonisolated hop is unnecessary — we're already the actor.
        return await recordAndResult(for: imageURL.absoluteString)
    }

    private func recordAndResult(for absoluteString: String) -> ImageValidationResult {
        validatedAbsoluteStrings.append(absoluteString)
        return resultsByAbsoluteString[absoluteString] ?? .invalid
    }

    func validatedURLStrings() -> [String] { validatedAbsoluteStrings }
}

/// The adversary the budget fail-safe MUST defeat: a validator that returns `.valid`
/// ONLY AFTER it observes its task was cancelled (i.e. its success arrives just after
/// the overall budget fires). Without the post-validate cancellation re-check + the
/// collector seal, such a late `.valid` would be recorded and the image wrongly KEPT.
/// It polls (swallowing cancellation on each sleep) so it also models a non-cooperative
/// validator that ignores cancellation until it decides to return.
private actor ReturnsValidAfterCancellationValidator: ImageURLValidating {
    func validate(imageURL: URL) async -> ImageValidationResult {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms poll; swallows cancellation
        }
        // Cancellation observed — return a LATE valid, exactly what must be dropped.
        return .valid
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
        // A valid (if unusual) unquoted src must be covered by Layer A too, not left
        // for the render-time net alone.
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

// MARK: - Pure HTML rewrite

struct ResearchImageRewriteTests {

    @Test func replacesOnlyTheInvalidImagesWithPlaceholders() {
        let html = """
        <div><img src="https://good.example/ok.jpg"><img src="https://bad.example/dead.png"></div>
        """
        let rewritten = ResearchImageValidator.rewriteHTMLReplacingInvalidImages(
            html: html,
            invalidSourceURLs: ["https://bad.example/dead.png"]
        )
        // The good image survives verbatim.
        #expect(rewritten.contains("<img src=\"https://good.example/ok.jpg\">"))
        // The bad image is gone, replaced by the placeholder.
        #expect(!rewritten.contains("https://bad.example/dead.png"))
        #expect(rewritten.contains("Image unavailable"))
    }

    @Test func leavesHTMLUntouchedWhenNothingIsInvalid() {
        let html = "<div><img src=\"https://good.example/ok.jpg\"></div>"
        let rewritten = ResearchImageValidator.rewriteHTMLReplacingInvalidImages(
            html: html,
            invalidSourceURLs: []
        )
        #expect(rewritten == html)
    }

    @Test func replacesAllOccurrencesOfARepeatedBrokenSource() {
        let html = """
        <img src="https://bad.example/x.png"><p>mid</p><img src="https://bad.example/x.png">
        """
        let rewritten = ResearchImageValidator.rewriteHTMLReplacingInvalidImages(
            html: html,
            invalidSourceURLs: ["https://bad.example/x.png"]
        )
        #expect(!rewritten.contains("https://bad.example/x.png"))
        // The surrounding markup is preserved.
        #expect(rewritten.contains("<p>mid</p>"))
        // Both images became placeholders.
        let placeholderCount = rewritten.components(separatedBy: "Image unavailable").count - 1
        #expect(placeholderCount == 2)
    }

    @Test func replacesAnUnquotedBrokenSource() {
        let html = "<div><img src=https://bad.example/raw.jpg width=100></div>"
        let rewritten = ResearchImageValidator.rewriteHTMLReplacingInvalidImages(
            html: html,
            invalidSourceURLs: ["https://bad.example/raw.jpg"]
        )
        #expect(!rewritten.contains("https://bad.example/raw.jpg"))
        #expect(rewritten.contains("Image unavailable"))
        #expect(rewritten.contains("<div>"))
    }

    @Test func placeholderIsSelfContainedInlineOnly() {
        // The placeholder must not introduce any external dependency.
        let placeholder = ResearchImageValidator.brokenImagePlaceholderHTML
        #expect(placeholder.contains("style="))
        #expect(!placeholder.lowercased().contains("http://"))
        #expect(!placeholder.lowercased().contains("https://"))
        #expect(!placeholder.lowercased().contains("<script"))
    }
}

// MARK: - Collector seal semantics (deterministic, scheduler-independent)

struct ConfirmedValidSourceCollectorSealTests {

    /// The core of the budget race fix, proven WITHOUT any scheduling dependency:
    /// a record made BEFORE the seal is returned by `sealAndSnapshot()`, and a record
    /// made AFTER the seal is REJECTED. Against a collector lacking the `isSealed`
    /// guard, the post-seal record would wrongly appear — so this deterministically
    /// fails-before / passes-after for the seal mechanism itself.
    @Test func sealRejectsPostSealRecordsAndReturnsExactlyThePreSealSet() async {
        let collector = ConfirmedValidSourceCollector()

        // Recorded BEFORE the seal → must be in the sealed snapshot.
        await collector.recordValid(sourceURLString: "https://a.example/pre.jpg")

        let sealedSnapshot = await collector.sealAndSnapshot()
        #expect(sealedSnapshot == ["https://a.example/pre.jpg"])

        // Recorded AFTER the seal → must be ignored.
        await collector.recordValid(sourceURLString: "https://b.example/post.jpg")

        let afterSeal = await collector.snapshotForTesting()
        #expect(afterSeal.contains("https://a.example/pre.jpg"))
        #expect(!afterSeal.contains("https://b.example/post.jpg"))
        // The set is unchanged by the rejected post-seal record.
        #expect(afterSeal == sealedSnapshot)
    }
}

// MARK: - Time-bounded orchestrator (through the injected fake)

struct ResearchImageValidationOrchestratorTests {

    @Test func invalidSetIsEveryUnconfirmedSource() async {
        let fake = FakeImageURLValidator(resultsByAbsoluteString: [
            "https://good.example/a.jpg": .valid,
            "https://bad.example/b.jpg": .invalid,
        ])
        let invalid = await ResearchImageValidator.determineInvalidImageSourceURLs(
            sourceURLStrings: [
                "https://good.example/a.jpg",
                "https://bad.example/b.jpg",
                "https://unknown.example/c.jpg", // defaults to invalid
            ],
            validator: fake,
            config: .default
        )
        #expect(invalid == ["https://bad.example/b.jpg", "https://unknown.example/c.jpg"])
    }

    @Test func ampersandEntitiesAreDecodedWhenFetching() async {
        // The raw src carries `&amp;`; the fetch must decode it to `&` so the real URL
        // is validated, but the INVALID-set key stays the raw src (so the rewrite matches).
        let rawSource = "https://img.example/p?a=1&amp;b=2"
        let decodedAbsolute = "https://img.example/p?a=1&b=2"
        let fake = FakeImageURLValidator(resultsByAbsoluteString: [decodedAbsolute: .valid])
        let invalid = await ResearchImageValidator.determineInvalidImageSourceURLs(
            sourceURLStrings: [rawSource],
            validator: fake,
            config: .default
        )
        // The decoded URL validated as valid, so the raw source is NOT in the invalid set.
        #expect(invalid.isEmpty)
        let asked = await fake.validatedURLStrings()
        #expect(asked == [decodedAbsolute])
    }

    @Test func budgetFailSafeDropsUnverifiedImages() async {
        // A validator that never returns within the budget → the image is dropped
        // (treated invalid) rather than hanging the run.
        let fake = FakeImageURLValidator(
            resultsByAbsoluteString: ["https://slow.example/z.jpg": .valid],
            artificialDelayNanoseconds: 5_000_000_000 // 5s, far past the 100ms budget
        )
        var config = ResearchImageValidationConfig.default
        config.totalBudgetSeconds = 0.1
        let invalid = await ResearchImageValidator.determineInvalidImageSourceURLs(
            sourceURLStrings: ["https://slow.example/z.jpg"],
            validator: fake,
            config: config
        )
        #expect(invalid == ["https://slow.example/z.jpg"])
    }

    @Test func lateValidAfterBudgetIsDroppedNotKept() async {
        // A validator whose `.valid` result arrives only AFTER the budget cancels the
        // run. The post-validate cancellation re-check + the collector seal must ensure
        // that late `.valid` is NOT recorded, so all these images are DROPPED (invalid).
        // Fail-before/pass-after: against the pre-fix code (no re-check, no seal) a late
        // valid could be recorded before the snapshot and the image wrongly kept; with
        // the fix, every not-yet-confirmed image is dropped deterministically.
        let adversary = ReturnsValidAfterCancellationValidator()
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
        let invalid = await ResearchImageValidator.determineInvalidImageSourceURLs(
            sourceURLStrings: sources,
            validator: adversary,
            config: config
        )
        // EVERY source is dropped — none of the late valids survived.
        #expect(invalid == Set(sources))
    }

    @Test func validateAndRewriteReplacesBrokenImagesOnDisk() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-imgval-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let reportURL = temporaryDirectory.appendingPathComponent("report.html")
        let html = """
        <html><body>
          <img src="https://good.example/ok.jpg">
          <img src="https://bad.example/dead.png">
        </body></html>
        """
        try html.write(to: reportURL, atomically: true, encoding: .utf8)

        let fake = FakeImageURLValidator(resultsByAbsoluteString: [
            "https://good.example/ok.jpg": .valid,
            "https://bad.example/dead.png": .invalid,
        ])
        await ResearchImageValidator.validateAndRewriteDeliverable(
            fileURL: reportURL,
            validator: fake,
            config: .default
        )

        let rewritten = try String(contentsOf: reportURL, encoding: .utf8)
        #expect(rewritten.contains("https://good.example/ok.jpg"))
        #expect(!rewritten.contains("https://bad.example/dead.png"))
        #expect(rewritten.contains("Image unavailable"))
    }

    @Test func validateAndRewriteIsANoOpWhenNoRemoteImages() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-imgval-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let reportURL = temporaryDirectory.appendingPathComponent("report.html")
        let html = "<html><body><p>No images here.</p></body></html>"
        try html.write(to: reportURL, atomically: true, encoding: .utf8)

        let fake = FakeImageURLValidator(resultsByAbsoluteString: [:])
        await ResearchImageValidator.validateAndRewriteDeliverable(
            fileURL: reportURL,
            validator: fake,
            config: .default
        )
        let after = try String(contentsOf: reportURL, encoding: .utf8)
        #expect(after == html)
    }
}
