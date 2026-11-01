import UIKit
import PDFKit

// MARK: - 拖柄几何常量(唯一出处;绘制 / 摆放 / 菜单避让都读这里)

/// 拖柄几何(v0.6.10:对齐原生)。所有与拖柄相关的数字集中于此,避免"绘制一套、避让又一套"。
enum HandleMetrics {
    /// 圆点直径
    static let dotDiameter: CGFloat = 14
    /// 竖线宽度(v0.6.11:2.5 → 4,加粗;小柄本身即选区边缘)
    static let lineWidth: CGFloat = 4
    // 竖线长度(v0.8.1):不再固定——等于"该行选区高度",随页面缩放自适应;
    // 多行选区取首行/末行各自的行高,见 ReaderCoordinator.refreshHandles。
    /// 竖线端头与圆点的交叠量(消除接缝,让圆点"长在"线圈上)
    static let dotLineOverlap: CGFloat = 2
    /// 圆点伸出选区(行矩形)外的距离 = 直径 − 交叠(菜单避让据此计算包络)
    static var dotProtrusion: CGFloat { dotDiameter - dotLineOverlap }
    /// 拖柄视图宽(= 圆点直径;拖动热区另按 hitMinimum 扩到 ≥44×44)
    static var handleWidth: CGFloat { dotDiameter }
    /// 拖柄视图高(v0.8.1:随行高自适应 = 该行选区高 + 圆点伸出距离;首/末行各自取行高)
    static func handleHeight(forLineHeight lineHeight: CGFloat) -> CGFloat {
        max(lineHeight, 1) + dotProtrusion
    }
    /// 蓝选区相对行矩形的扩边(v0.8.0:整体加大——水平 ±1.5、垂直 ±2)
    static let selectionPadX: CGFloat = 1.5
    static let selectionPadY: CGFloat = 2
    /// v0.8.3:行矩形 → **显示矩形**(±扩边)——全仓库唯一的扩边口径。
    /// 高亮注解 bounds、拖柄摆放(竖线中线骑跨高亮边缘)、生词本存储 rects 全部以此为源;
    /// 要改扩边,只改上面两个常量,调用点禁止再写魔法数字。
    static func displayRect(_ lineRect: CGRect) -> CGRect {
        lineRect.insetBy(dx: -selectionPadX, dy: -selectionPadY)
    }
    /// v0.8.3:显示矩形 → 行矩形(逆运算)——需要贴合**原始文字边缘**的场合(如拖柄拖动时的对侧锚点)
    static func lineRect(fromDisplay r: CGRect) -> CGRect {
        r.insetBy(dx: selectionPadX, dy: selectionPadY)
    }
    /// 最小拖动热区(短边不小于它,以"圆点 + 竖线"整体为中心)
    static let hitMinimum: CGFloat = 56
}

// MARK: - 拖动柄(原生同款:竖线 = 行高,圆点紧贴竖线外端;v0.6.10)

/// 选区拖柄:**一根与首/末行选区等高的竖线**沿选区边缘,圆点紧贴竖线外端——
/// 起点柄:竖线沿首行**左**边缘,圆点在竖线**上端**(位于选区外、上方);
/// 终点柄:竖线沿末行**右**边缘,圆点在竖线**下端**(位于选区外、下方)。
/// 视图尺寸由外部按行高设置:高 = 行高 + dotProtrusion,宽 = handleWidth;两端共用同一几何函数。
final class SelectionHandleView: UIView {
    let isStart: Bool
    private let dot = UIView()
    private let stem = UIView()

