//
//  SafetensorsFile.swift
//  ClawdyVoice
//
//  Minimal reader for the `.safetensors` container (an 8-byte little-endian header
//  length, a JSON header mapping tensor name → {dtype, shape, data_offsets}, then the
//  raw tensor bytes). Only float32 tensors are needed: the G2P fallback network's
//  weights. Kept dependency-free so the package builds on Intel and macOS 14.
//

import Foundation

struct SafetensorsTensor {
    let shape: [Int]
    let values: [Float]
}

enum SafetensorsFileError: Error {
    case malformedHeader
    case unsupportedDType(String)
    case truncated(tensorName: String)
}

enum SafetensorsFile {
    static func load(url: URL) throws -> [String: SafetensorsTensor] {
        let fileData = try Data(contentsOf: url)
        guard fileData.count >= 8 else { throw SafetensorsFileError.malformedHeader }
        let headerLength = fileData.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        let headerEnd = 8 + Int(headerLength)
        guard headerEnd <= fileData.count,
              let header = try JSONSerialization.jsonObject(with: fileData[8..<headerEnd]) as? [String: Any] else {
            throw SafetensorsFileError.malformedHeader
        }

        var tensors: [String: SafetensorsTensor] = [:]
        for (tensorName, rawEntry) in header where tensorName != "__metadata__" {
            guard let entry = rawEntry as? [String: Any],
                  let dtype = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [Int],
                  let offsets = entry["data_offsets"] as? [Int], offsets.count == 2 else {
                throw SafetensorsFileError.malformedHeader
            }
            guard dtype == "F32" else { throw SafetensorsFileError.unsupportedDType(dtype) }
            let byteStart = headerEnd + offsets[0]
            let byteEnd = headerEnd + offsets[1]
            guard byteEnd <= fileData.count else { throw SafetensorsFileError.truncated(tensorName: tensorName) }
            let elementCount = (byteEnd - byteStart) / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: elementCount)
            _ = values.withUnsafeMutableBytes { destination in
                fileData.copyBytes(to: destination, from: byteStart..<byteEnd)
            }
            tensors[tensorName] = SafetensorsTensor(shape: shape, values: values)
        }
        return tensors
    }
}
