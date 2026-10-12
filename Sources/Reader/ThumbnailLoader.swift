import UIKit
import PDFKit
import Combine

/// 缩略图后台生成器:用**独立 PDFDocument 实例**在串行后台队列渲染,
/// 避免主线程卡顿(缩略图页面滑动流畅性修复,v0.5.2)。
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var images: [Int: UIImage] = [:]

    private let url: URL?
    private let queue = DispatchQueue(label: "yuewen.thumbnails", qos: .utility)
    private var doc: PDFDocument?
    private var pending = Set<Int>()
    private var cancelled = false

    init(url: URL?) {
        self.url = url
    }

    /// 请求一张缩略图(幂等;已缓存/在途/已失效时直接返回)。
    func request(_ index: Int) {
        if images[index] != nil || pending.contains(index) || cancelled { return }
        pending.insert(index)
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            if self.doc == nil, let url = self.url {
                self.doc = PDFDocument(url: url)
            }
            let image = self.doc?.page(at: index)?.thumbnail(of: CGSize(width: 200, height: 264), for: .cropBox)
            DispatchQueue.main.async {
                self.pending.remove(index)
                guard !self.cancelled, let image else { return }
                self.images[index] = image
            }
        }
    }

    /// 面板关闭时调用:丢弃在途工作、释放独立文档实例。
    func invalidate() {
        cancelled = true
        doc = nil
    }

    deinit {
        cancelled = true
    }
}
