//
//  PreparingSpeech.swift
//  PodWash
//
//  ADR-029 — Rare spoken fallback when autoplay next is not warm yet.
//

import AVFoundation
import Foundation

enum PreparingSpeech {
    private static let synthesizer = AVSpeechSynthesizer()

    @MainActor
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}
