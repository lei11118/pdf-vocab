import Foundation

@MainActor final class ReaderSqueezeGate {
    static let shared = ReaderSqueezeGate()
    private var last: TimeInterval = -.infinity
    func accept(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard time - last >= 0.12 else { return false }
        last = time; return true
    }
}
