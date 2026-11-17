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
    struct NativeMathPressTarget {
        let lineSelection: PDFSelection
        let lineRange: NSRange
        let lineIdentity: String
        let glyphSelection: PDFSelection
        let glyphRange: NSRange
        let lineBounds: CGRect
    }

    private struct VerifiedVisualLine {
        let range: NSRange
        let bounds: CGRect
        let glyphCount: Int
        let complete: Bool
    }

    private final class GlyphMap {
        weak var page: PDFPage?
        let text: String
        let rotation: Int
        let glyphs: [Int: CGRect]
        let nominal: [String: CGFloat]
        let placed: [Int: CGRect]
        let attributed: NSAttributedString?
        init(page: PDFPage, text: String, glyphs: [Int: CGRect], nominal: [String: CGFloat], placed: [Int:CGRect]) {
            self.page = page; self.text = text; rotation = page.rotation
            self.glyphs = glyphs; self.nominal = nominal; self.placed = placed
            attributed = page.attributedString
        }
    }
    // Bounded, weak page ownership; do not retain closed documents.
    private static var glyphMaps: [GlyphMap] = []


    /// Include text ranges and geometry: repeated words on a page are distinct selections.
    static func identity(for selection: PDFSelection) -> String {
        selection.pages.map { page in
            let ranges = (0..<selection.numberOfTextRanges(on: page)).map {
                NSStringFromRange(selection.range(at: $0, on: page))
            }.joined(separator: ",")
            return "\(ObjectIdentifier(page))|\(ranges)|\(NSCoder.string(for: selection.bounds(for: page)))"
        }.joined(separator: ";")
    }

    /// PDFKit source ranges are the read-only bridge from a visual selection
    /// back to the unmodified `PDFPage.string` UTF-16 surface.
    static func sourceRanges(of selection: PDFSelection, on page: PDFPage) -> [NSRange] {
        guard let source = page.string else { return [] }
        let ranges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
        return validatedSourceRanges(ranges, in: source) ?? []
    }

    /// Reject the complete selection when even one PDFKit range is invalid;
    /// silently dropping a range could mismatch source offsets and display text.
    static func validatedSourceRanges(_ ranges: [NSRange], in source: String) -> [NSRange]? {
        guard !ranges.isEmpty else { return nil }
        let validated = ranges.compactMap { range -> NSRange? in
            guard range.length > 0 else { return nil }
            return UTF16Span(range: range, in: source)?.nsRange(in: source)
        }
        guard validated.count == ranges.count else { return nil }
        return validated
    }

    /// Changes when page rotation or the source boxes used for geometry change.
    static func contextGeometryRevision(for page: PDFPage) -> String {
        let media = page.bounds(for: .mediaBox)
        let crop = page.bounds(for: .cropBox)
        return "\(page.rotation)|\(NSCoder.string(for: media))|\(NSCoder.string(for: crop))"
    }

    /// Recover a nearby lexical glyph when PDFKit returns a space or a neighbour.
    /// Exact glyph hits win; the bounded tolerance never jumps to a distant line.
    static func wordCharacter(text: NSString, near index: Int, at point: CGPoint,
                              tolerance: CGFloat, bounds: (Int) -> CGRect) -> Int? {
        guard text.length > 0 else { return nil }
        let hint = index == NSNotFound ? 0 : min(max(index, 0), text.length - 1)
        var best: (index: Int, distance: CGFloat)?
        func inspect(_ candidate: Int) {
            let ch = text.character(at: candidate)
            guard WordPicker.isWordChar(ch) || WordPicker.isCJK(ch) || ch == 45 else { return }
            let rect = bounds(candidate)
            guard isValid(rect) else { return }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let limit = min(max(0, tolerance), rect.height * 0.25)
            guard dx <= limit, dy <= limit else { return }
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        for candidate in max(0, hint - 8)...min(text.length - 1, hint + 8) { inspect(candidate) }
        // Broken text runs can give a character index far from the visible hit.
        // A local tolerance hit is not proof of an exact global hit. Index
        // sequences can diverge, so compare all geometry before accepting it.
        if best?.distance != 0 { for candidate in 0..<text.length { inspect(candidate) } }
        return best?.index
    }

    /// Reconstruct a whole visual word instead of trusting PDF text-run splits.
    static func initialWord(on page: PDFPage, at point: CGPoint, tolerance: CGFloat = 2) -> PDFSelection? {
        guard let text = page.string else { return nil }
        let ns = text as NSString
        // Use the same range API for glyph geometry and the resulting selection.
        // Some PDFs expose a characterBounds index sequence that differs from
        // their string/range sequence (line breaks and text runs in particular).
        var glyphs: [Int: CGRect] = [:]
        var nominal: [String: CGFloat] = [:]
        func metricKey(_ index: Int, _ rect: CGRect) -> String {
            "\(ns.character(at:index))|\(Int((rect.height*10).rounded()))"
        }
        // PDFKit distributes TJ word spacing into adjacent selection rectangles.
        // Recover nominal advances from matching glyphs rather than treating those
        // expanded rectangles as the visible glyph outline.
        if let cached = glyphMaps.first(where: { $0.page === page && $0.text == text && $0.rotation == page.rotation }) {
            glyphs = cached.glyphs; nominal = cached.nominal
        } else {
        for i in 0..<ns.length {
            let rect = page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .null
            glyphs[i] = rect
            if isValid(rect) {
                let key = metricKey(i,rect)
                nominal[key] = min(nominal[key] ?? rect.width,rect.width)
            }
        }
        glyphMaps.removeAll { $0.page == nil || $0.page === page }
        if glyphMaps.count >= 8 { glyphMaps.removeFirst() }
                // Match by both character and page geometry; content-stream order and
        // PDFKit's extracted string order can differ (columns, forms, newlines).
        var source: [unichar:[CGRect]] = [:]
        for glyph in PDFTextLayout.glyphs(on:page) {
            let value = glyph.text as NSString
            guard value.length > 0 else { continue }
            for j in 0..<value.length {
                let rect = CGRect(x:glyph.rect.minX+glyph.rect.width*CGFloat(j)/CGFloat(value.length),
                    y:glyph.rect.minY,width:glyph.rect.width/CGFloat(value.length),height:glyph.rect.height)
                source[value.character(at:j),default:[]].append(rect)
            }
        }
        var placed: [Int:CGRect] = [:]
        for i in 0..<ns.length {
            guard let raw = glyphs[i], isValid(raw), let candidates = source[ns.character(at:i)] else { continue }
            let matches = candidates.filter {
                abs($0.midY-raw.midY) < max(raw.height,$0.height)*0.45
                    && abs($0.midX-raw.midX) < max(raw.width,raw.height)*0.8
                    && $0.maxX > raw.minX && $0.minX < raw.maxX
            }
            if let match = matches.min(by: { distanceSquared(CGPoint(x:$0.midX,y:$0.midY),CGPoint(x:raw.midX,y:raw.midY))
                < distanceSquared(CGPoint(x:$1.midX,y:$1.midY),CGPoint(x:raw.midX,y:raw.midY)) }) {
                placed[i] = match
            }
        }
        DiagLog.log("selection.layout: glyphs=\(ns.length) placed=\(placed.count)")
        glyphMaps.append(GlyphMap(page:page,text:text,glyphs:glyphs,nominal:nominal,placed:placed))
        }
        let map = glyphMaps.first(where: { $0.page === page })
        let attributed = map?.attributed
        func bounds(_ index: Int) -> CGRect {
            if let rect = map?.placed[index] { return rect }
            guard let rect = glyphs[index], isValid(rect) else { return .null }
            var width = nominal[metricKey(index,rect)] ?? rect.width
            if let attributed, index < attributed.length,
               let font = attributed.attribute(.font,at:index,effectiveRange:nil) as? UIFont {
                let advance = ns.substring(with:NSRange(location:index,length:1)).size(withAttributes:[.font:font]).width
                if advance > 0, advance < rect.height*2 { width = min(width,advance) }
            }
            return CGRect(x:rect.midX-width/2,y:rect.minY,width:width,height:rect.height)
        }
        func joins(_ left: Int, _ right: Int, _ space: Bool) -> Bool {
            let hyphen = ns.character(at:left) == 45 ? left : (ns.character(at:right) == 45 ? right : -1)
            if hyphen > 0, (48...57).contains(Int(ns.character(at:hyphen-1))) { return false }
            if let a = map?.placed[left], let b = map?.placed[right] { return joinsWord(a,b,acrossSpace:space) }
            guard let a = glyphs[left], let b = glyphs[right] else { return false }
            return joinsNominalGlyphs(a,b,leftAdvance:bounds(left).width,rightAdvance:bounds(right).width)
        }
        // An exact punctuation/symbol hit must not be stolen by a nearby word's
        // tolerance. The caller can select the complete Unicode character.
        if let character = initialCharacter(on:page,at:point,tolerance:0),
           let value = character.string as NSString?, value.length > 0 {
            let ch = value.character(at:0)
            if !WordPicker.isWordChar(ch), !WordPicker.isCJK(ch), ch != 45 { return nil }
        }
        guard let index = wordCharacter(text: ns, near: page.characterIndex(at: point), at: point,
                                       tolerance: tolerance, bounds: bounds),
              let range = visualWordRange(text: ns, at: index, bounds: bounds, join: joins),
              let word = page.selection(for: range), isSane(word, maxPages: 1, maxChars: 100),
              isSingleWordText(lookupText(for: word)),
              containsTouch(word, on: page, point: point, tolerance: tolerance) else { return nil }
        return word
    }

    static func initialCharacter(on page: PDFPage,
                                 at point: CGPoint,
                                 tolerance: CGFloat = 2,
                                 within sourceRange: NSRange? = nil) -> PDFSelection? {
        guard let text = page.string else { return nil }
        let ns = text as NSString
        let cached = glyphMaps.first { $0.page === page && $0.text == text && $0.rotation == page.rotation }
        let searchStart = sourceRange?.location ?? 0
        let searchEnd = sourceRange.map { NSMaxRange($0) } ?? ns.length
        guard searchStart >= 0, searchEnd <= ns.length, searchEnd > searchStart else { return nil }
        var best: (range: NSRange, distance: CGFloat)?
        var index = searchStart
        while index < searchEnd {
            let range = ns.rangeOfComposedCharacterSequence(at:index)
            guard range.location >= searchStart, NSMaxRange(range) <= searchEnd else { return nil }
            index = NSMaxRange(range)
            guard !ns.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
            let rect = (range.length == 1 ? (cached?.placed[range.location] ?? cached?.glyphs[range.location]) : nil)
                ?? page.selection(for:range)?.bounds(for:page) ?? .null
            guard isValid(rect) else { continue }
            let dx = max(rect.minX-point.x,0,point.x-rect.maxX)
            let dy = max(rect.minY-point.y,0,point.y-rect.maxY)
            let limit = min(max(0,tolerance),rect.height*0.25)
            guard dx <= limit, dy <= limit else { continue }
            let distance = dx*dx+dy*dy
            if best == nil || distance < best!.distance { best = (range,distance) }
        }
        return best.flatMap { page.selection(for:$0.range) }
    }

    /// A deliberately narrow native-PDF math target. It accepts one short,
    /// parser-verified visual line whose extracted glyph positions stay on that
    /// line, then returns the exact native glyph under the touch. If PDFKit
    /// fragments its line selection, rebuild only the contiguous visual line
    /// around the exact range hit using source-validated character geometry.
    static func nativeMathPressTarget(on page: PDFPage, at point: CGPoint) -> NativeMathPressTarget? {
        guard let source = page.string else { return nil }
        let sourceNSString = source as NSString
        let pdfLine = page.selectionForLine(at: point)
        let pdfLineRange = pdfLine.flatMap { onlySourceRange(of: $0, on: page, source: source) }
        let usablePDFLineRange = pdfLineRange.flatMap { $0.length <= 160 ? $0 : nil }
        if let usablePDFLineRange,
           let text = UTF16Span(range: usablePDFLineRange, in: source)?.substring(in: source),
           hasObviousNativeMathDisqualifier(text) {
            return nil
        }
        let indexedSearchRange = boundedCharacterSearchRange(
            near: page.characterIndex(at: point), in: sourceNSString)
        let glyph = usablePDFLineRange.flatMap {
            initialCharacter(on: page, at: point, tolerance: 0, within: $0)
        } ?? indexedSearchRange.flatMap {
            initialCharacter(on: page, at: point, tolerance: 0, within: $0)
        }
        guard let glyph,
              glyph.pages.count == 1,
              glyph.pages.first === page,
              let glyphRange = onlySourceRange(of: glyph, on: page, source: source),
              glyphRange.length > 0,
              glyphRange.length <= 2,
              NSMaxRange(glyphRange) <= sourceNSString.length else { return nil }
        let glyphRect = verifiedCharacterBounds(of: glyphRange, on: page, source: source)
            ?? placedBounds(of: glyph, on: page)
        guard isValid(glyphRect), glyphRect.contains(point) else { return nil }

        // Keep the established PDFKit path as the fast route when it proves
        // one complete, parser-valid line. Neighbor geometry below detects a
        // line range that PDFKit silently reduced to one text-run fragment.
        let nativeLineTarget: NativeMathPressTarget? = {
            guard let line = pdfLine,
                  line.pages.count == 1,
                  line.pages.first === page,
                  line.selectionsByLine().count == 1,
                  isSane(line, maxPages: 1, maxChars: 160),
                  let lineRange = onlySourceRange(of: line, on: page, source: source),
                  lineRange.length > 1,
                  NSMaxRange(lineRange) <= sourceNSString.length,
                  let lineText = UTF16Span(range: lineRange, in: source)?.substring(in: source),
                  isStrongNativeMathLine(lineText),
                  let lineBounds = validLineBounds(line, on: page),
                  hasVerifiedSingleVisualLineGeometry(lineRange, on: page, within: lineBounds),
                  glyphRange.location >= lineRange.location,
                  NSMaxRange(glyphRange) <= NSMaxRange(lineRange) else { return nil }
            return NativeMathPressTarget(lineSelection: line,
                                         lineRange: lineRange,
                                         lineIdentity: identity(for: line),
                                         glyphSelection: glyph,
                                         glyphRange: glyphRange,
                                         lineBounds: lineBounds)
        }()

        let nativeLineHasStackedNeighbor = nativeLineTarget.map {
            hasNearbyStackedGlyph(outside: $0.lineRange,
                                  lineBounds: $0.lineBounds,
                                  on: page,
                                  source: source)
        } ?? false
        if nativeLineHasStackedNeighbor { return nil }

        guard let visualLine = verifiedVisualLine(containing: glyphRange, on: page, source: source) else {
            return nativeLineTarget
        }
        // An unverified stop (for example, a same-row gap or a character whose
        // source geometry did not map back exactly) could hide more of the line.
        // A complete PDFKit selection remains usable after the local 2D check
        // above, which protects stacked layouts before that native range passes.
        if !visualLine.complete { return nativeLineTarget }
        if let nativeLineTarget, NSEqualRanges(nativeLineTarget.lineRange, visualLine.range) {
            return nativeLineTarget
        }
        let nativeRangeFitsVisualLine = nativeLineTarget.map {
            $0.lineRange.location >= visualLine.range.location
                && NSMaxRange($0.lineRange) <= NSMaxRange(visualLine.range)
        } ?? true
        guard visualLine.glyphCount > 1,
              visualLine.range.length > 1,
              NSMaxRange(visualLine.range) <= sourceNSString.length,
              nativeRangeFitsVisualLine,
              let lineText = UTF16Span(range: visualLine.range, in: source)?.substring(in: source),
              isStrongNativeMathLine(lineText),
              let line = page.selection(for: visualLine.range),
              line.pages.count == 1,
              line.pages.first === page,
              let selectedRange = onlySourceRange(of: line, on: page, source: source),
              NSEqualRanges(selectedRange, visualLine.range),
              isSane(line, maxPages: 1, maxChars: 160),
              !hasNearbyStackedGlyph(outside: visualLine.range,
                                     lineBounds: visualLine.bounds,
                                     on: page,
                                     source: source) else { return nil }
        return NativeMathPressTarget(lineSelection: line,
                                     lineRange: visualLine.range,
                                     lineIdentity: identity(for: line),
                                     glyphSelection: glyph,
                                     glyphRange: glyphRange,
                                     lineBounds: visualLine.bounds)
    }

    private static func verifiedCharacterBounds(of range: NSRange,
                                                on page: PDFPage,
                                                source: String) -> CGRect? {
        guard let selection = page.selection(for: range),
              selection.pages.count == 1,
              selection.pages.first === page,
              let selectedRange = onlySourceRange(of: selection, on: page, source: source),
              NSEqualRanges(selectedRange, range) else { return nil }
        let bounds = selection.bounds(for: page)
        return isValid(bounds) ? bounds : nil
    }

    private static func verifiedVisualLine(containing seed: NSRange,
                                           on page: PDFPage,
                                           source: String) -> VerifiedVisualLine? {
        let text = source as NSString
        guard seed.location >= 0, seed.length > 0, NSMaxRange(seed) <= text.length,
              let seedRect = verifiedCharacterBounds(of: seed, on: page, source: source) else { return nil }

        let verticalTolerance = max(seedRect.height * 0.9, 3)
        func isOnSeedLine(_ rect: CGRect) -> Bool {
            isValid(rect) && abs(rect.midY - seedRect.midY) <= verticalTolerance
        }
        func isAdjacent(_ left: CGRect, _ right: CGRect) -> Bool {
            let height = min(left.height, right.height)
            let gap = right.minX - left.maxX
            return gap >= -height * 0.6 && gap <= max(height * 1.5, 12)
        }
        func isLineBreak(_ range: NSRange) -> Bool {
            let value = text.substring(with: range)
            return value.rangeOfCharacter(from: .newlines) != nil || value.contains("\u{000C}")
        }
        func isWhitespace(_ range: NSRange) -> Bool {
            text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var lineStart = seed.location
        var lineEnd = NSMaxRange(seed)
        var rects: [CGRect] = [seedRect]
        var scannedUnits = seed.length
        var complete = true

        var cursor = seed.location
        while cursor > 0, scannedUnits < 160 {
            let previous = text.rangeOfComposedCharacterSequence(at: cursor - 1)
            guard NSMaxRange(previous) == cursor, !isLineBreak(previous) else { break }
            scannedUnits += previous.length
            if isWhitespace(previous) {
                cursor = previous.location
                continue
            }
            guard let rect = verifiedCharacterBounds(of: previous, on: page, source: source) else {
                complete = false
                break
            }
            guard isOnSeedLine(rect) else { break }
            guard isAdjacent(rect, rects.first ?? seedRect) else {
                complete = false
                break
            }
            lineStart = previous.location
            rects.insert(rect, at: 0)
            cursor = previous.location
        }
        if scannedUnits >= 160 { complete = false }

        cursor = NSMaxRange(seed)
        while cursor < text.length, scannedUnits < 160 {
            let next = text.rangeOfComposedCharacterSequence(at: cursor)
            guard next.location == cursor, !isLineBreak(next) else { break }
            scannedUnits += next.length
            if isWhitespace(next) {
                cursor = NSMaxRange(next)
                continue
            }
            guard let rect = verifiedCharacterBounds(of: next, on: page, source: source) else {
                complete = false
                break
            }
            guard isOnSeedLine(rect) else { break }
            guard isAdjacent(rects.last ?? seedRect, rect) else {
                complete = false
                break
            }
            lineEnd = NSMaxRange(next)
            rects.append(rect)
            cursor = NSMaxRange(next)
        }
        if scannedUnits >= 160 { complete = false }

        guard lineStart < lineEnd,
              let minMidY = rects.map(\.midY).min(),
              let maxMidY = rects.map(\.midY).max() else { return nil }
        let medianHeight = rects.map(\.height).sorted()[rects.count / 2]
        guard maxMidY - minMidY <= max(medianHeight * 0.9, 3) else { return nil }
        let bounds = rects.reduce(CGRect.null) { $0.union($1) }
        guard isValid(bounds) else { return nil }
        return VerifiedVisualLine(range: NSRange(location: lineStart, length: lineEnd - lineStart),
                                  bounds: bounds,
                                  glyphCount: rects.count,
                                  complete: complete)
    }

    private static func hasNearbyStackedGlyph(outside lineRange: NSRange,
                                              lineBounds: CGRect,
                                              on page: PDFPage,
                                              source: String) -> Bool {
        let text = source as NSString
        guard lineRange.location >= 0,
              lineRange.length > 0,
              NSMaxRange(lineRange) <= text.length,
              isValid(lineBounds),
              let firstGlyph = verifiedLineBoundary(of: lineRange,
                                                    fromStart: true,
                                                    on: page,
                                                    source: source),
              let lastGlyph = verifiedLineBoundary(of: lineRange,
                                                   fromStart: false,
                                                   on: page,
                                                   source: source),
              lineBounds.width > max(firstGlyph.width, lastGlyph.width) * 1.5 else { return false }

        func isSeparator(_ range: NSRange) -> Bool {
            let value = text.substring(with: range)
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || value.contains("\u{000C}")
        }
        func isLineBreak(_ range: NSRange) -> Bool {
            let value = text.substring(with: range)
            return value.rangeOfCharacter(from: .newlines) != nil || value.contains("\u{000C}")
        }
        func overlapsAsStacked(_ rect: CGRect, with anchor: CGRect) -> Bool {
            let verticalDistance = abs(rect.midY - anchor.midY)
            let baselineLimit = max(min(rect.height, anchor.height) * 0.9, 3)
            let fractionBand = max(rect.height, anchor.height) * 1.6
            let verticalGap = max(lineBounds.minY - rect.maxY, rect.minY - lineBounds.maxY, 0)
            let verticalLimit = max(rect.height, anchor.height) * 1.5
            let horizontalSlack = max(rect.width, anchor.width) * 0.5
            let overlapsAnchor = rect.minX <= anchor.maxX + horizontalSlack
                && rect.maxX >= anchor.minX - horizontalSlack
            return verticalDistance > baselineLimit
                && verticalDistance <= fractionBand
                && verticalGap <= verticalLimit
                && overlapsAnchor
        }
        func hasHorizontalASCIIContinuation(from range: NSRange,
                                             rect: CGRect,
                                             direction: Int) -> Bool {
            var cursor = direction < 0 ? range.location : NSMaxRange(range)
            var scanned = 0
            while scanned < 8 {
                let next: NSRange
                if direction < 0 {
                    guard cursor > 0 else { return false }
                    next = text.rangeOfComposedCharacterSequence(at: cursor - 1)
                    guard NSMaxRange(next) == cursor else { return false }
                    cursor = next.location
                } else {
                    guard cursor < text.length else { return false }
                    next = text.rangeOfComposedCharacterSequence(at: cursor)
                    guard next.location == cursor else { return false }
                    cursor = NSMaxRange(next)
                }
                scanned += next.length
                if isSeparator(next) {
                    if isLineBreak(next) { return false }
                    continue
                }
                guard let scalar = text.substring(with: next).unicodeScalars.first,
                      (65...90).contains(scalar.value) || (97...122).contains(scalar.value),
                      let continuation = verifiedCharacterBounds(of: next, on: page, source: source),
                      abs(continuation.midY - rect.midY)
                        <= max(min(continuation.height, rect.height) * 0.35, 3) else { return false }
                let gap = direction < 0 ? rect.minX - continuation.maxX : continuation.minX - rect.maxX
                return gap >= -min(rect.height, continuation.height) * 0.4
                    && gap <= max(min(rect.height, continuation.height) * 0.75, 6)
            }
            return false
        }
        func scan(_ direction: Int) -> Bool {
            var cursor = direction < 0 ? lineRange.location : NSMaxRange(lineRange)
            var scanned = 0
            while scanned < 8 {
                let neighbor: NSRange
                if direction < 0 {
                    guard cursor > 0 else { return false }
                    neighbor = text.rangeOfComposedCharacterSequence(at: cursor - 1)
                    guard NSMaxRange(neighbor) == cursor else { return false }
                    cursor = neighbor.location
                } else {
                    guard cursor < text.length else { return false }
                    neighbor = text.rangeOfComposedCharacterSequence(at: cursor)
                    guard neighbor.location == cursor else { return false }
                    cursor = NSMaxRange(neighbor)
                }
                scanned += neighbor.length
                if isSeparator(neighbor) { continue }
                guard let rect = verifiedBoundaryBounds(of: neighbor, on: page, source: source) else {
                    return false
                }
                guard overlapsAsStacked(rect, with: firstGlyph)
                        || overlapsAsStacked(rect, with: lastGlyph) else { return false }
                return !hasHorizontalASCIIContinuation(from: neighbor, rect: rect, direction: direction)
            }
            return false
        }
        return scan(-1) || scan(1)
    }

    private static func verifiedLineBoundary(of range: NSRange,
                                             fromStart: Bool,
                                             on page: PDFPage,
                                             source: String) -> CGRect? {
        let text = source as NSString
        var cursor = fromStart ? range.location : NSMaxRange(range)
        var scanned = 0
        while scanned < 8 {
            let character: NSRange
            if fromStart {
                guard cursor < NSMaxRange(range) else { return nil }
                character = text.rangeOfComposedCharacterSequence(at: cursor)
                guard character.location == cursor else { return nil }
                cursor = NSMaxRange(character)
            } else {
                guard cursor > range.location else { return nil }
                character = text.rangeOfComposedCharacterSequence(at: cursor - 1)
                guard NSMaxRange(character) == cursor else { return nil }
                cursor = character.location
            }
            scanned += character.length
            if text.substring(with: character).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return verifiedBoundaryBounds(of: character, on: page, source: source)
        }
        return nil
    }

    private static func verifiedBoundaryBounds(of range: NSRange,
                                               on page: PDFPage,
                                               source: String) -> CGRect? {
        guard let selection = page.selection(for: range),
              selection.pages.count == 1,
              selection.pages.first === page,
              let selectedRange = onlySourceRange(of: selection, on: page, source: source) else { return nil }
        if NSEqualRanges(selectedRange, range) {
            let bounds = selection.bounds(for: page)
            return isValid(bounds) ? bounds : nil
        }

        let text = source as NSString
        guard selectedRange.location == range.location,
              selectedRange.length > range.length,
              selectedRange.length <= range.length + 2,
              NSMaxRange(selectedRange) <= text.length,
              let requested = UTF16Span(range: range, in: source)?.substring(in: source),
              let actual = UTF16Span(range: selectedRange, in: source)?.substring(in: source),
              actual.hasPrefix(requested),
              actual.trimmingCharacters(in: .whitespacesAndNewlines) == requested,
              text.substring(with: NSRange(location: range.location + range.length,
                                            length: selectedRange.length - range.length))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bounds = selection.bounds(for: page)
        return isValid(bounds) ? bounds : nil
    }

    private static func onlySourceRange(of selection: PDFSelection,
                                        on page: PDFPage,
                                        source: String? = nil) -> NSRange? {
        guard selection.numberOfTextRanges(on: page) == 1,
              let text = source ?? page.string,
              let ranges = validatedSourceRanges([selection.range(at: 0, on: page)], in: text),
              ranges.count == 1 else { return nil }
        return ranges[0]
    }

    private static func boundedCharacterSearchRange(near index: Int, in source: NSString) -> NSRange? {
        guard source.length > 0, index != NSNotFound else { return nil }
        let center = min(max(index, 0), source.length - 1)
        var start = max(0, center - 80)
        var end = min(source.length, start + 160)
        start = max(0, end - 160)
        if start > 0 { start = source.rangeOfComposedCharacterSequence(at: start).location }
        if end < source.length, end > 0 {
            end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: end - 1))
        }
        guard end > start, end - start <= 162 else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func hasObviousNativeMathDisqualifier(_ text: String) -> Bool {
        text.utf16.count > 160 || hasSentencePunctuation(text) || hasLongASCIIWord(text)
    }

    private static func validLineBounds(_ selection: PDFSelection, on page: PDFPage) -> CGRect? {
        let bounds = selection.bounds(for: page)
        return isValid(bounds) ? bounds : nil
    }

    private static func isStrongNativeMathLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf16.count <= 160,
              !hasSentencePunctuation(trimmed),
              let result = MathReadingService.resolve(trimmed),
              result.status == .parsedText,
              result.ast?.isComplete == true else { return false }

        // Long ASCII words are ordinary prose even if they contain a relation.
        // The first pass handles compact variables and symbols only.
        return !hasLongASCIIWord(trimmed)
    }

    private static func hasLongASCIIWord(_ text: String) -> Bool {
        var asciiWordLength = 0
        for scalar in text.unicodeScalars {
            let isASCIIWord = scalar.value < 128
                && ((65...90).contains(scalar.value) || (97...122).contains(scalar.value))
            if isASCIIWord {
                asciiWordLength += 1
                if asciiWordLength > 3 { return true }
            } else {
                asciiWordLength = 0
            }
        }
        return false
    }

    private static func hasSentencePunctuation(_ text: String) -> Bool {
        let characters = Array(text)
        for index in characters.indices where ",;:!?".contains(characters[index]) {
            return true
        }
        for index in characters.indices where characters[index] == "." {
            let hasDigitBefore = index > 0 && characters[index - 1].wholeNumberValue != nil
            let hasDigitAfter = index + 1 < characters.count && characters[index + 1].wholeNumberValue != nil
            if !hasDigitBefore || !hasDigitAfter { return true }
        }
        return false
    }

    private static func hasVerifiedSingleVisualLineGeometry(_ range: NSRange,
                                                             on page: PDFPage,
                                                             within lineBounds: CGRect) -> Bool {
        guard let source = page.string else { return false }
        let text = source as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return false }
        guard page.numberOfCharacters == text.length else { return false }
        var glyphRects: [CGRect] = []
        var index = range.location
        while index < NSMaxRange(range) {
            let characterRange = text.rangeOfComposedCharacterSequence(at: index)
            guard characterRange.length > 0, NSMaxRange(characterRange) <= NSMaxRange(range) else { return false }
            index = NSMaxRange(characterRange)
            if text.substring(with: characterRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let rect = page.characterBounds(at: characterRange.location)
            guard isValid(rect), lineBounds.insetBy(dx: -3, dy: -3).contains(rect) else { return false }
            glyphRects.append(rect)
        }
        guard glyphRects.count >= 2 else { return false }
        let heights = glyphRects.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        guard medianHeight > 0,
              let minMidY = glyphRects.map(\.midY).min(),
              let maxMidY = glyphRects.map(\.midY).max() else { return false }
        return maxMidY - minMidY <= max(medianHeight * 0.9, 3)
    }

    static func placedBounds(of selection: PDFSelection, on page: PDFPage) -> CGRect {
        guard let map = glyphMaps.first(where: { $0.page === page }) else { return selection.bounds(for:page) }
        let text = map.text as NSString
        var result = CGRect.null
        for n in 0..<selection.numberOfTextRanges(on:page) {
            let range = selection.range(at:n,on:page)
            guard range.location != NSNotFound,NSMaxRange(range) <= text.length else { return selection.bounds(for:page) }
            for i in range.location..<NSMaxRange(range) {
                if let scalar = Unicode.Scalar(text.character(at:i)), CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                guard let rect = map.placed[i], let vertical = map.glyphs[i] else { return selection.bounds(for:page) }
                // PDFKit supplies the visual line's ascent/descent (including
                // accents and math). Use the content stream's unexpanded x
                // advances, while keeping that established display alignment.
                // Word joining uses the separate per-font placed height above.
                result = result.union(CGRect(x:rect.minX,y:vertical.minY,width:rect.width,height:vertical.height))
            }
        }
        return isValid(result) ? result : selection.bounds(for:page)
    }

    /// PDFKit can return a plausible word whose selected range belongs elsewhere.
    /// Validate the final selection, not only the character used to construct it.
    static func containsTouch(_ selection: PDFSelection, on page: PDFPage,
                              point: CGPoint, tolerance: CGFloat) -> Bool {
        selection.selectionsByLine().contains {
            let rect = $0.bounds(for: page)
            return isValid(rect) && rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// A TJ gap expands both bordering advances. Expansion on only one side
    /// belongs to the other boundary of that glyph; do not split its own word.
    static func joinsNominalGlyphs(_ left: CGRect, _ right: CGRect,
                                   leftAdvance: CGFloat, rightAdvance: CGFloat) -> Bool {
        guard isValid(left), isValid(right) else { return false }
        let h = min(left.height,right.height)
        let rawGap = right.minX-left.maxX
        let sharedSpacing = min(max(0,left.width-leftAdvance),max(0,right.width-rightAdvance))
        return abs(left.midY-right.midY)<h*0.35 && rawGap >= -h*0.4 && rawGap+sharedSpacing < h*0.09
    }

    static func joinsWord(_ left:CGRect,_ right:CGRect,acrossSpace:Bool)->Bool {
        guard isValid(left),isValid(right) else { return false }
        let height=min(left.height,right.height)
        let gap=right.minX-left.maxX
        return abs(left.midY-right.midY)<height*0.35 && gap>=(-height*0.4)
            && gap<min(height*(acrossSpace ? 0.06:0.18), min(left.width,right.width)*0.55)
    }

    static func visualWordRange(text:NSString,at index:Int,bounds:(Int)->CGRect,
                                join: ((Int,Int,Bool)->Bool)? = nil)->NSRange? {
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
            guard letter(previous),(join?(previous,first,previous<first-1) ?? joinsWord(bounds(previous),bounds(first),acrossSpace:previous<first-1)) else { break }
            first=previous
        }
        while last+1<text.length && last-index<100 {
            var next=last+1
            while space(next) { next+=1 }
            guard letter(next),(join?(last,next,next>last+1) ?? joinsWord(bounds(last),bounds(next),acrossSpace:next>last+1)) else { break }
            last=next
        }
        return NSRange(location:first,length:last-first+1)
    }

    /// Remove only artificial in-word spacing; real phrase/line boundaries stay.
    static func lookupText(for selection:PDFSelection)->String {
        var pieces:[String]=[]
        for page in selection.pages {
            let map = glyphMaps.first { $0.page === page }
            func glyph(_ i:Int) -> CGRect { map?.placed[i] ?? page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .null }
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
                           joinsWord(glyph(start-1),
                                     glyph(i), acrossSpace:true) { continue }
                        units.append(32)
                    } else { units.append(ch);i+=1 }
                }
                let text=String(utf16CodeUnits:units,count:units.count)
                if let previous=previousBounds,!pieces.isEmpty,
                   joinsWord(previous,glyph(range.location),acrossSpace:true) {
                    pieces[pieces.count-1]+=text
                } else { pieces.append(text) }
                if range.length>0 { previousBounds=glyph(NSMaxRange(range)-1) }
            }
        }
        return (pieces.isEmpty ? (selection.string ?? "") : pieces.joined(separator:" ")).trimmingCharacters(in: .whitespacesAndNewlines)
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
