import UIKit

/// v0.28.0:**工具状态的唯一真相源**。
///
/// 以前状态散在三处:`PencilToolSession` 的 @Published 值、`PencilToolPrefs` 的
/// 按笔状态表、`PencilOverlayProvider` 的四个 config 元组。任何一处漏存/漏装,
/// 真机表现就是"工具选好了但没生效/重进后忘了"。
///
/// 现在整份状态是一个 Codable 值:一处分片、一次装填、全局 + 按书各存一份。
/// `PencilToolPrefs` 里缺的 `shapeKind / useCustomEraser / rulerActive` 也在顶层补齐
/// (v0.26 的快照路径提前 return,导致这三项按书记忆实际失效)。
struct PencilToolState: Codable, Equatable {
    /// 状态表版本;以后加字段只追加,不删旧键。
    var schemaVersion: Int = 2
    var kind: PencilToolKind = .pen
    var lastInkKind: PencilToolKind = .pen
    var shapeKind: PencilShapeKind = .line
    var useCustomEraser: Bool = true
    var rulerActive: Bool = false
    /// kind.rawValue → 该支笔自己的墨色/笔宽/笔锋/橡皮参数
    var prefs: [String: PencilToolPrefs] = [:]

    var activePrefs: PencilToolPrefs {
        prefs[kind.rawValue] ?? PencilToolPrefs()
    }

    var currentUIColor: UIColor {
        let p = activePrefs
        let idx = min(max(p.colorIndex, -1), 5)
        switch kind {
        case .marker:
            let palette = PencilToolSession.markerColors
            return idx < 0 ? UIColor(rgba: UInt32(truncatingIfNeeded: p.customRGBA))
                           : palette[min(max(idx, 0), palette.count - 1)]
        default:
            let palette = PencilToolSession.inkColors
            return idx < 0 ? UIColor(rgba: UInt32(truncatingIfNeeded: p.customRGBA))
                           : palette[min(max(idx, 0), palette.count - 1)]
        }
    }

    var width: CGFloat { PencilMetrics.width(kind: kind, index: activePrefs.widthIndex) }
    var eraserRadius: CGFloat {
        PencilMetrics.eraserRadii[min(max(activePrefs.eraserSizeIndex, 0), PencilMetrics.eraserRadii.count - 1)]
    }
    var eraserWhole: Bool { activePrefs.eraserWhole }
}

extension PencilToolState {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, lastInkKind, shapeKind, useCustomEraser, rulerActive, prefs
    }

    /// 容错解码:以后给状态加字段时,老 v2 blob 缺键也能读(否则整份状态回退默认)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        kind = try c.decodeIfPresent(PencilToolKind.self, forKey: .kind) ?? .pen
        lastInkKind = try c.decodeIfPresent(PencilToolKind.self, forKey: .lastInkKind) ?? .pen
        shapeKind = try c.decodeIfPresent(PencilShapeKind.self, forKey: .shapeKind) ?? .line
        useCustomEraser = try c.decodeIfPresent(Bool.self, forKey: .useCustomEraser) ?? true
        rulerActive = try c.decodeIfPresent(Bool.self, forKey: .rulerActive) ?? false
        prefs = try c.decodeIfPresent([String: PencilToolPrefs].self, forKey: .prefs) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(kind, forKey: .kind)
        try c.encode(lastInkKind, forKey: .lastInkKind)
        try c.encode(shapeKind, forKey: .shapeKind)
        try c.encode(useCustomEraser, forKey: .useCustomEraser)
        try c.encode(rulerActive, forKey: .rulerActive)
        try c.encode(prefs, forKey: .prefs)
    }
}

/// 每支笔自己的参数槽。v2 起用自定义解码:以后加字段时,老 JSON 缺键也能读,
/// 不会被合成的 Codable 直接判失败(那会让整份状态回退默认值)。
struct PencilToolPrefs: Codable, Equatable {
    var colorIndex: Int = 0
    var customRGBA: Int = 0
    var widthIndex: Int = 2
    /// v0.29.0:书法笔已移除。这两个键仅为兼容旧 v2 blob 保留(解码时读入、不再使用)。
    var nibAngleIndex: Int = 2
    var smoothing: Bool = true
    var eraserWhole: Bool = false
    var eraserSizeIndex: Int = 2

    init() {}

