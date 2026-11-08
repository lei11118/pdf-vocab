import Foundation

public enum MathSymbolLexicon {
    public struct Entry: Equatable, Sendable {
        public let chineseName: String
        public let latex: String

        public init(chineseName: String, latex: String) {
            self.chineseName = chineseName
            self.latex = latex
        }
    }

    private static let symbolEntries: [String: Entry] = {
        var entries: [String: Entry] = [:]

        let greek: [(String, String, String)] = [
            ("α", "希腊小写 alpha", "\\alpha"), ("β", "希腊小写 beta", "\\beta"),
            ("γ", "希腊小写 gamma", "\\gamma"), ("δ", "希腊小写 delta", "\\delta"),
            ("ε", "希腊小写 epsilon", "\\varepsilon"), ("ζ", "希腊小写 zeta", "\\zeta"),
            ("η", "希腊小写 eta", "\\eta"), ("θ", "希腊小写 theta", "\\theta"),
            ("ι", "希腊小写 iota", "\\iota"), ("κ", "希腊小写 kappa", "\\kappa"),
            ("λ", "希腊小写 lambda", "\\lambda"), ("μ", "希腊小写 mu", "\\mu"),
            ("ν", "希腊小写 nu", "\\nu"), ("ξ", "希腊小写 xi", "\\xi"),
            ("ο", "希腊小写 omicron", "ο"), ("π", "希腊小写 pi", "\\pi"),
            ("ρ", "希腊小写 rho", "\\rho"), ("σ", "希腊小写 sigma", "\\sigma"),
            ("ς", "希腊小写 final sigma", "\\varsigma"), ("τ", "希腊小写 tau", "\\tau"),
            ("υ", "希腊小写 upsilon", "\\upsilon"), ("φ", "希腊小写 phi", "\\varphi"),
            ("χ", "希腊小写 chi", "\\chi"), ("ψ", "希腊小写 psi", "\\psi"),
            ("ω", "希腊小写 omega", "\\omega"), ("ϵ", "希腊小写 epsilon symbol", "\\epsilon"),
            ("ϑ", "希腊小写 theta symbol", "\\vartheta"), ("ϖ", "希腊小写 pi symbol", "\\varpi"),
            ("ϱ", "希腊小写 rho symbol", "\\varrho"), ("ϕ", "希腊小写 phi symbol", "\\phi"),
            ("𝜖", "数学斜体小写 epsilon", "\\epsilon"), ("𝜙", "数学斜体小写 phi", "\\phi"),
            ("Α", "希腊大写 Alpha", "Α"), ("Β", "希腊大写 Beta", "Β"),
            ("Γ", "希腊大写 Gamma", "\\Gamma"), ("Δ", "希腊大写 Delta", "\\Delta"),
            ("Ε", "希腊大写 Epsilon", "Ε"), ("Ζ", "希腊大写 Zeta", "Ζ"),
            ("Η", "希腊大写 Eta", "Η"), ("Θ", "希腊大写 Theta", "\\Theta"),
            ("Ι", "希腊大写 Iota", "Ι"), ("Κ", "希腊大写 Kappa", "Κ"),
            ("Λ", "希腊大写 Lambda", "\\Lambda"), ("Μ", "希腊大写 Mu", "Μ"),
            ("Ν", "希腊大写 Nu", "Ν"), ("Ξ", "希腊大写 Xi", "\\Xi"),
            ("Ο", "希腊大写 Omicron", "Ο"), ("Π", "希腊大写 Pi", "\\Pi"),
            ("Ρ", "希腊大写 Rho", "Ρ"), ("Σ", "希腊大写 Sigma", "\\Sigma"),
            ("Τ", "希腊大写 Tau", "Τ"), ("Υ", "希腊大写 Upsilon", "Υ"),
            ("Φ", "希腊大写 Phi", "\\Phi"), ("Χ", "希腊大写 Chi", "Χ"),
            ("Ψ", "希腊大写 Psi", "\\Psi"), ("Ω", "希腊大写 Omega", "\\Omega")
        ]
        for (symbol, name, latex) in greek {
            entries[symbol] = Entry(chineseName: name, latex: latex)
        }

        let common: [(String, String, String)] = [
            ("+", "加号", "+"), ("−", "减号", "-"), ("-", "连字符或减号（依原式位置）", "-"),
            ("×", "乘号", "\\times"), ("⋅", "点乘号", "\\cdot"), ("·", "间隔乘点", "\\cdot"),
            ("÷", "除号", "\\div"), ("/", "斜线；不推断分数结合", "/"),
            ("±", "正负号", "\\pm"), ("∓", "负正号", "\\mp"), ("=", "等号", "="),
            ("≠", "不等号", "\\neq"), ("≈", "约等于", "\\approx"), ("≡", "恒等或同余符号", "\\equiv"),
            ("<", "小于号", "<"), (">", "大于号", ">"), ("≤", "小于等于", "\\leq"),
            ("≥", "大于等于", "\\geq"), ("∞", "无穷大", "\\infty"), ("∑", "求和符号", "\\sum"),
            ("∏", "连乘符号", "\\prod"), ("∫", "积分符号", "\\int"), ("∮", "闭合积分符号", "\\oint"),
            ("∂", "偏导符号", "\\partial"), ("∇", "nabla 算子", "\\nabla"), ("√", "平方根号", "\\sqrt"),
            ("∈", "属于", "\\in"), ("∉", "不属于", "\\notin"), ("⊂", "真子集符号", "\\subset"),
            ("⊆", "子集或相等", "\\subseteq"), ("∪", "并集", "\\cup"), ("∩", "交集", "\\cap"),
            ("∧", "逻辑与", "\\wedge"), ("∨", "逻辑或", "\\vee"), ("→", "右箭头", "\\rightarrow"),
            ("←", "左箭头", "\\leftarrow"), ("↔", "双向箭头", "\\leftrightarrow"),
            ("⇒", "蕴含箭头", "\\Rightarrow"), ("⇔", "等价箭头", "\\Leftrightarrow"),
            ("∀", "全称量词", "\\forall"), ("∃", "存在量词", "\\exists"),
            ("ℏ", "约化普朗克常数", "\\hbar"), ("ℓ", "花体小写 ell", "\\ell"),
            ("x", "拉丁小写 x（变量；含义未知）", "x"), ("v", "拉丁小写 v（变量；含义未知）", "v"),
            ("l", "拉丁小写 l（字母，不是数字 1）", "l"), ("1", "数字 1（不是字母 l）", "1")
        ]
        for (symbol, name, latex) in common {
            entries[symbol] = Entry(chineseName: name, latex: latex)
        }
        return entries
    }()

    public static func entry(for symbol: String) -> Entry? {
        symbolEntries[symbol]
    }

    public static func chineseName(for symbol: String) -> String? {
        entry(for: symbol)?.chineseName
    }

    public static func latex(for symbol: String) -> String? {
        entry(for: symbol)?.latex
    }
}
