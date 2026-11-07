# v0.71.1-beta 测试说明

版本配置：`0.71.1`（build `122`）
候选提交：`54db26b398a65785b4094b51e6b13f75c142f470`
用途：内部测试候选。

## 本次修改

- 为文字层 PDF 与 OCR 选区增加有边界的短语解析：仅在连续英文词、同一原始行/句子和 2–4 个词、最多 40 个字符的范围内查找已启用词典的精确短语；使用最长已登记匹配。片段可以作为选词来源，语境翻译仍要求完整句子。
- 双击选词和悬浮释义可扩展到已验证短语。PDFKit 扩展要求每个词的原文范围、同一行及相邻几何通过检查；OCR 扩展限于同一行和相邻词框。未通过验证时保留单词选区。
- 增加短语组 source/target attributed marker、严格对齐校验及与普通选词隔离的翻译缓存。词组中的单词 Token 仍保留。
- 增加语境翻译 driver 的 prepare→completion 生命周期测试接口、旧结果/取消屏障以及不记录源句的分类诊断。
- 增加段落边界、原始 UTF-16 坐标、词典修订缓存失效和 OCR/PDF 路由测试。

## 文件与测试映射

| 文件 | 修改与原因 | 对应测试 |
|---|---|---|
| `Sources/ContextReading/VerifiedPhraseGroupResolver.swift`、`Sources/Dict/DictionaryStore.swift`、`Sources/Dict/DictionaryCatalog.swift` | 有界最长短语匹配；以启用词典中的精确短语存在性验证；词典来源变化时失效 lookup cache。 | `Tests/VerifiedPhraseGroupResolverTests.swift` 覆盖最长匹配、精确命中策略、标点/换行边界、片段及 revision/cache 失效。SQLite 精确查询还须由 CI 验证。 |
| `Sources/Reader/Selection/ReaderCoordinator.swift`、`Sources/ContextReading/ContextSelectionRouter.swift`、`Sources/ContextReading/OCR/ContextOCRSelectionSource.swift`、`Sources/ContextReading/Models/SourceModels.swift` | 双击/hover 可选择已验证词组；PDFKit 与 OCR 均保留原始 source span，并要求同一行和相邻几何。普通单词 route 不扩选。 | `Tests/RealPDFSelectionTests.swift`、`Tests/InteractionPolishTests.swift`、`Tests/ContextOCRSelectionTests.swift` 覆盖精确 PDF 范围、双击扩展和 OCR 同行/列间距拒绝。 |
| `Sources/ContextReading/SentenceContextBuilder.swift` | 修复最近空行边界截断时的相对 range 计算；段落分界处不再丢失正常句子 context。 | `Tests/SentenceContextBuilderTests.swift` 中新增段落边界用例；实际结果待 test-ink。 |
| `Sources/ContextReading/ContextualTranslationAlignment.swift`、`Sources/ContextReading/ContextualTranslationService.swift`、`Sources/Card/ContextualTranslationTaskView.swift` | 将已验证词组作为一个 many-to-one 对齐单元；严格拒绝缺失/未知/偏移/分散 marker 与整译文 marker；词组和普通词选区缓存隔离；记录不含源文的失败分类。 | `Tests/ContextualTranslationTests.swift`、`Tests/ContextualTranslationDriverTests.swift` 覆盖 group decode、cache key、prepare→completion、旧结果和取消；这些是合成值测试，不代表 Apple Translation 译义质量。 |
| `Sources/Card/WordCardView.swift`、`Sources/Reader/HoverTipView.swift`、`Sources/Reader/PDFKitView.swift`、`Sources/Reader/ReaderView.swift`、`Sources/Reader/WordInteractionLayer.swift` | 将共享 translation driver 接到完整卡与 hover，保留 hover 词典释义/语境译义展示路径。 | `Tests/PhotoHoverRegressionTests.swift`、`Tests/InteractionPolishTests.swift`；CI 结果待定，系统翻译真实响应仍需真机验收。 |
| `project.yml` | 更新为 `0.71.1` / build `122`。 | `build-ipa` 的 Info.plist/架构/包校验待 run 完成后记录。 |

## 启用与系统翻译前提

“语境 Token 阅读”开关位于设置页，默认关闭（`Sources/App/SettingsView.swift`）。仅当需要验收系统语境候选时才手动打开。该能力要求 iPadOS 26.4 或更高版本，并需要系统英语 `en` → 简体中文 `zh-Hans` 离线翻译语言已安装；设置 `supported` 时，按卡片提示由用户启动语言准备，待状态变为 `installed` 后重试。选择完整句中的单词或已验证词组再检查候选。短语解析和普通词典查询不依赖系统翻译语言包；fragment 也不绕过完整句翻译门槛。

## 当前验证状态

