import SwiftUI
import UIKit

/// Paper Modern 设计系统 v0.15.0 —— 依据《Notability 16.13 逆向学习》references
/// (`tokens.json` 采样色 + `03-design-language.md` 类型/间距/圆角规格)重构:
/// **中性面(#F6F6F8)+ 白卡 + 一个强调蓝(#5A89FF)**;90% 中性、1 个强调色,彩色只留给内容与状态。
/// 规则:组件不得直接写十六进制色/字号/阴影——一律引用这里的 token。
enum DS {

    // MARK: - 采样品牌 / 内容色(references/tokens.json · sampled)

    /// 品牌蓝(营销面/插画主色)
    static let brandBlue = dynamic(light: 0x5497FE, dark: 0x5497FE)
    /// 主操作蓝(Chat 发送按钮采样)
    static let actionBlue = dynamic(light: 0x4377FF, dark: 0x6B95FF)
    /// 选中底(文本工具栏选中态采样)
    static let selectedTint = dynamic(light: 0xECF2FF, dark: 0x1C2A45)
    /// 中性面(卡片容器底)
    static let surfaceNeutral = dynamic(light: 0xF6F6F8, dark: 0x101215)
    /// 内容卡片面
    static let surfaceWhite = dynamic(light: 0xFFFFFF, dark: 0x1A1D21)
    /// 工具图标描边灰
    static let iconGray = dynamic(light: 0x444F60, dark: 0xAEB6C2)
    /// 录音/警示红
    static let recordRed = dynamic(light: 0xED5279, dark: 0xFF6E8C)
    /// 暖白纸面(画布外沿)
    static let paperWhite = dynamic(light: 0xFBF8F3, dark: 0x14161A)
    /// 内容色(采样自荧光笔调色盘)
    static let inkYellow = dynamic(light: 0xFDFD01, dark: 0xFDFD01)
    static let inkLime = dynamic(light: 0xA9FD1B, dark: 0xA9FD1B)
    static let inkMagenta = dynamic(light: 0xFD00D4, dark: 0xFD00D4)
    static let inkBlack = dynamic(light: 0x0A0A0A, dark: 0x0A0A0A)

    // MARK: - 语义色(自动适配浅色 / 深色)

    /// 背景 1:页面底(中性灰)
    static let background1 = dynamic(light: 0xF6F6F8, dark: 0x101215)
    /// 背景 2:卡片 / 面板
    static let background2 = dynamic(light: 0xFFFFFF, dark: 0x1A1D21)
    /// 背景 3:浮层(工具托盘、词卡)
    static let background3 = dynamic(light: 0xFFFFFF, dark: 0x23262B)
    /// 背景 4:选中底 / 强调容器
    static let background4 = dynamic(light: 0xECF2FF, dark: 0x26334A)

    /// 前景 1:主文字
    static let foreground1 = dynamic(light: 0x0E1116, dark: 0xF3F5F8)
    /// 前景 2:次文字 / 图标灰
    static let foreground2 = dynamic(light: 0x444F60, dark: 0xAEB6C2)
    /// 前景 3:弱提示
    static let foreground3 = dynamic(light: 0x8892A6, dark: 0x7C8595)
    /// 前景 4:禁用 / 极弱
    static let foreground4 = dynamic(light: 0xC3C9D4, dark: 0x4E5665)

    /// 主强调(选中、当前工具、链接)
    static let accent = dynamic(light: 0x5A89FF, dark: 0x7BA3FF)
    /// 主色浅底(选中容器)
    static let accentContainer = dynamic(light: 0xECF2FF, dark: 0x1C2A45)
    /// 主色上的文字 / 图标
    static let onAccent = Color.white
    /// 次级强调
    static let secondary = dynamic(light: 0x6E7C91, dark: 0x8E9AAD)

    static let success = dynamic(light: 0x2E9E63, dark: 0x55C289)
    static let caution = dynamic(light: 0xD98E24, dark: 0xE3A94D)
    static let alert = dynamic(light: 0xED5279, dark: 0xFF6E8C)
    static let incorrect = dynamic(light: 0xC74440, dark: 0xE06B67)

    /// 内容 / 品牌辅助色(标签、分组、插画位)
    static let ink = dynamic(light: 0x0A0A0A, dark: 0x0A0A0A)
    static let coral = dynamic(light: 0xFF8E4D, dark: 0xFF8E4D)
    static let sage = dynamic(light: 0x8FA98D, dark: 0x8FA98D)
    static let sky = dynamic(light: 0x86B9DB, dark: 0x86B9DB)
    static let terracotta = dynamic(light: 0xC97B5D, dark: 0xC97B5D)

    /// UIKit 侧使用(画布外沿:暖白纸面)
    static let uiBackground1 = UIColor(dynamicProvider: { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0x14161A) : UIColor(hex: 0xFBF8F3)
    })

    // MARK: - 间距(4pt 基准;9 级)

    enum Space {
        static let x4s: CGFloat = 2
        static let x3s: CGFloat = 4
        static let x2s: CGFloat = 6
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - 圆角(sharp / regular / comfy / pill)

    enum Radius {
        static let sharp: CGFloat = 4
        static let regular: CGFloat = 12
        static let comfy: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: - 语义字号(references/tokens.json · inferred)

    enum Fonts {
        static let display3 = Font.system(size: 28, weight: .bold)
        static let title1 = Font.system(size: 26, weight: .bold)
        static let title2 = Font.system(size: 22, weight: .semibold)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let subhead = Font.system(size: 15, weight: .regular)
        static let body = Font.system(size: 17, weight: .regular)
        static let caption = Font.system(size: 13, weight: .regular)
        static let caption2 = Font.system(size: 11, weight: .medium)
        static let micro = Font.system(size: 10, weight: .medium)
    }

    // MARK: - 卡片(白面 + 轻描边 + 极轻阴影;卡片几乎无阴影,靠底色分层)

    struct PaperCard: ViewModifier {
        var radius: CGFloat = DS.Radius.comfy
        var padding: CGFloat = DS.Space.m

        func body(content: Content) -> some View {
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(DS.background2)
                        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(DS.foreground1.opacity(0.06), lineWidth: 0.8)
                )
        }
    }

    // MARK: - 动态色工具

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor(dynamicProvider: { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }))
    }
}

extension View {
    /// 卡片:用于文档卡、提示块、浮层内容。
    func dsCard(radius: CGFloat = DS.Radius.comfy, padding: CGFloat = DS.Space.m) -> some View {
        modifier(DS.PaperCard(radius: radius, padding: padding))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

/// 纸纹背景(可选):暖白底 + 细微纸纹。v0.15.0 起文档库/词表改用中性面 `DS.background1`,
/// 纸纹仅保留给需要"纸张感"的内容面;素材缺失时自动退化为纯色。
struct PaperBackground: View {
    var body: some View {
        ZStack {
            DS.paperWhite
            if let grain = UIImage(named: "paper-grain") {
                Image(uiImage: grain)
                    .resizable(resizingMode: .tile)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}
