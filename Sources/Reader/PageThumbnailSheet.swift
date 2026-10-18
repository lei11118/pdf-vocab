import SwiftUI
import PDFKit

/// v0.23.0:页面缩略图导航 —— 长文档(几百页)靠滑动找页太慢,缩略图一屏几十页。
/// 缩略图按需生成(只在 cell 出现时渲染),避免一次性把整本书画成图片。
struct PageThumbnailSheet: View {
    let document: PDFDocument
    let currentPage: Int
    var onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var thumbnails: [Int: UIImage] = [:]

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        pageCell(index)
                    }
                }
                .padding(DS.Space.m)
            }
            .background(DS.background1)
            .navigationTitle("页面缩略图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func pageCell(_ index: Int) -> some View {
        let selected = index == currentPage
        return Button {
            onSelect(index)
            dismiss()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if let image = thumbnails[index] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DS.background2)
                            .aspectRatio(0.72, contentMode: .fit)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 142)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(selected ? DS.accent : DS.foreground1.opacity(0.08),
                                      lineWidth: selected ? 1.8 : 0.6)
                )

                Text("\(index + 1)")
                    .font(DS.Fonts.micro.monospacedDigit())
                    .foregroundStyle(selected ? DS.accent : DS.foreground3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { load(index) }
        .accessibilityLabel("第 \(index + 1) 页")
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private func load(_ index: Int) {
        guard thumbnails[index] == nil, let page = document.page(at: index) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = page.thumbnail(of: CGSize(width: 216, height: 300), for: .cropBox)
            DispatchQueue.main.async {
                thumbnails[index] = image
            }
        }
    }
}
