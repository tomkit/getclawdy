//
//  JSONLineDecodingTests.swift
//  ClawdyTests
//
//  Headless unit tests for the shared `decodeJSONLine` NDJSON/JSONL line decoder
//  that ClaudeStreamEvent, ResearchStreamParser, CodexEngine, and TranscriptParser
//  all build their per-line parsing on. Locks in the exact pre-existing semantics:
//  trim whitespace/newlines, skip blanks, reject non-UTF-8 and non-object JSON.
//

import Testing
import Foundation
@testable import Clawdy

struct JSONLineDecodingTests {

    // MARK: - Valid objects

    @Test func decodesAValidJSONObject() {
        let decoded = decodeJSONLine("{\"type\":\"result\",\"is_error\":false}")
        #expect(decoded?["type"] as? String == "result")
        #expect(decoded?["is_error"] as? Bool == false)
    }

    @Test func trimsLeadingAndTrailingWhitespaceAndNewlinesBeforeDecoding() {
        let decoded = decodeJSONLine("  \n\t {\"key\":\"value\"}\r\n  ")
        #expect(decoded?["key"] as? String == "value")
    }

    @Test func decodesAnEmptyObject() {
        let decoded = decodeJSONLine("{}")
        #expect(decoded != nil)
        #expect(decoded?.isEmpty == true)
    }

    // MARK: - Blank / whitespace lines return nil

    @Test func returnsNilForAnEmptyString() {
        #expect(decodeJSONLine("") == nil)
    }

    @Test func returnsNilForAWhitespaceAndNewlineOnlyLine() {
        #expect(decodeJSONLine("   \n\t\r\n  ") == nil)
    }

    // MARK: - Invalid JSON returns nil

    @Test func returnsNilForSyntacticallyInvalidJSON() {
        #expect(decodeJSONLine("{not valid json") == nil)
    }

    @Test func returnsNilForATrailingGarbageLine() {
        #expect(decodeJSONLine("{\"a\":1} trailing") == nil)
    }

    // MARK: - Valid JSON that is not a top-level object returns nil

    @Test func returnsNilForABareArray() {
        #expect(decodeJSONLine("[1, 2, 3]") == nil)
    }

    @Test func returnsNilForABareNumber() {
        #expect(decodeJSONLine("42") == nil)
    }

    @Test func returnsNilForABareString() {
        #expect(decodeJSONLine("\"just a string\"") == nil)
    }

    @Test func returnsNilForBareNull() {
        #expect(decodeJSONLine("null") == nil)
    }

    // MARK: - Odd / non-ASCII input still returns nil when it isn't a JSON object

    @Test func returnsNilForNonASCIIContentThatIsNotAJSONObject() {
        // A Swift `String` is always valid Unicode, so `data(using: .utf8)` can
        // never fail (that guard branch is defensive and unreachable from the
        // String API). What we DO guarantee is that arbitrary non-JSON text —
        // including replacement characters produced from a malformed byte
        // sequence — never decodes to an object and safely returns nil.
        let malformedBytes: [UInt8] = [0x80, 0x81, 0x82]
        let replacementCharString = String(decoding: malformedBytes, as: UTF8.self)
        #expect(decodeJSONLine(replacementCharString) == nil)
    }
}
