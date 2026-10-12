import UIKit
import PDFKit
import Combine

/// 缩略图加载器 v2(v0.6.1,用户反馈"加载太慢"修复):
/// - **3 个并发渲染 worker**,每个持有独立 PDFDocument 实例(各自串行队列,互不阻塞主线程);
/// - **两级缓存**:内存(images)+ 磁盘(Application Support/thumb-cache/<文档>/pN.jpg,重开秒开);
/// - 可见格优先 + 前方预取(prefetch);
/// - 面板关闭 invalidate,在途任务不再发布结果。
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var images: [Int: UIImage] = [:]

    private let url: URL?
    private let renderSize = CGSize(width: 200, height: 264)
    private let diskDir: URL?
    private let ioQueue = DispatchQueue(label: "yuewen.thumbnails.io", qos: .userInitiated)
    private var workers: [Worker] = []
    private var rr = 0
    private var pending = Set<Int>()
    private var cancelled = false

    private final class Worker {
        let queue: DispatchQueue
        var doc: PDFDocument?

        init(_ index: Int) {
            queue = DispatchQueue(label: "yuewen.thumbnails.worker\(index)", qos: .userInitiated)
        }
    }

    init(url: URL?) {
        self.url = url
        var dir: URL?
        if let url {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            dir = base?
                .appendingPathComponent("thumb-cache", isDirectory: true)
                .appendingPathComponent(url.lastPathComponent, isDirectory: true)
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        diskDir = dir
        workers = (0..<3).map(Worker.init)
    }

    /// 请求一张缩略图(幂等;内存 → 磁盘 → 渲染 三级)。
    func request(_ index: Int) {
        if images[index] != nil || pending.contains(index) || cancelled { return }
        guard index >= 0, url != nil else { return }
        pending.insert(index)
        let dir = diskDir
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let dir, let cached = UIImage(contentsOfFile: dir.appendingPathComponent("p\(index).jpg").path) {
                DispatchQueue.main.async {
                    self.pending.remove(index)
                    guard !self.cancelled else { return }
                    self.images[index] = cached
                }
                return
            }
            self.renderOnWorker(index)
        }
    }

    /// 前方预取(面板打开/滚动时调用;幂等,已缓存或已在途的会直接跳过)。
    func prefetch(from index: Int, ahead: Int = 12) {
        guard index >= 0 else { return }
        for i in index..<(index + ahead) {
            request(i)
        }
    }

    private func renderOnWorker(_ index: Int) {
        let worker = workers[rr % workers.count]
        rr += 1
        worker.queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            if worker.doc == nil, let url = self.url {
                worker.doc = PDFDocument(url: url)
            }
            let image = worker.doc?.page(at: index)?.thumbnail(of: self.renderSize, for: .cropBox)
            DispatchQueue.main.async {
                self.pending.remove(index)
                guard !self.cancelled, let image else { return }
                self.images[index] = image
                self.writeToDisk(index, image)
            }
        }
    }

    private func writeToDisk(_ index: Int, _ image: UIImage) {
        guard let dir = diskDir, let data = image.jpegData(compressionQuality: 0.72) else { return }
        let path = dir.appendingPathComponent("p\(index).jpg")
        ioQueue.async {
            try? data.write(to: path, options: .atomic)
        }
    }

    /// 面板关闭时调用:丢弃在途工作、释放独立文档实例。
    func invalidate() {
        cancelled = true
        workers.forEach { $0.doc = nil }
    }

    deinit {
        cancelled = true
    }
}
