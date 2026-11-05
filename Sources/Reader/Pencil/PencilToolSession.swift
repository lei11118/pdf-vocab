import SwiftUI
import PencilKit

/// v0.15.0:手写工具类型(Notability 四件套 + 蜡笔)
/// 毛笔使用独立 brush 类型及压感曲线，旧 calligraphy 存档仍按既有规则解码。
/// 旧存档里 kind = "calligraphy" 的会在解码时回退成钢笔,不会让整份工具状态失效。
enum PencilToolKind: String, CaseIterable, Identifiable, Codable {
    case pen, brush, pencil, marker, crayon, lasso, shape, laser, eraser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "钢笔"
        case .brush: return "毛笔"
        case .pencil: return "铅笔"
        case .marker: return "荧光笔"
        case .crayon: return "蜡笔"
        case .lasso: return "套索"
        case .shape: return "形状"
        case .laser: return "激光笔"
        case .eraser: return "橡皮"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .brush: return "paintbrush.pointed"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .crayon: return "scribble"
        case .lasso: return "lasso"
        case .shape: return "square.on.circle"
        case .laser: return "scope"
        case .eraser: return "eraser"
        }
    }

    /// 容错解码:未知/已移除的工具(如 v0.28 的 "calligraphy")回退成钢笔,
    /// 而不是让整份 `PencilToolState` 解码失败、所有按书记忆一起回默认。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = PencilToolKind(rawValue: raw) ?? .pen
    }
}

/// v0.23.0:形状工具 —— 拖动即得规整图形(Notability 的 shape 工具)。
enum PencilShapeKind: String, CaseIterable, Identifiable, Codable {
    case line, rect, ellipse, arrow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: return "直线"
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        }
    }

    var systemImage: String {
        switch self {
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        }
    }
}

/// v0.15.0:手写工具会话 —— 工具 + 墨色/荧光色 + **5 档笔宽** + **橡皮双模式**,持久记忆。
/// v0.28.0:状态收敛为单个 `PencilToolState`(见 PencilToolState.swift),本类只负责
/// 编辑与 UI 绑定;每次变更 `stateRevision += 1`,SwiftUI 与协调器据此同步。
/// 由双列浮动工具托盘(PencilPaletteView)与挤压弧形工具盘(PencilArcMenu)共同驱动。
final class PencilToolSession: ObservableObject {
    private let defaults: UserDefaults

    @Published var kind: PencilToolKind = .pen {
        didSet {
            if kind != .eraser, kind != .lasso, kind != oldValue { lastInkKind = kind }
            // v0.28.0:切到哪支笔,就装回哪支笔自己的状态(笔宽/墨色/笔锋…),互不污染。
            // 第一次使用某支笔时给它一份默认槽,而不是把上一支笔的档位带过去。
            if !applying, kind != oldValue {
                if prefs[kind.rawValue] == nil { prefs[kind.rawValue] = PencilToolPrefs() }
                applyPrefs(for: kind)
            }
            persist()
        }
    }
    @Published var colorIndex: Int = 0 { didSet { persist() } }
    @Published var markerColorIndex: Int = 0 { didSet { persist() } }
    /// v0.17.0:自定义颜色(取色器)—— RGBA 0xRRGGBBAA;colorIndex = -1 时生效
    @Published var customInkRGBA: Int = 0xE4572EFF { didSet { persist() } }
    @Published var customMarkerRGBA: Int = 0xFFD400CC { didSet { persist() } }
    /// 0…4 五档笔宽(Notability 托盘为 5 档尺寸圆点)
    @Published var widthIndex: Int = 2 {
        didSet {
            if !applying, widthIndex != oldValue { customWidth = nil }
            persist()
        }
    }
    @Published private(set) var customWidth: CGFloat? = nil { didSet { persist() } }
    /// 橡皮:false = 局部(bitmap,擦过即擦),true = 整笔(vector,整条笔迹消失)
    @Published var eraserWhole: Bool = false { didSet { persist() } }
    /// v0.22.0:自研橡皮半径档位(页面点;画布坐标里会 ×超采样倍数)
    @Published var eraserSizeIndex: Int = 2 { didSet { persist() } }
    /// v0.22.0:自研橡皮开关(关掉则退回 PencilKit 原生橡皮,视觉尺寸随超采样缩小)
    @Published var useCustomEraser: Bool = true { didSet { persist() } }
    /// v0.23.0:形状工具的当前形状
    @Published var shapeKind: PencilShapeKind = .line { didSet { persist() } }
    /// PencilKit 原生直尺:开启后沿直尺边画线,适合画表格/下划线;不改动笔具。
    @Published var rulerActive: Bool = false { didSet { persist() } }