    init(colorIndex: Int, customRGBA: Int, widthIndex: Int,
         eraserWhole: Bool, eraserSizeIndex: Int) {
        self.colorIndex = colorIndex
        self.customRGBA = customRGBA
        self.widthIndex = widthIndex
        self.eraserWhole = eraserWhole
        self.eraserSizeIndex = eraserSizeIndex
    }

    private enum CodingKeys: String, CodingKey {
        case colorIndex, customRGBA, widthIndex, nibAngleIndex, smoothing, eraserWhole, eraserSizeIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        customRGBA = try c.decodeIfPresent(Int.self, forKey: .customRGBA) ?? 0
        widthIndex = try c.decodeIfPresent(Int.self, forKey: .widthIndex) ?? 2
        nibAngleIndex = try c.decodeIfPresent(Int.self, forKey: .nibAngleIndex) ?? 2
        smoothing = try c.decodeIfPresent(Bool.self, forKey: .smoothing) ?? true
        eraserWhole = try c.decodeIfPresent(Bool.self, forKey: .eraserWhole) ?? false
        eraserSizeIndex = try c.decodeIfPresent(Int.self, forKey: .eraserSizeIndex) ?? 2
    }
}

/// 笔宽/笔锋/橡皮档位的唯一取值表(UI 与持久化状态共用,避免两处漂移)。
enum PencilMetrics {
    static func width(kind: PencilToolKind, index: Int) -> CGFloat {
        let i = min(max(index, 0), 4)
        switch kind {
        case .pen, .shape: return [1.2, 2.0, 3.2, 4.8, 7.0][i]
        case .pencil:      return [1.0, 1.6, 2.4, 3.6, 5.2][i]
        case .marker:      return [10, 16, 24, 34, 46][i]
        case .crayon:      return [2.5, 4.0, 6.0, 9.0, 13.0][i]
        case .lasso, .laser, .eraser: return 0
        }
    }

    /// 自研橡皮半径五档(页面点)。
    static let eraserRadii: [CGFloat] = [4, 7, 11, 16, 24]
}

/// v2 状态的读写与一次性迁移。
enum PencilToolStateStore {
    static let globalKey = "pencil.state.global.v2"
    /// v0.26 的全局快照键(只有 [String: PencilToolPrefs])。
    static let legacyGlobalPrefsKey = "pencil.state.global"

    static func docKey(_ sha: String) -> String { "pencil.state.doc.\(sha).v2" }
    /// v0.26 的按书快照键(只有 prefs,读不到 shape/ruler/customEraser)。
    static func legacyDocPrefsKey(_ sha: String) -> String { "pencil.state.\(sha)" }

    static func loadGlobal() -> PencilToolState? {
        decode(UserDefaults.standard.data(forKey: globalKey))
    }

    static func loadDoc(_ sha: String) -> PencilToolState? {
        guard !sha.isEmpty else { return nil }
        return decode(UserDefaults.standard.data(forKey: docKey(sha)))
    }

    static func saveGlobal(_ state: PencilToolState) {
        guard let data = encode(state) else { return }
        UserDefaults.standard.set(data, forKey: globalKey)
    }

    static func saveDoc(_ state: PencilToolState, sha: String) {
        guard !sha.isEmpty, let data = encode(state) else { return }
        UserDefaults.standard.set(data, forKey: docKey(sha))
    }

    static func encode(_ state: PencilToolState) -> Data? {
        try? JSONEncoder().encode(state)
    }

