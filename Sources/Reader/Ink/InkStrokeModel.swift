import UIKit
import PencilKit

/// v0.45.0:自研墨迹模型(对照 Notability 逆向文档 §3.4 / §4.4)。
///
/// **存中心线 + 每点笔刷参数,不存渲染结果** —— 这是"任意缩放都锐利"的前提。
/// 渲染在 `InkMetalCanvasView` 里用 Metal 解析式描边实时生成,不做位图放大。
struct InkPoint: Codable {
    var x: Double
    var y: Double
    /// 该点笔宽(页面点)
    var width: Double
    var force: Double
    var altitude: Double
    var azimuth: Double
    var time: Double

    var cg: CGPoint { CGPoint(x: x, y: y) }

    init(x: Double, y: Double, width: Double, force: Double = 0,
         altitude: Double = .pi / 2, azimuth: Double = 0, time: Double = 0) {
        self.x = x; self.y = y; self.width = width
        self.force = force; self.altitude = altitude; self.azimuth = azimuth; self.time = time
    }
}

struct InkStroke: Codable {
    enum Kind: String, Codable { case pen, pencil, marker, crayon, custom }
    var kind: Kind
    /// sRGB 0...1
    var r: Double, g: Double, b: Double, a: Double
    var points: [InkPoint]
    /// 荧光笔等半透明笔要先做 stencil 合并,否则自交处变深(见逆向文档 §4.5)
    var isTranslucent: Bool { a < 0.999 }

    var color: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
}

/// 一页的墨迹(页面坐标,左上原点)
struct InkPage: Codable {
    var strokes: [InkStroke] = []
    var isEmpty: Bool { strokes.isEmpty }

    func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> InkPage? { try? JSONDecoder().decode(InkPage.self, from: data) }

    mutating func append(_ stroke: InkStroke) { strokes.append(stroke) }
    mutating func removeLast() { if !strokes.isEmpty { strokes.removeLast() } }
}

// MARK: - 旧笔迹迁移(选项 3-A)

enum InkLegacyMigration {

    /// 把 `PKDrawing` 的每一笔采样成中心线;`size` 直接作为该点笔宽。
    /// - Parameter transform: 画布坐标 → 页面坐标的缩放/平移(旧数据是 ×3 画布)
    static func strokes(from drawing: PKDrawing, scale: CGFloat) -> [InkStroke] {
        drawing.strokes.compactMap { stroke -> InkStroke? in
            let points = Array(stroke.path)
            guard points.count >= 2 else { return nil }

            let inkType = stroke.ink.inkType
            let kind: InkStroke.Kind
            var alpha: Double = 1
            switch inkType {
            case .marker: kind = .marker; alpha = 0.55
            case .pencil: kind = .pencil
            case .crayon: kind = .crayon
            default: kind = .pen
            }

            var r: CGFloat = 0.04, g: CGFloat = 0.04, b: CGFloat = 0.04, a: CGFloat = 1
            if stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                // 取到真实色值
            } else {
                r = 0.04; g = 0.04; b = 0.04; a = 1
            }

            let converted = points.map { p -> InkPoint in
                InkPoint(x: Double(p.location.x / scale),
                         y: Double(p.location.y / scale),
                         width: Double(max(0.5, p.size.width / scale)),
                         force: Double(p.force),
                         altitude: Double(p.altitude),
                         azimuth: Double(p.azimuth),
                         time: p.timeOffset)
            }
            return InkStroke(kind: kind, r: Double(r), g: Double(g), b: Double(b),
                             a: alpha * Double(a), points: converted)
        }
    }
}
