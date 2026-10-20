import Foundation
import GRDB
import PencilKit

/// 一页手写的二进制 + 它的坐标放大倍数(scale)。
/// v0.17.0 起画布按页面 ×`InkGeometry.scale` 超采样(高清书写),
/// 老数据 scale=1,读取时按目标倍数放大并回写迁移。
struct InkDrawingRecord: Sendable {
    var data: Data
    var scale: Double
}

/// Pencil 手写标记数据层(v0.9.0,M4):按 (docSha, page) 存 PKDrawing 二进制;**不改动原 PDF**。
struct PencilInkStore: Sendable {
    let db: AppDatabase

    func drawing(docSha: String, page: Int) -> InkDrawingRecord? {
        (try? db.dbQueue.read { db -> InkDrawingRecord? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT data, scale FROM pencil_ink WHERE docSha = ? AND page = ?",
                arguments: [docSha, page]
            ) else { return nil }
            return InkDrawingRecord(data: row["data"], scale: row["scale"] ?? 1)
        }) ?? nil
    }

    func save(docSha: String, page: Int, data: Data, scale: Double) {
        try? db.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pencil_ink (docSha, page, data, scale, updatedAt) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(docSha, page) DO UPDATE SET data = excluded.data, scale = excluded.scale, updatedAt = excluded.updatedAt
                    """,
                arguments: [docSha, page, data, scale, Date()]
            )
        }
    }

    func delete(docSha: String, page: Int) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pencil_ink WHERE docSha = ? AND page = ?", arguments: [docSha, page])
        }
    }

    /// 某文档是否有手写(供 P2「导出带标记 PDF」等功能使用)。
    func hasInk(docSha: String) -> Bool {
        ((try? db.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pencil_ink WHERE docSha = ?", arguments: [docSha])
        }) ?? nil ?? 0) > 0
    }
}

/// v0.17.0:高清书写的几何口径(唯一来源)。
///
/// 背景:PDFKit 的页叠层会被 PDFView 的变换放大,PKCanvasView 自己按屏幕 scale(2×)
/// 栅格化 → 页面上的一笔在屏幕上被放大 `pdfView.scaleFactor` 倍,于是发糊。
/// Apple 工程师确认这是 `PKCanvasView`(UIScrollView 子类)的固有行为、无公开开关。
///
/// 对策:**超采样画布** —— 画布 bounds = 页面点 × `scale`,再用 1/scale 的变换压回页面大小。
/// 栅格化密度提高到 scale 倍(默认 2),笔宽/橡皮宽同步乘 scale,视觉尺寸不变。
enum InkGeometry {
    /// 超采样倍数:3 → 页面 433pt 宽时画布 1299pt,屏幕栅格约 2598px,
    /// 可保证 pdfView.scaleFactor ≤ 3 时笔迹 1:1 清晰。
    /// 注:v0.22.0 起配自研橡皮(半径可调、按画布坐标缩放),不再受 SDK 橡皮无宽度参数的限制。
    static let scale: CGFloat = 3

    /// 画布坐标系(页面点 × scale)下的尺寸(含四周出血)
    static func canvasSize(for pageSize: CGSize) -> CGSize {
        CGSize(width: (pageSize.width + bleedX * 2) * scale,
               height: (pageSize.height + bleedTop + bleed) * scale)
    }

    /// 把画布压回页面大小
    static var inverseTransform: CGAffineTransform {
        CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
    }

    /// v0.20.0:跨页书写 —— 画布向下多留的"出血区"(页面点)。
    /// 笔尖越过页底后可继续写,抬笔时超出的部分切到下一页。
    ///
    /// v0.25.0:200/240 太短了 —— `PKCanvasView` 是 UIScrollView,`clipsToBounds` 默认为真,
    /// **超出画布 bounds 的墨迹会被裁掉**。真机反馈"从下一页往回画到上一页会被截断",
    /// 根因就是这一点:笔往上走 200pt 以后就不再显示,抬笔时也只能切走这 200pt。
    /// 现在上下都给足到 620pt(≈22cm,A4 页高的 3/4),一支跨页长笔几乎不可能写穿。
    static let bleed: CGFloat = 620

    /// v0.23.2:向上的出血区 —— 从下一页往回写到上一页时,笔尖越过页顶也能继续。
    /// 抬笔时把 y<0 的部分切到上一页底部。
    static let bleedTop: CGFloat = 620

    /// v0.29.0:左右出血区 —— 横向排布(左右翻页)时,笔尖越过页左/页右也要能继续写。
    /// v0.28.0 之前只有上下出血,横向排布下越过页边的墨直接被画布边界裁掉,所以「左右排序」必断。
    static let bleedX: CGFloat = 360

    /// 带四周出血的画布 bounds(原点 0;页面左上角在 (bleedX×scale, bleedTop×scale) 处)
    static func canvasBounds(for pageSize: CGSize) -> CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: (pageSize.width + bleedX * 2) * scale,
            height: (pageSize.height + bleedTop + bleed) * scale
        )
    }

    /// 画布层在页面坐标系里的位置(左上各外扩出血,使页面左上角落在画布 (bleedX, bleedTop))
    static var canvasOrigin: CGPoint {
        CGPoint(x: -bleedX, y: -bleedTop)
    }

    /// 页面顶部在画布坐标里的 y
    static func pageTopY() -> CGFloat { bleedTop * scale }

    /// 页面左侧在画布坐标里的 x
    static func pageLeftX() -> CGFloat { bleedX * scale }

    /// 页面坐标 → 画布坐标(唯一口径;落库/载入/搬运都用它,避免各写一份 ± 偏移)
    static var canvasFromPage: CGAffineTransform {
        CGAffineTransform(translationX: pageLeftX(), y: pageTopY())
    }

    /// 画布坐标 → 页面坐标
    static var pageFromCanvas: CGAffineTransform {
        CGAffineTransform(translationX: -pageLeftX(), y: -pageTopY())
    }

    /// 画布坐标里「页面矩形」(不含出血)
    static func pageRectInCanvas(pageSize: CGSize) -> CGRect {
        CGRect(
            x: pageLeftX(),
            y: pageTopY(),
            width: pageSize.width * scale,
            height: pageSize.height * scale
        )
    }

    /// v0.25.0:一笔是否已经顶到画布的四周边缘(说明被裁了,需要更大的出血区)。
    /// 只用于诊断日志 —— 真机上再出现"截断"时,能一眼看出是不是又被画布边界裁掉。
    static func touchesCanvasEdge(_ stroke: PKStroke, pageSize: CGSize) -> Bool {
        let rect = pageRectInCanvas(pageSize: pageSize)
        for point in stroke.path {
            if point.location.y <= 1 || point.location.y >= rect.maxY + bleed * scale - 1
                || point.location.x <= 1 || point.location.x >= rect.maxX + bleedX * scale - 1 {
                return true
            }
        }
        return false
    }
}
