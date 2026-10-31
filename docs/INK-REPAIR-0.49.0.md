# v0.49.0 / build 92：手写编辑与空闲稳定性

代码：`5b2872e69d3b7274d11878378f4747827aced993`，分支 `codex/fix-ink-input-ruler`。保留现有矢量数据和 Bundle ID，不回退版本，不增加第三方依赖。

## 改动清单

| 文件 | 改动与原因 | 验证方式 |
|---|---|---|
| Sources/Reader/Ink/MetalInkHost.swift | 按当前视口尺寸重建缓存，限制像素预算、历史快照和页缓存；回收内存时保留最近操作；关闭阅读器后阻止延迟刷新重新挂载。接通套索、形状与变换事务。 | 滚动同步、套索跨页移动/缩放、保存、撤销重做、拆卸后延迟回调测试 |
| Sources/Reader/Ink/InkMetalCanvasView.swift | 抗锯齿改为屏幕像素尺度；干墨顶点按笔缓存，实时段单独构建；最多两帧在途；检查分配失败并记录 GPU 错误；资源释放后可从矢量重建。 | 8 倍渲染边缘像素、缓存重建一致性、透明度和运行时着色器测试 |
| Sources/Reader/Ink/InkBrush.swift | 拓宽钢笔轻重响应，增加速度影响、起收锋与中心线插值；保留原始采样，渲染时平滑。 | 压力归一化、轻重宽度比、平滑端点与有限数值测试 |
| Sources/Reader/Ink/InkEditGeometry.swift | 新增圈选命中、长线穿越检测、直线/矩形/椭圆/箭头几何，以及选框、拖动和四角等比缩放控件。 | 圈选几何、缩放锚点、四种形状整笔撤销及套索事务集成测试 |
| Sources/Reader/Ink/InkStrokeModel.swift | 增加值相等比较，避免变换结束时为比较改动而重复序列化整页。编码格式不变。 | 编译和变换保存/撤销测试 |
| Sources/Reader/Selection/ReaderCoordinator.swift | 传递形状种类；阅读器拆卸时收尾墨迹和编辑视图；自有选词手势让位于选词柄与墨迹编辑控件；关闭滚动方向锁定。 | 构建、形状与拆卸测试；真实手势需真机复测 |
| Sources/Reader/Selection/SelectionKit.swift | 选词柄热区扩大到 56pt，增加最近柄判定，装饰子视图不接触摸。 | 扩展热区命中测试 |
| Sources/Reader/VocabPDFView.swift | 在 PDF 页内容之前解析选词柄命中，重叠热区选择距离圆点最近的柄。 | 被 PDF 内容覆盖的扩展热区优先测试 |
| Resources/ink-grain-v1.png | 使用 imagegen 技能生成的原创石墨/蜡笔颗粒，作为实际 GPU 遮罩；荧光笔不使用颗粒。1254×1254 RGB，无文本元数据。 | 源图检查、测试断言资源存在、最终 IPA 资源检查 |
| Sources/Reader/ThumbnailLoader.swift | 用锁同步取消状态；PDFDocument 只在所属串行工作队列释放；渲染使用 autoreleasepool；内存缩略图最多保留 96 张。 | 请求缩略图后立即关闭的异步回归 |
| Sources/OCR/OCRService.swift | OCR 逐页释放临时资源，周期重开独立文档，渲染限制为 600 万像素与 4096 最大边；取消不标记完成。 | 普通/异常大页面预算测试、编译 |
| Sources/Support/DiagLog.swift、Sources/App/PdfVocabApp.swift | 增加内存告警、前后台、上次会话阶段的本地日志；未知退出原因明确标为 unknown。 | 构建；实际退出类型仍需系统报告 |
| Tests/InkEditingTests.swift、project.yml | 新增编辑、压感、清晰度、资源重建、空闲取消与拆卸测试；版本为 0.49.0 / 92。 | 最终 test-ink、build-ipa 和解包校验 |

## 验证

- 最终测试：[test-ink](https://github.com/lei11118/pdf-vocab/actions/runs/41195267916)，`Executed 16 tests, with 0 failures`、`TEST SUCCEEDED`，headSha 与上述代码一致。
- 最终构建：[build-ipa](https://github.com/lei11118/pdf-vocab/actions/runs/41195269125)，成功，headSha 与代码一致。
- 安装包：`dist/v0.49.0/PdfVocab-unsigned.ipa`，13,118,503 字节。
- 已验证 ZIP CRC、版本 0.49.0 / 92、原 Bundle ID、未签名 arm64、内置词典和笔刷图、无测试 bundle。
- SHA256：`5e28773c4fb7af3d91c535cd8da06bc272f06ce5959373ac9bd96837ac83a9e9`。
- 原有手势、尺子、PencilKit 保存、荧光笔同笔不加深、橡皮保存和撤销等测试保留。

## 闪退证据边界与遗留

用户补充“没有操作也会闪退”。源码确认缩略图文档的跨线程释放、OCR 临时资源累积、已拆卸阅读器的延迟重新挂载等风险；本轮针对这些路径做修正。它们与用户这次退出的因果关系仍为推断，业务日志没有异常栈或 Jetsam 原因，不能声称真机闪退已彻底消失。

真实 Pencil 压感、笔刷质感、单指斜拖、惯性滚动和长时间空闲仍需 iPad 验收；现有系统报告（PdfVocab .ips 或 JetsamEvent）才能进一步确认退出类型。局部橡皮仍为矢量切分；此轮未扩展激光笔和 JSON 墨迹 PDF 导出。老笔迹保留已存笔宽，新压力响应用于新笔迹。

本机 Claude Code 完成了只读审阅，但中文提示在 CLI 管道中存在编码问题；仅采纳经源码核对的生命周期/性能意见。其“取消会丢笔”“失败时 continue”等建议与现有代码或保全数据目标不符，未采用。

## 已清理

Python 通过 stdin 执行，未生成临时脚本；本轮测试用 UUID 隔离数据，defer 清理测试记录、PDF 和缩略图缓存目录。保留 IPA 与原创笔刷交付物；不删除用户原有目录。文档使用明确 UTF-8 写入，修正旧版记录的中文乱码。
