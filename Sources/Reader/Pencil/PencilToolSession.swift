import SwiftUI
import PencilKit

/// v0.15.0:手写工具类型(Notability 四件套 + 蜡笔)
enum PencilToolKind: String, CaseIterable, Identifiable {
    case pen, pencil, marker, crayon, lasso, eraser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "钢笔"
        case .pencil: return "铅笔"
        case .marker: return "荧光笔"
        case .crayon: return "蜡笔"
        case .lasso: return "套索"
        case .eraser: return "橡皮"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .crayon: return "scribble"
        case .lasso: return "lasso"
        case .eraser: return "eraser"
        }
    }
}

/// v0.15.0:手写工具会话 —— 工具 + 墨色/荧光色 + **5 档笔宽** + **橡皮双模式**,持久记忆。
/// 由双列浮动工具托盘(PencilPaletteView)与挤压弧形工具盘(PencilArcMenu)共同驱动。
final class PencilToolSession: ObservableObject {
    @Published var kind: PencilToolKind = .pen {
        didSet {
            if kind != .eraser, kind != .lasso, kind != oldValue { lastInkKind = kind }
            persist()
        }
    }
    @Published var colorIndex: Int = 0 { didSet { persist() } }
    @Published var markerColorIndex: Int = 0 { didSet { persist() } }
    /// v0.17.0:自定义颜色(取色器)—— RGBA 0xRRGGBBAA;colorIndex = -1 时生效
    @Published var customInkRGBA: Int = 0xE4572EFF { didSet { persist() } }
    @Published var customMarkerRGBA: Int = 0xFFD400CC { didSet { persist() } }
    /// 0…4 五档笔宽(Notability 托盘为 5 档尺寸圆点)
    @Published var widthIndex: Int = 2 { didSet { persist() } }
    /// 橡皮:false = 局部(bitmap,擦过即擦),true = 整笔(vector,整条笔迹消失)
    @Published var eraserWhole: Bool = false { didSet { persist() } }
    /// v0.22.0:自研橡皮半径档位(页面点;画布坐标里会 ×超采样倍数)
    @Published var eraserSizeIndex: Int = 2 { didSet { persist() } }
    /// v0.22.0:自研橡皮开关(关掉则退回 PencilKit 原生橡皮,视觉尺寸随超采样缩小)
    @Published var useCustomEraser: Bool = true { didSet { persist() } }
    /// Notability 式细节:擦除一笔后自动回到上一支笔(可在工具托盘右键菜单开关)。
    @Published var autoReturnFromEraser: Bool = true { didSet { persist() } }
    /// PencilKit 原生直尺:开启后沿直尺边画线,适合画表格/下划线;不改动笔具。
    @Published var rulerActive: Bool = false { didSet { persist() } }

    /// 被隐藏的工具(rawValue 列表;长按工具图标隐藏,「⋯」里恢复)——可定制工具带
    @Published var hiddenToolRaw: String = UserDefaults.standard.string(forKey: "pencilHiddenTools") ?? "" {
        didSet { UserDefaults.standard.set(hiddenToolRaw, forKey: "pencilHiddenTools") }
    }

    /// 橡皮切换前的上一支笔(双击手势回退用)
    private(set) var lastInkKind: PencilToolKind = .pen

