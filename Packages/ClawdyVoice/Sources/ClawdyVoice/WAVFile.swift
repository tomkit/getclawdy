//
//  WAVFile.swift
//  ClawdyVoice
//
//  Wraps float samples as 16-bit PCM WAV bytes so a synthesized clip can be handed to
//  `AVAudioPlayer` (the player the app already uses for ElevenLabs clips and cue files)
//  or written to the cue cache.
//

import Foundation

public enum WAVFile {
    /// 16-bit mono PCM WAV for `samples` in −1…1 at `sampleRate` Hz.
    public static func data(samples: [Float], sampleRate: Double) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var output = Data(capacity: 44 + dataSize)
        func append(_ value: UInt32) { var little = value.littleEndian; output.append(Data(bytes: &little, count: 4)) }
        func append(_ value: UInt16) { var little = value.littleEndian; output.append(Data(bytes: &little, count: 2)) }

        output.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        output.append(contentsOf: Array("WAVE".utf8))
        output.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                                   // fmt chunk size
        append(UInt16(1))                                    // PCM
        append(UInt16(1))                                    // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * UInt32(bytesPerSample))  // byte rate
        append(UInt16(bytesPerSample))                       // block align
        append(UInt16(16))                                   // bits per sample
        output.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            pcm[index] = Int16(max(-1, min(1, sample)) * Float(Int16.max))
        }
        pcm.withUnsafeBufferPointer { output.append(Data(buffer: $0)) }
        return output
    }
}