- 本地 `git diff --check` → 通过。
- 本机无 `swift`、`xcodegen`、`xcodebuild` 命令；未在本地运行 Xcode 测试或 IPA 构建。
- 首次 [`build-ipa run 42233403067`](https://github.com/lei11118/pdf-vocab/actions/runs/42233403067) 在 `2d5c4c07651c26a76553908d2491fc92e5e5e4d0` 失败：`ContextualTranslationAlignment.swift:154:13: error: invalid redeclaration of 'selectedPhrase'`。修复提交 `54db26b` 将局部变量改为 `resolvedSelectedPhrase`。首次 [`test-ink run 42233387319`](https://github.com/lei11118/pdf-vocab/actions/runs/42233387319) 在队列中时按授权取消；不计为测试结果。
- [`build-ipa run 42234159330`](https://github.com/lei11118/pdf-vocab/actions/runs/42234159330) 在候选 SHA `54db26b398a65785b4094b51e6b13f75c142f470` 成功：unsigned IPA 版本/build `0.71.1 / 122`，minimum OS `26.0`，文件大小 `48,114,846 bytes`，SHA-256 `d9b7412a33d92330329a4a6bcc1720948818ff48ab115204e8a5d6a1318d5b2c`。CI 的 IPA 结构检查与 `lipo` ARM64 验证通过；下载包位于 `D:\codx\pdf-vocab\dist\v0.71.1-beta\PdfVocab-unsigned.ipa`，本地 ZIP CRC 检查通过，主 app plist 为 `com.lei11118.pdfvocab`、`0.71.1` / `122` / minimum OS `26.0`；`science.sqlite`（44,998,656 bytes）和 `ecdict.sqlite`（14,483,456 bytes）均为 SQLite 资源。
- [`test-ink run 42234158880`](https://github.com/lei11118/pdf-vocab/actions/runs/42234158880) 在同一 SHA 完成：244 项 unit/integration 中 1 项失败；6 项 UI 全部通过。唯一失败为 `Tests/RealPDFSelectionTests.swift` 的 `testVerifiedPhraseGroupRoutesThroughExactPDFKitRange`，PDFKit 短语范围未能完成 route。失败测试尚在定位，不能称为全量测试通过。
- 为定位该失败，测试专用诊断提交 `a57e540849ef6fdc4f96da428cabf9a0cedc2f08` 只拆分该用例的既有 guards 并打印不含原文的阶段计数；不改生产代码、测试 fixture、prefix 范围或断言。unit-only [`test-ink run 42238093706`](https://github.com/lei11118/pdf-vocab/actions/runs/42238093706) 排队 15 分钟后被取消，job `steps=[]`，未开始测试，不能记为代码测试失败或通过。按授权重派的 [`test-ink run 42240576044`](https://github.com/lei11118/pdf-vocab/actions/runs/42240576044) 目前已启动，阶段计数待定。
- 产品代码 build 和 full test run 均对应 SHA `54db26b398a65785b4094b51e6b13f75c142f470`；诊断 run 的 head SHA 为 `a57e540849ef6fdc4f96da428cabf9a0cedc2f08`。当前测试结论为 1 项失败，待阶段计数确定原因并修复；排队取消的 unit-only run 没有可用测试日志。

## 真机验收仍待完成

- 在 iPad 上验证文字层 PDF 的双击、悬浮释义、重复词 occurrence、换行/空行、双栏及词典精确短语命中。
- 验证 OCR 同行选词范围、词框相邻性、悬浮卡片布局，以及片段词组不触发整句翻译。
- 在目标 iPadOS 版本及对应语言包状态下验证系统 Translation 的候选内容、准备/取消/重试和返回词典流程。
- 当前代码测试和 CI 均不能替代真实 PDF/OCR 样本与真实 iPad 操作验收。

在 CI 和真机检查完成前，`0.71.1` 仍是候选版本；不得将运行中的 CI 或合成样例写成通过证据。

## Sentence-context recovery follow-up

- Failure evidence on diagnostic SHA `a57e540849ef6fdc4f96da428cabf9a0cedc2f08`: the existing OpenStax PDF route test recorded `seed_attempt=80 seed_context_missing=80`. The counter does not distinguish an initial builder miss from a multiline-layout rejection.
- `Sources/ContextReading/ContextSelectionRouter.swift`: when the normal candidate is absent or its multiline layout fails, the router now derives a bounded trusted source block from the original PDFKit source rows. It checks only the seed row and up to nine rows on either side; every row must map back to that exact page-relative source range and one visual line. Neighbor expansion stops at blank rows, untrusted geometry, column changes, and line-height changes. The original seed/display equality and source spans remain intact.
- `Sources/ContextReading/SentenceContextBuilder.swift`: the sentence builder intersects that trusted block with the original nearest-blank-line paragraph and keeps page-relative UTF-16 offsets. Only a sentence touching an edge cut by the eight-row cap becomes a fragment; naturally bounded complete sentences remain eligible for translation.
- `Tests/SentenceContextBuilderTests.swift`: covers trusted-block expansion, title/body and blank-line boundaries, column and row-height rejection, page-relative intersections, and sentence fragments at capped edges.
- `Tests/RealPDFSelectionTests.swift`: preserves the existing exact PDF phrase-route assertion and adds an OpenStax fixture test that scans base word seeds until it constructs a complete-sentence request and verifies exact global-to-local source/display spans.
- The source fix and new fixture request test are pending CI on the next commit. No test or build result is claimed here.