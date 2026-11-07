# ★标记★ 语境布局块与翻译对齐证据

> 状态：v0.72.0 / build 123 在研记录，核对日期 2026-11-07。仓库基线为 `18ba9a5`；本轮改动仍在工作树中，尚无本轮 CI 结果。本文只记录已检查的源码、样本与官方资料，不代表候选已通过质量验收。

## 本轮决策

- 保留已有的 Apple `TranslationSession` attributed-string 路径和项目自定义 Token ID 属性。Apple 文档说明 `translate(AttributedString)` 会保留格式及自定义属性；当前代码仍以 `iOS 26.4` 可用性检查保护请求。此处复用现有候选能力，不宣称真实 iPad 上的译义或 Token 对齐已验收。
- 保留当前 Vision `.accurate` 识别的词级框，以及已有的原文 UTF-16 / DP 对齐与 `verifiedCharacter` 完整性门槛。新增代码只把有界的 PDF 行布局和列几何接到上下文构造；不将 Vision 词框冒称字符框，也不让外部模型替换现有翻译对齐路径。
- 只有可信行几何、同列邻接关系和源文本映射都通过验证时，才生成 `.layoutBlock`。编号题目、标题、公式等结构边界会截断上下文；长度受 2,048 UTF-16 单元上限约束，OCR 邻接扩展当前至多检查每侧 8 行。其他情况继续使用现有回退路径。代码仍在本轮工作树中，行为须由本轮 XCTest 和 CI 证明。
- `Apple Vision RecognizeDocumentsRequest`、PaddleOCR PP-StructureV3、awesome-align 和 SimAlign 都是评估候选；本轮未接入它们。对齐方案先复用 Apple Translation attributes 和已有几何 / DP 校验，避免再加入一个独立模型输出协议。

相关代码：`Sources/ContextReading/LayoutBlockContextBuilder.swift`、`Sources/ContextReading/SentenceContextBuilder.swift`、`Sources/ContextReading/OCR/ContextOCRSelectionSource.swift`、`Sources/ContextReading/ContextualTranslationAlignment.swift`、`Sources/Card/ContextualTranslationTaskView.swift`。当前工作树尚未完成代码审查和本轮 CI。

## PDF 样本事实

两份用户本地 PDF 均未复制进仓库。页数由 `pdfinfo` 核对；整本文字层覆盖由 bundled Python 的 `pypdf` `Page.extract_text()` 逐页统计。以下计数只说明 API 能否提取到文本，不说明文字正确、版面顺序正确或 PDFKit 会返回同样结果。

| 样本 | 页数 | 文字层观察 | 代表页与媒体框 |
|---|---:|---|---|
| IELTS workbook | 205 | 仅 1/205 页非空（约 0.5%）；唯一非空页是末页书目信息，正文扫描页没有可抽取文字。 | PDF 第 10 页（书印第 6 页）为引言双栏正文；第 50 页（书印第 46 页）为编号练习、字格和图表。两页 MediaBox 均为 558.7086 × 768 pt。 |
| Halliday / Resnick physics | 1,453 | 1,452/1,453 页非空（约 99.9%），共 5,570,625 个提取字符；1,407 页超过 2,000 字符。pypdf 对若干 CFF Type1 字体发出缺少 `fontTools` 的解析警告，因此这里不把覆盖率当作字符准确率。 | PDF 第 61 页（书印第 33 页）含双栏题目、模块标题和图注；第 88 页（书印第 60 页）含双栏向量题。两页 MediaBox 为 732 × 849 pt，CropBox 为 `[32.98, 32.98, 699.02, 816.02]`。 |

physics 文件首页 MediaBox 为 666 × 783.36 pt；`pdfinfo` 的整本摘要显示首页尺寸。第 61/88 页具有不同的 MediaBox 和更小的 CropBox，这是页级框不同，不是页数或文字覆盖统计冲突。fixture 的 bbox 使用所标页面 MediaBox 的左下原点 PDF 点坐标。pypdf / pdfplumber 的结果不是 PDFKit 兼容性证明；真正的 PDFKit 选词和设备回归仍待完成。

代表行文本、每行 bbox、选中 UTF-16 范围及坐标约定位于 `Tests/Fixtures/LayoutBlock-Samples.json`。该 JSON 当前由 `Tests/LayoutBlockContextBuilderTests.swift` 读取。IELTS 第 50 页样本只保留一段题干前缀，bbox 覆盖整行且不含圆圈题号，因此只验证基本几何与范围映射，不用于断言题号检测。

## 扫描页 OCR 参考图

`Tests/Fixtures/IELTS-context-strip.png` 是 IELTS PDF 第 10 页正文两行的独立裁剪图，尺寸 1056 × 105 px；由 300 dpi 页面渲染裁出，页面像素边界为左上原点 `(54, 690)–(1110, 795)`，对应 MediaBox 左下原点约 `[12.96, 577.2, 253.44, 25.2]` pt。裁剪图只含两行正文和边白，不含整页。