    init(isStart: Bool) {
        self.isStart = isStart
        // 占位尺寸;实际尺寸由 refreshHandles 按行高自适应设置(v0.8.1)
        super.init(frame: CGRect(x: 0, y: 0, width: HandleMetrics.handleWidth,
                                 height: HandleMetrics.handleHeight(forLineHeight: 20)))
        backgroundColor = .clear
        stem.backgroundColor = .systemBlue
        stem.layer.cornerRadius = HandleMetrics.lineWidth / 2
        stem.isUserInteractionEnabled = false
        addSubview(stem)
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = HandleMetrics.dotDiameter / 2
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.15
        dot.layer.shadowRadius = 2
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        dot.isUserInteractionEnabled = false
        addSubview(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 竖线(局部坐标;两端共用同一函数,左右对称)——起点在局部 y=dotProtrusion 处(圆点下方),终点在 y=0 处(圆点上方)。
    private func lineFrame(lineHeight: CGFloat) -> CGRect {
        CGRect(
            x: (bounds.width - HandleMetrics.lineWidth) / 2,
            y: isStart ? HandleMetrics.dotProtrusion : 0,
            width: HandleMetrics.lineWidth,
            height: lineHeight
        )
    }

    /// 圆点(局部坐标;紧贴竖线外端,与竖线交叠 dotLineOverlap 消除接缝)。
    private func dotFrame(lineHeight: CGFloat) -> CGRect {
        let d = HandleMetrics.dotDiameter
        let y = isStart
            ? 0                                                       // 上端:圆点在竖线之上(选区外)
            : lineHeight + HandleMetrics.dotProtrusion - d            // 下端:圆点在竖线之下(选区外)
        return CGRect(x: (bounds.width - d) / 2, y: y, width: d, height: d)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 视图高 = 行高 + 圆点伸出距离;竖线 = 行高
        let lineHeight = max(bounds.height - HandleMetrics.dotProtrusion, 1)
        stem.frame = lineFrame(lineHeight: lineHeight)
        dot.frame = dotFrame(lineHeight: lineHeight)
    }

    /// 拖动热区 ≥ hitMinimum × hitMinimum,以"圆点 + 竖线"整体(即视图 bounds)为中心。
    func hitDistance(to point: CGPoint) -> CGFloat {
        let height=max(1,bounds.height-HandleMetrics.dotProtrusion)
        let dot=dotFrame(lineHeight:height)
        return hypot(point.x-dot.midX,point.y-dot.midY)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (HandleMetrics.hitMinimum - bounds.width) / 2)
        let dy = max(0, (HandleMetrics.hitMinimum - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

// MARK: - 系统放大镜(iOS 17+,任意视图可用)

/// `UITextLoupeSession` 薄封装:与原生拖动手感一致的放大镜。
final class LoupeController {
    private var session: UITextLoupeSession?

    var isActive: Bool { session != nil }

    /// 开始(或移动到)指定位置。widget 传"选区把手视图"时,系统从它开始动画;传 nil 从触点开始。
    func begin(at point: CGPoint, widget: UIView?, in view: UIView) {
        if session == nil {
            session = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: widget, in: view)
            DiagLog.log("loupe: begin")
        } else {
            move(to: point)
        }
    }

    func move(to point: CGPoint) {
        session?.move(to: point, withCaretRect: .null, trackingCaret: false)
    }

    func end() {
        guard session != nil else { return }
        session?.invalidate()
        session = nil
        DiagLog.log("loupe: end")
    }
}

// MARK: - 感知 Pencil 的拖动手势

/// 记录首触点类型的 pan 手势(用于"放大镜只对指尖显示、不对 Pencil 显示")。
final class PencilAwarePanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var isPencilDriven = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            isPencilDriven = (touch.type == .pencil)
        }
        super.touchesBegan(touches, with: event)
    }
}

// MARK: - 几何与合法性(全部集中于此,避免散落)

enum SelectionGeometry {

    /// Include text ranges and geometry: repeated words on a page are distinct selections.
    static func identity(for selection: PDFSelection) -> String {
        selection.pages.map { page in
            let ranges = (0..<selection.numberOfTextRanges(on: page)).map {
                NSStringFromRange(selection.range(at: $0, on: page))
            }.joined(separator: ",")
            return "\(ObjectIdentifier(page))|\(ranges)|\(NSCoder.string(for: selection.bounds(for: page)))"
        }.joined(separator: ";")
    }