    /// 被隐藏的工具(rawValue 列表;长按工具图标隐藏,「⋯」里恢复)——可定制工具带
    @Published var hiddenToolRaw: String = "" {
        didSet { defaults.set(hiddenToolRaw, forKey: "pencilHiddenTools") }
    }

    private static let arcToolOrderKey = "pencil.arcTools.v1"
    @Published private(set) var arcToolRaw: String = ""
    var arcToolKinds: [PencilToolKind] {
        var seen = Set<PencilToolKind>()
        return arcToolRaw.split(separator: ",").compactMap { PencilToolKind(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
    }
    var availableArcToolKinds: [PencilToolKind] { PencilToolKind.allCases.filter { !arcToolKinds.contains($0) } }
    var arcItems: [PencilArcItem] {
        arcToolKinds.map { PencilArcItem(id:$0.rawValue,kind:$0,name:$0.label) }
    }
    func activate(_ item: PencilArcItem) {
        select(kind:item.kind)
    }
    func isActive(_ item: PencilArcItem) -> Bool {
        kind == item.kind
    }
    func addArcTool(_ tool: PencilToolKind) {
        guard !arcToolKinds.contains(tool) else { return }
        setArcToolKinds(arcToolKinds + [tool])
    }
    func removeArcTools(at offsets: IndexSet) {
        let current = arcToolKinds
        guard !current.isEmpty else { return }
        let remaining = current.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
        setArcToolKinds(remaining.isEmpty ? [current[0]] : remaining)
    }
    func moveArcTools(from offsets: IndexSet, to destination: Int) {
        var kinds = arcToolKinds
        kinds.move(fromOffsets: offsets, toOffset: destination)
        setArcToolKinds(kinds)
    }
    private func setArcToolKinds(_ kinds: [PencilToolKind]) {
        var seen = Set<PencilToolKind>()
        let unique = kinds.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        arcToolRaw = unique.map(\.rawValue).joined(separator: ",")
        defaults.set(arcToolRaw, forKey: Self.arcToolOrderKey)
    }

    /// 橡皮切换前的上一支笔(双击手势回退用)
    private(set) var lastInkKind: PencilToolKind = .pen

    /// v0.28.0:每次状态变更 +1。SwiftUI 与协调器只盯这一个值,
    /// 不再需要给每个属性挂 onChange(漏挂一处就少一次应用)。
    @Published private(set) var stateRevision: Int = 0

    /// 当前文档 sha(按书持久化的键)
    private var docKey: String?

    // MARK: - v0.26.0 每支笔的状态表(按书持久化)

    /// kind.rawValue → 该笔的状态
    private var prefs: [String: PencilToolPrefs] = [:]
    /// 正在装填状态时,`didSet` 不回写状态表、不触发保存
    private var applying = false

    /// 墨色:近黑 / 主操作蓝 / 录音红 / 绿 / 橙 / 紫
    static let inkHex: [UInt32] = [0x0A0A0A, 0x4377FF, 0xED5279, 0x2E9E63, 0xF08C33, 0x9B6BD6]
    /// 荧光笔色(references/tokens.json 采样:黄 #FDFD01 / 青柠 #A9FD1B / 品红 #FD00D4 + 天蓝 / 粉)
    static let markerHex: [UInt32] = [0xFDFD01, 0xA9FD1B, 0xFD00D4, 0x86C8FF, 0xFFB3C7]

    static let inkColors: [UIColor] = inkHex.map { UIColor(hex: $0) }
    static let markerColors: [UIColor] = markerHex.map { UIColor(hex: $0) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenToolRaw = defaults.string(forKey: "pencilHiddenTools") ?? ""
        if let storedArcTools = defaults.string(forKey: Self.arcToolOrderKey) {
            let fallback = PencilToolKind.allCases.filter { !Set(hiddenToolRaw.split(separator: ",").map(String.init)).contains($0.rawValue) }
            let stored = storedArcTools.split(separator: ",").compactMap { PencilToolKind(rawValue: String($0)) }
            var seen = Set<PencilToolKind>()
            let normalized = stored.filter { seen.insert($0).inserted }
            let initial = normalized.isEmpty ? (fallback.isEmpty ? [.pen] : fallback) : normalized
            arcToolRaw = initial.map(\.rawValue).joined(separator: ",")
            defaults.set(arcToolRaw, forKey: Self.arcToolOrderKey)
        } else {
            let hidden = Set(hiddenToolRaw.split(separator: ",").map(String.init))
            let visible = PencilToolKind.allCases.filter { !hidden.contains($0.rawValue) }
            arcToolRaw = (visible.isEmpty ? [.pen] : visible).map(\.rawValue).joined(separator: ",")
            defaults.set(arcToolRaw, forKey: Self.arcToolOrderKey)
        }
        // v0.28.0:优先 v2 状态;没有就迁移 v0.26 快照 + 逐键值。
        if let saved = PencilToolStateStore.loadGlobal(defaults: defaults) {
            apply(saved)
        } else {
            let migrated = PencilToolStateStore.migrateGlobal(defaults: defaults)
            apply(migrated)
            if prefs[kind.rawValue] == nil {
                captureCurrentPrefs()
            }
            saveState()
        }
        DiagLog.log("pencil: state loaded rev=\(stateRevision) scope=global kind=\(kind.rawValue) shape=\(shapeKind.rawValue) ruler=\(rulerActive ? 1 : 0) customEraser=\(useCustomEraser ? 1 : 0)")
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

    /// 五档笔宽(按工具分档;与持久化状态共用 PencilMetrics)
    var width: CGFloat { PencilMetrics.width(kind: kind, index: widthIndex, customWidth: customWidth) }

    /// v0.22.0:橡皮半径五档(页面点)
    static let eraserRadii: [CGFloat] = PencilMetrics.eraserRadii
    var eraserRadius: CGFloat { Self.eraserRadii[clamped(eraserSizeIndex, 0, 4)] }
    func setEraserSize(_ index: Int) { eraserSizeIndex = clamped(index, 0, 4) }

    /// v0.17.0:`scale` = 画布超采样倍数 —— 工具宽度按画布坐标放大,视觉宽度不变。
    func makeTool(scale: CGFloat = 1) -> PKTool {
        switch kind {
        case .pen, .brush:
            return PKInkingTool(.pen, color: currentUIColor, width: width * scale)
        case .pencil:
            return PKInkingTool(.pencil, color: currentUIColor, width: width * scale)
        case .marker:
            return PKInkingTool(.marker, color: currentUIColor, width: width * scale)
        case .crayon:
            return PKInkingTool(.crayon, color: currentUIColor, width: width * scale)
        case .shape:
            // 形状由自研手势生成 PKStroke,这里的工具只作占位(绘制手势会被关闭)
            return PKInkingTool(.pen, color: currentUIColor, width: width * scale)
        case .laser:
            return PKInkingTool(.pen, color: currentUIColor, width: 2 * scale)
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
        // 少见的工具组合(实测易卡),切到这几个工具时顺手关掉。
        if newKind == .lasso || newKind == .eraser || newKind == .shape || newKind == .laser, rulerActive {
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
        setWidth((widthIndex + 1) % 5)
    }

    func setWidth(_ index: Int) {
        let wasApplying = applying
        applying = true
        customWidth = nil
        widthIndex = clamped(index, 0, 4)
        applying = wasApplying
        persist()
    }

    func setCustomWidth(_ value: CGFloat?) {
        customWidth = PencilMetrics.normalizedCustomWidth(kind: kind, value: value)
    }

    func toggleEraserWhole() {
        eraserWhole.toggle()
    }

    /// 直尺是叠加在画布上的辅助层,不改变当前笔具;适合 Notability 式“画直线/表格”。
    /// v0.16.2:直尺只对墨迹笔有意义 —— 套索/橡皮下开启时先切回钢笔,避免 PencilKit 少见组合。
    func toggleRuler() {
        if !rulerActive, kind == .lasso || kind == .eraser || kind == .shape || kind == .laser {
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

    // MARK: - v0.18.0:每个 PDF 记忆自己的工具

    /// 打开某份 PDF 时调用:恢复这份文档上次用的工具/颜色/笔宽/橡皮/直尺。
    /// 没有记录时沿用全局默认(上次在任何文档里用的那套)。
    func attachDocument(_ sha: String) {
        guard !sha.isEmpty, docKey != sha else { return }
        docKey = sha
        // v0.28.0:v2 按书状态优先;没有就迁移旧快照/逐键值;都没有则沿用全局状态。
        if let saved = PencilToolStateStore.loadDoc(sha, defaults: defaults) {
            apply(saved)
            DiagLog.log("pencil: state loaded rev=\(stateRevision) scope=doc kind=\(kind.rawValue) shape=\(shapeKind.rawValue) ruler=\(rulerActive ? 1 : 0) customEraser=\(useCustomEraser ? 1 : 0) tools=\(prefs.count)")
        } else if let migrated = PencilToolStateStore.migrateDoc(sha, fallback: state, defaults: defaults) {
            apply(migrated)
            saveState()
            DiagLog.log("pencil: state migrated rev=\(stateRevision) scope=doc kind=\(kind.rawValue) shape=\(shapeKind.rawValue) ruler=\(rulerActive ? 1 : 0) customEraser=\(useCustomEraser ? 1 : 0) tools=\(prefs.count)")
        } else {
            DiagLog.log("pencil: state default (no doc state) kind=\(kind.rawValue)")
        }
    }

    /// 当前会话的完整状态(协调器/叠加层一次性装填;也是持久化的唯一形状)
    var state: PencilToolState {
        var s = PencilToolState()
        s.kind = kind
        s.lastInkKind = lastInkKind
        s.shapeKind = shapeKind
        s.useCustomEraser = useCustomEraser
        s.rulerActive = rulerActive
        s.prefs = prefs
        // 当前笔的实时值优先(可能还没回写进 prefs)
        var p = s.prefs[kind.rawValue] ?? PencilToolPrefs()
        let isMarker = kind == .marker
        p.colorIndex = isMarker ? markerColorIndex : colorIndex
        p.customRGBA = isMarker ? customMarkerRGBA : customInkRGBA
        p.widthIndex = widthIndex
        p.customWidth = PencilMetrics.normalizedCustomWidth(kind: kind, value: customWidth)
        p.eraserWhole = eraserWhole
        p.eraserSizeIndex = eraserSizeIndex
        s.prefs[kind.rawValue] = p
        return s
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

    // MARK: v0.28.0 状态装填 / 持久化

    /// 把一份完整状态装回会话。装填期间 `didSet` 只改值,不保存、不触发 revision。
    private func apply(_ source: PencilToolState) {
        applying = true
        prefs = source.prefs
        kind = source.kind
        lastInkKind = source.lastInkKind
        shapeKind = source.shapeKind
        useCustomEraser = source.useCustomEraser
        rulerActive = source.rulerActive
        if prefs[source.kind.rawValue] == nil { prefs[source.kind.rawValue] = PencilToolPrefs() }
        applyPrefs(for: source.kind)
        applying = false
        stateRevision &+= 1
        DiagLog.log("pencil: state applied rev=\(stateRevision) kind=\(kind.rawValue) shape=\(shapeKind.rawValue) ruler=\(rulerActive ? 1 : 0) customEraser=\(useCustomEraser ? 1 : 0)")
    }

    /// 把当前 UI 上的值写回"当前这支笔"的状态槽
    private func captureCurrentPrefs() {
        guard !applying else { return }
        let isMarker = kind == .marker
        prefs[kind.rawValue] = PencilToolPrefs(
            colorIndex: isMarker ? markerColorIndex : colorIndex,
            customRGBA: isMarker ? customMarkerRGBA : customInkRGBA,
            widthIndex: widthIndex,
            customWidth: PencilMetrics.normalizedCustomWidth(kind: kind, value: customWidth),
            eraserWhole: eraserWhole,
            eraserSizeIndex: eraserSizeIndex
        )
    }

    /// 装回某支笔自己的状态(apply 期间 forbear 回写,避免把新笔的值写到别的槽里)
    private func applyPrefs(for tool: PencilToolKind) {
        guard let p = prefs[tool.rawValue] else { return }
        let wasApplying = applying
        applying = true
        if tool == .marker {
            markerColorIndex = p.colorIndex
            customMarkerRGBA = p.customRGBA
        } else {
            colorIndex = p.colorIndex
            customInkRGBA = p.customRGBA
        }
        widthIndex = p.widthIndex
        customWidth = PencilMetrics.normalizedCustomWidth(kind: tool, value: p.customWidth)
        eraserWhole = p.eraserWhole
        eraserSizeIndex = p.eraserSizeIndex
        applying = wasApplying
    }

    /// 写入全局 + 当前书(v2 blob)。只由显式开关/选值触发。
    private func saveState() {
        captureCurrentPrefs()
        let snapshot = state
        PencilToolStateStore.saveGlobal(snapshot, defaults: defaults)
        if let docKey {
            PencilToolStateStore.saveDoc(snapshot, sha: docKey, defaults: defaults)
        }
    }

    private func clamped(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    private func persist() {
        guard !applying else { return }
        saveState()
        stateRevision &+= 1
    }
}

struct PencilArcItem: Identifiable {
    let id: String
    let kind: PencilToolKind
    let name: String
    var systemImage: String { kind.systemImage }
    var label: String { name }
}

struct PencilArcToolSettingsView: View {
    @ObservedObject var session: PencilToolSession
    @Environment(\.readerPanelClose) private var panelClose
    @State private var editMode: EditMode = .inactive
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.arcToolKinds) { tool in
                        Label(tool.label, systemImage: tool.systemImage)
                            .deleteDisabled(session.arcToolKinds.count <= 1)
                    }
                    .onDelete(perform: session.removeArcTools)
                    .onMove(perform: session.moveArcTools)
                } header: {
                    Text("弧形工具顺序")
                } footer: {
                    Text("至少保留一个工具。此顺序独立于底部工具栏的显示设置。")
                }
                Section("添加内置工具") {
                    if session.availableArcToolKinds.isEmpty {
                        Text("所有内置工具均已加入")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.foreground3)
                    } else {
                        ForEach(session.availableArcToolKinds) { tool in
                            Button { session.addArcTool(tool) } label: {
                                Label(tool.label, systemImage: tool.systemImage)
                            }
                        }
                    }
                }
            }
                .safeAreaInset(edge:.top,spacing:0) {
                    if panelClose != nil {
                        HStack {
                            Text("弧形工具设置").font(.headline)
                            Spacer()
                            Button(editMode.isEditing ? "完成编辑" : "编辑") {
                                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                            }
                            .accessibilityIdentifier("arc-tools-edit")
                        }
                        .padding(.leading,16).padding(.trailing,56).padding(.vertical,12)
                        .background(DS.background1)
                    }
                }
                .navigationTitle("弧形工具设置").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarTrailing) { if panelClose == nil { EditButton() } }
                }
        }
        .environment(\.editMode,$editMode)
    }
}
