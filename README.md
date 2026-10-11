# 读词 · pdf-vocab

在 iPad 上读英文 PDF 时,长按/拖选(Pencil 也行)选中单词 → 加亮 → 侧边弹出词典卡牌(音标、发音、释义、例句);
单词可归入分组/标签,最终导出 Anki 卡牌组。Apple Pencil Pro 可用系统原生标记工具直接在 PDF 上批注。

- **纯本地**:无账号、无登录、无云同步、无广告、无内购、无统计埋点;数据全部存在本机
- **自签侧载**:只用免费 Apple ID(AltStore / SideStore / Sideloadly)
- **不需要 Mac**:全部通过 GitHub Actions 出包(未签名 IPA)

> 当前状态:**M1(修复版 `v0.2.9`)** —— PDF 导入(文件选择器)、阅读、长按/拖选取词(手指与 Pencil 统一自有管线,且**不再设置 PDFView 选区**)、临时加亮、阅读进度记忆;**规范化读取副本**(针对 PDFKit 异常文档,首次打开自动生成);跳页护栏;全量诊断日志页。
> 开发方案、核实结论与里程碑见 [docs/PLAN.md](docs/PLAN.md)。

## 获取 IPA

### 方式 A:手动触发 Actions 构建
1. 打开仓库的 **Actions** 标签页 → 选择 **build-ipa** → **Run workflow**
2. 等约 5–15 分钟,构建完成后在该次运行的 **Artifacts** 里下载 `PdfVocab-unsigned-ipa`(zip,内含 .ipa)

### 方式 B:发布版(推荐)
- **Releases** 页面直接下载 `PdfVocab-unsigned.ipa`(推送 tag 如 `v0.1.0` 时自动发布)

## 安装到 iPad(免费 Apple ID)

`.ipa` 是**未签名**的,需要用自己的 Apple ID 现场签名安装。三种方式任选:

### AltStore(推荐:同一 Wi-Fi 下自动 7 天刷新)
1. Windows 电脑安装 [AltServer](https://altstore.io)(需已装 iTunes / Apple 设备驱动)
2. AltServer 菜单栏 → Install AltStore → 选择你的 iPad,把 AltStore 装进 iPad
3. 在 **iPad 的 Safari** 打开本仓库 Release 页,下载 `.ipa` → 分享 → 用 AltStore 打开并安装
4. 首次安装后:iPad 设置 → 通用 → VPN与设备管理 → 信任你的开发者证书
5. 保持 AltServer 与 iPad 在同一 Wi-Fi,AltStore 会自动刷新(也可手动 Refresh All)

### Sideloadly(Windows 直接签名安装)
1. Windows 安装 [Sideloadly](https://sideloadly.io)(同样需要 iTunes / Apple 设备驱动)
2. 用数据线连接 iPad,把 `.ipa` 拖进 Sideloadly,填 Apple ID → Start
3. iPad 上信任证书后即可使用;7 天到期后重跑一次

### SideStore(无需常开电脑)
- 参考 [SideStore 文档](https://docs.sidestore.io) 安装 SideStore 本体(需要一次性配对文件),之后可在 iPad 上直接安装与刷新

## 免费账号限制说明

| 限制 | 值 | 对本项目的影响 |
|---|---|---|
| 描述文件有效期 | 7 天 | 到期 App 打不开;用 AltStore 自动刷新或重新签名即可,**数据不丢** |
| 每设备 App 数 | 3 个 | 一般够用;不够时 AltStore 支持"停用"其他 App |
| App ID | 10 个 / 7 天 | 本项目无 App Extension,只占 1 个 |
| 数据安全 | 删除 App = 数据丢失 | 重签/刷新不会丢;**删 App 前请先导出备份(P2 功能,规划中)** |

## 本地构建(可选,需要 Mac + Xcode)

```bash
brew install xcodegen
xcodegen generate
open PdfVocab.xcodeproj
```

CI 固定工具链(见 `docs/PLAN.md`):`macos-26` 镜像 + Xcode 26.6。

## 目录结构

```
.github/workflows/build-ipa.yml   出包流水线(archive 关签名 → Payload 打包 → Artifact/Release)
project.yml                       XcodeGen 工程定义(SPM 依赖:GRDB、ZIPFoundation)
Sources/App/                      App 入口与界面(随里程碑扩展)
Resources/                        Assets.xcassets、Info.plist(XcodeGen 生成)
docs/PLAN.md                      开发方案:核实结论 / 数据模型 / 里程碑 / 风险
```

## 技术栈与许可证

Swift + SwiftUI + PDFKit / PencilKit / Vision / NaturalLanguage / AVFoundation;
[GRDB.swift](https://github.com/groue/GRDB.swift)(MIT)、[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)(MIT)、
词库数据 [ECDICT](https://github.com/skywind3000/ECDICT)(MIT)。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
