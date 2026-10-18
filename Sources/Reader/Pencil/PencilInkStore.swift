import Foundation
import GRDB

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
    /// 超采样倍数:2 → 页面 433pt 宽时画布 866pt,屏幕栅格约 1732px,
    /// 可保证 pdfView.scaleFactor ≤ 2 时笔迹 1:1 清晰(再高会按比例略软)。
    /// 注:PKEraserTool 在 iOS 26 SDK 里没有宽度参数,倍数越高橡皮视觉尺寸越小,
    /// 因此先取 2 倍(橡皮缩小一半仍可用);后续若做自定义橡皮再提到 3 倍。
    static let scale: CGFloat = 2

    /// 画布坐标系(页面点 × scale)下的尺寸
    static func canvasSize(for pageSize: CGSize) -> CGSize {
        CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
    }

    /// 把画布压回页面大小
    static var inverseTransform: CGAffineTransform {
        CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
    }
}
