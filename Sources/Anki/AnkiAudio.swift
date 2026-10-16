import Foundation
import AVFoundation

/// M5(v0.11.0):Anki 导出音频——系统 TTS **离线**合成到 WAV(无需网络),按词元缓存复用。
/// 缓存目录:Application Support/anki-audio/pv_<key>.wav
enum AnkiAudio {

    static func cacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("anki-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 该词元对应音频文件(已缓存直接复用;否则合成)。失败返回 nil(该卡无音频,导出不中断)。
    static func audioFile(forKey key: String, term: String) async -> URL? {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        let url = cacheDir().appendingPathComponent("pv_\(safe).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let ok = await synthesize(term: term, to: url)
        return ok ? url : nil
    }

    private final class SynthBox {
        var synth = AVSpeechSynthesizer()
    }

    /// AVSpeechSynthesizer.write 到 PCM buffer → AVAudioFile(WAV)。零长 buffer 表示结束;
    /// 额外挂 6s 兜底(极端情况下回调不齐也能返回,不让导出挂死)。
    private static func synthesize(term: String, to url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = SynthBox()
            let utterance = AVSpeechUtterance(string: term)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.45
            var file: AVAudioFile?
            var resumed = false
            let finish: (Bool) -> Void = { ok in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: ok)
            }
            box.synth.write(utterance) { buffer in
                guard !resumed else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finish(file != nil)
                    box.synth = AVSpeechSynthesizer()
                    return
                }
                if file == nil {
                    file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings)
                }
                try? file?.write(from: pcm)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                finish(file != nil)
            }
        }
    }
}
