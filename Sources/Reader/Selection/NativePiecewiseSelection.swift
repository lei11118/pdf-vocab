import PDFKit

/// Reads two aligned columns next to a left brace from PDF glyph geometry.
struct NativePiecewiseSelection {
    private typealias Glyph = PDFTextLayout.Glyph
    private static let bracePieces: Set<String> = ["⎧", "⎨", "⎩", "⎪"]
    private static let relations: Set<String> = ["<", ">", "≤", "≥", "=", "≠"]
    let whole: FormulaCircleDetail
    private let glyphs: [Glyph]
    private let cells: [FormulaCircleDetail]

    static func hasBrace(in glyphs: [PDFTextLayout.Glyph]) -> Bool {
        if glyphs.contains(where: { bracePieces.contains($0.text) }) { return true }
        let textHeight = glyphs.filter { $0.text != "{" }.map(\.rect.height).max() ?? 0
        return textHeight > 0 && glyphs.contains { $0.text == "{" && $0.rect.height >= textHeight * 1.5 }
    }

    static func build(on page: [PDFTextLayout.Glyph], enclosed: Set<Int>) -> Self? {
        guard enclosed.count <= 96 else { return nil }
        let glyphs = enclosed.sorted().map { page[$0] }
        let braces = glyphs.filter { $0.text == "{" || bracePieces.contains($0.text) }
        guard let brace = braceBounds(braces) else { return nil }

        let prefix = glyphs.filter { $0.rect.midX < brace.midX && !bracePieces.contains($0.text) && $0.text != "{" }
            .sorted { $0.rect.midX < $1.rect.midX }
        guard let equals = prefix.last, equals.text == "=",
              abs(equals.rect.midY - brace.midY) <= brace.height * 0.4,
              let prefixLayout = NativeEquationCircleSelection.inlineLayout(prefix, baseline: equals.baseline.y,
                                                                             fontHeight: equals.rect.height) else { return nil }
        let prefixText = prefixLayout.map(\.text).joined()
        guard prefixText.count > 1,
              let prefixLatex = NativeFractionReadingSelection.safeParserText(prefixText) else { return nil }

        var body = glyphs.filter { $0.rect.midX > brace.midX && !bracePieces.contains($0.text) && $0.text != "{" }
            .sorted { $0.rect.midX < $1.rect.midX }
        if body.last?.text == "." { body.removeLast() }
        let comparisons = body.filter { relations.contains($0.text) }.sorted { $0.baseline.y > $1.baseline.y }
        guard let anchor = comparisons.first else { return nil }
        let fontHeight = anchor.rect.height
        let tolerance = max(1.5, fontHeight * 0.20)
        var baselines: [CGFloat] = []
        for relation in comparisons {
            if let previous = baselines.last, previous - relation.baseline.y <= tolerance { continue }
            baselines.append(relation.baseline.y)
        }
        guard (2...5).contains(baselines.count),
              zip(baselines, baselines.dropFirst()).allSatisfy({ pair in
                  (fontHeight * 0.85...fontHeight * 2.5).contains(pair.0 - pair.1)
              }),
              let bottom = baselines.last,
              baselines[0] <= brace.maxY + tolerance, bottom >= brace.minY - tolerance,
              abs(baselines[0] - brace.maxY) <= fontHeight * 1.2,
              abs(bottom - brace.minY) <= fontHeight * 0.8 else { return nil }

        var rowGlyphs = Array(repeating: [Glyph](), count: baselines.count)
        for glyph in body {
            let y = glyph.baseline.y
            guard let index = baselines.indices.min(by: { abs(y - baselines[$0]) < abs(y - baselines[$1]) }),
                  abs(y - baselines[index]) <= fontHeight * 0.65 else { return nil }
            rowGlyphs[index].append(glyph)
        }

        var cells: [FormulaCircleDetail] = []
        var rows: [(expression: String, condition: String)] = []
        var rowText: [String] = []
        var conditionStart: CGFloat?
        for (baseline, row) in zip(baselines, rowGlyphs) {
            guard let relation = row.firstIndex(where: { relations.contains($0.text) }),
                  relation >= 2, relation < row.count - 1 else { return nil }
            let split = (1..<relation).max { gap(in: row, at: $0) < gap(in: row, at: $1) }!
            guard gap(in: row, at: split) >= fontHeight * 0.55 else { return nil }
            let separator = row[split].rect.minX
            if let conditionStart, abs(conditionStart - separator) > fontHeight * 0.55 { return nil }
            conditionStart = separator
            guard let left = cell(Array(row[..<split]), baseline: baseline, fontHeight: fontHeight),
                  let right = cell(Array(row[split...]), baseline: baseline, fontHeight: fontHeight),
                  let leftLatex = left.readingResult?.latex, let rightLatex = right.readingResult?.latex,
                  let leftText = left.readingResult?.sourceText, let rightText = right.readingResult?.sourceText
            else { return nil }

            // Check neighboring glyphs on the original page to reject a cropped
            // digit or a missing token inside either of the two columns.
            let originalRow = left.region.union(right.region).insetBy(dx: -fontHeight * 0.6, dy: 0)
            guard !page.indices.contains(where: { index in
                let glyph = page[index]
                return !enclosed.contains(index) && glyph.rect.midX > brace.maxX
                    && abs(glyph.baseline.y - baseline) <= tolerance
                    && originalRow.contains(CGPoint(x: glyph.rect.midX, y: glyph.rect.midY))
                    && glyph.text != "." && !glyph.text.allSatisfy(\.isWhitespace)
            }) else { return nil }

            cells += [left, right]
            rows.append((leftLatex, rightLatex))
            rowText.append(leftText + "    " + rightText)
        }
        let source = prefixText + " {\n" + rowText.joined(separator: "\n")
        guard let result = MathReadingService.resolveLayoutCases(sourceText: source, prefix: prefixLatex, rows: rows) else { return nil }
        let region = (prefix + body).reduce(brace) { $0.union($1.rect) }
        return Self(whole: FormulaCircleDetail(region: region, result: result), glyphs: prefix + body, cells: cells)
    }

