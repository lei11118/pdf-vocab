import AVFoundation

/// 发音服务:系统 TTS(AVSpeechSynthesizer),完全离线可用。
final class SpeechService {
    static let shared = SpeechService()
    static let usVoice = "en-US"
    static let gbVoice = "en-GB"

    private let synth = AVSpeechSynthesizer()

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    func speak(_ text: String, language: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = 0.45
        synth.speak(utterance)
    }
}
