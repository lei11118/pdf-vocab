import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class TranslationModelManager: ObservableObject {
    static let shared = TranslationModelManager()

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var enabling: String?
    private var downloads: [String: ModelDownload] = [:]

    private init() {
        installed = Set(TranslationModel.available.filter {
            FileManager.default.fileExists(atPath: Self.modelURL($0).path)
        }.map(\.id))
    }

    nonisolated private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "TranslationModels", directoryHint: .isDirectory)
    }

    nonisolated static func modelURL(_ model: TranslationModel) -> URL {
        directory.appending(path: "\(model.id)-\(model.sha256).gguf")
    }

    func download(_ model: TranslationModel) {
        guard installed.contains(model.id) == false, progress[model.id] == nil else { return }
        do {
            var directory = Self.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let bytes = capacity.volumeAvailableCapacityForImportantUsage, bytes < model.bytes + 134_217_728 {
                throw ModelDownload.Failure.space
            }
        } catch {
            messages[model.id] = error.localizedDescription
            return
        }
        let resumeURL = Self.directory.appending(path: "\(model.sha256).resume")
        let destination = Self.modelURL(model)
        messages[model.id] = nil
        progress[model.id] = 0
        let download = ModelDownload(
            model: model, destination: destination, resumeURL: resumeURL,
            onProgress: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.progress[model.id] != nil else { return }
                    self.progress[model.id] = value
                }
            },
            onCompletion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.progress[model.id] = nil
                    self.downloads[model.id] = nil
                    switch result {
                    case .success: self.installed.insert(model.id)
                    case .failure(let error): self.messages[model.id] = error.localizedDescription
                    }
                }
            }
        )
        downloads[model.id] = download
        download.start()
    }

    func pause(_ model: TranslationModel) {
        downloads[model.id]?.pause()
    }

    func enable(_ model: TranslationModel) async {
        guard installed.contains(model.id), enabling == nil else { return }
        enabling = model.id
        defer { enabling = nil }
        do {
            try await LocalContextTranslation.shared.testLoad(model)
            UserDefaults.standard.set(model.id, forKey: TranslationModel.preferenceKey)
            messages[model.id] = nil
        } catch {
            messages[model.id] = error.localizedDescription
        }
    }

    func remove(_ model: TranslationModel) async {
        guard enabling == nil else { return }
        let defaults = UserDefaults.standard
        do {
            try FileManager.default.removeItem(at: Self.modelURL(model))
            installed.remove(model.id)
            if defaults.string(forKey: TranslationModel.preferenceKey) == model.id {
                defaults.set(TranslationModel.systemID, forKey: TranslationModel.preferenceKey)
            }
            await LocalContextTranslation.shared.evict(modelID: model.id)
            messages[model.id] = nil
        } catch {
            messages[model.id] = error.localizedDescription
        }
    }
}

private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case space, response, checksum, paused

        var errorDescription: String? {
            switch self {
            case .space: return "设备剩余空间不足。"
            case .response: return "模型下载失败，请重试。"
            case .checksum: return "模型文件校验失败，请重新下载。"
            case .paused: return "下载已暂停，可继续下载。"
            }
        }
    }

    private let model: TranslationModel
    private let destination: URL
    private let resumeURL: URL
    private let onProgress: @Sendable (Double) -> Void
    private let onCompletion: @Sendable (Result<Void, Error>) -> Void
    private let queue = OperationQueue()
    private var outcome: Result<Void, Error>?
    private var task: URLSessionDownloadTask?

    init(model: TranslationModel, destination: URL, resumeURL: URL,
         onProgress: @escaping @Sendable (Double) -> Void,
         onCompletion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.model = model
        self.destination = destination
        self.resumeURL = resumeURL
        self.onProgress = onProgress
        self.onCompletion = onCompletion
        queue.maxConcurrentOperationCount = 1
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 86_400
        configuration.allowsExpensiveNetworkAccess = false
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        if let resumeData = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: model.downloadURL)
        }
        task?.resume()
    }

    func pause() {
        // The delegate receives resume data in didCompleteWithError.
        task?.cancel(byProducingResumeData: { _ in })
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(min(1, Double(totalBytesWritten) / Double(model.bytes)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        outcome = Result {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { throw Failure.response }
            guard try Self.verify(location, model: model) else { throw Failure.checksum }
            try FileManager.default.moveItem(at: location, to: destination)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let outcome {
            onCompletion(outcome)
        } else if let error = error as NSError? {
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL, options: .atomic)
            }
            onCompletion(.failure(error.code == NSURLErrorCancelled ? Failure.paused : error))
        } else {
            onCompletion(.failure(Failure.response))
        }
    }

    private static func verify(_ url: URL, model: TranslationModel) throws -> Bool {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, Int64(size) == model.bytes else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == model.sha256
    }
}
