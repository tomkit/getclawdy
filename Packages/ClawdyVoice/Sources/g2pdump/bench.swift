import Foundation
import ClawdyVoice

/// `swift run -c release g2pdump --bench` — times G2P init, session load, prewarm and synthesis.
func runBenchmark() async {
    let modelURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Clawdy/Models/kokoro-v1.0.fp16.onnx")
    func timed<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let start = Date()
        let result = try await work()
        print(String(format: "%-28@ %6.0f ms", label, Date().timeIntervalSince(start) * 1000))
        return result
    }
    let synthesizer = try! await timed("session + g2p init") { try KokoroSynthesizer(modelURL: modelURL) }
    await timed("prewarm") { await synthesizer.prewarm() }
    for text in ["mm-hm.", "Okay.", "Hey, I'm Clawdy. Ask me anything on your screen and I'll point at it.",
                 "The button is at the top right, next to Share. Click it, then choose Export as PDF, and the file lands in your Downloads folder."] {
        let samples = try! await timed("synth \(text.count) chars") { try await synthesizer.synthesize(text: text, voice: .defaultVoice) }
        print(String(format: "    → %.2f s of audio", Double(samples.count) / KokoroSynthesizer.sampleRate))
    }
}