    /// 墨色:近黑 / 主操作蓝 / 录音红 / 绿 / 橙 / 紫
    static let inkHex: [UInt32] = [0x0A0A0A, 0x4377FF, 0xED5279, 0x2E9E63, 0xF08C33, 0x9B6BD6]
    /// 荧光笔色(references/tokens.json 采样:黄 #FDFD01 / 青柠 #A9FD1B / 品红 #FD00D4 + 天蓝 / 粉)
    static let markerHex: [UInt32] = [0xFDFD01, 0xA9FD1B, 0xFD00D4, 0x86C8FF, 0xFFB3C7]

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
        if defaults.object(forKey: "pencilCustomInkRGBA") != nil {
            customInkRGBA = defaults.integer(forKey: "pencilCustomInkRGBA")
        }
        if defaults.object(forKey: "pencilCustomMarkerRGBA") != nil {
            customMarkerRGBA = defaults.integer(forKey: "pencilCustomMarkerRGBA")
        }
        eraserSizeIndex = defaults.object(forKey: "pencilEraserSize") == nil
            ? 2
            : defaults.integer(forKey: "pencilEraserSize")
        useCustomEraser = defaults.object(forKey: "pencilCustomEraser") == nil
            ? true
            : defaults.bool(forKey: "pencilCustomEraser")
        widthIndex = defaults.object(forKey: "pencilWidthIndex") == nil
            ? 2
            : defaults.integer(forKey: "pencilWidthIndex")
        eraserWhole = defaults.bool(forKey: "pencilEraserWhole")
        autoReturnFromEraser = defaults.object(forKey: "pencilAutoReturnEraser") == nil
            ? true
            : defaults.bool(forKey: "pencilAutoReturnEraser")
        rulerActive = defaults.bool(forKey: "pencilRulerActive")
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
            return colorIndex < 0 ? customInkColor : Self.inkColors[clamped(colorIndex, 0, Self.inkColors.count - 1)]
        case .marker:
            return markerColorIndex < 0 ? customMarkerColor : Self.markerColors[clamped(markerColorIndex, 0, Self.markerColors.count - 1)]
        default:
            return colorIndex < 0 ? customInkColor : Self.inkColors[clamped(colorIndex, 0, Self.inkColors.count - 1)]
        }
    }

    var customInkColor: UIColor { UIColor(rgba: UInt32(truncatingIfNeeded: customInkRGBA)) }
    var customMarkerColor: UIColor { UIColor(rgba: UInt32(truncatingIfNeeded: customMarkerRGBA)) }

    /// v0.17.0:取色器选色 —— 直接落到"自定义颜色"并选中(index = -1)
    func setCustomColor(_ color: Color) {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        let rgba = (UInt32(clamping: Int(r * 255)) << 24)
            | (UInt32(clamping: Int(g * 255)) << 16)
            | (UInt32(clamping: Int(b * 255)) << 8)
            | UInt32(clamping: Int(a * 255))
        if kind == .marker {
            customMarkerRGBA = Int(rgba)
            markerColorIndex = -1
        } else {
            customInkRGBA = Int(rgba)
            colorIndex = -1
        }
    }

    var swatchColor: Color { Color(uiColor: currentUIColor) }

    /// 五档笔宽(按工具分档)
    var width: CGFloat {
        switch kind {
        case .pen: return [1.2, 2.0, 3.2, 4.8, 7.0][clamped(widthIndex, 0, 4)]
        case .pencil: return [1.0, 1.6, 2.4, 3.6, 5.2][clamped(widthIndex, 0, 4)]
        case .marker: return [10, 16, 24, 34, 46][clamped(widthIndex, 0, 4)]
        case .crayon: return [2.5, 4.0, 6.0, 9.0, 13.0][clamped(widthIndex, 0, 4)]
        case .lasso, .eraser: return 0
        }
    }

    /// v0.22.0:橡皮半径五档(页面点)
    static let eraserRadii: [CGFloat] = [4, 7, 11, 16, 24]
    var eraserRadius: CGFloat { Self.eraserRadii[clamped(eraserSizeIndex, 0, 4)] }
    func setEraserSize(_ index: Int) { eraserSizeIndex = clamped(index, 0, 4) }

    /// v0.17.0:`scale` = 画布超采样倍数 —— 工具宽度按画布坐标放大,视觉宽度不变。
    func makeTool(scale: CGFloat = 1) -> PKTool {
        switch kind {
        case .pen:
            return PKInkingTool(.pen, color: currentUIColor, width: width * scale)
        case .pencil:
            return PKInkingTool(.pencil, color: currentUIColor, width: width * scale)
        case .marker:
            return PKInkingTool(.marker, color: currentUIColor, width: width * scale)
        case .crayon:
            return PKInkingTool(.crayon, color: currentUIColor, width: width * scale)
        case .lasso:
            return PKLassoTool()
        case .eraser:
            // v0.17.0:SDK 的 PKEraserTool 没有宽度参数,超采样后视觉尺寸会缩小 1/scale;
            // 2 倍下仍可用(整笔擦除不受尺寸影响)。
            return PKEraserTool(eraserWhole ? .vector : .bitmap)
        }
    }

    // MARK: - 交互

    func select(kind newKind: PencilToolKind) {
        guard kind != newKind else { return }
        // v0.16.1:直尺只对墨迹笔有意义;套索/橡皮下保留直尺会让 PencilKit 处于
        // 少见的工具组合(实测易卡),切到这两个工具时顺手关掉。
        if newKind == .lasso || newKind == .eraser, rulerActive {
            rulerActive = false
        }
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
        widthIndex = (widthIndex + 1) % 5
    }

    func setWidth(_ index: Int) {
        widthIndex = clamped(index, 0, 4)
    }

    func toggleEraserWhole() {
        eraserWhole.toggle()
    }

    /// 直尺是叠加在画布上的辅助层,不改变当前笔具;适合 Notability 式“画直线/表格”。
    /// v0.16.2:直尺只对墨迹笔有意义 —— 套索/橡皮下开启时先切回钢笔,避免 PencilKit 少见组合。
    func toggleRuler() {
        if !rulerActive, kind == .lasso || kind == .eraser {
            kind = .pen
        }
        rulerActive.toggle()
    }

    /// Pencil 轻点两下:橡皮 ⇄ 上一支笔
    func toggleEraser() {
        if kind == .eraser {
            kind = lastInkKind
        } else {
            if kind != .lasso { lastInkKind = kind }
            kind = .eraser
        }
    }

    /// 完成一次擦除后回到上一支笔(Notability 的可选“用完即回”行为)。
    func returnFromEraserIfNeeded() {
        guard kind == .eraser, autoReturnFromEraser else { return }
        kind = lastInkKind
    }

    // MARK: - v0.18.0:每个 PDF 记忆自己的工具

    private var docKey: String?

    /// 打开某份 PDF 时调用:恢复这份文档上次用的工具/颜色/笔宽/橡皮/直尺。
    /// 没有记录时沿用全局默认(上次在任何文档里用的那套)。
    func attachDocument(_ sha: String) {
        guard !sha.isEmpty, docKey != sha else { return }
        docKey = sha
        let defaults = UserDefaults.standard
        let prefix = "pencil.doc.\(sha)."
        guard defaults.object(forKey: prefix + "width") != nil else {
            DiagLog.log("pencil: doc tools default (no saved state)")
            return
        }
        if let raw = defaults.string(forKey: prefix + "kind"),
           let saved = PencilToolKind(rawValue: raw),
           saved != .eraser {
            kind = saved
        }
        if defaults.object(forKey: prefix + "color") != nil {
            colorIndex = defaults.integer(forKey: prefix + "color")
        }
        if defaults.object(forKey: prefix + "markerColor") != nil {
            markerColorIndex = defaults.integer(forKey: prefix + "markerColor")
        }
        widthIndex = defaults.integer(forKey: prefix + "width")
        if defaults.object(forKey: prefix + "eraserWhole") != nil {
            eraserWhole = defaults.bool(forKey: prefix + "eraserWhole")
        }
        if defaults.object(forKey: prefix + "ruler") != nil {
            rulerActive = defaults.bool(forKey: prefix + "ruler")
        }
        if defaults.object(forKey: prefix + "eraserSize") != nil {
            eraserSizeIndex = defaults.integer(forKey: prefix + "eraserSize")
        }
        if defaults.object(forKey: prefix + "customEraser") != nil {
            useCustomEraser = defaults.bool(forKey: prefix + "customEraser")
        }
        DiagLog.log("pencil: doc tools loaded kind=\(kind.rawValue) width=\(widthIndex)")
    }

    private func persistDoc(_ defaults: UserDefaults) {
        guard let docKey else { return }
        let prefix = "pencil.doc.\(docKey)."
        defaults.set(kind.rawValue, forKey: prefix + "kind")
        defaults.set(colorIndex, forKey: prefix + "color")
        defaults.set(markerColorIndex, forKey: prefix + "markerColor")
        defaults.set(widthIndex, forKey: prefix + "width")
        defaults.set(eraserWhole, forKey: prefix + "eraserWhole")
        defaults.set(eraserSizeIndex, forKey: prefix + "eraserSize")
        defaults.set(useCustomEraser, forKey: prefix + "customEraser")
        defaults.set(rulerActive, forKey: prefix + "ruler")
    }

    // MARK: - 工具隐藏 / 恢复(可定制工具带)

    var hiddenSet: Set<String> { Set(hiddenToolRaw.split(separator: ",").map(String.init)) }
    var visibleKinds: [PencilToolKind] { PencilToolKind.allCases.filter { !hiddenSet.contains($0.rawValue) } }
    var hiddenKinds: [PencilToolKind] { PencilToolKind.allCases.filter { hiddenSet.contains($0.rawValue) } }

    func hide(_ target: PencilToolKind) {
        guard visibleKinds.count > 1 else { return }   // 至少保留一个工具
        var set = hiddenSet
        set.insert(target.rawValue)
        hiddenToolRaw = set.sorted().joined(separator: ",")
        if kind == target, let fallback = visibleKinds.first {
            kind = fallback
        }
    }

    func unhide(_ target: PencilToolKind) {
        var set = hiddenSet
        set.remove(target.rawValue)
        hiddenToolRaw = set.sorted().joined(separator: ",")
    }

    // MARK: - 私有

    private func clamped(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(kind.rawValue, forKey: "pencilToolKind")
        defaults.set(colorIndex, forKey: "pencilColorIndex")
        defaults.set(markerColorIndex, forKey: "pencilMarkerIndex")
        defaults.set(customInkRGBA, forKey: "pencilCustomInkRGBA")
        defaults.set(customMarkerRGBA, forKey: "pencilCustomMarkerRGBA")
        defaults.set(widthIndex, forKey: "pencilWidthIndex")
        defaults.set(eraserWhole, forKey: "pencilEraserWhole")
        defaults.set(eraserSizeIndex, forKey: "pencilEraserSize")
        defaults.set(useCustomEraser, forKey: "pencilCustomEraser")
        defaults.set(autoReturnFromEraser, forKey: "pencilAutoReturnEraser")
        defaults.set(rulerActive, forKey: "pencilRulerActive")
        persistDoc(defaults)
    }
}
