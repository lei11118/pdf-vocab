import SwiftUI
import SwiftMath
import UIKit

enum MathCardRouting {
    static func resolve(sourceText: String,
                        contextReadingEnabled: Bool,
                        mathEnabled: Bool,
                        contextualSelectionIsCurrent: Bool = true,
                        isMathDetail: Bool = false) -> MathReadingResult? {
        guard contextReadingEnabled, mathEnabled, contextualSelectionIsCurrent else { return nil }
        // ReaderCoordinator caps display text at 400 characters and appends an ellipsis.
        // A truncated display value is not safe input for a parsed math result.
        guard !(sourceText.count > 400 && sourceText.hasSuffix("…")) else { return nil }
        if isMathDetail { return singleGlyphDetail(sourceText) }
        return MathReadingService.resolve(sourceText)
    }

    private static func singleGlyphDetail(_ sourceText: String) -> MathReadingResult {
        let glyph = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if glyph == sourceText, glyph.unicodeScalars.count == 1, let scalar = glyph.unicodeScalars.first,
           (48...57).contains(scalar.value) {
            return MathReadingResult(sourceText: glyph,
                                     latex: glyph,
                                     unicode: glyph,
                                     explanation: "数字 \(glyph)。它在公式中的位置决定它表示常数、系数还是索引。",
                                     status: .parsedText,
                                     ast: .number(glyph))
        }
        if glyph == sourceText, glyph.unicodeScalars.count == 1, let scalar = glyph.unicodeScalars.first,
           (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
            let caseName = scalar.value <= 90 ? "大写" : "小写"
            let explanation = MathSymbolLexicon.chineseName(for: glyph)
                ?? "拉丁\(caseName)字母 \(glyph)（变量；具体含义需结合公式上下文）"
            return MathReadingResult(sourceText: glyph,
                                     latex: glyph,
                                     unicode: glyph,
                                     explanation: explanation,
                                     status: .parsedText,
                                     ast: .symbol(glyph))
        }
        if glyph == "²" || glyph == "³" || glyph == "¹" || glyph == "⁰" {
            let value = ["²": "2", "³": "3", "¹": "1", "⁰": "0"][glyph]!
            return MathReadingResult(sourceText: glyph,
                                     latex: "{}^{\(value)}",
                                     unicode: glyph,
                                     explanation: "上标 \(value)；基底需由公式上下文确定。",
                                     status: .parsedText,
                                     ast: .symbol(glyph))
        }
        if glyph == "√" {
            return MathReadingResult(sourceText: glyph,
                                     latex: nil,
                                     unicode: glyph,
                                     explanation: "保留原字符供核对；平方根符号单独出现时缺少被开方数。",
                                     status: .needsReview,
                                     ast: .unknown(glyph))
        }
        if let entry = MathSymbolLexicon.entry(for: glyph) {
            return MathReadingResult(sourceText: glyph,
                                     latex: entry.latex,
                                     unicode: glyph,
                                     explanation: entry.chineseName,
                                     status: .parsedText,
                                     ast: .symbol(glyph))
        }
        return MathReadingResult(sourceText: sourceText,
                                 latex: nil,
                                 unicode: sourceText,
                                 explanation: "保留原字符供核对；目前无法安全地单独排版。",
                                 status: .needsReview,
                                 ast: .unknown(sourceText))
    }
}

struct MathMeaningCard: View {
    @Environment(\.readerPanelClose) private var panelClose
    let result: MathReadingResult
    let onClose: () -> Void
    var sourceImage: UIImage? = nil
    @State private var copied = false
    @State private var copiedLatex = false
    @ScaledMetric(relativeTo: .title2) private var formulaFontSize: CGFloat = 24

