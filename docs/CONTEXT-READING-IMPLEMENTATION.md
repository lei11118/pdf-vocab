# ★标记★ iPadOS 26 语境 Token 与数学识别实施现状

> 本文是当前实现与阶段状态的权威说明。按代码核对日期：2026-11-05。
> 核查基线：`codex/v062-interaction-rebuild`，`3ce90bd2f3fbf8ff79adf1de5560df4446b21a16`（v0.70.0 / build 118，G0）。
> 设计来源：`pdf-vocab：iPadOS 26 语境 Token 与数学表达式智能阅读系统`。设计文档描述目标，不证明功能已实现。

## 当前基座与边界

- iPad 专用应用；Bundle ID 为 `com.lei11118.pdfvocab`。G0 不修改 Bundle ID、营销版本或 build 号。
- G0 系统升级已通过 CI；G1 Token 选择仍在实现和审查中。当前代码差异不代表阶段验收完成。
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
| 扫描 PDF OCR | `Sources/OCR/OCRService.swift` 按页面区域调用 Vision `.accurate` 识别，再用英文字母词正则生成 `OCRWord` 词框；`Sources/OCR/OCRStore.swift` 保存词框。 | 没有持久化字符级结果、完整阅读 Token 序列或数学结构。 |
| 整句翻译 | `Sources/Card/ReaderSentenceTranslationView.swift` 的 `SentenceTranslationTask` 使用 SwiftUI `translationTask` 执行英语到简体中文的普通句子翻译。 | 没有语境服务、词级对齐或可验证的词义对应结果。 |
| 数据库迁移 | `Sources/Data/AppDatabase.swift` 当前最后一项为 `v13.workspaceFolders`。 | 不得重写已有迁移；新 schema 变化从 v14 起追加。 |

## 阶段状态

| 阶段 | 状态 | 证据 / 下一步 |
|---|---|---|
| G0 系统升级 | 通过 CI | [test-ink run 41988049409](https://github.com/lei11118/pdf-vocab/actions/runs/41988049409)：97 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；[build-ipa run 41988049058](https://github.com/lei11118/pdf-vocab/actions/runs/41988049058)：archive/unsigned IPA 成功。CI 通过不替代真实 iPad/Pencil 验收。 |
| G1 Token 选择 | 进行中 | 默认关闭的开关、原生 PDF Token 映射、候选卡片和回归测试已完成主脑代码审查；CI 测试与截图验收待运行。`sentenceID`/`blockID` 仍为 nil，尚未完成句子/文本块分段，也没有可验证的语境译义。原文范围与显示 surface 分开保存；不确定几何不强行拆 token。 |
| G2 OCR 改进 | 未开始 | 先测代表性 PDF 的识别和定位质量。 |
| G3 系统翻译 | 未开始 | 保留现有独立整句翻译。 |
| G4 词/短语对齐 | 未开始 | 需要人工标注评测，不推断子词含义。 |
| G5 数学符号 | 未开始 | 先验证 Unicode 与简单结构转换。 |
| G6 数学 OCR | 未开始 | 需实际设备上的公式识别质量与资源评估。 |
| G7 外部模型 | 未开始 | 导入、安全、卸载与设备验证通过前不开放。 |
| G8 发布验收 | 未开始 | 自动化与 iPad 手指/Pencil 真机回归均需完成。 |

任何未运行或未通过的 CI、真机和质量评测均保持待验证，不以设计或代码存在代替验收。