    private static func braceBounds(_ glyphs: [Glyph]) -> CGRect? {
        if glyphs.count == 1, let glyph = glyphs.first, glyph.text == "{" { return glyph.rect }
        let sorted = glyphs.sorted { $0.rect.midY > $1.rect.midY }
        guard sorted.first?.text == "⎧", sorted.last?.text == "⎩",
              sorted.filter({ $0.text == "⎨" }).count == 1,
              sorted.dropFirst().dropLast().allSatisfy({ $0.text == "⎨" || $0.text == "⎪" }),
              let top = sorted.first,
              sorted.allSatisfy({ abs($0.rect.midX - top.rect.midX) <= top.rect.width })
        else { return nil }
        return sorted.reduce(CGRect.null) { $0.union($1.rect) }
    }

    private static func gap(in row: [Glyph], at split: Int) -> CGFloat {
        row[split].rect.minX - row[split - 1].rect.maxX
    }

    private static func cell(_ glyphs: [Glyph], baseline: CGFloat, fontHeight: CGFloat) -> FormulaCircleDetail? {
        guard let layout = NativeEquationCircleSelection.inlineLayout(glyphs, baseline: baseline, fontHeight: fontHeight) else { return nil }
        let text = layout.map(\.text).joined()
        guard let latex = NativeFractionReadingSelection.safeParserText(text),
              let parsed = MathReadingService.resolveVerifiedFragment(latex), parsed.status == .parsedText else { return nil }
        let reading = MathReadingResult(sourceText: text, latex: parsed.latex, unicode: parsed.unicode,
                                        explanation: parsed.explanation, status: parsed.status, ast: parsed.ast)
        return FormulaCircleDetail(region: glyphs.reduce(CGRect.null) { $0.union($1.rect) }, result: reading)
    }

    func detail(at point: CGPoint) -> FormulaCircleDetail? {
        let hits = glyphs.filter { $0.rect.contains(point) }
        if let glyph = hits.first, hits.count == 1 {
            return FormulaCircleDetail(region: glyph.rect, result: MathSymbolReading.detail(glyph.text), isGlyph: true)
        }
        let matchingCells = cells.filter { $0.region.contains(point) }
        return matchingCells.count == 1 ? matchingCells[0] : nil
    }
}
