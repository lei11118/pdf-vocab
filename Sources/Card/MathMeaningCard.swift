import SwiftUI
import SwiftMath
import UIKit

enum MathCardRouting {
    static func resolve(sourceText: String,
                        contextReadingEnabled: Bool,
                        mathEnabled: Bool,
                        contextualSelectionIsCurrent: Bool = true) -> MathReadingResult? {
        guard contextReadingEnabled, mathEnabled, contextualSelectionIsCurrent else { return nil }
        // ReaderCoordinator caps display text at 400 characters and appends an ellipsis.
        // A truncated display value is not safe input for a parsed math result.
        guard !(sourceText.count > 400 && sourceText.hasSuffix("…")) else { return nil }
        return MathReadingService.resolve(sourceText)
    }
}

struct MathMeaningCard: View {
    @Environment(\.readerPanelClose) private var panelClose
    let result: MathReadingResult
    let onClose: () -> Void
    @State private var copied = false
    @State private var copiedLatex = false

    private var isParsed: Bool { result.status == .parsedText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("数学符号与公式文字")
                            .font(DS.Fonts.wordTitle)
                            .foregroundStyle(DS.foreground1)
                        Text(isParsed ? "文字结构已解析" : "结构待核对")
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
                    Text(result.sourceText)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(DS.foreground1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("math-card-source")
                }

                if isParsed, let latex = result.latex, !latex.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("公式排版")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.foreground2)
                        ScrollView(.horizontal) {
                            MathFormulaLabel(latex: latex)
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
                    Label("请对照原文核对符号结构；此结果不代表数学证明或图像识别。",
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
        label.fontSize = 24
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
