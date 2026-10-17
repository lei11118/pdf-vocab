import SwiftUI
import UIKit
import PDFKit

/// v0.16.0:资料库封面缩略图。
/// 只读取 PDF 首页生成缩略图,带内存缓存;失败时回退为“纸封面”占位,
/// 不阻塞文档列表滚动,也不写任何新缓存文件。
struct DocumentCoverThumbnail: View {
    let doc: DocumentRecord
    let url: URL?

    @State private var image: UIImage?
    @State private var failed = false

    private var coverColor: Color {
        let values = Array(doc.sha256.utf8.prefix(8))
        let seed = values.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff }
        return DS.coverPalette[seed % DS.coverPalette.count]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(coverColor)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    placeholder(in: geo.size)
                }

                // 书脊与底部渐隐:把 PDF 首页变成“一本书”,而不是普通缩略图。
                LinearGradient(
                    colors: [.clear, .black.opacity(0.18)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(.black.opacity(0.10))
                        .frame(width: 5)
                    Rectangle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 1)
                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .strokeBorder(.white.opacity(0.38), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
        }
        .aspectRatio(DS.Layout.coverAspect, contentMode: .fit)
        .task(id: doc.sha256) { await loadThumbnail() }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func placeholder(in size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(.white.opacity(0.72))
                .padding(DS.Space.s)

            VStack(spacing: DS.Space.s) {
                Image(systemName: failed ? "doc.questionmark" : "doc.richtext")
                    .font(.system(size: min(size.width, size.height) * 0.20, weight: .medium))
                    .foregroundStyle(DS.foreground2.opacity(0.55))
                Text(doc.hasTextLayer ? "TEXT PDF" : "SCANNED PDF")
                    .font(DS.Fonts.micro)
                    .tracking(1.2)
                    .foregroundStyle(DS.foreground3)
            }
        }
    }

    @MainActor
    private func loadThumbnail() async {
        guard let url else {
            failed = true
            return
        }
        let key = "\(doc.sha256)-library-cover" as NSString
        if let cached = DocumentCoverCache.shared.object(forKey: key) {
            image = cached
            return
        }

        let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let pdf = PDFDocument(url: url), let page = pdf.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 440, height: 580), for: .cropBox)
        }.value

        guard !Task.isCancelled else { return }
        failed = loaded == nil
        image = loaded
        if let loaded {
            DocumentCoverCache.shared.setObject(loaded, forKey: key)
        }
    }
}

private final class DocumentCoverCache {
    static let shared = DocumentCoverCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 80
    }

    func object(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func setObject(_ image: UIImage, forKey key: NSString) {
        cache.setObject(image, forKey: key)
    }
}

/// 资料库卡片中重复出现的“元数据”短句,单独抽离便于统一字距/颜色。
struct DocumentMetaLine: View {
    let doc: DocumentRecord

    var body: some View {
        HStack(spacing: DS.Space.x2s) {
            Text("\(doc.pageCount) 页")
            Text("·")
            Text(doc.hasTextLayer ? "文字版" : "扫描版")
            if doc.lastPage > 0 {
                Text("·")
                Text("第 \(min(doc.lastPage + 1, doc.pageCount)) 页")
            }
        }
        .font(DS.Fonts.caption2)
        .foregroundStyle(DS.foreground3)
        .lineLimit(1)
    }
}
