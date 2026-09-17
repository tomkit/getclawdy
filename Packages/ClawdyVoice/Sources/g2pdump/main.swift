//
//  g2pdump — developer tool: prints the Misaki phonemes Clawdy will feed Kokoro for each
//  argument. `swift run g2pdump "Open Settings > Privacy & Security."`
//  Pass `--tokens` to also print the per-token breakdown (tag, phonemes, rating; rating 1 =
//  the fallback network guessed), `--raw` to skip the app's text normalizer.
//
import Foundation
import ClawdyVoice

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--bench") {
    let semaphore = DispatchSemaphore(value: 0)
    Task { await runBenchmark(); semaphore.signal() }
    semaphore.wait()
    exit(0)
}
let showTokens = arguments.contains("--tokens")
// `--raw` skips the app's SpokenTextNormalizer (by default the dump shows exactly what
// the app would feed the model: normalized text → G2P).
let raw = arguments.contains("--raw")
let g2p = EnglishG2P(british: false)
let normalizer = SpokenTextNormalizer()
for line in arguments where !line.hasPrefix("--") {
    let text = raw ? line : normalizer.normalize(line)
    let (phonemes, tokens) = g2p.phonemize(text: text)
    print(line, "\t", phonemes)
    if showTokens {
        for token in tokens {
            print("   [\(token.text)] tag=\(token.tag.map { $0.rawValue } ?? "nil") ws=[\(token.whitespace)] ph=\(token.phonemes ?? "nil") rating=\(token._.rating.map(String.init) ?? "nil")")
        }
    }
}
