# ★标记★ iPadOS 26 语境 Token 与数学识别实施现状

> 本文是当前实现与阶段状态的权威说明。按代码核对日期：2026-11-05。
> 核查基线：`codex/v062-interaction-rebuild`，`618b4c0b03f89a82c5ba636500d6de11b572bb8e`（v0.70.0 / build 118，G1）；G2a 当前为未提交工作差异。
> 设计来源：`pdf-vocab：iPadOS 26 语境 Token 与数学表达式智能阅读系统`。设计文档描述目标，不证明功能已实现。

## 当前基座与边界

- iPad 专用应用；Bundle ID 为 `com.lei11118.pdfvocab`。G0 不修改 Bundle ID、营销版本或 build 号。
- G0 系统升级、G1 测试与 archive 已通过 CI；两张语境卡截图已由主脑视觉审阅通过。当前代码差异不代表发布验收完成。
- 新能力后续必须保持本地运行；总开关默认关闭，关闭后回到当前阅读路径。
- 保留现有单击链接跳转；不新增单击选词。当前双击和长按选词继续可用。
- 保留尺子的现有位置与手势；保留用户指定的不可拖动双层弧形工具栏，以及编辑、颜色和笔宽管理。
- 保留现有词卡和独立整句翻译。新语境词卡不得展示原句或整句译文。
- 数据库已有 v13 migration；后续如需改库，只能追加 v14 或更高版本。

以上产品约束是后续阶段要求，不表示 G0 已实现或验证了这些能力。

## 源码核实的现有接口

| 区域 | 当前实现 | 尚不存在的能力 |
|---|---|---|
| PDF 文字选取 | `Sources/Reader/Selection/ReaderCoordinator.swift` 管理手势；双击和长按通过 `SelectionGeometry` 命中，几何与字形布局分别在 `Sources/Reader/Selection/SelectionKit.swift` 和 `PDFTextLayout.swift`。单击仍处理链接、已有选区菜单和空白处清除。 | 没有方案文档描述的 `selectionForWord(at:)` 路由；不应整体替换协调器或改变单击语义。 |
| 扫描 PDF OCR | 已提交基座按区域调用 Vision `.accurate`，再用英文字母词正则生成 `OCRWord`；`Sources/OCR/OCRStore.swift` 保存旧词框。G2a 工作差异新增同步完整行候选采集、`ContextOCRPage` 和独立 JSON page store，尚未提交或 CI 验证。 | 不生成字符级框，不接入生产调度；尚无数学结构。 |
| 整句翻译 | `Sources/Card/ReaderSentenceTranslationView.swift` 的 `SentenceTranslationTask` 使用 SwiftUI `translationTask` 执行英语到简体中文的普通句子翻译。 | 没有语境服务、词级对齐或可验证的词义对应结果。 |
| 数据库迁移 | 已提交基座最后一项为 `v13.workspaceFolders`；G2a 工作差异仅追加 `v14.contextOCRPages`。 | v14 尚未 CI 验证；不重写已有迁移或触碰旧 OCR 表。 |

## 阶段状态

| 阶段 | 状态 | 证据 / 下一步 |
|---|---|---|
| G0 系统升级 | 通过 CI | [test-ink run 41988049409](https://github.com/lei11118/pdf-vocab/actions/runs/41988049409)：97 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；[build-ipa run 41988049058](https://github.com/lei11118/pdf-vocab/actions/runs/41988049058)：archive/unsigned IPA 成功。CI 通过不替代真实 iPad/Pencil 验收。 |
| G1 Token 选择 | CI 与截图审阅通过 | [test-ink run 41996577706](https://github.com/lei11118/pdf-vocab/actions/runs/41996577706)：104 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；Token 模型 5 项测试、OpenStax 真实 PDF 路由、Coordinator 拖选与截图用例均通过，导出 37 个 UIReview 附件。[build-ipa run 41996594391](https://github.com/lei11118/pdf-vocab/actions/runs/41996594391)：archive 与 unsigned IPA 成功。IPA 已独立核验 ZIP CRC、0.70.0/118、MinimumOSVersion 26.0、ARM64、`science.sqlite`；SHA-256 为 `7a9869452472739997564306d864e1f2247a00d964b6078a78802c324841d6a5`。浅色与窄宽深色截图已由主脑视觉审查通过。已提交的 G1 PDF Token `sentenceID`/`blockID` 仍为 nil，尚未完成句子/文本块分段，也没有可验证的语境译义。原文范围与显示 surface 分开保存；不确定几何不强行拆 token。此阶段验证不代表发布完成。 |
| G2 OCR 改进 | G2a 工作差异待审查与 CI | 当前未提交差异新增纯值 OCR 行/候选/Token 几何模型、同步 Vision 采集、v14 单页 JSON store 和回归测试；所有 OCR token geometry 最多标记 `.word`，不构造字符框。PDF 识别仍未接入生产调度，未改 Reader/手势/旧 OCR 表，未做 `.fast` 精化。Windows 环境未运行 Swift/Xcode 测试；合成 raster 的 CER/WER 仅在 test-ink 执行后报告，暂为待验证。G1 PDF Token 的 blockID 仍 nil；G2a OCR 行工作差异尝试加入稳定 blockID，但未编译验证；sentenceID/句子映射仍未实现。 |
| G3 系统翻译 | 未开始 | 保留现有独立整句翻译。 |
| G4 词/短语对齐 | 未开始 | 需要人工标注评测，不推断子词含义。 |
| G5 数学符号 | 未开始 | 先验证 Unicode 与简单结构转换。 |
| G6 数学 OCR | 未开始 | 需实际设备上的公式识别质量与资源评估。 |
| G7 外部模型 | 未开始 | 导入、安全、卸载与设备验证通过前不开放。 |
| G8 发布验收 | 未开始 | 自动化与 iPad 手指/Pencil 真机回归均需完成。 |

任何未运行或未通过的 CI、真机和质量评测均保持待验证，不以设计或代码存在代替验收。
