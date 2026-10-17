import SwiftUI
import UIKit

/// Paper Modern 设计系统(v0.14.0)
/// 依据《Notability 16.13 逆向学习 Skill》提炼的**语义化 token 设计**(非像素复刻,不使用其任何专有资产):
/// 暖纸面 + 现代排版 + 语义色层级 + 克制动效。
/// 规则:组件不得直接写十六进制色/字号/阴影——一律引用这里的 token。
enum DS {

    // MARK: - 语义色(自动适配浅色 / 深色)

    /// 背景 1:主背景(暖纸白 / 墨黑)
    static let background1 = dynamic(light: 0xF7F4EC, dark: 0x151412)
    /// 背景 2:次级面板 / 工具条底
    static let background2 = dynamic(light: 0xEFEBDF, dark: 0x1D1C19)
    /// 背景 3:浮层 / 卡片
    static let background3 = dynamic(light: 0xFFFFFF, dark: 0x26241F)
    /// 背景 4:强调容器 / 选中底
    static let background4 = dynamic(light: 0xE8E3D3, dark: 0x322F28)

    /// 前景 1:主文字 / 主图标
    static let foreground1 = dynamic(light: 0x171510, dark: 0xF3EFE2)
    /// 前景 2:次文字
    static let foreground2 = dynamic(light: 0x5B564A, dark: 0xB7B1A1)
    /// 前景 3:弱提示 / 占位
    static let foreground3 = dynamic(light: 0x8B8678, dark: 0x8D8879)
    /// 前景 4:禁用 / 极弱
    static let foreground4 = dynamic(light: 0xC2BDAD, dark: 0x5C584D)

    /// 主操作 / 当前工具 / 链接(Notability 蓝)
    static let accent = dynamic(light: 0x0A84FF, dark: 0x3D9BFF)
    /// 主色浅底(选中态容器)
    static let accentContainer = dynamic(light: 0xE3F0FF, dark: 0x12263D)
    /// 主色上的文字 / 图标
    static let onAccent = Color.white
    /// 次级强调
    static let secondary = dynamic(light: 0x6E8B96, dark: 0x8FA9B2)

    static let success = dynamic(light: 0x2E9E63, dark: 0x55C289)
    static let caution = dynamic(light: 0xD98E24, dark: 0xE3A94D)
    static let alert = dynamic(light: 0xD2544A, dark: 0xE5766D)
    static let incorrect = dynamic(light: 0xC74440, dark: 0xE06B67)

    /// 内容 / 品牌辅助色(用于标签、分组、贴纸位;不是 UI 状态色)
    static let ink = dynamic(light: 0x14120E, dark: 0x14120E)
    static let coral = dynamic(light: 0xFF8E4D, dark: 0xFF8E4D)
    static let sage = dynamic(light: 0x8FA98D, dark: 0x8FA98D)
    static let sky = dynamic(light: 0x86B9DB, dark: 0x86B9DB)
    static let terracotta = dynamic(light: 0xC97B5D, dark: 0xC97B5D)

    /// UIKit 侧使用(PDFView 背景等)
    static let uiBackground1 = UIColor(dynamicProvider: { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0x151412) : UIColor(hex: 0xF7F4EC)
    })

    // MARK: - 间距(4pt 基准)

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

    // MARK: - 圆角

    enum Radius {
        static let sharp: CGFloat = 6
        static let regular: CGFloat = 12
        static let comfy: CGFloat = 18
    }

    // MARK: - 语义字号(与 Dynamic Type 联动由系统字体负责)

    enum Fonts {
        static let display3 = Font.system(size: 28, weight: .bold)
        static let title1 = Font.system(size: 24, weight: .bold)
        static let title2 = Font.system(size: 20, weight: .semibold)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let subhead = Font.system(size: 15, weight: .regular)
        static let body = Font.system(size: 16, weight: .regular)
        static let caption = Font.system(size: 13, weight: .regular)
        static let caption2 = Font.system(size: 11, weight: .regular)
        static let micro = Font.system(size: 10, weight: .medium)
    }

    // MARK: - 纸感卡片(暖底 + 轻描边 + 柔和阴影;纸感来自叠层,不来自复古装饰)

    struct PaperCard: ViewModifier {
        var radius: CGFloat = DS.Radius.comfy
        var padding: CGFloat = DS.Space.m

        func body(content: Content) -> some View {
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(DS.background3)
                        .shadow(color: Color.black.opacity(0.07), radius: 12, x: 0, y: 4)
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
    /// 纸感卡片:用于文档卡、提示块、浮层内容。
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

/// 纸感背景:暖底 + 细微纸纹(自制素材 paper-grain;无资产时自动退化为纯色)。
/// 依据设计原则:纸纹只出现在内容表面(文档库 / 词卡),系统面板保持现代。
struct PaperBackground: View {
    var body: some View {
        ZStack {
            DS.background1
            if let grain = UIImage(named: "paper-grain") {
                Image(uiImage: grain)
                    .resizable(resizingMode: .tile)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}