    /// Recover a nearby lexical glyph when PDFKit returns a space or a neighbour.
    /// Exact glyph hits win; the bounded tolerance never jumps to a distant line.
    static func wordCharacter(text: NSString, near index: Int, at point: CGPoint,
                              tolerance: CGFloat, bounds: (Int) -> CGRect) -> Int? {
        guard index != NSNotFound, index >= 0, index < text.length else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for candidate in max(0, index - 8)...min(text.length - 1, index + 8) {
            let ch = text.character(at: candidate)
            guard WordPicker.isWordChar(ch) || WordPicker.isCJK(ch) || ch == 45 else { continue }
            let rect = bounds(candidate)
            guard isValid(rect) else { continue }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let limit = min(max(0, tolerance), rect.height * 0.25)
            guard dx <= limit, dy <= limit else { continue }
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        return best?.index
    }

    /// Reconstruct a whole visual word instead of trusting PDF text-run splits.
    static func initialWord(on page: PDFPage, at point: CGPoint, tolerance: CGFloat = 2) -> PDFSelection? {
        guard let text = page.string else { return nil }
        let ns = text as NSString
        guard let index = wordCharacter(text: ns, near: page.characterIndex(at: point), at: point,
                                       tolerance: tolerance, bounds: { page.characterBounds(at: $0) }),
              let range = visualWordRange(text: ns, at: index, bounds: { page.characterBounds(at: $0) }),
              let word = page.selection(for: range), isSane(word, maxPages: 1, maxChars: 100),
              isSingleWordText(lookupText(for: word)) else { return nil }
        return word
    }

    static func joinsWord(_ left:CGRect,_ right:CGRect,acrossSpace:Bool)->Bool {
        guard isValid(left),isValid(right) else { return false }
        let height=min(left.height,right.height)
        let gap=right.minX-left.maxX
        return abs(left.midY-right.midY)<height*0.35 && gap>=(-height*0.4)
            && gap<height*(acrossSpace ? 0.18:0.45)
    }

    static func visualWordRange(text:NSString,at index:Int,bounds:(Int)->CGRect)->NSRange? {
        func letter(_ i:Int)->Bool {
            i>=0 && i<text.length && (WordPicker.isWordChar(text.character(at:i)) || text.character(at:i)==45)
        }
        func space(_ i:Int)->Bool {
            guard i>=0,i<text.length,let scalar=Unicode.Scalar(text.character(at:i)) else { return false }
            return CharacterSet.whitespaces.contains(scalar)
        }
        guard index>=0,index<text.length else { return nil }
        if WordPicker.isCJK(text.character(at:index)) { return NSRange(location:index,length:1) }
        guard letter(index) else { return nil }
        var first=index,last=index
        while first>0 && index-first<100 {
            var previous=first-1
            while space(previous) { previous-=1 }
            guard letter(previous),joinsWord(bounds(previous),bounds(first),acrossSpace:previous<first-1) else { break }
            first=previous
        }
        while last+1<text.length && last-index<100 {
            var next=last+1
            while space(next) { next+=1 }
            guard letter(next),joinsWord(bounds(last),bounds(next),acrossSpace:next>last+1) else { break }
            last=next
        }
        return NSRange(location:first,length:last-first+1)
    }

    /// Remove only artificial in-word spacing; real phrase/line boundaries stay.
    static func lookupText(for selection:PDFSelection)->String {
        var pieces:[String]=[]
        for page in selection.pages {
            guard let value=page.string else { continue }
            let ns=value as NSString
            var previousBounds:CGRect?
            for n in 0..<selection.numberOfTextRanges(on:page) {
                let range=selection.range(at:n,on:page)
                guard range.location != NSNotFound,range.location>=0,NSMaxRange(range)<=ns.length else { continue }
                var units:[unichar]=[],i=range.location
                while i<NSMaxRange(range) {
                    let ch=ns.character(at:i)
                    if let scalar=Unicode.Scalar(ch),CharacterSet.whitespaces.contains(scalar) {
                        let start=i
                        while i<NSMaxRange(range),let next=Unicode.Scalar(ns.character(at:i)),CharacterSet.whitespaces.contains(next) { i+=1 }
                        if start>range.location,i<NSMaxRange(range),
                           joinsWord(page.characterBounds(at:start-1),page.characterBounds(at:i),acrossSpace:true) { continue }
                        units.append(32)
                    } else { units.append(ch);i+=1 }
                }
                let text=String(utf16CodeUnits:units,count:units.count)
                if let previous=previousBounds,!pieces.isEmpty,
                   joinsWord(previous,page.characterBounds(at:range.location),acrossSpace:true) {
                    pieces[pieces.count-1]+=text
                } else { pieces.append(text) }
                if range.length>0 { previousBounds=page.characterBounds(at:NSMaxRange(range)-1) }
            }
        }
        return pieces.isEmpty ? (selection.string ?? "") : pieces.joined(separator:" ")
    }
    static func isSingleWordText(_ value:String)->Bool {
        let text=value.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:.punctuationCharacters)
        return text.range(of:#"^[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*$"#,options:.regularExpression) != nil
    }

    static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// 页面坐标 y 向上:先按行(容差 6pt),同行按 x 排序,保证 from 在 to 之前。
    static func ordered(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        if abs(a.y - b.y) < 6 { return a.x <= b.x ? (a, b) : (b, a) }
        return a.y > b.y ? (a, b) : (b, a)
    }

    static func isSane(_ selection: PDFSelection, maxPages: Int, maxChars: Int) -> Bool {
        guard !selection.pages.isEmpty, selection.pages.count <= maxPages else { return false }
        guard let text = selection.string, !text.isEmpty, text.count <= maxChars else { return false }
        return true
    }

    static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.width < 10_000 && rect.height < 10_000
    }

    static func logSnippet(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").prefix(16))
    }
}
