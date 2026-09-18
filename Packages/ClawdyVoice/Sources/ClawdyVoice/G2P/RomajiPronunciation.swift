//
//  RomajiPronunciation.swift
//  ClawdyVoice
//
//  Pronunciation for Japanese words written in Hepburn romaji ("Aomori", "Shibuya",
//  "Nebuta", "Nakamura") when the English lexicon doesn't know them. The fallback
//  network is trained on English spelling and mangles these ("Aomori" → "a-MORE-ee",
//  "Shibuya" → "SHIB-ya"), but romaji is a regular syllabary: every word is a chain of
//  (consonant)(vowel) syllables with five pure vowels, so a rule-based reading is exact.
//
//  A word is transcribed ONLY when it parses completely into romaji syllables, so
//  English out-of-vocabulary words ("clawdy", "tomkit") still go to the network. Stress
//  falls on the penultimate syllable — the way English speakers say these names
//  (a-o-MO-ri, shi-BU-ya, na-ka-MU-ra).
//

import Foundation

enum RomajiPronunciation {
    /// Misaki phonemes for `word`, or nil when it doesn't read as romaji.
    static func phonemes(for word: String) -> String? {
        let lowercased = word.lowercased()
        guard lowercased.count >= 3, lowercased.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        guard let syllables = syllabify(lowercased), syllables.count >= 2 else { return nil }

        let stressedIndex = max(0, syllables.count - 2)
        var output = ""
        for (index, syllable) in syllables.enumerated() {
            output += syllable.onset
            if index == stressedIndex { output += "ˈ" }
            output += syllable.nucleus
            output += syllable.coda
        }
        return output
    }

    private struct Syllable {
        let onset: String     // consonant phonemes (may be empty)
        let nucleus: String   // vowel phonemes
        let coda: String      // syllable-final "n" (ん), if any
    }

    /// Longest-match consonant onsets, romaji → Misaki phonemes.
    private static let onsets: [(romaji: String, phonemes: String)] = [
        ("shi", "ʃi"), ("chi", "ʧi"), ("tsu", "tsu"),   // handled as full syllables below
        ("sh", "ʃ"), ("ch", "ʧ"), ("ts", "ts"), ("ky", "kj"), ("gy", "ɡj"), ("ny", "nj"), ("hy", "hj"),
        ("by", "bj"), ("py", "pj"), ("my", "mj"), ("ry", "ɹj"),
        ("k", "k"), ("g", "ɡ"), ("s", "s"), ("z", "z"), ("j", "ʤ"), ("t", "t"), ("d", "d"), ("n", "n"),
        ("h", "h"), ("f", "f"), ("b", "b"), ("p", "p"), ("m", "m"), ("y", "j"), ("r", "ɹ"), ("w", "w"),
    ]

    /// Vowels and the long/diphthong spellings, romaji → Misaki phonemes (Misaki's "O" is
    /// /oʊ/ and "A" is /eɪ/ — how an English speaker renders Japanese o and ei).
    private static let nuclei: [(romaji: String, phonemes: String)] = [
        ("ou", "O"), ("oo", "O"), ("ei", "A"), ("uu", "u"), ("aa", "ɑ"), ("ii", "i"), ("ai", "I"),
        ("a", "ɑ"), ("i", "i"), ("u", "u"), ("e", "ɛ"), ("o", "O"),
    ]

    private static func syllabify(_ word: String) -> [Syllable]? {
        var syllables: [Syllable] = []
        var remaining = Substring(word)
        while !remaining.isEmpty {
            // Geminate consonant ("Sapporo", "Hokkaido"): the doubled letter is silent in
            // English speech; drop the first copy. ("nn" is ん + n, handled below.)
            if remaining.count >= 2, let first = remaining.first, first == remaining.dropFirst().first,
               "kstpcbdgmr".contains(first) {
                remaining = remaining.dropFirst()
            }
            var onset = ""
            var matched = false
            for candidate in onsets where remaining.hasPrefix(candidate.romaji) {
                // The three irregular full syllables carry their own vowel.
                if ["shi", "chi", "tsu"].contains(candidate.romaji) {
                    remaining = remaining.dropFirst(candidate.romaji.count)
                    let coda = takeSyllableFinalN(&remaining)
                    let nucleusPhonemes = String(candidate.phonemes.last!)
                    syllables.append(Syllable(onset: String(candidate.phonemes.dropLast()), nucleus: nucleusPhonemes, coda: coda))
                    matched = true
                    break
                }
                onset = candidate.phonemes
                remaining = remaining.dropFirst(candidate.romaji.count)
                break
            }
            if matched { continue }
            // A syllable-final "n" (ん) with no vowel after it ("shinjuku", "nihon").
            if onset == "n", remaining.first.map({ !"aiueoy".contains($0) }) ?? true {
                guard var last = syllables.popLast() else { return nil }
                last = Syllable(onset: last.onset, nucleus: last.nucleus, coda: last.coda + "n")
                syllables.append(last)
                continue
            }
            guard let nucleus = nuclei.first(where: { remaining.hasPrefix($0.romaji) }) else { return nil }
            remaining = remaining.dropFirst(nucleus.romaji.count)
            let coda = takeSyllableFinalN(&remaining)
            syllables.append(Syllable(onset: onset, nucleus: nucleus.phonemes, coda: coda))
        }
        return syllables
    }

    /// Consumes a syllable-final "n" when the next letter can't start a syllable with it.
    private static func takeSyllableFinalN(_ remaining: inout Substring) -> String {
        guard remaining.first == "n" else { return "" }
        let afterN = remaining.dropFirst().first
        if let afterN, "aiueoy".contains(afterN) { return "" }   // "na", "nya": the n starts the next syllable
        if remaining.dropFirst().hasPrefix("n"), let afterNN = remaining.dropFirst(2).first, "aiueoy".contains(afterNN) {
            remaining = remaining.dropFirst()                     // "kannami": ん + na
            return "n"
        }
        remaining = remaining.dropFirst()
        return "n"
    }
}