    static func decode(_ data: Data?) -> PencilToolState? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(PencilToolState.self, from: data)
    }

    // MARK: - 迁移(v0.26 / 更早)

    /// 全局迁移:优先 v0.26 的 prefs 快照,补齐只有逐键存的三项。
    static func migrateGlobal() -> PencilToolState {
        let d = UserDefaults.standard
        var state = PencilToolState()
        if let raw = d.string(forKey: "pencilToolKind"),
           let kind = PencilToolKind(rawValue: raw) { state.kind = kind }
        if let raw = d.string(forKey: "pencilShapeKind"),
           let shape = PencilShapeKind(rawValue: raw) { state.shapeKind = shape }
        if d.object(forKey: "pencilCustomEraser") != nil {
            state.useCustomEraser = d.bool(forKey: "pencilCustomEraser")
        }
        state.rulerActive = d.bool(forKey: "pencilRulerActive")

        if let data = d.data(forKey: legacyGlobalPrefsKey),
           let prefs = try? JSONDecoder().decode([String: PencilToolPrefs].self, from: data) {
            state.prefs = prefs
        } else if d.object(forKey: "pencilWidthIndex") != nil {
            var p = PencilToolPrefs()
            let isMarker = state.kind == .marker
            p.colorIndex = d.integer(forKey: isMarker ? "pencilMarkerIndex" : "pencilColorIndex")
            p.customRGBA = d.integer(forKey: isMarker ? "pencilCustomMarkerRGBA" : "pencilCustomInkRGBA")
            p.widthIndex = d.integer(forKey: "pencilWidthIndex")
            p.nibAngleIndex = d.object(forKey: "pencilNibAngle") == nil
                ? 2 : d.integer(forKey: "pencilNibAngle")
            p.smoothing = d.object(forKey: "pencilCalliSmooth") == nil
                ? true : d.bool(forKey: "pencilCalliSmooth")
            p.eraserWhole = d.bool(forKey: "pencilEraserWhole")
            p.eraserSizeIndex = d.object(forKey: "pencilEraserSize") == nil
                ? 2 : d.integer(forKey: "pencilEraserSize")
            state.prefs[state.kind.rawValue] = p
        }
        // 老版本的橡皮模式/大小是全局键;即使迁移时当前不是橡皮,也要把它的槽补上。
        if state.prefs[PencilToolKind.eraser.rawValue] == nil,
           d.object(forKey: "pencilEraserWhole") != nil {
            var p = PencilToolPrefs()
            p.eraserWhole = d.bool(forKey: "pencilEraserWhole")
            p.eraserSizeIndex = d.object(forKey: "pencilEraserSize") == nil
                ? 2 : d.integer(forKey: "pencilEraserSize")
            state.prefs[PencilToolKind.eraser.rawValue] = p
        }
        return state
    }

    /// 按书迁移:prefs 快照 + 逐键的 kind/shape/customEraser/ruler。
    /// 没有任何这本书的记录时返回 nil(沿用全局状态,不覆盖)。
    static func migrateDoc(_ sha: String, fallback: PencilToolState) -> PencilToolState? {
        guard !sha.isEmpty else { return nil }
        let d = UserDefaults.standard
        let prefix = "pencil.doc.\(sha)."
        var state = fallback
        var found = false

        if let data = d.data(forKey: legacyDocPrefsKey(sha)),
           let prefs = try? JSONDecoder().decode([String: PencilToolPrefs].self, from: data) {
            state.prefs = prefs
            found = true
        }
        if let raw = d.string(forKey: prefix + "kind"),
           let kind = PencilToolKind(rawValue: raw) {
            state.kind = kind
            found = true
        }
        if let raw = d.string(forKey: prefix + "shape"),
           let shape = PencilShapeKind(rawValue: raw) {
            state.shapeKind = shape
        }
        if d.object(forKey: prefix + "customEraser") != nil {
            state.useCustomEraser = d.bool(forKey: prefix + "customEraser")
        }
        if d.object(forKey: prefix + "ruler") != nil {
            state.rulerActive = d.bool(forKey: prefix + "ruler")
        }

        // 更老的版本没有 prefs 快照,只有逐键值。
        if !found, d.object(forKey: prefix + "width") != nil {
            var p = PencilToolPrefs()
            let isMarker = state.kind == .marker
            p.colorIndex = d.integer(forKey: prefix + (isMarker ? "markerColor" : "color"))
            p.widthIndex = d.integer(forKey: prefix + "width")
            p.nibAngleIndex = d.object(forKey: prefix + "nibAngle") == nil
                ? 2 : d.integer(forKey: prefix + "nibAngle")
            p.smoothing = d.object(forKey: prefix + "calliSmooth") == nil
                ? true : d.bool(forKey: prefix + "calliSmooth")
            p.eraserWhole = d.bool(forKey: prefix + "eraserWhole")
            p.eraserSizeIndex = d.object(forKey: prefix + "eraserSize") == nil
                ? 2 : d.integer(forKey: prefix + "eraserSize")
            state.prefs[state.kind.rawValue] = p
            found = true
        }
        return found ? state : nil
    }
}
