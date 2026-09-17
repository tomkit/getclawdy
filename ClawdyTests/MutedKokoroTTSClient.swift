//
//  MutedKokoroTTSClient.swift
//  ClawdyTests
//
//  The REAL built-in voice for tests: a `KokoroTTSClient` with playback muted, so every
//  speak path exercises the actual synthesizer (model, G2P, chunking, playback timing)
//  without sound coming out of the machine. There is no other voice to fake.
//

import Foundation
@testable import Clawdy

@MainActor
func makeMutedKokoroTTSClient() -> KokoroTTSClient {
    let client = KokoroTTSClient()
    client.playbackVolume = 0
    client.prewarm()
    return client
}
