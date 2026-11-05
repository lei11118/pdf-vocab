# ★标记★ iPadOS 26 语境 Token 与数学识别实施现状

> 本文是当前实现与阶段状态的权威说明。按代码核对日期：2026-11-05。
> 核查基线：分支 codex/v062-interaction-rebuild；字符对齐基础的旧验证基线为 2ff58b0。G2b 自动回归已通过；旧全量验证中的 G2c 仅包含纯原文对齐基础。本次字符框精化由后续 unit-only run 单独验证，不扩展旧全量/UI 证据。G1 归档基线为 618b4c0b03f89a82c5ba636500d6de11b572bb8e（v0.70.0 / build 118）。
> 设计来源：`pdf-vocab：iPadOS 26 语境 Token 与数学表达式智能阅读系统`。设计文档描述目标，不证明功能已实现。

## 当前基座与边界

- iPad 专用应用；Bundle ID 为 `com.lei11118.pdfvocab`。G0 不修改 Bundle ID、营销版本或 build 号。
- G0 系统升级与 G1 测试、archive 均已有 CI 通过证据；G1 两张语境卡截图已由主脑视觉审查通过。当前版本仍为 v0.70.0 / build 118，G2 工作不代表发布验收完成。
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
| 扫描 PDF OCR | G2a commit 0c674f6 保存完整候选行与 word-level geometry。全页宽 overlapping bands 修正位于 e71b364；unit-only [run 42009421256](https://github.com/lei11118/pdf-vocab/actions/runs/42009421256) 已通过，112 项 unit 测试零失败。合成 raster full-line raw=`charge plus 3.2 = п`（1 行），相对旧版 raw=`2ニTTI 2 = TI charge plus 3.2 = charge plus 3.2 :` 有改善；full-text CER/WER 从 0.316/0.600 降为 0.053/0.200，English lexical CER/WER 从 0.636/1.000 降为 0/0。 | 此样例仍把 gold π 识别成西里尔 п；单一合成样例不证明真实照片精度。旧 OCR 的 raw 为 `charge plus TI TTI`。G2 OCR 质量仍待更广泛验证。 |
| 整句翻译 | `Sources/Card/ReaderSentenceTranslationView.swift` 的 `SentenceTranslationTask` 使用 SwiftUI `translationTask` 执行英语到简体中文的普通句子翻译。 | 没有语境服务、词级对齐或可验证的词义对应结果。 |
| 数据库迁移 | 已提交 G2a v14.contextOCRPages 单页 JSON 存储；上下文页 schema revision 当前为 2。G2b 完整回归包含 worker/store 测试。旧 ocr_word / ocr_status 保持独立。 | [全量回归 run 42013095097](https://github.com/lei11118/pdf-vocab/actions/runs/42013095097) 已通过；这不替代真实设备验收。 |

## 阶段状态

| 阶段 | 状态 | 证据 / 下一步 |
|---|---|---|
| G0 系统升级 | 通过 CI | [test-ink run 41988049409](https://github.com/lei11118/pdf-vocab/actions/runs/41988049409)：97 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；[build-ipa run 41988049058](https://github.com/lei11118/pdf-vocab/actions/runs/41988049058)：archive/unsigned IPA 成功。CI 通过不替代真实 iPad/Pencil 验收。 |
| G1 Token 选择 | CI 与截图审阅通过 | [test-ink run 41996577706](https://github.com/lei11118/pdf-vocab/actions/runs/41996577706)：104 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；Token 模型 5 项测试、OpenStax 真实 PDF 路由、Coordinator 拖选与截图用例均通过，导出 37 个 UIReview 附件。[build-ipa run 41996594391](https://github.com/lei11118/pdf-vocab/actions/runs/41996594391)：archive 与 unsigned IPA 成功。IPA 已独立核验 ZIP CRC、0.70.0/118、MinimumOSVersion 26.0、ARM64、`science.sqlite`；SHA-256 为 `7a9869452472739997564306d864e1f2247a00d964b6078a78802c324841d6a5`。浅色与窄宽深色截图已由主脑视觉审查通过。已提交的 G1 PDF Token `sentenceID`/`blockID` 仍为 nil，尚未完成句子/文本块分段，也没有可验证的语境译义。原文范围与显示 surface 分开保存；不确定几何不强行拆 token。此阶段验证不代表发布完成。 |
| G2a OCR 完整行基础 | commit 0c674f6 的 [test-ink run 42005268440](https://github.com/lei11118/pdf-vocab/actions/runs/42005268440) 完成，111 项单元/集成测试与 5 项 UI 测试通过（`TEST SUCCEEDED`），但当时的合成 raster full-line 输出退化。e71b364 改为全页宽重叠 bands；[unit-only run 42009421256](https://github.com/lei11118/pdf-vocab/actions/runs/42009421256) 的 112 项 unit 测试通过，样例指标见上；G2b 全量回归 run 42013095097 也通过。 | bands 修正改善该单样例，但 gold π 仍误识别为西里尔 п；真实照片评测仍待验证。原始候选与 token 保留，geometry 仅为 `.word`；未生成字符框。 |
| G2b Reader 接入与调度 | 已提交 commit ab7367f，包含完整 OCR source、Coordinator pinned snapshot、OCR handle/body/hover 路由，以及 actor 的当前页优先与后台 utility 旧 OCR 调度；页 revision 为 2，master 开关默认关闭。初次 run 42011428288 在测试编译阶段失败，commit 3bbddda 补上 async 数据库写入的 `await`。修正后的全量 [test-ink run 42013095097](https://github.com/lei11118/pdf-vocab/actions/runs/42013095097) 通过：130 项 unit/integration、5 项 UI，零失败。 | 自动回归通过不代表 iPad/Pencil 真机验收。仍未实现 `.fast` OCR 字符几何，也未验证字符框定位精度。 |
| G2c OCR 原文字符对齐与几何测量基础 | 已验证代码基线 2ff58b0 的纯值 `OCRCharacterAligner` 将原文按 composed grapheme 与原始 UTF-16 对齐，用前向/后向 Levenshtein 找出所有最优路径必需的精确配对，并在超限时拒绝。旧全量 run 42013095097 中 10 项 aligner 测试通过，包含 `[a,b]` 长度 0…3 的 225 组独立穷举 oracle。本次新增 `.fast` 行 ROI 采集、保守纯校验与 CoreText gold raster benchmark；unit-only [run 42017762878](https://github.com/lei11118/pdf-vocab/actions/runs/42017762878) 通过：141 项 unit 测试零失败，含 11 项 refiner 测试。单条合成 Latin 样例 raw 为 `charge + beta 3.2`；14 个可见 glyph 中 14 个得到字符框覆盖，14/14 gold center 落入对应框，mean covered-center error 为 1.39 pt，fallback 为 nil。 | 该 benchmark 只有单条合成样例，不能代表真实照片或形成精度承诺。Refiner 尚未接入 production，也不生成 `.verifiedCharacter`；unit-only run 不含 UI 测试。旧全量 run 42013095097 只验证 2ff58b0 基线，不覆盖本次新增文件。Apple Vision 的 [`VNRecognizedText.boundingBox(for:)`](https://developer.apple.com/documentation/vision/vnrecognizedtext/boundingboxforrange%3Aerror%3A?language=objc) 文档说明 accurate 框为词级、fast 框为字符级，且边框不保证像素精确。 |
| G3 系统翻译 | 未开始 | 保留现有独立整句翻译。 |
| G4 词/短语对齐 | 未开始 | 需要人工标注评测，不推断子词含义。 |
| G5 数学符号 | 未开始 | 先验证 Unicode 与简单结构转换。 |
| G6 数学 OCR | 未开始 | 需实际设备上的公式识别质量与资源评估。 |
| G7 外部模型 | 未开始 | 导入、安全、卸载与设备验证通过前不开放。 |
| G8 发布验收 | 未开始 | 自动化与 iPad 手指/Pencil 真机回归均需完成。 |

任何未运行或未通过的 CI、真机和质量评测均保持待验证，不以设计或代码存在代替验收。
