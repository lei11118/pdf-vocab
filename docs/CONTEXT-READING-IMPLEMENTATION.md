# ★标记★ iPadOS 26 语境 Token 与数学识别实施现状

> 当前在研增量：v0.72.0 / build 123，核对日期 2026-11-07。工作树包含语境布局块、Translation attributes 对齐和同屏释义显示改动；尚未有本轮 CI 结果。具体样本、研究候选与 OCR 测试状态见 [语境布局块与翻译对齐证据](CONTEXT-BLOCK-ALIGNMENT.md)。
> 最新已验证基线是 `18ba9a5`： [test-ink run 42339957440](https://github.com/lei11118/pdf-vocab/actions/runs/42339957440) 通过 251 项、0 失败；[build-ipa run 42339957547](https://github.com/lei11118/pdf-vocab/actions/runs/42339957547) 成功，产物为 v0.71.1 / build 122。这两条记录只适用于该基线，不验证当前工作树的 v0.72.0 改动。
> `project.yml` 当前工作树候选值为 v0.72.0 / build 123；本轮代码审查、`test-ink`、`build-ipa`、真实 iPad/Pencil 验收仍待完成。数学识别和外部模型阶段未完成。
> 设计来源：`pdf-vocab：iPadOS 26 语境 Token 与数学表达式智能阅读系统`。设计文档描述目标，不证明功能已实现。

## 当前增量状态（权威，2026-11-07；CI 待跑）

- 当前工作树候选为 v0.72.0 / build 123。最近通过的 `18ba9a5` 基线及其 run 不覆盖本轮变更。
- 工作树正在构造受可信几何约束的 `.layoutBlock` context：原生 PDF/OCR 行保留来源映射，只在有效的同栏邻接与结构边界检查后生成有界块。当前实现受 2,048 UTF-16 单元限制；OCR 行布局最多向每侧检查 8 行。源码和算法细节见 [新证据文档](CONTEXT-BLOCK-ALIGNMENT.md)。
- 工作树继续复用 TranslationSession attributed-string Token ID 路径，并调整卡片与悬浮释义显示。候选服务目前不是设备验收结果；iOS 26.4+ 语言包、Apple 返回属性、词义和真机显示均待验证。
- 新增 `Tests/Fixtures/LayoutBlock-Samples.json` 与 `Tests/LayoutBlockContextBuilderTests.swift`，覆盖人工转录扫描行和原生 PDF 文本层行的范围/几何映射。新增 `Tests/Fixtures/IELTS-context-strip.png` 与 `Tests/RealScanContextTests.swift`，测试真实 Vision OCR → `classroom` source span → `.layoutBlock` → 翻译请求的路径；该 XCTest 尚未运行，CI 待跑。扫描页字符串是人工参照，不是 OCR 输出或精度结论。
- 0.72.0 的本轮 `test-ink` / `build-ipa` 尚未验证。数学符号识别、数学 OCR、外部模型安全与发布验收仍未完成；真实 iPad/Pencil 回归仍待完成。

下方保留 v0.71.0 与更早阶段的源代码说明和验证记录作为历史归档；历史通过结果只适用于对应 SHA，不代表当前增量通过。若归档文字与本节冲突，以本节为准。

## 历史验证档案（v0.71.0 / build 121）

- `43a63c9700fe9be9a184832340f9b6f0df84c789` 的 [build-ipa run 42182468504](https://github.com/lei11118/pdf-vocab/actions/runs/42182468504) 曾成功：IPA v0.71.0 / build 121，minimum OS 26.0，48,075,418 bytes，SHA-256 `ef33542468c1d065a0e5a60d0501433891d422fdff67c6bb7b5f01740edd50e7`；主 app ZIP CRC、ARM64、science/ecdict 资源头检查通过。
- 同 SHA 的 [test-ink run 42182468786](https://github.com/lei11118/pdf-vocab/actions/runs/42182468786) 曾成功：223 项 unit/integration + 6 项 UI，共 229 项，0 失败。主脑审阅过 UIReview 44 张图中的 4 张代表图；静态布局无明显裁切或旧矩形挡条，浅/深卡片未显示原句或整句译文。截图为实验开关关闭的词典回退状态，不验证系统候选译义、动态 Gaussian 质量或真机行为。
- 19 文件增量由 `a487108` 引入；`43a63c9` 修正两处 Swift 编译问题：将嵌套 `State` 改为 `TranslationState`，并针对 `attributedText` 而非 `attributed` 包装值构造 `String.Index`。
- v0.70.2 / build 120 的同 SHA [test-ink run 42172727928](https://github.com/lei11118/pdf-vocab/actions/runs/42172727928) 与 [build-ipa run 42172740816](https://github.com/lei11118/pdf-vocab/actions/runs/42172740816) 曾成功。历史完整 [test-ink run 42146019076](https://github.com/lei11118/pdf-vocab/actions/runs/42146019076) 和 [build-ipa run 42146414284](https://github.com/lei11118/pdf-vocab/actions/runs/42146414284) 属于 v0.70.0 / build 118；它们都不验证当前增量。

## 历史基座与持续产品边界（v0.71.0 归档）

本节记录的是 v0.71.0 / build 121 时的实现与持续产品约束，不是 v0.72.0 的验证结果。旧 run 与历史证据继续保留。

- v0.71.0 / build 121 的 `43a63c9700fe9be9a184832340f9b6f0df84c789` 曾通过 [build-ipa run 42182468504](https://github.com/lei11118/pdf-vocab/actions/runs/42182468504) 和 [test-ink run 42182468786](https://github.com/lei11118/pdf-vocab/actions/runs/42182468786)；后者为 223 项 unit/integration + 6 项 UI，0 失败。IPA 元数据、包内检查和历史 UIReview 结论仅适用于该 SHA。
- v0.71.0 / build 121 的 UIReview 只检查静态布局，没有验证真实 Apple 候选译义、动态 Gaussian 质量或真实设备行为。

- iPad 专用应用；Bundle ID 为 `com.lei11118.pdfvocab`。G0 历史阶段未修改 Bundle ID、营销版本或 build 号；这不覆盖本次 v0.71.0 候选版本配置。
- 该 v0.71.0 / build 121 的 `build-ipa` run 42182468504 与 `test-ink` run 42182468786 均曾通过；后者共 223 项 unit/integration 与 6 项 UI，零失败。历史 G0、G1 与 G2 测试记录只适用于各自 SHA。
- 新能力后续必须保持本地运行；总开关默认关闭，关闭后回到当前阅读路径。
- 保留现有单击链接跳转；不新增单击选词。当前双击和长按选词继续可用。
- 保留尺子的现有位置与手势；保留用户指定的不可拖动双层弧形工具栏，以及编辑、颜色和笔宽管理。
- 保留现有词卡和独立整句翻译。新语境词卡不得展示原句或整句译文。
- 数据库已有 v14 context OCR 页与 v15 派生字符几何缓存 migration；后续如需改库，只能追加更高版本。

以上产品约束是持续要求；历史 CI 不代表 v0.71.0 增量或真机行为已验收。

## 历史源码与接口归档（v0.70.x 基线）

| 区域 | 当前实现 | 尚不存在的能力 |
|---|---|---|
| PDF 文字选取 | `Sources/Reader/Selection/ReaderCoordinator.swift` 管理手势；双击和长按通过 `SelectionGeometry` 命中，几何与字形布局分别在 `Sources/Reader/Selection/SelectionKit.swift` 和 `PDFTextLayout.swift`。单击仍处理链接、已有选区菜单和空白处清除。 | 没有方案文档描述的 `selectionForWord(at:)` 路由；不应整体替换协调器或改变单击语义。 |
| 扫描 PDF OCR | G2a commit 0c674f6 保存完整候选行与 word-level geometry。全页宽 overlapping bands 修正位于 e71b364；unit-only [run 42009421256](https://github.com/lei11118/pdf-vocab/actions/runs/42009421256) 已通过，112 项 unit 测试零失败。合成 raster full-line raw=`charge plus 3.2 = п`（1 行），相对旧版 raw=`2ニTTI 2 = TI charge plus 3.2 = charge plus 3.2 :` 有改善；full-text CER/WER 从 0.316/0.600 降为 0.053/0.200，English lexical CER/WER 从 0.636/1.000 降为 0/0。 | 此样例仍把 gold π 识别成西里尔 п；单一合成样例不证明真实照片精度。旧 OCR 的 raw 为 `charge plus TI TTI`。G2 OCR 质量仍待更广泛验证。 |
| 句子上下文候选 | `ContextualSelection` 现在可携带 `sentenceContext`。原生 PDF 用 source UTF-16 ranges 找唯一句子，限制 2048 单元，display mismatch、空行或未确认的行布局拒绝 context；CR/LF 只以等长空格规范化，原始 source 坐标保留。OCR 仅使用原文完整的单行构建器；fragment 不标为完整句。历史 [test-ink run 42146019076](https://github.com/lei11118/pdf-vocab/actions/runs/42146019076) 只验证早期 builder，不包含当前新增接线；当前 [test-ink run 42182468786](https://github.com/lei11118/pdf-vocab/actions/runs/42182468786) 已通过：223 项 unit/integration 与 6 项 UI 测试，零失败。 | OCR 跨行上下文暂未接入；原生多栏/跨行精确度仍需真机与 PDF 样例回归。 |
| Reader 语境卡 | `ReaderView` 在 `contextual.tokens.count == 1` 且 `wordCount <= 1` 时打开 `ContextualCardView`；多词选区继续使用旧整句卡。contextual card 有“查看词典释义”入口；无法确认句子或翻译不可用时可以回退。 | 只接通单 Token Reader 路由；不代表多词 Token 候选或语义准确度已验收。 |
| 系统 Token 对齐候选 | `ContextualTranslationTaskView` 受默认关闭的实验开关控制，并用 `#available(iOS 26.4, *)` 守卫；语言状态检查英语 `en` → 简体中文 `zh-Hans`，在已安装后调用 `TranslationSession.translate(attributedSource)`，用 attributed token ranges 提取候选短语。候选文案明确标为“系统对齐，待校对”。 | 当前 `build-ipa` 与 `test-ink` 均已通过；后者有 223 项 unit/integration 与 6 项 UI 测试，零失败。iPadOS 26.4+ 实机、attributed range 行为、候选词义和设置页措辞仍待校对。 |
| 语言包准备 | 语境卡复用离线翻译准备 UI；`.supported` 进入用户手动准备状态，`.installed` 才尝试 Token 对齐，`.unsupported` 保留词典入口。`supported` 只表示系统可准备，不表示已经安装。 | 真实 iPad 上的下载、取消、安装状态刷新与断网表现待验证。 |
| 普通整句翻译 | `Sources/Card/ReaderSentenceTranslationView.swift` 保留英语到简体中文的独立整句翻译；它与单 Token 语境候选是两条不同的 Reader 卡片路径。 | 整句译文不等同于所选 Token 的词义或对齐结果。 |
| 语境 Token 对齐服务 | `Sources/ContextReading/ContextualTranslationService.swift` 管理带 attributed Token 标记的请求、候选提取、有限内存缓存与过期请求拒绝；由 `ContextualTranslationTaskView` 调用。历史 [run 42154102655](https://github.com/lei11118/pdf-vocab/actions/runs/42154102655) 测的是 `SentenceTranslationService`，不验证这次新增的 Token 对齐 UI 或服务接线。 | 候选缓存尚无 GRDB 持久化/迁移；金标对齐 precision/recall/F1 和系统结果人工校对待做。 |
| 数据库迁移 | G2a v14.contextOCRPages 保存行 OCR；G2c 追加 v15 `ocr_character_geometry` 派生缓存，32 MiB 总预算、单 payload 1 MiB，文档删除时级联清理。缓存不覆写基础 context OCR 页或旧 `ocr_word`。 | 历史回归 [run 42013095097](https://github.com/lei11118/pdf-vocab/actions/runs/42013095097) 验证 v14/G2b；历史完整 [run 42146019076](https://github.com/lei11118/pdf-vocab/actions/runs/42146019076) 包含 v15。两者均不覆盖当前增量。 |

## 历史阶段状态归档

G0-G3 的状态和 run 链接是对应历史 SHA 的记录；G3 描述 v0.71.0 时的候选接线，不代表当前工作树通过，真机验收当时仍未完成。

| 阶段 | 状态 | 证据 / 下一步 |
|---|---|---|
| G0 系统升级 | 历史 CI 通过 | [test-ink run 41988049409](https://github.com/lei11118/pdf-vocab/actions/runs/41988049409)：97 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；[build-ipa run 41988049058](https://github.com/lei11118/pdf-vocab/actions/runs/41988049058)：archive/unsigned IPA 成功。CI 通过不替代真实 iPad/Pencil 验收，也不覆盖 v0.71.0。 |
| G1 Token 选择 | 历史 CI 与截图审阅通过 | [test-ink run 41996577706](https://github.com/lei11118/pdf-vocab/actions/runs/41996577706)：104 项单元/集成测试与 5 项 UI 测试零失败，`TEST SUCCEEDED`；Token 模型 5 项测试、OpenStax 真实 PDF 路由、Coordinator 拖选与截图用例均通过，导出 37 个 UIReview 附件。[build-ipa run 41996594391](https://github.com/lei11118/pdf-vocab/actions/runs/41996594391)：archive 与 unsigned IPA 成功。该 IPA 核验值属于历史 v0.70.0/118 SHA。浅色与窄宽深色截图已由主脑视觉审查通过。G1 PDF Token `sentenceID`/`blockID` 当时为 nil；不确定几何不强行拆 token。此历史验证不代表当前增量或发布完成。 |
| G2a OCR 完整行基础 | commit 0c674f6 的 [test-ink run 42005268440](https://github.com/lei11118/pdf-vocab/actions/runs/42005268440) 完成，111 项单元/集成测试与 5 项 UI 测试通过（`TEST SUCCEEDED`），但当时的合成 raster full-line 输出退化。e71b364 改为全页宽重叠 bands；[unit-only run 42009421256](https://github.com/lei11118/pdf-vocab/actions/runs/42009421256) 的 112 项 unit 测试通过，样例指标见上；G2b 全量回归 run 42013095097 也通过。 | bands 修正改善该单样例，但 gold π 仍误识别为西里尔 п；真实照片评测仍待验证。原始候选与 token 保留，geometry 仅为 `.word`；未生成字符框。 |
| G2b Reader 接入与调度 | 已提交 commit ab7367f，包含完整 OCR source、Coordinator pinned snapshot、OCR handle/body/hover 路由，以及 actor 的当前页优先与后台 utility 旧 OCR 调度；页 revision 为 2，master 开关默认关闭。初次 run 42011428288 在测试编译阶段失败，commit 3bbddda 补上 async 数据库写入的 `await`。修正后的全量 [test-ink run 42013095097](https://github.com/lei11118/pdf-vocab/actions/runs/42013095097) 通过：130 项 unit/integration、5 项 UI，零失败。 | 自动回归通过不代表 iPad/Pencil 真机验收。仍未实现 `.fast` OCR 字符几何，也未验证字符框定位精度。 |
| G2c OCR 原文字符对齐与几何测量 | 已接入 production worker。历史验证包括代码基线 2ff58b0 的纯值 `OCRCharacterAligner`（按 composed grapheme 与原始 UTF-16 对齐，前向/后向 Levenshtein 找出所有最优路径必需的精确配对，超限时拒绝），以及 `.fast` 行 ROI 采集、保守校验与 CoreText gold raster benchmark；unit-only [run 42017762878](https://github.com/lei11118/pdf-vocab/actions/runs/42017762878) 有 141 项 unit 测试通过，含 11 项 refiner 测试。单条合成 Latin 样例 raw 为 `charge + beta 3.2`；14 个可见 glyph 全部得到字符框覆盖，14/14 gold center 落入对应框，mean covered-center error 为 1.39 pt，fallback 为 nil。当前 worker 按需精化单个 block，重新应用缓存前用当前原文、布局和 observations 重验。此前完整 [test-ink run 42144690686](https://github.com/lei11118/pdf-vocab/actions/runs/42144690686) 在 `Sources/ContextReading/SentenceContextBuilder.swift:191` 编译失败：`mappedDisplayRange` 的 `guard isWhitespace(grapheme.surface) else` 分支追加 index 后能够落出，违反 Swift `guard` 的退出要求。提交 `4b84593` 将该分支改为 `if !isWhitespace(grapheme.surface)`，同时保留缺失映射立即返回 `nil`。修正后的完整 [test-ink run 42146019076](https://github.com/lei11118/pdf-vocab/actions/runs/42146019076) 成功：175 项单元/集成测试、5 项 UI 测试均零失败，`SentenceContextBuilderTests` 的 7 项测试通过；同 SHA 的 [build-ipa run 42146414284](https://github.com/lei11118/pdf-vocab/actions/runs/42146414284) 成功，版本 v0.70.0 / build 118。 | v15 将派生字符几何与准确词级基础页分开，32 MiB 总预算、1 MiB 单条上限；缓存不覆写原文或旧词框。Composer 对连通 token 组原子升级，缺少必要几何时保留基础词框回退。Reader 的取消、请求去重和 pin 生命周期接入当前页精化。`.verifiedCharacter` 表示通过原文身份与完整几何检查，不承诺像素精度。历史 benchmark 仅为单条合成样例，不能代表真实照片。该历史 G2c 基线未做真实 iPad/Pencil 验证；“句子候选未接入 UI”和“G3 UI、语言包流程待实现”仅描述旧版本，不适用于当前增量。Apple Vision 的 [`VNRecognizedText.boundingBox(for:)`](https://developer.apple.com/documentation/vision/vnrecognizedtext/boundingboxforrange%3Aerror%3A?language=objc) 文档说明 accurate 框为词级、fast 框为字符级，且边框不保证像素精确。 |
| G3 系统 Token 对齐 | 单 Token 语境卡已接线；CI 通过，真机待验收 | 当前候选只对完整 context 的单 Token 语境卡请求系统对齐；悬浮预览和小胶囊保留词典释义，多词选区沿用旧整句卡。`build-ipa` run 42182468504 成功；`test-ink` run 42182468786 在同 SHA 上通过（223 项 unit/integration + 6 项 UI，零失败）。6 项 UI 为既有导航/布局/手势回归，不验证本次 SwiftUI TranslationSession 候选流程。 | 当前候选服务只有内存缓存，GRDB 持久化未做；OCR 跨行、系统 attributed-token 候选校对、金标 precision/recall/F1 与 iPadOS 26.4+ 真机验证待完成。 |
| G4 词/短语对齐质量评测 | 未完成 | 需要建立人工标注金标集并报告 precision、recall、F1；系统返回候选不能代替词义校对。 |
| G5 数学符号 | 未开始 | 先验证 Unicode 与简单结构转换。 |
| G6 数学 OCR | 未开始 | 需实际设备上的公式识别质量与资源评估。 |
| G7 外部模型 | 未开始 | 导入、安全、卸载与设备验证通过前不开放。 |
| G8 发布验收 | IPA 构建和 CI 通过；真机待验收 | 当前 `build-ipa` run 42182468504 的 IPA 元数据、主 app ZIP CRC、ARM64 和 science/ecdict 资源头检查通过；`test-ink` run 42182468786 已通过（223 项 unit/integration + 6 项 UI，零失败）。主脑已审阅 44 张 UIReview PNG 中的 4 张代表图，静态布局结论见文首。 | 动态 Gaussian 质量、iPadOS 26.4+ 语言/Token 行为与 iPad 手指/Pencil 真机回归仍待验证。 |

任何未运行或未通过的 CI、真机和质量评测均保持待验证，不以设计或代码存在代替验收。
