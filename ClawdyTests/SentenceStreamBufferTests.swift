//
//  SentenceStreamBufferTests.swift
//  ClawdyTests
//
//  Headless unit tests for the streamed-TTS sentence buffering: completing
//  sentences as accumulated text grows, stripping a trailing [POINT:...] tag
//  (even while it's still arriving) so it's never spoken, and handing each chunk
//  of text out exactly once across the streaming + final passes.
//

import Testing
import Foundation
@testable import Clawdy

struct SentenceStreamBufferTests {

    // MARK: - POINT-tag stripping (static, pure)

    @Test func strippingRemovesCompleteTrailingPointTag() {
        #expect(SentenceStreamBuffer.strippingPointTag(from: "it's blue. [POINT:32,24:blue]") == "it's blue. ")
        #expect(SentenceStreamBuffer.strippingPointTag(from: "all done [POINT:none]") == "all done ")
    }

    @Test func strippingWithholdsInProgressPointTag() {
        // A tag being typed character-by-character must be withheld so a partial
        // tag is never spoken.
        #expect(SentenceStreamBuffer.strippingPointTag(from: "it's blue. [") == "it's blue. ")
        #expect(SentenceStreamBuffer.strippingPointTag(from: "it's blue. [PO") == "it's blue. ")
        #expect(SentenceStreamBuffer.strippingPointTag(from: "it's blue. [POINT:32,2") == "it's blue. ")
    }

    @Test func strippingLeavesOrdinaryBracketsAlone() {
        // A real bracket in the text (not a point tag) is preserved.
        #expect(SentenceStreamBuffer.strippingPointTag(from: "use array[0] here") == "use array[0] here")
    }

    // MARK: - Sentence boundary detection (static, pure)

    @Test func confirmedBoundaryRequiresWhitespaceAfterTerminator() {
        // "blue. and" — the period (index 4) is followed by a space, confirming
        // the sentence; the boundary offset is just past the period, at 5
        // (prefix(5) == "blue.").
        #expect(SentenceStreamBuffer.confirmedSentenceBoundaryOffset(in: "blue. and") == 5)
        // No following whitespace yet (still being written) → unconfirmed.
        #expect(SentenceStreamBuffer.confirmedSentenceBoundaryOffset(in: "blue.") == nil)
        // A decimal mid-number is not a boundary (period followed by a digit).
        #expect(SentenceStreamBuffer.confirmedSentenceBoundaryOffset(in: "version 3.5 is") == nil)
    }

    // MARK: - End-to-end streaming behavior

    @Test func speaksSentencesAsTheyCompleteAndNeverSpeaksThePointTag() {
        let buffer = SentenceStreamBuffer()

        // First sentence isn't confirmed until a space follows the period.
        #expect(buffer.consumeAccumulatedText("you'll want the color") == [])
        #expect(buffer.consumeAccumulatedText("you'll want the color inspector.") == [])
        let firstBatch = buffer.consumeAccumulatedText("you'll want the color inspector. click ")
        #expect(firstBatch == ["you'll want the color inspector."])

        // The point tag starts arriving — nothing new is spoken, and the partial
        // tag is withheld.
        #expect(buffer.consumeAccumulatedText("you'll want the color inspector. click that. [POI") == ["click that."])

        // Final authoritative text: the tag is stripped, and everything already
        // spoken is NOT repeated — only any unspoken tail comes back (none here).
        let final = buffer.consumeFinalText("you'll want the color inspector. click that. [POINT:1100,42:color inspector]")
        #expect(final == nil)
    }

    @Test func finalTextSpeaksTheLastSentenceThatHadNoTrailingSpace() {
        let buffer = SentenceStreamBuffer()
        // Mid-stream, the only sentence has no trailing whitespace, so nothing is
        // confirmed during streaming.
        #expect(buffer.consumeAccumulatedText("that's the save button") == [])
        // At finish, the whole reply (point tag stripped) is the unspoken remainder.
        let final = buffer.consumeFinalText("that's the save button [POINT:640,400:save button]")
        #expect(final == "that's the save button")
    }

    @Test func ultraShortFirstSentenceIsSpokenEarlyAndPointTagStillStripped() {
        // Round-2 change: the model is told to OPEN with a very short first
        // sentence so streaming TTS can start audio at the first token. Verify a
        // tiny opener ("ah, gotcha.") is confirmed and spoken as soon as a space
        // follows it, and that the trailing [POINT:...] tag is never spoken.
        let buffer = SentenceStreamBuffer()

        // The short opener confirms the moment a space follows its period.
        let firstBatch = buffer.consumeAccumulatedText("ah, gotcha. that's the run ")
        #expect(firstBatch == ["ah, gotcha."])

        // The rest streams in and the point tag begins arriving — only the second
        // sentence is spoken; the partial tag is withheld.
        let secondBatch = buffer.consumeAccumulatedText("ah, gotcha. that's the run button up top. [POIN")
        #expect(secondBatch == ["that's the run button up top."])

        // Final authoritative text: tag stripped, nothing already-spoken repeated.
        let final = buffer.consumeFinalText("ah, gotcha. that's the run button up top. [POINT:285,11:run button]")
        #expect(final == nil)
    }

    @Test func eachChunkIsHandedOutExactlyOnce() {
        let buffer = SentenceStreamBuffer()
        let spoken1 = buffer.consumeAccumulatedText("one. two. three")
        #expect(spoken1 == ["one.", "two."])
        // "three" has no terminator yet.
        #expect(buffer.consumeAccumulatedText("one. two. three") == [])
        // Final flush returns only the still-unspoken tail.
        #expect(buffer.consumeFinalText("one. two. three.") == "three.")
        // A second final call returns nil (nothing left).
        #expect(buffer.consumeFinalText("one. two. three.") == nil)
    }
}