两行参考字符串由人根据扫描图转录，保存在 fixture 与测试中；不是 PDF 文字层，也不是 Vision 输出。`Tests/RealScanContextTests.swift` 将该图置入约 293.44 × 65.2 pt 的纯图像 PDF，调用现有 `OCRService.recognizeContextPage`，从实际识别的 `classroom` 建立选择、验证 `.layoutBlock` 和 `ContextualTranslationRequest.make`，并只打印 CER/WER 数值与行数、不输出识别全文、不设准确率阈值。该 XCTest 尚未在 iOS Simulator / iPad 上运行；CI 结果待补。

## 官方资料与运行 / 许可核查

下表记录截至 2026-11-07 能从官方文档或仓库核对到的事实。开源仓库许可证只覆盖仓库代码；预训练权重和数据集须另行核对其自身许可。

| 候选 | 已核实的能力、许可与运行条件 | 本轮状态 |
|---|---|---|
| [Apple attributed Translation API](https://developer.apple.com/documentation/translation/translationsession/translate%28_%3A%29-59zi2) | `translate(AttributedString)` 支持保留格式和自定义属性；当前项目代码有 `iOS 26.4` 可用性保护，并使用既有 Token ID attributes。实际语言包、候选译义、属性回传仍需真实设备验证。 | 复用已有路径；本轮不新增翻译服务。 |
| [Apple RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest) 与 [WWDC25 介绍](https://developer.apple.com/videos/play/wwdc2025/272/) | Apple 文档说明结构化观察可包含词、行、段落、表格和列表；WWDC25 介绍涵盖 iPad。 | 可作为本机结构识别备选；当前代码未调用。后续需对其文本与现有 canonical OCR 做精确对齐，再评估页框与性能。 |
| [PaddleOCR PP-StructureV3](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-StructureV3/PP-StructureV3.html) | PaddleOCR 仓库代码为 Apache-2.0；官方安装文档把文档解析列为 `doc-parser` 可选组，需 Python 与已安装的推理引擎（如 PaddlePaddle、Transformers 或 ONNX Runtime），运行时还需模型权重。PaddleOCR 核心 Python 要求为 3.8+；部分可选组要求 3.9+。权重许可需逐模型核对。 | 候选参考，不在 iOS 工程中；无已验证的 iPad 转换产物、端侧性能或耗电数据。当前 bundled Python 未安装 `paddleocr` / `paddle`。 |
| [awesome-align](https://github.com/neulab/awesome-align) | 仓库许可为 BSD-3-Clause；README 要求安装依赖，项目使用 PyTorch 和 multilingual BERT checkpoint，checkpoint 可下载并缓存。依赖与权重许可须分别核对。 | 词对齐候选，不负责 PDF 版面结构；无本项目 iPad 打包或端侧实测。当前 bundled Python 未安装 `torch` / `awesome_align`。 |
| [SimAlign](https://github.com/cisnlp/simalign) | 仓库许可为 MIT；README 记录的旧测试环境是 Python 3.7、Transformers 3.1.0、Torch 1.5.0，并称可在 CPU 上运行。`setup.cfg` 列有 NumPy、Torch、SciPy、Transformers、regex、NetworkX、scikit-learn 等依赖。该 README 不是对现代或 iPad 环境的兼容性承诺。 | 词对齐研究候选；未接入、未安装、未在本项目设备上验证。 |

本次只在隔离的 bundled Python 环境检查了模块存在性：`pypdf` 与 `pdfplumber` 可用；PaddleOCR、PaddlePaddle、PyTorch、Transformers、SimAlign、awesome-align 均未安装。未下载模型、未运行在线 OCR，也未安装新依赖。

## 验证状态

- `Tests/LayoutBlockContextBuilderTests.swift` 已引用 JSON 样本；`Tests/RealScanContextTests.swift` 已建立真实 Vision OCR 测试链路。测试代码和资源尚未在本机执行。
- 最新已通过的仍是 `18ba9a5` 基线：`test-ink` run `42339957440`（251 项，0 失败）和 `build-ipa` run `42339957547`（IPA `0.71.1` / build `122`）。两条 run 均不覆盖本轮 0.72.0 工作树改动。
- 本轮 `test-ink`、`build-ipa`、iPadOS 26.4+ Translation 行为、真实 iPad OCR 与选词精度均待验证；数学识别、外部模型集成和 release acceptance 仍未完成。

## 参考链接

- [PaddleOCR Apache-2.0 LICENSE](https://github.com/PaddlePaddle/PaddleOCR/blob/main/LICENSE)
- [PaddleOCR 3.x 安装说明](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/installation.en.md)
- [PaddleOCR PP-StructureV3 用法](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/pipeline_usage/PP-StructureV3.en.md)
- [awesome-align BSD-3-Clause LICENSE](https://github.com/neulab/awesome-align/blob/master/LICENSE) 与 [依赖声明](https://github.com/neulab/awesome-align/blob/master/setup.py)
- [SimAlign MIT LICENSE](https://github.com/cisnlp/simalign/blob/master/LICENSE)、[README](https://github.com/cisnlp/simalign/blob/master/README.md) 与 [依赖声明](https://github.com/cisnlp/simalign/blob/master/setup.cfg)
