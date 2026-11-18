import AVFoundation

/// 发音服务:系统 TTS(AVSpeechSynthesizer),完全离线可用。
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()
    static let usVoice = "en-US"
    static let gbVoice = "en-GB"

    private let synth = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var owner: UUID?
    private var onRange: ((NSRange) -> Void)?
    private var onEnd: (() -> Void)?

    private override init() {
        super.init()
        synth.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    func speak(_ text: String, language: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        play(trimmed, language: language, owner: nil, onRange: nil, onEnd: nil)
    }

    func play(_ text: String, language: String, owner: UUID?,
              onRange: ((NSRange) -> Void)?, onEnd: (() -> Void)?) {
        guard !text.isEmpty else { return }
        stopCurrent()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = 0.45
        activeUtterance = utterance
        self.owner = owner
        self.onRange = onRange
        self.onEnd = onEnd
        synth.speak(utterance)
    }

    func pauseOrContinue(owner: UUID) {
        guard self.owner == owner else { return }
        if synth.isPaused {
            synth.continueSpeaking()
        } else {
            synth.pauseSpeaking(at: .word)
        }
    }

    func stop(owner: UUID) {
        if self.owner == owner { stopCurrent() }
    }

    private func stopCurrent() {
        finish()
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    private func finish() {
        let completion = onEnd
        activeUtterance = nil
        owner = nil
        onRange = nil
        onEnd = nil
        completion?()
    }

    @objc private func audioInterrupted(_ note: Notification) {
        guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ==
                AVAudioSession.InterruptionType.began.rawValue else { return }
        DispatchQueue.main.async { [weak self] in self?.stopCurrent() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                           utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            self.onRange?(range)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            self.finish()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        self.speechSynthesizer(synthesizer, didFinish: utterance)
    }
}