    private var isParsed: Bool { result.status == .parsedText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("数学释义")
                            .font(DS.Fonts.title2)
                            .foregroundStyle(DS.foreground1)
                        Text(result.status == .parsedOCR ? "扫描候选 · 待核对" : isParsed ? "文字结构已解析" : "结构待核对")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isParsed ? DS.accent : DS.caution)
                            .accessibilityIdentifier("math-card-status")
                    }
                    Spacer(minLength: 4)
                    if panelClose == nil {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭窗口")
                    }
                }
                .padding(.trailing, panelClose == nil ? 0 : 44)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("原文")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.foreground2)
                    if let sourceImage {
                        Image(uiImage: sourceImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 120, alignment: .leading)
                            .accessibilityLabel("公式原页裁剪")
                            .accessibilityIdentifier("math-card-original-crop")
                    }
                    Text(result.sourceText)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(DS.foreground1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("math-card-source")
                }

                if let latex = result.latex, !latex.isEmpty, isParsed || result.status == .parsedOCR {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(result.status == .parsedOCR ? "候选排版" : "公式排版")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.foreground2)
                        ScrollView(.horizontal) {
                            MathFormulaLabel(latex: latex, fontSize: formulaFontSize)
                                .fixedSize(horizontal: true, vertical: true)
                                .padding(DS.Space.s)
                        }
                        .background(DS.background1, in: RoundedRectangle(cornerRadius: DS.Radius.sharp))
                        .accessibilityIdentifier("math-card-rendered-formula")

                        HStack {
                            Text("LaTeX")
                                .font(DS.Fonts.caption)
                                .foregroundStyle(DS.foreground2)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = latex
                                copiedLatex = true
                            } label: {
                                Label(copiedLatex ? "已复制" : "复制 LaTeX",
                                      systemImage: copiedLatex ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.medium))
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("math-card-copy-latex")
                        }
                        Text(latex)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DS.foreground1)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("math-card-latex")
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("解析说明")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.foreground2)
                    Text(result.explanation)
                        .font(.callout)
                        .foregroundStyle(DS.foreground1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("math-card-explanation")
                }

                if isParsed, result.ast?.isComplete == true {
                    Label("结构解析完整", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(DS.accent)
                } else {
                    Label("请对照原图核对符号与结构。",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(DS.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack {
                        Text("Unicode 形式")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.foreground2)
                        Spacer()
                        if let unicode = result.unicode, !unicode.isEmpty {
                            Button {
                                UIPasteboard.general.string = unicode
                                copied = true
                            } label: {
                                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.medium))
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("math-card-copy-unicode")
                        }
                    }
                    if let unicode = result.unicode, !unicode.isEmpty {
                        Text(unicode)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DS.foreground1)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("math-card-unicode")
                    } else {
                        Text("此结构没有可无损复制的 Unicode 形式。")
                            .font(.callout)
                            .foregroundStyle(DS.foreground2)
                    }
                }

                if !isParsed {
                    Text("当前版本只解析选中的公式文字，不识别页面中的公式图片。")
                        .font(.caption)
                        .foregroundStyle(DS.foreground2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.m)
        }
        .background(DS.background2)
        .accessibilityIdentifier("math-card-scroll-content")
        .onChange(of: result) { _, _ in
            copied = false
            copiedLatex = false
        }
    }
}

private struct MathFormulaLabel: UIViewRepresentable {
    let latex: String
    let fontSize: CGFloat

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        label.latex = latex
        label.labelMode = .text
        label.textAlignment = .left
        label.fontSize = fontSize
        label.textColor = UIColor.label
        label.invalidateIntrinsicContentSize()
    }
}

struct CompactMathCardContent: View {
    let result: MathReadingResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.sourceText)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("compact-math-source")
            Text(result.status == .parsedText ? "数学文字已解析" : "数学结构待核对")
                .font(.caption2)
                .foregroundStyle(result.status == .parsedText ? DS.accent : DS.caution)
                .lineLimit(1)
                .accessibilityIdentifier("compact-math-status")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.leading, 16)
        .padding(.trailing, 92)
        .accessibilityIdentifier("compact-math-card")
    }
}
