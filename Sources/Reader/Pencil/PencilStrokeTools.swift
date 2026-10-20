import UIKit
import PencilKit

/// v0.20.0:笔迹工具函数。
///
/// v0.30.0:跨页不再"按页边切分 + 搬到邻页" —— 墨迹留在落笔的那一页,
/// 越过页面矩形的部分由 `PencilDryInkHost` 在 PDFView 之上渲染出来。
/// 因此这里只保留"用一组点重建一笔"这一个能力(橡皮分段重建 / 直线吸附 / 形状提交)。
enum PencilStrokeTools {

    /// 用一组点重建一笔(保留原笔的 ink / transform / 创建时间)。
    ///
    /// 保留 `creationDate` —— 一笔被部分擦除后仍是共享同一 `creationDate` 的多段,
    /// 换成新日期会让"整笔橡皮"再也找不齐同一笔的其它段。
    static func makeStroke(points: [PKStrokePoint], template: PKStroke,
                           creationDate: Date? = nil) -> PKStroke? {
        guard points.count >= 2 else { return nil }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: creationDate ?? template.path.creationDate)
        return PKStroke(ink: template.ink, path: path, transform: template.transform, mask: nil)
    }
}
