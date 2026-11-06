# ★标记★ iPadOS 26 语境 Token 与数学识别实施现状

> 本文是当前实现与阶段状态的权威说明。按代码核对日期：2026-11-06。
> 核查基线：分支 `codex/v062-interaction-rebuild`，当前代码提交 `02aadbe9eb928b2aa739ad910416fbe9d8cb3552`（产品版本仍为 v0.70.0 / build 118；本次服务层改动未打包）。字符对齐与几何测量的历史基线为 `2ff58b0`；历史 G2c unit-only [run 42017762878](https://github.com/lei11118/pdf-vocab/actions/runs/42017762878) 有 141 项 unit 测试通过，合成 Latin benchmark mean covered-center error 为 1.39 pt。此前全量 [test-ink run 42144690686](https://github.com/lei11118/pdf-vocab/actions/runs/42144690686) 在 `SentenceContextBuilder.swift:191` 编译失败；`mappedDisplayRange` 中 `guard isWhitespace(...) else` 的 `else` 分支可落出。提交 `4b84593` 改为 `if !isWhitespace(...)`，并保留缺失映射立即返回 `nil`。修正后的完整 [test-ink run 42146019076](https://github.com/lei11118/pdf-vocab/actions/runs/42146019076) 有 175 项单元/集成测试与 5 项 UI 测试全部通过；同 SHA 的 [build-ipa run 42146414284](https://github.com/lei11118/pdf-vocab/actions/runs/42146414284) 成功，版本为 v0.70.0 / build 118。CI 通过不代表真实 iPad/Pencil 验收；G3 目前只有服务层基础和 unit-only 验证，尚未接入 UI，GRDB 持久化与语言包流程待实现，未做端到端或真机验收。
> 设计来源：`pdf-vocab：iPadOS 26 语境 Token 与数学表达式智能阅读系统`。设计文档描述目标，不证明功能已实现。

## 当前基座与边界

- iPad 专用应用；Bundle ID 为 `com.lei11118.pdfvocab`。G0 不修改 Bundle ID、营销版本或 build 号。
- G0 系统升级与 G1 测试、archive 均已有 CI 通过证据；G1 两张语境卡截图已由主脑视觉审查通过。当前版本仍为 v0.70.0 / build 118，G2 工作不代表发布验收完成。
- 新能力后续必须保持本地运行；总开关默认关闭，关闭后回到当前阅读路径。
- 保留现有单击链接跳转；不新增单击选词。当前双击和长按选词继续可用。
- 保留尺子的现有位置与手势；保留用户指定的不可拖动双层弧形工具栏，以及编辑、颜色和笔宽管理。
- 保留现有词卡和独立整句翻译。新语境词卡不得展示原句或整句译文。
- 数据库已有 v14 context OCR 页与 v15 派生字符几何缓存 migration；后续如需改库，只能追加更高版本。

以上产品约束是后续阶段要求，不表示 G0 已实现或验证了这些能力。

## 源码核实的现有接口

| 区域 | 当前实现 | 尚不存在的能力 |
|---|---|---|
| PDF 文字选取 | `Sources/Reader/Selection/ReaderCoordinator.swift` 管理手势；双击和长按通过 `SelectionGeometry` 命中，几何与字形布局分别在 `Sources/Reader/Selection/SelectionKit.swift` 和 `PDFTextLayout.swift`。单击仍处理链接、已有选区菜单和空白处清除。 | 没有方案文档描述的 `selectionForWord(at:)` 路由；不应整体替换协调器或改变单击语义。 |
| 扫描 PDF OCR | G2a commit 0c674f6 保存完整候选行与 word-level geometry。全页宽 overlapping bands 修正位于 e71b364；unit-only [run 42009421256](https://github.com/lei11118/pdf-vocab/actions/runs/42009421256) 已通过，112 项 unit 测试零失败。合成 raster full-line raw=`charge plus 3.2 = п`（1 行），相对旧版 raw=`2ニTTI 2 = TI charge plus 3.2 = charge plus 3.2 :` 有改善；full-text CER/WER 从 0.316/0.600 降为 0.053/0.200，English lexical CER/WER 从 0.636/1.000 降为 0/0。 | 此样例仍把 gold π 识别成西里尔 п；单一合成样例不证明真实照片精度。旧 OCR 的 raw 为 `charge plus TI TTI`。G2 OCR 质量仍待更广泛验证。 |
| 句子上下文候选 | `Sources/ContextReading/SentenceContextBuilder.swift` 是单行纯值基础组件：在原文与显示文本可可靠对齐时生成句子范围及选区范围；完整 [test-ink run 42146019076](https://github.com/lei11118/pdf-vocab/actions/runs/42146019076) 中 `SentenceContextBuilderTests` 的 7 项测试通过。 | 尚未接入语境翻译服务或 UI；这些单元测试不代表系统句子翻译或用户可见功能已实现。 |
| 整句翻译 | `Sources/Card/ReaderSentenceTranslationView.swift` 的 `SentenceTranslationTask` 使用 SwiftUI `translationTask` 执行英语到简体中文的普通句子翻译。 | 与新建的句子语境翻译服务尚未连接；不提供可验证的词义对应结果。 |
| 句子语境翻译服务 | `Sources/ContextReading/SentenceTranslationService.swift` 提供句子翻译与 `AppleTranslationSessionAdapter`，并以独立请求代次拒绝已失效的在途结果。unit-only [run 42154102655](https://github.com/lei11118/pdf-vocab/actions/runs/42154102655) 中服务测试 9 项通过。 | 目前尚未接入 Reader/Selection UI；缓存仅在内存中，GRDB 持久化/迁移及语言包可用性、下载和状态引导流程待实现。 |
| 数据库迁移 | G2a v14.contextOCRPages 保存准确行 OCR；上下文页 schema revision 当前为 2。G2c 追加 v15 `ocr_character_geometry` 派生缓存，32 MiB 总预算、单 payload 1 MiB，文档删除时级联清理。缓存不覆写基础 context OCR 页或旧 `ocr_word`。 | 历史[全量回归 run 42013095097](https://github.com/lei11118/pdf-vocab/actions/runs/42013095097) 验证了 v14/G2b；当前包含 v15 的[完整 test-ink run 42146019076](https://github.com/lei11118/pdf-vocab/actions/runs/42146019076) 已通过，175 项单元/集成测试与 5 项 UI 测试零失败。 |

## 阶段状态

| 阶段 | 状态 | 证据 / 下一步 |
|---|---|---|
| G0 系统升级 | 通过 CI | [test-ink run 41988049409](https://github.com/lei11118/pdf-vocab/actions/runs/41988049409)：97 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；[build-ipa run 41988049058](https://github.com/lei11118/pdf-vocab/actions/runs/41988049058)：archive/unsigned IPA 成功。CI 通过不替代真实 iPad/Pencil 验收。 |
| G1 Token 选择 | CI 与截图审阅通过 | [test-ink run 41996577706](https://github.com/lei11118/pdf-vocab/actions/runs/41996577706)：104 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；Token 模型 5 项测试、OpenStax 真实 PDF 路由、Coordinator 拖选与截图用例均通过，导出 37 个 UIReview 附件。[build-ipa run 41996594391](https://github.com/lei11118/pdf-vocab/actions/runs/41996594391)：archive 与 unsigned IPA 成功。IPA 已独立核验 ZIP CRC、0.70.0/118、MinimumOSVersion 26.0、ARM64、`science.sqlite`；SHA-256 为 `7a9869452472739997564306d864e1f2247a00d964b6078a78802c324841d6a5`。浅色与窄宽深色截图已由主脑视觉审查通过。已提交的 G1 PDF Token `sentenceID`/`blockID` 仍为 nil，尚未完成句子/文本块分段，也没有可验证的语境译义。原文范围与显示 surface 分开保存；不确定几何不强行拆 token。此阶段验证不代表发布完成。 |
| G2a OCR 完整行基础 | commit 0c674f6 的 [test-ink run 42005268440](https://github.com/lei11118/pdf-vocab/actions/runs/42005268440) 完成，111 项单元/集成测试与 5 项 UI 测试通过（`TEST SUCCEEDED`），但当时的合成 raster full-line 输出退化。e71b364 改为全页宽重叠 bands；[unit-only run 42009421256](https://github.com/lei11118/pdf-vocab/actions/runs/42009421256) 的 112 项 unit 测试通过，样例指标见上；G2b 全量回归 run 42013095097 也通过。 | bands 修正改善该单样例，但 gold π 仍误识别为西里尔 п；真实照片评测仍待验证。原始候选与 token 保留，geometry 仅为 `.word`；未生成字符框。 |
| G2b Reader 接入与调度 | 已提交 commit ab7367f，包含完整 OCR source、Coordinator pinned snapshot、OCR handle/body/hover 路由，以及 actor 的当前页优先与后台 utility 旧 OCR 调度；页 revision 为 2，master 开关默认关闭。初次 run 42011428288 在测试编译阶段失败，commit 3bbddda 补上 async 数据库写入的 `await`。修正后的全量 [test-ink run 42013095097](https://github.com/lei11118/pdf-vocab/actions/runs/42013095097) 通过：130 项 unit/integration、5 项 UI，零失败。 | 自动回归通过不代表 iPad/Pencil 真机验收。仍未实现 `.fast` OCR 字符几何，也未验证字符框定位精度。 |
| G2c OCR 原文字符对齐与几何测量 | 已接入 production worker。历史验证包括代码基线 2ff58b0 的纯值 `OCRCharacterAligner`（按 composed grapheme 与原始 UTF-16 对齐，前向/后向 Levenshtein 找出所有最优路径必需的精确配对，超限时拒绝），以及 `.fast` 行 ROI 采集、保守校验与 CoreText gold raster benchmark；unit-only [run 42017762878](https://github.com/lei11118/pdf-vocab/actions/runs/42017762878) 有 141 项 unit 测试通过，含 11 项 refiner 测试。单条合成 Latin 样例 raw 为 `charge + beta 3.2`；14 个可见 glyph 全部得到字符框覆盖，14/14 gold center 落入对应框，mean covered-center error 为 1.39 pt，fallback 为 nil。当前 worker 按需精化单个 block，重新应用缓存前用当前原文、布局和 observations 重验。此前完整 [test-ink run 42144690686](https://github.com/lei11118/pdf-vocab/actions/runs/42144690686) 在 `Sources/ContextReading/SentenceContextBuilder.swift:191` 编译失败：`mappedDisplayRange` 的 `guard isWhitespace(grapheme.surface) else` 分支追加 index 后能够落出，违反 Swift `guard` 的退出要求。提交 `4b84593` 将该分支改为 `if !isWhitespace(grapheme.surface)`，同时保留缺失映射立即返回 `nil`。修正后的完整 [test-ink run 42146019076](https://github.com/lei11118/pdf-vocab/actions/runs/42146019076) 成功：175 项单元/集成测试、5 项 UI 测试均零失败，`SentenceContextBuilderTests` 的 7 项测试通过；同 SHA 的 [build-ipa run 42146414284](https://github.com/lei11118/pdf-vocab/actions/runs/42146414284) 成功，版本 v0.70.0 / build 118。 | v15 将派生字符几何与准确词级基础页分开，32 MiB 总预算、1 MiB 单条上限；缓存不覆写原文或旧词框。Composer 对连通 token 组原子升级，缺少必要几何时保留基础词框回退。Reader 的取消、请求去重和 pin 生命周期接入当前页精化。`.verifiedCharacter` 表示通过原文身份与完整几何检查，不承诺像素精度。历史 benchmark 仅为单条合成样例，不能代表真实照片。当前代码有 CI 与 archive 成功证据，但未做真实 iPad/Pencil 验证；句子候选仍未接入 UI；G3 服务层基础已有 unit-only 测试，UI、GRDB 与语言包流程待实现。Apple Vision 的 [`VNRecognizedText.boundingBox(for:)`](https://developer.apple.com/documentation/vision/vnrecognizedtext/boundingboxforrange%3Aerror%3A?language=objc) 文档说明 accurate 框为词级、fast 框为字符级，且边框不保证像素精确。 |
| G3 系统翻译 | 服务层基础已测试；未接 UI | `SentenceTranslationService` 与 `AppleTranslationSessionAdapter` 已实现服务层基础，并通过 [test-ink unit-only run 42154102655](https://github.com/lei11118/pdf-vocab/actions/runs/42154102655)：`PdfVocabTests` 共 184 项测试零失败，其中 `SentenceTranslationServiceTests` 9 项通过，包含两条请求失效测试。该服务尚未从 Reader/Selection UI 调用；目前只有内存缓存，没有 GRDB 持久化或迁移，也未实现语言包可用性、下载或状态引导流程。保留现有独立整句翻译；本次 CI 不代表端到端或真机验收。 |
| G4 词/短语对齐 | 未开始 | 需要人工标注评测，不推断子词含义。 |
| G5 数学符号 | 未开始 | 先验证 Unicode 与简单结构转换。 |
| G6 数学 OCR | 未开始 | 需实际设备上的公式识别质量与资源评估。 |
| G7 外部模型 | 未开始 | 导入、安全、卸载与设备验证通过前不开放。 |
| G8 发布验收 | 未开始 | 自动化与 iPad 手指/Pencil 真机回归均需完成。 |

任何未运行或未通过的 CI、真机和质量评测均保持待验证，不以设计或代码存在代替验收。
