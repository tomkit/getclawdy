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

    @Test func strippingRemovesInlinePointTagMidText() {
        // Tags are now emitted INLINE, right after the clause naming each element —
        // a trailing-only strip would read them aloud. Every complete tag anywhere
        // must be removed.
        #expect(
            SentenceStreamBuffer.strippingPointTag(from: "click here [POINT:10,20:save] and you're done")
                == "click here  and you're done"
        )
    }

    @Test func strippingRemovesMultipleInlineTagsInOneReply() {
        let stripped = SentenceStreamBuffer.strippingPointTag(
            from: "first this [POINT:1,2:a] then that [POINT:3,4:b] to finish"
        )
        #expect(!stripped.contains("[POINT:"))
        #expect(stripped == "first this  then that  to finish")
    }

    @Test func strippingRemovesInlineTagsButStillWithholdsATrailingPartial() {
        // A completed inline tag is removed AND a half-typed tag still arriving at
        // the end is withheld so streamed TTS never speaks either.
        #expect(
            SentenceStreamBuffer.strippingPointTag(from: "click here [POINT:10,20:save] then [POI")
                == "click here  then "
        )
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

    @Test func inlinePointTagIsNeverSpokenAcrossStreamingAndFinalPasses() {
        // A reply with a tag in the MIDDLE (not just the end) must never surface the
        // tag in any spoken chunk, and the surrounding words must all still be spoken.
        let buffer = SentenceStreamBuffer()

        // The tag arrives mid-stream, right after "run button". Only the completed
        // first sentence is spoken; the inline tag is stripped out of it.
        let firstBatch = buffer.consumeAccumulatedText("that's the run button [POINT:40,11:run button] up top. now ")
        #expect(firstBatch == ["that's the run button  up top."])
        #expect(!firstBatch.joined().contains("[POINT:"))

        // The rest streams in with a second inline tag, then the reply ends.
        let secondBatch = buffer.consumeAccumulatedText("that's the run button [POINT:40,11:run button] up top. now open the menu [POINT:210,11:menu] here. ")
        #expect(secondBatch == ["now open the menu  here."])
        #expect(!secondBatch.joined().contains("[POINT:"))

        // Final authoritative text: nothing already-spoken is repeated and no tag
        // leaks into the remainder.
        let final = buffer.consumeFinalText("that's the run button [POINT:40,11:run button] up top. now open the menu [POINT:210,11:menu] here.")
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
