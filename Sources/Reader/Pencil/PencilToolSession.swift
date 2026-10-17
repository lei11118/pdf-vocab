import SwiftUI
import PencilKit

/// v0.14.0:手写工具类型(Notability 式四件套)
enum PencilToolKind: String, CaseIterable, Identifiable {
    case pen, pencil, marker, eraser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "钢笔"
        case .pencil: return "铅笔"
        case .marker: return "荧光笔"
        case .eraser: return "橡皮"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        }
    }

    var isInk: Bool { self != .eraser }
}

/// v0.14.0:手写工具会话 —— 工具 + 墨色/荧光色 + 笔宽,持久记忆;
/// 由自绘浮动工具带(PencilPaletteView)驱动,并套用到所有页画布。
final class PencilToolSession: ObservableObject {
    @Published var kind: PencilToolKind = .pen {
        didSet {
            if kind != .eraser, kind != oldValue { lastInkKind = kind }
            persist()
        }
    }
    @Published var colorIndex: Int = 0 { didSet { persist() } }
    @Published var markerColorIndex: Int = 0 { didSet { persist() } }
    @Published var widthIndex: Int = 1 { didSet { persist() } }

    /// 橡皮切换前的上一支笔(双击手势回退用)
    private(set) var lastInkKind: PencilToolKind = .pen

    /// 墨色(深色纸面上也可读;蓝=主操作色)
    static let inkHex: [UInt32] = [0x14120E, 0x0A84FF, 0xE5484D, 0x2E9E63, 0xF08C33, 0x9B6BD6]
    /// 荧光笔色(半透明叠加由 PencilKit marker 处理)
    static let markerHex: [UInt32] = [0xFFD84D, 0x8FE08A, 0x86C8FF, 0xFFA9C4, 0xFFC48A]

    static let inkColors: [UIColor] = inkHex.map { UIColor(hex: $0) }
    static let markerColors: [UIColor] = markerHex.map { UIColor(hex: $0) }

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "pencilToolKind"),
           let saved = PencilToolKind(rawValue: raw) {
            kind = saved
        }
        colorIndex = defaults.integer(forKey: "pencilColorIndex")
        markerColorIndex = defaults.integer(forKey: "pencilMarkerIndex")
        widthIndex = defaults.integer(forKey: "pencilWidthIndex")
        if kind == .eraser { kind = .pen }
    }

    // MARK: - 展示 / 当前值

    /// 调色盘色板(按当前工具切换墨色 / 荧光色)
    var swatches: [UIColor] {
        kind == .marker ? Self.markerColors : Self.inkColors
    }

    var currentUIColor: UIColor {
        switch kind {
        case .eraser:
            return Self.inkColors[min(max(colorIndex, 0), Self.inkColors.count - 1)]
        case .marker:
            return Self.markerColors[min(max(markerColorIndex, 0), Self.markerColors.count - 1)]
        default:
            return Self.inkColors[min(max(colorIndex, 0), Self.inkColors.count - 1)]
        }
    }

    var swatchColor: Color { Color(uiColor: currentUIColor) }

    var width: CGFloat {
        switch kind {
        case .pen: return [1.8, 3.2, 5.6][min(widthIndex, 2)]
        case .pencil: return [1.2, 2.6, 4.6][min(widthIndex, 2)]
        case .marker: return [12, 20, 30][min(widthIndex, 2)]
        case .eraser: return 0
        }
    }

    func makeTool() -> PKTool {
        switch kind {
        case .pen:
            return PKInkingTool(.pen, color: currentUIColor, width: width)
        case .pencil:
            return PKInkingTool(.pencil, color: currentUIColor, width: width)
        case .marker:
            return PKInkingTool(.marker, color: currentUIColor, width: width)
        case .eraser:
            return PKEraserTool(.bitmap)
        }
    }

    // MARK: - 交互

    func select(kind newKind: PencilToolKind) {
        guard kind != newKind else { return }
        kind = newKind
    }

    func selectColor(_ index: Int) {
        if kind == .marker {
            markerColorIndex = index
        } else {
            colorIndex = index
        }
    }

    func cycleWidth() {
        widthIndex = (widthIndex + 1) % 3
    }

    /// Pencil 轻点两下:橡皮 ⇄ 上一支笔
    func toggleEraser() {
        if kind == .eraser {
            kind = lastInkKind
        } else {
            lastInkKind = kind
            kind = .eraser
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(kind.rawValue, forKey: "pencilToolKind")
        defaults.set(colorIndex, forKey: "pencilColorIndex")
        defaults.set(markerColorIndex, forKey: "pencilMarkerIndex")
        defaults.set(widthIndex, forKey: "pencilWidthIndex")
    }
}
