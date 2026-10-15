import PDFKit

/// 原句提取(v0.8.2):只用"点坐标 API"(`selectionForLine(at:)`),不碰字符索引——
/// 规避 iOS 18+ PDFKit 的字符索引/几何顺序回归(FB14843671)。
///
/// 策略(以选区首/末行为锚,行矩形均为**页坐标**):
///  1. 向下:逐行扩展——先补齐选区覆盖(到末行),再继续到句末标点;
///  2. 向上:上一行不以句末标点收尾则并入,直到句子起点(遇段落大间隙/页首即止);
///  3. 拼接:行末连字符去连字直拼,其余以空格连接。
enum SentenceExtractor {

    /// 提取包含 [firstLine, lastLine] 所在行的整句;失败(无文本层等)返回 nil。
    static func sentenceContext(firstLine: CGRect, lastLine: CGRect, on page: PDFPage, maxLines: Int = 10) -> String? {
        guard let firstSel = page.selectionForLine(at: CGPoint(x: firstLine.minX + 4, y: firstLine.midY)),
              let firstText = firstSel.string,
              !firstText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var lines: [PDFSelection] = [firstSel]
        var bottom = firstSel.bounds(for: page)

        // 1) 向下:覆盖选区 + 扩到句末
        var steps = 0
        while steps < maxLines {
            steps += 1
            let lastText = (lines.last?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let covered = bottom.midY <= lastLine.midY + 0.5
            if covered && endsSentence(lastText) { break }
            let probe = CGPoint(x: bottom.minX + 4, y: bottom.minY - max(bottom.height * 0.65, 5))
            guard let next = page.selectionForLine(at: probe),
                  let nextText = next.string, !nextText.isEmpty,
                  nextText != lines.last?.string else { break }
            let nextBounds = next.bounds(for: page)
            if nextBounds.maxY < bottom.minY - max(bottom.height * 1.6, 14) { break }   // 段落大间隙 → 断段
            lines.append(next)
            bottom = nextBounds
        }

        // 2) 向上:上一行未收句则并入
        var top = firstSel.bounds(for: page)
        steps = 0
        while steps < maxLines {
            steps += 1
            let probe = CGPoint(x: top.minX + 4, y: top.maxY + max(top.height * 0.65, 5))
            guard let up = page.selectionForLine(at: probe),
                  let upText = up.string, !upText.isEmpty,
                  upText != lines.first?.string else { break }
            if endsSentence(upText) { break }                                           // 上文已收句 → 不并入
            let upBounds = up.bounds(for: page)
            if upBounds.minY > top.maxY + max(top.height * 1.2, 12) { break }           // 段落大间隙 → 不跨段
            lines.insert(up, at: 0)
            top = upBounds
        }

        let raw = lines.compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var text = raw.first else { return nil }
        for line in raw.dropFirst() {
            if text.hasSuffix("-") {
                text.removeLast()
                text += line
            } else {
                text += " " + line
            }
        }
        return text
    }

    /// 是否以句末标点收尾(容忍其后的引号/括号)。
    private static func endsSentence(_ s: String) -> Bool {
        var chars = Array(s.reversed())
        while let c = chars.first, "”\"’')）]}".contains(c) { chars.removeFirst() }
        guard let c = chars.first else { return false }
        return ".!?…。！？".contains(c)
    }
}
