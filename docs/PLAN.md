# 跃文(pdf-vocab)开发方案 · M0 时点(已确认)

> 更名记录:App 显示名「读词」→「跃文」(2026-10-12,v0.5.0 起;仓库 slug 保持 pdf-vocab)。

## 0. 已确认的决定

| 项 | 决定 |
|---|---|
| 仓库 | `lei11118/pdf-vocab`(**公开**;公开仓库的 macOS 构建分钟全免费) |
| 最低系统 | **iPadOS 17.5**(Pencil Pro 挤压/触觉 API 的硬性要求,已核实) |
| 词库 | 默认**内置精简词库**(CI 从 ECDICT 生成,开箱离线可用);支持**单文件导入**扩展词库(选一个文件→自动完成);提供"不内置"构建开关 |
| 分发 | GitHub Actions 出**未签名 IPA** → AltStore / SideStore / Sideloadly 自签安装(免费 Apple ID) |
| App 名 | 跃文(Bundle ID `com.lei11118.pdfvocab`;2026-10-12 前为「读词」) |
| 工程 | XcodeGen(project.yml),`.xcodeproj` 不入库 |

## 1. 核实结论(2026-10 查证)

| 存疑点 | 结论 |
|---|---|
| Pencil Pro 挤压 API | `UIPencilInteractionDelegate.pencilInteraction(_:didReceiveSqueeze:)`(`UIPencilInteraction.Squeeze`,带 phase),**iPadOS 17.5+**;可读系统偏好 `UIPencilInteraction.preferredSqueezeAction` |
| 挤压 vs PKToolPicker 共存 | 使用 PKToolPicker 时,"挤压弹出工具面板"是**零代码自动行为**;自行注册 UIPencilInteraction 并实现代理即接管该手势。实现方式:尊重系统偏好(默认=显示工具面板),自定义映射作为设置项;真机联调确认 |
| 悬停 API | `UIHoverGestureRecognizer`(iPadOS 16.1+ 支持 Pencil 悬停;Pencil Pro 挤压/双击事件附带 hoverPose) |
| Pencil 触觉 API | `UICanvasFeedbackGenerator`(**iPadOS 17.5+**),仅 `alignmentOccurred(at:)` / `pathCompleted(at:)` 两类,仅 iPad + Pencil(或妙控板)生效 |
| PencilKit 叠加 PDF | 路线可行:`PDFPageOverlayViewProvider`(iOS 16+,WWDC22 官方)逐页挂 overlay + `PKCanvasView.drawingPolicy = .pencilOnly`(iOS 14+);社区有已知坑(canvas 尺寸/首响应者/缩放画质),真机联调 |
| PDFView 原生选择 + Pencil | 无法离线确证,**真机验证**;已设计统一取词层兜底(`PDFPage.characterIndex(at:)` 命中 + 自定义手势 `allowedTouchTypes=[.direct,.pencil]`) |
| 翻译框架 | 系统面板 `translationPresentation` 17.4+;程序化 `TranslationSession` 18+;仅 SwiftUI、仅真机 → P1 按版本分级降级 |
| 最低系统 | **iPadOS 17.5**(挤压 + 触觉为最高门槛) |
| ECDICT | 许可证 **MIT**;ecdict.csv 65.9MB / 76 万词条;CI 生成精简 SQLite 打包(预估 40–90MB,实测为准) |
| 免费 Apple ID | 10 App ID / 7 天、3 设备 / 7 天、3 App / 设备、描述文件 7 天过期;重签不丢数据,删 App 才丢 |
| Actions 计费 | 公开仓库标准 runner **免费(含 macOS)**;私有仓库 Free 计划 2000 分钟/月,macOS ×10 ≈ 200 分钟/月 |
| Runner / Xcode | 钉 `macos-26` 镜像 + `DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer`(不依赖 macos-latest 漂移) |
| .apkg | genanki 同款 **Legacy 1**(collection.anki2 schema 11 + media JSON + 编号媒体文件,deflate zip);稳定 GUID → 重复导入=更新不重复;音频:在线音源缓存 mp3,TTS 兜底导出 wav |

## 2. 技术选型

- Swift(Swift 5 语言模式)+ SwiftUI 为主;PDFView / PencilKit 以 UIKit 包装;单 App target,无扩展、不使用 iCloud/Push/App Groups 等付费能力
- 阅读页:`UIViewRepresentable(PDFView)` + Coordinator(选择 / 高亮 / 点击命中);词卡用 `.inspector`(17+,`inspectorColumnWidth` 可拖宽度)
- 数据:GRDB(用户库 user.sqlite)+ 只读 `ecdict.sqlite`(随包)+ 沙盒文件(音频缓存 / PDF 副本按 SHA-256 命名)
- 取词统一接口:文本层(characterIndex / characterBounds)与 OCR 词框(归一化坐标)两个实现,上层同一 API;词形还原 = NLTagger lemma + ECDICT exchange 兜底
- 高亮:临时 = 内存 PDFAnnotation(不写原文件);永久 = 存 DB、重开重建;点击命中 → 字符/词框定位 → 查 DB 开卡
- 发音:在线音源(Free Dictionary API,可关)→ 本地缓存;离线兜底 AVSpeechSynthesizer
- Anki 导出:GRDB 写 schema 11 + ZIPFoundation 打包 + 系统分享面板;备选 CSV/TSV

## 3. 开源组件

| 组件 | 用途 | 许可证 | 引入 |
|---|---|---|---|
| GRDB.swift | SQLite(用户库 + 读 ECDICT) | MIT | SPM |
| ZIPFoundation | zip 读写(.apkg / 备份) | MIT | SPM |
| ECDICT | 离线词库数据 | MIT | 构建期脚本生成 |
| XcodeGen | 生成 Xcode 工程 | MIT | CI(brew) |
| genanki | .apkg 格式参考 | MIT | 仅参考,不引入 |

系统框架:PDFKit、PencilKit、Vision、NaturalLanguage、AVFoundation、Translation(可选)。

## 4. 数据模型(草案)

```
documents(sha256 PK, title, pageCount, hasTextLayer, importedAt, lastPage)
pages(docId, idx, text, tokensJSON)     -- 文本层:字符区间;扫描版:OCR 词框(归一化坐标)
highlights(id, docId, page, kind, start, len, text, lemmaKey, origin, createdAt)
words(id, lemma UNIQUE, surface, phonetic, translation, definition, pos,
      collins, oxford, tags, frq, audioFile, status, createdAt, updatedAt)
senses(wordId, ord, text, selected)     -- 收录时勾选义项
occurrences(id, wordId, docId, page, sentence, hlId)   -- 语境追加
groups / group_words / tags / word_tags
drawings(docId, page, data BLOB)        -- PKDrawing,按 PDF 哈希 + 页码
audioCache(wordKey, file, source)
```

ECDICT 侧(只读):`ecdict(word PK, phonetic, translation, definition, pos, collins, oxford, tag, bnc, frq, exchange)` + `forms(变形 → 原形)`。

## 5. 目录结构

```
pdf-vocab/
├─ .github/workflows/build-ipa.yml   # 出包流水线
├─ project.yml                       # XcodeGen 工程定义(SPM 依赖)
├─ scripts/                          # (M2 起)词库构建脚本 build_dict.py
├─ Sources/
│  ├─ App/          入口、全局状态、设置页
│  ├─ Library/      文档库(导入 / 列表 / 进度)
│  ├─ Reader/       PDFView 封装、取词、选择、高亮、点击命中
│  │  └─ Pencil/    PKCanvas 叠加、模式切换、悬停 / 挤压 / 触觉
│  ├─ Card/         侧边词卡(inspector)
│  ├─ Vocab/        生词本、分组、标签
│  ├─ Dict/         ECDICT 查询、在线补充、TTS + 缓存
│  ├─ OCR/          Vision 识别流水线
│  ├─ Anki/         .apkg 导出
│  └─ Data/         GRDB 模型 / 迁移 / 仓储
├─ Resources/       Assets.xcassets、Info.plist(XcodeGen 生成)
├─ docs/            PLAN.md / 安装说明
└─ README.md        构建 / 安装 / FAQ
```

## 6. CI 出包

- 触发:`workflow_dispatch` + push tag `v*`
- Runner/Toolchain:`macos-26` + Xcode 26.6(见 §1)
- 流程:checkout → 选 Xcode → brew 装 xcodegen →(M2 起)python 生成词库(cache)→ `xcodegen generate` → `xcodebuild archive`(`CODE_SIGNING_ALLOWED=NO`)→ 组 `Payload/App.app` → zip 未签名 IPA → 校验结构 → 上传 Artifact;tag 时发布 Release
- 装机:iPad Safari 打开 Release 下载 → 分享给 AltStore/SideStore;或 Windows Sideloadly 签名安装

## 7. 里程碑

| 里程碑 | 内容 |
|---|---|
| M0 ✅ | 空壳 App + CI 出包 + README 安装指南 |
| M1 ✅ | 导入 PDF、渲染、长按/拖选取词(手指 + Pencil)、临时高亮、阅读进度记忆 |
| M2 | 侧栏词卡 + ECDICT 查词 + 词形还原 + 发音(在线缓存 / TTS 兜底) |
| M3 | 生词本:收录、永久高亮、已收录追加语境、分组 / 标签、义项勾选 |
| M4 | Pencil:PKCanvas 叠加、工具面板、模式切换、悬停预览、挤压映射、触觉 |
| M5 | Anki .apkg 导出(稳定 GUID、正反模板;CSV 备选) |
| M6 | 扫描版 OCR 取词 + P0(已收录词自动加亮、音频离线化) |
| M7 | P1/P2:词频 / 考试标签批量收录、整句翻译(版本分级)、导出含标记 PDF、整库备份 / 导入、StarDict 导入、打磨 |

每个里程碑要求:Actions 构建通过;涉及交互的里程碑附真机测试清单。

## 8. 风险与未决项(诚实清单)

1. PDFView 原生选择对 Pencil 的响应 —— 只能真机验证;已备自研取词回退(接口统一)
2. 工具面板与自定义挤压的最终共存行为 —— 按系统偏好处理,真机联调
3. PKCanvasView 叠加 PDF overlay 的社区已知坑(首响应者 / 缩放画质)—— M4 专项处理
4. ECDICT 精简 SQLite 实际体积以 CI 实测为准;过大则加词频过滤
5. Pencil 触觉类型受系统限制(仅对齐 / 路径完成两类)
6. M1/M4 需要真机实测反馈(交互问题无法在无设备环境发现)
7. Anki 客户端版本差异 —— 采用最保守的 genanki 同款格式,附导入测试步骤
8. ✅ 已处理(2026-10-11):iPadOS 26 上 SwiftUI `.fileImporter` 安全作用域失效(社区已验证的 iOS 26 回归)→ 改用 UIKit `UIDocumentPickerViewController`(`asCopy: true`,系统先拷进沙盒再交付,无需安全作用域);导入管线重构为"先落地沙盒再处理";选择器类型放宽 `[.pdf, .data]`;新增"拖入文件夹 / Inbox 自动导入"通道
9. ✅ 已处理(2026-10-11,v0.2.2):Pencil 取词偏移 / 拖选跳变 / 偶发卡顿退出——**根因:iOS 18+ PDFKit `characterBounds(at:)` 与 `page.string` 顺序回归**(Apple 论坛 FB14843671、SO 78977349 等均有记录),字符串索引 ↔ 几何位置不再可靠,大范围错选还会导致高亮注解风暴卡死主线程。**修复:取词改为纯点坐标路线**(`selectionForWord` / `selectionForLine` / `selection(from:to:)`,不经字符串索引);手势结束保留原生选择(可用手柄继续调整);高亮重建去重 + 移动节流 + NaN/异常矩形防护。另:按用户要求删除两条备用导入路径(共享打开、拖入文件夹自动导入),仅保留文件选择器
10. ✅ 已处理(2026-10-11,v0.2.3):①编辑菜单英文 → 声明 zh-Hans 本地化(`CFBundleLocalizations: [zh-Hans, en]` + `CFBundleDevelopmentRegion`),系统菜单随设备显示中文(QA1828);②屏蔽菜单"全选"(PDFView 子类 `canPerformAction`;社区已知:大文档全选会导致内存暴涨卡死);③文字量大的 PDF 卡顿:临时高亮改**差量更新**(只增删变化的行注解,不再清空重建)、词数统计改线性扫描(弃用 NLTokenizer)、信息条文本截断 400 字、拖动节流 3pt、每选区注解上限 120 行
11. ✅ 已处理(2026-10-11,v0.2.4):①Pencil 编辑栏概率性不出现——自定义手势抢跑原生所致,改为手势延后 0.75s + 检测到原生驱动的选择变化即完全让位(原生优先,兜底接管);②"选择后跳最后一页 + 卡死数秒"——疑为数据损坏页面上 point-pair 选择被解析成全文档巨型选区(设选区→PDFKit 滚到选区末端=最后一页;selectionsByLine 全文档展开→主线程卡死),新增 `isSane` 选区合法性校验(页数/字符数上限,非法一律拒绝)、selectionsByLine 先截行数再取边界、自适应节流(选区 >800 字符时步进 8pt)
12. 🔍 进行中(v0.2.5):问题仍概率性出现(编辑栏"有些词有有些没有";选词卡死+跳页偶发)→ 策略切换为**数据驱动**:①新增 `DiagLog` 诊断日志(Documents/diagnostics.log,记录每笔手势走了哪条路径、selectionForWord/from-to/setCurrentSelection/highlight 各步耗时、滚动恢复动作、选区拒绝原因);②自定义路径手势结束时**主动弹出自绘编辑菜单**(UIEditMenuInteraction,含"复制"),不再依赖系统概率性弹菜单;③设置选区后若滚动位置变动>1pt 则强制恢复(防跳页);④自定义路径选区收紧为单页 ≤6000 字符。待用户复现并回传日志/PDF 样本后精确定位
13. ✅ 已处理(2026-10-11,v0.2.6):用户反馈「文件」App 中**没有**「读词」文件夹 → 解包核实:IPA 内有 `UIFileSharingEnabled`,但缺 `LSSupportsOpeningDocumentsInPlace`(Files「我的 iPad」可见性需两键齐全;v0.2.2 清理备用导入路径时被移除)→ 补回;同时新增 **App 内「诊断日志」查看页**(文档库左上角「诊断」:查看/复制全部/分享文件/刷新/清空),不再依赖 Files;App 启动即写一条日志(保证日志文件先存在)
14. ✅ 已处理(2026-10-11,v0.2.7):用户反馈"日志都未变化" → 判断为 v0.2.6 日志覆盖过窄(只记异常:让位/拒绝/慢操作,正常选区变化、翻页、点击均无记录)→ 改为**全量记录**:`selChange(own/native): len/pages`(每次通知)、`page->N`(翻页/跳页可见)、`tap`、`clearSelection`、`pencil.end ours=`;慢操作阈值下调(高亮>40ms、设选区>60ms);诊断页新增**状态头**(行数/字节/更新时间/文件路径)+ **「写入测试日志」按钮**(一键验证写入-读取链路,0.4s 后自动刷新)
15. ✅ 已处理(2026-10-11,v0.2.8,**基于用户回传的真实日志定位**):日志实证:①全部选区变化均来自**原生机制**(唯一一次 Pencil 测试走了自有路径:pickup=2ms、无卡顿);②**两处跳页现场**:选中 len=3 后 52ms 跳到 page 204(204=该文档最后一页),选中 len=6 后 53ms 跳到 page 1452,随后日志断档 **6.4 秒**(=卡死),并出现 len=1353/pages=2 的巨型选区 → 判定:**PDFKit 内置选择机制在异常文本层文档上把选区/自动显现解析到文档末尾**。修复:③手指与 Pencil **统一走自有取词管线**(停用 PDFKit 内置选择手势:遍历视图树禁用全部 `UILongPressGestureRecognizer` 与 `numberOfTapsRequired≥2` 的 tap;保留滚动/缩放/链接单击;文档加载后延时二次压制 + 检测到原生选区泄漏时自愈再压);④**跳页护栏**:紧跟选区变化 0.3s 内、跨页>5 且向后的 `pageDidChange` 判为异常,自动拉回上一稳定页并记日志;⑤高亮矩形增加**页面边界校验**(越界拒绝并计数 rej=);⑥日志补充:文档页数+sha、每笔高亮耗时、手势种类、选中文字片段
16. ✅ 已处理(2026-10-11,v0.2.9,**用户提供两个问题样本 PDF 后取证**):文件取证(纯标准库解析):样本1=**FreePic2Pdf 生成的 205 页扫描书**(204 张图、极简 OCR 文本层、**非线性化**);样本2=**iText 5.5.6 / InDesign CC 2015 制作的 1453 页教材**(329 节点深页面树、xref 流 + 150 个对象流、Type1 字体、**非线性化**、含约 297 个疑似空白小页)。两份"跳到底"的目标页(204 / 1452)**正是各自最后一页** → 与社区已知的"非线性化 PDF 触发 PDFKit 异常、重存副本可恢复"经验吻合。修复:①**规范化读取副本**:导入时/首次打开时用 `PDFDocument.write(to:)` 非破坏性生成 `PDFs/<sha>.norm.pdf`(页数校验通过才使用;失败回退原文件;删除文档时一并清理);②自有取词管线**彻底不再设置 PDFView 选区**(移除 `setCurrentSelection` 及相关滚动恢复)——黄高亮/信息条/菜单全部由自有状态驱动,从根上消除触发面;③跳页护栏窗口放宽到 0.8s;④选区处理统一收紧为单页 ≤6000 字符。**用户确认:跳页与卡死问题解决** ✓
17. ✅ 已处理(2026-10-11,v0.3.0,基于用户反馈):①**拖动扩选回归**——长按 .began 后拖动时,页面滚动(内部 pan)与自有长按手势同时识别,拖动被滚动抢走、选区不跟手 → 长按期间**冻结滚动视图的 pan 手势**,松手/取消时恢复(与原生选择手感一致;顺带在 clearSelection/documentDidChange 处兜底恢复);②**编辑菜单补全**:自绘菜单从仅"复制"扩充为**复制 / 翻译 / 朗读 / 共享**——翻译由 SwiftUI 层 `translationPresentation`(系统翻译面板,iOS 17.4+,首次使用需下载语言包)承接;朗读用 AVSpeechSynthesizer(en-US);共享用 UIActivityViewController(iPad 需 popover 锚点,已设 sourceView/sourceRect,延迟 0.15s 等菜单收起)
18. ✅ 已处理(2026-10-11,v0.3.1,用户要求"蓝色手柄可以,编辑框和原生一样只取消全选"):**选择交互完全回归 PDFView 原生**——原生长按/拖选/双击选词/**原生蓝色手柄**/**原生编辑菜单**(`VocabPDFView.canPerformAction` 已屏蔽"全选"),手指与 Pencil 一致。删除全部自建机制(自有长按手势、UIEditMenuInteraction 自绘菜单、原生手势压制、滚动冻结、自建翻译/朗读/共享);它们的使命(=在未规范化文档上绕开 PDFKit 缺陷)已由**规范化读取副本**根治。保留保险层:选区合法性校验(>5 页或 >10000 字符拒绝)、跳页护栏(0.8s 窗口自动拉回)、高亮矩形越界拒绝、全量日志;黄高亮与信息条改由 `.PDFViewSelectionChanged` 通知驱动(逻辑不变)
19. ✅ 已处理(2026-10-11,v0.3.2,**用户实测反馈:v0.3.1 一换回原生 bug 立刻复现**——证明"压制原生选择机制"才是跳页/卡死的关键,规范化副本只解决一部分):**退回自研管线**(v0.3.0 架构:自有长按手势手指+Pencil、压制原生选择手势、不设置 PDFView 选区、拖动期间冻结滚动),并补齐用户要求的两项:①**自研拖动柄**(选区两端蓝点圆形手柄,`SelectionHandleView`,拖任意一端=以另一端词为锚走自有扩选逻辑;KVO 观察内部 scrollView 的 contentOffset/zoomScale 跟随滚动缩放;44pt 触控区;拖柄期间同样冻结滚动);②**编辑菜单五项**:复制 / 查询(UIReferenceLibraryViewController 系统词典,取选中首词)/ 翻译(translationPresentation 系统翻译面板)/ 搜索网页(Bing)/ 共享(UIActivityViewController + popover 锚点)
20. ✅ 已处理(2026-10-11,v0.3.3,用户要求"选词风格材质和原装一模一样 + 再次点击可关闭/呼出编辑栏"):①选区高亮色由黄改**系统蓝(α0.35)**,视觉对齐原生选择;②拖动柄重做为**原生风格**(14pt 蓝点 + 白边 + 短柄:起点柄短柄朝下指向首行、终点柄短柄朝上指向末行);③**点击交互**:点选区=切换编辑菜单(已弹出则 `dismissMenu()` 关闭,否则重新呼出);点空白=取消选中并关闭菜单;菜单弹出/关闭状态经 `willPresentMenuFor/willDismissMenuFor` 代理跟踪
21. ✅ 已处理(2026-10-12,v0.3.4,用户截图反馈修正):①**手柄布局纠正为原生不对称样式**——起点柄在选区下方(圆点在下、短柄朝上),终点柄在选区上方(圆点在上、短柄朝下)——此前做反了(用户附 iOS 原生"aqa"选区截图对照);②**点击规则修正**:点选区=仅切换编辑菜单、**永不关闭选区**(此前点到选区边缘被误判为空白而清掉整个选区);点空白=菜单开着时**先只关菜单、选区保留**,菜单已关时再点空白才取消选中;③命中判定加 10pt 容差;④选区蓝调 α0.35→0.30 更贴近原生色
22. ✅ 已处理(2026-10-12,v0.4.0,用户指示"自研管线仿照原生重构,或者直接找开源项目"):**开源调研结论:无现成可用件**(PDFium/MuPDF 只是引擎;pdf.js 是 Web 栈;PDFEditorSDK 只有批注;VisionKit Live Text 与 UITextInteraction 有重大架构代价 → 均记录于 docs/SELECTION-PARITY.md)。**仿原生重构**(把手写件尽量换成系统真件 + 补齐原生手势集):①**系统放大镜**接入(`UITextLoupeSession`,iOS 17+ 公开 API,拖动选词/拖柄/拖选区时实时跟随;拖柄场景以把手视图为动画锚);②**双击选词**并弹菜单(原生同款);③**三击选行**(对应原生三击选段落,PDF 取整行)并弹菜单;④**长按选区本体拖动微调**(以远端为锚,与原生"按住选区拖动"一致,复用已证稳定的长按+冻结滚动机制避免与滚动抢手势);⑤suppressNative 白名单同步放行新手势;⑥新增 docs/SELECTION-PARITY.md 记录原生对照表与有意保留的差异(词粒度吸附/拖动冻结滚动/三击取行)
23. ✅ 已处理(2026-10-12,v0.5.0,**用户要求"选词管线推倒重来、仿照原生、先研究再动手"**):**重写取词管线**(删除旧协调器补丁层;新拆 `SelectionKit`(拖柄/系统放大镜/Pencil 感知手势/几何校验)+ `SelectionMenu`(系统菜单封装);`ReaderCoordinator` 全量重写为单一状态机)。修复与原生体验的差距:①拖动中拖柄实时显示(旧版拖动时消失);②放大镜只对指尖显示(Pencil 不显示);③菜单时机对齐原生(按住 ~0.35s 弹出→拖动收起→松手回归→拖柄结束回归);④新增贴边自动滚动(冻结滚动之上,自研 contentOffset 控制,≈7pt/帧封顶);⑤旋转/缩放/连续滚动坐标实时换算(新增 pdfView.bounds 观察)。研究结论与原生对照表更新于 docs/SELECTION-PARITY.md(无现成开源件可用;UITextInteraction 全家桶需 UITextInput + 可靠索引文本,列为后续 PDFium 升级项)
24. ✅ 已处理(2026-10-12,v0.5.0,**选页**):顶栏新增「当前页 / 总页数」按钮 → 跳页面板(数字输入 + 滑杆,越界提示,空输入禁用,滑杆松手即跳);与 PDFViewPageChanged 实时同步;跳转走协调器 go(toPage:),不触发跳页护栏
25. ✅ 已处理(2026-10-12,v0.5.0,**退出位置记忆**):以内容哈希 sha256 为键(GRDB 迁移 v2:document 表加 pageX/pageY/zoom/zoomAuto 列),保存"页码 + 页内比例位置 + 缩放(含 autoScales 标志)";滚动尾随防抖 2s + 切后台/退页强制保存;恢复在文档加载后按比例落位(两次校正,用户已操作则跳过);多文件互不干扰;文件缺失时阅读页显示「文件缺失」占位,不崩溃
26. ✅ 已处理(2026-10-12,v0.5.1,用户附 iPadOS 26 真机截图要求"选区和截图一模一样"):**选区交互逐像素对齐真机**:①手柄布局纠正为**起点柄圆点在上(短柄朝下)、终点柄圆点在下(短柄朝上)**、实心蓝点去白描边(截图逐点核对);②高亮蓝 α0.30→0.35;③**点空白 = 蓝色选区与编辑栏一起消失(一步)**(点选区内仍只切换编辑栏、永不关选区——保留用户此前明确要求)
27. ✅ 已处理(2026-10-12,v0.5.1):**选页面板升级**:「按页码 / 缩略图」分段——缩略图网格(LazyVGrid 懒加载、当前页描边高亮、打开自动定位当前页、点击即跳);顶栏页码按钮加胶囊底更易发现
28. ✅ 已处理(2026-10-12,v0.5.1):**返回主页位置记忆加固**:新增视图拆卸兜底保存(onTeardown → captureReadingState),连同 滚动尾随防抖/切后台/退页 共四条保存路径;重开文档按 sha 恢复(页码+页内比例+缩放)
29. ✅ 已处理(2026-10-12,v0.5.2,用户反馈):①**缩略图滑动卡顿修复**——改用 `ThumbnailLoader`(独立 PDFDocument 实例 + 串行后台队列 `.utility` + 幂等请求 + 面板关闭失效),主线程不再做缩略图渲染;②**编辑栏位置**改为选区**上方居中**(`menuSourcePoint()` = 选区视图矩形上边中点),不再只贴起点小柄;③**蓝色小柄加长**(6pt→13pt)直达选区边界(柄尖距边界 1pt)
30. 📝 记录(2026-10-12,用户授权,待 M6):扫描版取词的 **OCR 方案允许二选一**——苹果原生(VisionKit Live Text)或现有自研管线;M6 实施时按效果/性能/成本择一,并在 SELECTION-PARITY 文档记录取舍;**用户提醒(v0.6.2):M6 的 OCR 取词需同步套用最新交互口径**(两端圆点拖柄 + 编辑栏下边对准起点圆点 + 悬浮词卡)
31. ✅ 已处理(2026-10-12,v0.6.0,**M2:侧边词卡 + 离线查词 + 发音**):①**内置精简词库**:CI 下载 ECDICT 1.0.28 官方 sqlite 包(ecdict-sqlite-28.zip,actions/cache 缓存 zip)→ `scripts/build_dict.py` 筛选(词频/BNC/考试标签/柯林斯/牛津任一命中)+ 生成 form 词形表 → 打包 Resources/ecdict.sqlite(不入库);②**查词链**:原文直查 → 词形表(went→go 等)→ NLTagger 词形还原再查;③**侧边词卡**:选中即开(单词卡:词头/音标/美音·英音发音/考试标签/柯林斯星级/牛津核心/中英释义;整句卡:原句 + 可点击词块);点空白或清选自动关闭,关闭按钮同步清选区;④**发音**:AVSpeechSynthesizer 离线 TTS(en-US / en-GB);⑤词库以 GRDB 只读打开 bundle 内 SQLite
32. ✅ 已处理(2026-10-12,v0.6.1,用户反馈):①**编辑栏锚点**改为**永远在第一个小柄(起点圆点)正上方**;②**缩略图提速**:`ThumbnailLoader` v2 = 3 个并发渲染 worker(独立 PDFDocument 实例)+ 磁盘 JPEG 缓存(重开秒开)+ 前方预取;③**词卡改为悬浮小窗**:可自由拖动、位置持久(UserDefaults)、**点 × 才关闭、不再自动关闭**、不推挤 PDF(独立浮层);④选区拖柄改为**两端各一个蓝色圆点**(去短柄)
33. ✅ 已处理(2026-10-12,v0.6.2,用户反馈):①悬浮窗拖动"抽风"修复——`DragGesture` 改用 `.global` 坐标空间 + 记录拖动起点(局部坐标随窗口移动导致反馈抖动);②编辑栏改为**下边对准起点圆点顶部**(锚点 y -26 → -19);③悬浮窗**可自由缩放**(右下角手柄,像原生窗口;最小 240×220、最大 = 阅读区-16,尺寸持久化);④窗口逻辑抽成独立 `FloatingCardWindow` 视图(拖动/缩放只重绘窗口自身,不再牵动整页);⑤窗口适配:旋转/分屏改变尺寸时自动重钳位置与大小
34. ✅ 已处理(2026-10-12,v0.6.3,用户反馈"编辑栏盖住选区、点不了词"):**根因**——仅提供**裸 sourcePoint** 时,iPadOS 26 的编辑栏会挂在锚点**下方**(锚点越低盖得越狠;v0.6.2 下调 7pt 反而加剧);**修复**——实现 `UIEditMenuInteractionDelegate.editMenuInteraction(_:targetRectFor:)`,`targetRect` = **选区矩形**(全部选中行 + 向上扩 24pt 以含起点圆点区域)→ 系统把编辑栏放到矩形**上方**、底部贴齐起点圆点,不再压住文字;sourcePoint 保留在起点圆点顶部做兜底
35. ✅ 已处理(2026-10-12,v0.6.4,用户反馈):①**去掉底部"已选中单词"信息条**(正下方那条);②弹窗形状改为**胶囊圆角**(连续圆角 min(30, 高/2),迷你时即标准胶囊);③**点空白取消选中时弹窗一起消失**(按最新要求);④**迷你胶囊模式**:窗口可缩到最小 180×48,高度 <140 自动切换为横排「单词 + 发音按钮 + 翻译(首行)」;双击胶囊可在迷你/完整间切换;缩放手柄迷你时自动变小
36. ✅ 已处理(2026-10-12,v0.6.5,用户反馈):①**"已有选区后再长按漏出原生选区"修复**——三管齐下:长按/拖柄手势 `.began` 时**再压一遍**、压制过滤增加私有"Selection/Loupe/Caret/TextInteraction"类名手势(不同系统构建类名兜底)、检测到原生选区泄漏时**立即清掉**(currentSelection=nil + clearSelection,不再只是重压);②**迷你态=真胶囊**(半径=高/2,≤120pt;120–160 与圆角矩形平滑过渡);③**胶囊⇄词卡切换丝滑动画**(双击切换用 spring;阈值跨越内容交叉淡入);④**拖选改为字符粒度**("一个字母一个字母"):`selection(from:to:)` 终点直接取原始触点(最近字符边界收口),锚点侧吸附初始词首/词尾(向后拖从词首、向左/上拖以词尾为锚)
37. ✅ 已处理(2026-10-12,v0.6.6,用户反馈):①**"有文字层的 PDF 不能选词"修复**——回退 v0.6.5 的"按类名压制私有手势"(在文字层 PDF 上误伤 PDFKit 文本处理链路);拖选改为**字符粒度优先 + 词粒度兜底**;选区**坏帧不再清空**(applySelection 拒收时保留上一个好选区,不再把蓝色高亮/词卡清掉);原生选区泄漏由 selectionDidChange 即时清除兜底 + **重入保护**(防 clearSelection 循环);②**缩放拖动"突然断掉"修复**——拖拽期间**冻结形态**(heldCompact),内容分支/手柄尺寸不在拖拽中变化;③**缩放手柄改为白色小条**(45° 贴角,替代箭头符号),按压时放大变亮(spring 动画)
38. ✅ 已处理(2026-10-12,v0.6.7,用户反馈):①**白色缩放条改为"就是边缘"**——右下角改为**沿窗口圆角边缘的白色弧条**(`CornerGripArc` Shape:弧半径随圆角连续变化,胶囊态半圆、矩形态圆角,全程贴合边缘),按下加粗变亮(spring);命中区独立透明;**②小蓝球恢复小柄**——蓝点+短柄,柄**直达蓝色选区边缘**(起点柄朝下贴首行上缘、终点柄朝上贴末行下缘);编辑栏 targetRect 上扩 24→36pt、锚点 -19→-35(含新柄位);③**胶囊⇄词卡的文字过渡**——内容改双层交叉淡入(ZStack + opacity + allowsHitTesting),不再忽然切换
39. ✅ 已处理(2026-10-12,v0.6.8,用户反馈):①**小柄穿入蓝选区**——柄端从"贴边"改为**穿进选区约 6pt**(摆放偏移 ±22→±16;浅色/深色页面都能看到"穿过"效果);编辑栏随之微调(sourcePoint -35→-29、targetRect 上扩 36→30);②**弹窗文字改为拖动中实时变化**——去掉 v0.6.6 的"拖拽期冻结形态"(v0.6.7 已把内容改双层交叉淡入、无结构切换,冻结已无必要),文字随手指移动实时交叉过渡;缩放手柄命中区改固定 32pt(不再随形态变)
40. ✅ 已处理(2026-10-13,v0.6.9,用户反馈):①**柄端紧贴蓝选区**——从"穿入 6pt"收敛为**紧贴边缘并压入约 2pt**(摆点 ±16→±21;按实时换算的选区边缘自适应,任何缩放/行高都严丝合缝、无缝隙);编辑栏随之微调(sourcePoint -29→-34、targetRect 上扩 30→36);②**胶囊触摸判定 = 窗口形状本身**——迷你体 contentShape 改为随圆角连续变化的 `RoundedRectangle`(形状之外不拦截触摸);缩放手柄命中区改为**全窗大小的透明层 + 「窗口形状 ∩ 右下角区」**(`CornerHitShape`,CGPath 布尔交集),圆角外同样不拦截;③**新增设置页**(文档库 ⚙️ / 阅读页 ⚙️,`Sources/App/SettingsView.swift`):开关「**选词后自动发音**」(默认关;开启后选中单词、词卡出现时自动朗读美音;句卡不发音)
41. ✅ 已处理(2026-10-13,v0.6.10,用户反馈):①**拖柄几何对齐原生**——弃"短柄+圆点"旧造型,改为**一根与首/末行选区等高的竖线**(沿选区左/右边缘)+ **圆点紧贴竖线外端**(起点在上端、终点在下端,均位于选区外);全部数字收进 `HandleMetrics`(圆点 14 / 线宽 2.5 / 交叠 2 / 伸出 12 / 热区 ≥44),绘制、摆放、菜单避让**共用**;②**编辑菜单避让拖柄**——`targetRectFor` 返回「拖柄包络矩形」(选区并集 ±「圆点伸出距离+menuHandleGap 8pt」),菜单无论在上在下都不遮圆点;锚点加方向决策(上放不下→改锚终点柄下方)+ `preferredArrowDirection`(.down/.up);滚动/缩放/旋转后 `updateVisibleMenuPosition` 同步;**③诊断新增 `menu: sel/env/dir/anchor` 一行**
42. ✅ 已处理(2026-10-13/14,v0.7.0):①**小柄加粗 + 选区收进**——线宽 2.5→4pt;蓝选区水平收进「线宽/2−1」(与柄内缘衔接,**柄即选区边缘**);②**M3-A 生词本 + 永久加亮**——GRDB v3 迁移(`vocab_word`/`vocab_occurrence`/`vocab_highlight`;词条键=归一化词元 went→go;语境按(doc,page,context)去重;加亮按 docSha+页坐标矩形 JSON 存);新增 `Sources/Vocab/VocabStore.swift`;词卡新增生词本栏(加入生词本 / 已收录·N 处语境 / 已掌握 / 重新收录);永久加亮重开渲染(协调器 perm 层 + 点击命中开卡,点已加亮词优先于菜单切换);已收录词再次选中**自动追加语境、不重复建卡**;设置新增「**选中即自动收录并永久加亮**」(默认关,已掌握词不自动复活);阅读页 📖「生词本」列表(`VocabListView`,M3-B 再加分组/标签/筛选);⚠️ 语境暂存"选中文本"(原句提取待 M5 前补)
43. ✅ 已处理(2026-10-14,v0.8.0,用户反馈批):①**蓝选区加大**(±1.5/±2);②**拖柄固定尺寸 32pt**(圆点14+竖线20,与缩放无关);③**胶囊 × 关闭**;④**整窗触摸判定收敛为窗口形状**(contentShape 顶闸,形状外不拦截) + 胶囊态缩放手柄命中区 22pt;⑤**生词本上主页**(全部)/文档内(仅本文档);⑥**出处标注 + 一键抵达 + 橙色临时高亮(2.5s)+ 预览不记忆阅读位置**(suppressSave);⑦点生词弹**胶囊式预览**;⑧生词**可删**(左滑);⑨**高亮自选颜色(蓝/橙/绿/粉)+ 取消高亮**;⑩**M3-B 分组**(GRDB v4:vocab_group/vocab_word_group;词卡分组勾选、列表筛选/新建/重命名/删除)。⚠️ 标签(一种词的"雅思/论文"标记)并入分组语义暂缺;跨页批量移动待下轮
44. ✅ 已处理(2026-10-15,v0.8.1,用户指定拖柄几何):①**竖线 = 首/末行选区高**(自适应缩放;v0.8.0 固定 32pt 线长作废);②**圆点定尺寸**(14pt)紧贴竖线外端、位于选区外(起点上端/终点下端,交叠 2pt 消缝);③**两端同一几何函数**(lineFrame/dotFrame 按 isStart 镜像);线宽 4pt/圆点 14pt/交叠 2pt/热区 ≥44 全部为 HandleMetrics 常量(方便调);④**拖动热区 ≥44×44 以"圆点+竖线"整体为中心**(point(inside:) 扩边);⑤**与"按住选区本体拖动"不冲突**——长按 .began 先过 `handleHitTest`,命中拖柄热区即让位(不启动本体拖动/新选词);⑥浅色深色页面均可见(实心 systemBlue,沿用 v0.6.8;不加白描边)
45. ✅ 已处理(2026-10-15,v0.8.2,原句提取+M3-B 批量操作):①**语境 = 整句原句**——新增 `SentenceExtractor`(纯点坐标 `selectionForLine(at:)`,规避 iOS 18 字符索引回归):以选区首/末行为锚,向下补齐覆盖再扩到句末标点、向上并入未收句的行(段落大间隙断段),行末连字符去连字;`collectWord` 与自动追加两条路径统一走 `sentenceContextOrSelection`(失败回退选中文本→词面);②生词本**点「N 处语境」**查看全部原句(新→旧 + 出处,可一键跳转橙色高亮;新增 `VocabStore.occurrences(forLemma:)`);③**多选批量移动分组 / 批量删除**(编辑模式 + 底部操作条;编辑态行内按钮自动让位)
46. ✅ 已处理(2026-10-15,v0.8.3,拖柄-高亮对齐根因修复):①**根因** = 两份矩形口径——高亮渲染用扩边矩形(`insetBy(−padX/−padY)`),而 `rects` 写回(第 692 行)与拖柄摆放用未扩边矩形,竖线中线恒落在原始边缘、与高亮边缘差 selectionPadX(页面pt,缩放放大后≈3–4.5 屏幕pt);②**修复** = `HandleMetrics.displayRect(_:)` 成为**唯一扩边口径**:updateHighlight 注解 bounds 与 `rects` 写回同源(refreshHandles 竖线中线=显示矩形边缘,Δ=0 构造性成立);生词本存储 rects 同为显示矩形,渲染/跳转**直接使用不再二次扩边**(旧数据 ≤v0.8.2 收录的高亮渲染会略收 1.5/2pt,不可感知);拖柄拖动对侧锚点经 `lineRect(fromDisplay:)` 逆运算保持贴原始文字边缘;③**常驻自检**:每次选区变化后诊断日志记一行 `handles: Δstart/Δend`(柄中线 vs 高亮边缘,目标 ≤0.5pt)
47. ✅ 已处理(2026-10-15,v0.9.0,**M4 第一步:Pencil 标记模式**):①**按页画布叠加**——`PencilOverlayProvider`(PDFPageOverlayViewProvider,iOS 16+)每页叠一个透明容器 + `PKCanvasView`(`drawingPolicy=.pencilOnly`),画布尺寸=该页 PDF 尺寸,不改动原 PDF;②**双模式**(工具栏铅笔按钮 ⇄ **Pencil Pro 挤压**切换,`@AppStorage("readerMarkMode")` 持久):**选词模式**容器 hitTest 一律 nil(手指+Pencil 全穿透,选区管线原样);**标记模式**容器只接 `touch.type == .pencil`(手指仍滚动/缩放/长按选词;Pencil 专属选区手势`pencilPress`/双击三击的 pencil 触型同步停用);③**系统工具面板** `PKToolPicker()`(自持实例,`shared(for:)` 已废弃)标记模式下对画布 show 且 `becomeFirstResponder`;④**持久化** GRDB **v5.pencilInk**(`pencil_ink(docSha,page,data,updatedAt)`,PK[docSha,page])+ `PencilInkStore`;停笔 0.8s 防抖落盘,翻页/收尾 flush;⑤`suppressNativeSelection` 遍历**跳过画布子树**;诊断日志新增 `pencil: overlay/marking/saved` 与画布尺寸行(真机核对缩放变换用)。⚠️ 待真机验证:画布随缩放的变换方式、工具面板与挤压行为并存、笔迹跨缩放对齐;悬停预览/触觉/动作映射设置项留 M4-B
48. ✅ 已处理(2026-10-15,v0.10.0,重构批:**Bug 1.1/1.2/1.3 + 生词本 Task 2.1–2.4**):**【Bug 1.1】小白条**——命中区改 **44×44 实心方块**(钉右下角,废弃"形状∩弧线"裁剪)+ `highPriorityGesture` 拦截;缩放/移动全部改 **"起手基准 + 总位移(translation)"** 计算(严禁逐帧增量 → 不瞬移);胶囊右侧留白 26→52(× 不与热区重叠)。**【Bug 1.2】Pencil 标记不能画**——根因:内层滚动视图 pan 抢 Pencil 触摸;修复:标记模式把 `scroll pan.allowedTouchTypes` 收紧为仅手指(退出还原原触型,滚动完整恢复);配合画布 becomeFirstResponder。**【Bug 1.3】挤压**——**撤销自装 UIPencilInteraction**(它顶掉了系统行为),挤压/轻点两下交还 `PKToolPicker` 原生接管(环形工具面板)。**【Task 2.1】**「加入生词本 / 高亮(4 色)/ 取消高亮」移入**编辑栏子菜单**「生词本」(`SelectionMenu` + 协调器 `menuWord/currentSelectionVocabState` 等);高亮隐含收录。**【Task 2.2】**词卡去掉收录/高亮/已掌握交互(只读状态);生词本行 = 单词+**翻译预览**+**发音**+**跳转**;点行 → **详情页**(词卡内容 + 备注 + 分组 + 跳转至原文);长按 → 菜单(发音/备注/移动分组/跳转/删除);**【Task 2.3】分组** = 文件夹拖动条(点=筛选,`dropDestination` 拖拽移动分组 / 拖到「未分组」移出;长按分组=重命名/删除)+ 行 `draggable`;**【已掌握概念整体移除】**(Status 枚举/字段/UI 全删,`vocab_word.status` 列保留存量数据不再读写;GRDB **v6.vocabNote** 加 `note` 列)
49. ✅ 已处理(2026-10-16,v0.11.0,**M4-B + M5 + M6 一次交付**):**M4-B**:①**悬停预览**(`UIHoverGestureRecognizer`,选词模式 + 设置开关门控)——悬停词 → 淡黄词框预览注解 + **0.5s 后迷你释义气泡**(音标 + 释义首行,`HoverTipView`,不拦截触摸),移开即清;②**触觉**(`PencilHaptics` = `UICanvasFeedbackGenerator`,17.5+):选词完成(拖选/双击/三击/拖柄结束)与加入生词本成功各一次(仅 Pencil Pro/触控板有硬件感);③设置页新「Pencil」组(悬停/触觉开关)。**M5 Anki 导出**:`Sources/Anki/{AnkiExporter,AnkiAudio,AnkiExportSheet}.swift`——**genanki 同款 Legacy 格式**(collection.anki2 schema 11 + media JSON + 编号媒体;col.models/decks/dconf/conf 全量 JSON;字段 8 枚:单词/音标/中英释义/例句/出处/备注/音频;`[sound:]` 正面自动播放);**稳定 GUID** = `pv_<词元>`(重复导出导入=更新)+ FNV-1a 稳定 deckId/noteId(不用 hashValue 随机种子);音频 = `AVSpeechSynthesizer.write` → **离线合成 WAV**(按词元缓存 Application Support/anki-audio,6s 兜底防挂);导出面板(VocabListView 左上角 ⬆️):牌组名(持久)/音频开关/进度显示/分享面板;CSV/TSV 兜底。**M6 扫描版 OCR**:`Sources/OCR/{OCRService,OCRStore}.swift` + GRDB **v7.ocr**(`ocr_word` 词框 + `ocr_status`)——打开文档采样判扫描版(前 4 页多无文字层)→ 后台整本识别(`page.thumbnail` 2.5x → `VNRecognizeTextRequest .accurate` + 正则切词 → **`VNRecognizedText.boundingBox(for:)` 词级框**(accurate 模式即词级,已核实)→ top-left 归一化入库;进度胶囊;每文档一次);协调器 **OCR 取词全链路**:长按起手(文字层失败自动兜底)→ **词粒度拖动扩选**(跨行并集)→ 双击选词 → 复用既有高亮/拖柄/菜单/编辑栏(抽出 `applyHighlightDesired` 共用)→ 语境 = 整行词拼接 → 加入生词本/高亮/点词开卡与文字层一致。**调试坑(本轮)**:成员初始化器参数顺序必须与属性声明顺序一致(新参数插错位置 = 编译错,已修);注释里 `1)/2)/3)` 列表会让朴素括号配对检查误报。⚠️ 待真机验证:悬停气泡时机与位置、触觉手感(需 Pencil Pro)、OCR 识别质量/坐标对齐(尤其页面旋转的扫描件)、Anki 导入实测(音频播放/更新去重)
50. ✅ 已处理(2026-10-16,v0.12.0,**M7 主体一批**):①**夜间模式**(`@AppStorage("readerNightMode")`,阅读页 ⋯ 菜单 Toggle;`reader(for:)` 上 0.52 黑罩层 + 动画,不拦截触摸);②**目录 + 书签**(`ReaderOutlineSheet` + `BookmarkStore` + GRDB **v8.bookmark**(PK[docSha,page]);PDFOutline 后台压平 ≤2000 条(destination 与 PDFActionGoTo 双路取页,`destination.page` 是可选需绑定)、书签增删/滑动删除/跳转);③**全文搜索**(`ReaderSearchSheet`:450ms 防抖 `findString`(caseInsensitive+diacriticInsensitive)逐条结果带 `selectionsByLine` 矩形(≤200 条);**扫描版回退 `OCRStore.searchLines`**(LIKE 命中词框 → 按行聚合 → 行矩形跳转闪显));④**词频分析·批量收录**(`VocabAnalyzeSheet`:全文字符统计(≤2M 字符)→ 正则分词 → top4000 词 ECDICT 富化 → 词频/考试标签 chips/柯林斯星级/排除牛津核心词 筛选 → 勾选批量 `collectHeadword`(新 API:只建卡无位置));⑤**数据备份/恢复**(`BackupService` + 设置页「数据」区:**导出** = `VACUUM INTO` 快照(writeWithoutTransaction!VACUUM 不能跑事务里)+ manifest → zip 分享;**恢复** = 校验 SQLite 魔数 → `AppDatabase.replaceDatabase` **热替换**(关旧队列→换文件→新队列→迁移,`dbQueue` 改 var 后各 Store 自动用新队列)+ `yuewenDataDidRestore` 通知文档库刷新;设置页醒目提醒"删除 App 会丢数据");⑥**批注版 PDF 导出**(`AnnotatedPDFExporter`:逐页 2x 栅格 + 高亮矩形(页坐标左下→图片左上换算)+ PKDrawing.image 烧录 → UIGraphicsPDFRenderer 新 PDF;**原文件不动;输出为图片化页面(丢文字层)**);⑦阅读页工具栏新增 🔍 与 ⋯ 菜单(夜间/目录/词频/批注导出)。**坑**:`PDFDestination.page` 为可选(goTo 分支需 `let` 绑定,CI 首红即此);`UIGraphicsImageRendererFormat.scale=1` 才能像素对像素合成。⚠️ 待真机验证:夜间罩层观感、目录跳转、扫描版搜索、批量收录性能、备份往返恢复、批注版 PDF 在各端查看效果
51. ✅ 已处理(2026-10-16,v0.13.0,**M7 收官批**):①**整句卡翻译**(onTranslate 经 FloatingCardWindow→WordCardPanel→SentenceCardView 透传,卡片内「翻译」按钮直开系统翻译面板);②**P0 已收录词自动加亮**(设置「已收录词自动加亮(打开页面时扫描)」默认关;`autoHighlightCurrentPage` 按页扫描一次/会话:页文本正则分词∩`allLemmas()`(5s 缓存)→ `page.selection(for: NSRange)` 取行矩形(**圆整 0.01pt** 保 JSON 一致去重)→ `addHighlight` 去重入库;`pageDidChange`/`documentDidLoad` 接入);③**再选中补亮**(`vocabDidSelectWord` 已收录分支 → 新位置 addHighlight + 主线程 reload);④**义项勾选**(GRDB **v9.vocab_sense**(只存被排除项);`CardVocabBridge` 加 `excludedSenses`/`setSense` 闭包;词卡已收录时逐行 checkbox,取消义项在卡片与导出中过滤;`AnkiExportSheet.filteredTranslation` 同步);⑤**Anki 增强**:基础模型升 9 字段(+截图)+ 双模板(ord0/ord1 反向卡);**挖空卡** = 独立 Cloze 模型 `跃文挖空`(type=1,{{c1::词}} 正则替换,guid `pvc_` 前缀);**页面截图** = `AnkiExporter.pageScreenshot`(cropBox 页坐标→像素换算,并集+边距裁剪 PNG)经 `NoteMedia` 统一入 media 编号;note/card ID 改 `nextId` 游标(nowMs*100)防冲突;⑥**StarDict 导入**(`StarDictImporter`:多选/zip;**手写 gzip 头跳过**(FEXTRA/FNAME/FCOMMENT/FHCRC)→ Compression raw-deflate **流式解压** `.dict.dz`;.idx 大端 offset/size 解析;逐条读释义(HTML→text、行首类型字节启发式剥离、`[..]` 音标提取)批量入库 `userdict.sqlite`(dict/form/meta 表,原子替换);`DictionaryStore` 双队列**用户词典优先命中** + reload/移除;设置页「词典」区);⑦多窗口此前已开启(`UIApplicationSupportsMultipleScenes`)。**坑**:新文件别忘 `import SwiftUI`(picker 的 Context/Representable 在 SwiftUI);`try? fileHandle.read(upToCount:)` 在非抛错重载上会双层可选——写 `let x = try? ...` 再 `guard let x`;CI 首红两处一次修净。⚠️ 待真机验证:自动加亮扫描性能与位置准确度、挖空卡/反向卡/截图在 Anki 端表现、StarDict 导入(朗道/牛津等实测)、.dz 解压正确性
52. ✅ 已处理(2026-10-16,v0.13.1,**紧急修复:标记模式 Pencil 书写失效**):真机复盘——Pencil 在标记模式下仍触发滚动/无反应。根因:①旧修复(v0.10.0)只改「第一个」滚动视图的 pan 触型(`findScrollView` 取首个),PDFView 内部另有手势可抢 Pencil;②PDFView 在文档加载/翻页时**重建内部手势层级**,一次性设置被顶掉,而 `setMarkMode` 有 `guard markMode != on` 早退、加载后无重臂;③画布命中只查 `allTouches.first`,屏上有手指时把 Pencil 误判为穿透。**修复(三层)**:①`PencilTouchIsolation.targetGestures(in:)` 遍历 PDFView 整棵子树收集全部 pan/pinch/longPress/tap/swipe(**跳过页叠层画布子树**,绝不碰 PKCanvasView 绘制手势);②`PencilScrollGuard` 动态 delegate——逐触摸 `shouldReceive`:标记模式+Pencil → false;其余转发原 delegate(`ShouldBegin`/`ShouldRecognizeSimultaneously` 一并转发保真);每个手势**账本存原始 delegate/触型**,pan 双保险收紧 `allowedTouchTypes=[.direct]`;③**幂等重臂**:`setMarkMode` 冗余调用也重臂(SwiftUI 每次 updateUIView 天然触发)+ `documentDidLoad` / `documentDidChange`(+0.5s 后再臂)/ `pageDidChange` 全接;退出标记模式逐条还原。另:画布 `hitTest` 改「含任一 Pencil 触摸即接管」。⚠️ 待真机:标记模式下 Pencil 立即出墨、绝不滚页;退出后 Pencil/手指均恢复滚动;双指捏合两模式正常
53. ✅ 已处理(2026-10-16,v0.13.2,**紧急修复:标记模式闪退**):v0.13.1 引入回归——一点击/切换到标记模式立即闪退(v0.13.0 同路径不崩)。**根因**:v0.13.1 给 PDFView 子树内所有手势(UIScrollView 的 pan、PDFKit 私有识别器)**替换 delegate**;系统内部手势的 delegate 是 UIKit 私有对象,内部机制对其有超出公开协议的假定,换成自定义对象后内部代码向"假定的私有类型"发消息 → EXC_BAD_ACCESS / unrecognized selector(CI 只编译、无法暴露真机私有契约问题,所以 CI 绿而真机崩)。**修复**:①**彻底移除 delegate 替换**(删除 `PencilScrollGuard` 类与相关代码,严禁再换系统手势 delegate);②改用两个**公开安全属性**达到同等隔离——`scroll.panGestureRecognizer.allowedTouchTypes = [.direct]`(禁 Pencil 滚动)+ `scroll.delaysContentTouches = false`(画布立即收笔,不被滚动判定吞起手);③收集**全部** UIScrollView(不只第一个)、跳过页叠层画布子树;④`pan.state == .possible` 才动(正在跟踪的手势跳过,下轮重臂补);⑤保留:幂等重臂(冗余 setMarkMode / documentDidLoad / documentDidChange+0.5s / pageDidChange)与画布 hitTest「含任一 Pencil 触摸即接管」;⑥关键点加 `DiagLog` + NSLog(`[yuewen/pencil]` 前缀,真机 Console 可逐步定位)。**教训**:唯一碰系统内部手势的允许操作 = 公开属性;替换 delegate 必崩,永不重试。
54. ✅ 已处理(2026-10-16,v0.13.3,**紧急修复:标记模式仍无法书写**):v0.13.2 闪退修复后,真机 Pencil 仍写不出字。**定位**:画布接管判定中唯一"看运气"的环节 = `hitTest` 依赖 `event.allTouches` 能否看到 Pencil——命中判定的时机不可靠(首次 hitTest 时触摸列表可能缺失/不含笔),一旦漏判 Pencil 就落空 =「画不出字」。**修复(三重加固,全公开 API)**:①**命中无条件接管**——标记模式下 `InkOverlayView.hitTest` 一律返回画布(`super.hitTest`),不再按触摸类型过滤;手指滚动/缩放/长按选词全部由**祖先手势机制**(pan/pinch 挂在滚动视图、长按挂在 pdfView)与 `drawingPolicy=.pencilOnly` 保证,不依赖命中目标,照常工作;②画布初始化显式 `canvas.tool = PKInkingTool(.pen, black, 2.5)`(不依赖工具面板同步状态)+ `canvas.drawingGestureRecognizer.allowedTouchTypes = [.pencil]`(绘制手势只收笔,公开属性第二道闸);③**可见性兜底**:叠层创建后 0.15s `bringSubviewToFront`,进入标记模式时再补一次(防"墨画了但被页内容盖住");④激活顺序改为先 `becomeFirstResponder` 再 `toolPicker.setVisible`;⑤**真机诊断埋点**:`hitTest` 日志(触摸类型+命中结果,1s 节流)、`canvasViewDidBeginUsingTool/EndUsingTool`(无 BEGIN = 触摸未达画布;有 BEGIN 无墨 = 可见性问题)、`activate` 日志(尺寸/父视图)。⚠️ 真机判读:有 tool begin+出墨=好;有 begin 无墨=可见性;无 begin=触摸链,回报日志。
55. ✅ 已处理(2026-10-16,v0.13.4,**修复:Anki 包被拒收 missing field `id`**):真机实测导入 Anki/AnkiMobile 报 `500: JsonError { info: "decoding deck config: missing field \`id\`" }`。**根因**:Anki 新后端(2.1.50+ Rust+serde)解码牌组配置(dconf)时 id/name 为必填,我们的包中 dconf 条目缺 `"id"`。**修复**:①dconf 补 `"id": 1`(并对照 genanki 0.13.1 基准包逐键核对,补 `new.separate`);②decks 补 `lrnToday/revToday/newToday/timeToday` 数组;③新增 **`AnkiExporter.validateCollectionJSON`** 导出前自检(dconf/decks/models 必填口径,缺则抛错,不再产坏包)。**核对方法**:本机 `uv venv` + `uv pip install genanki` 生成基准 apkg → 读 `collection.anki2` 的 col JSON 与我们的 Swift 输出对拍(全部字段核对通过)。⚠️ 待真机:重新导出导入 Anki(桌面/AnkiMobile)应正常。
56. ✅ 已处理(2026-10-17,v0.14.0,**Paper Modern UI 重构 + 手写体验**):依据《Notability 16.13 逆向学习 Skill》提炼的设计方法(语义 token / 纸感叠层 / 浮动工具 / 渐进披露 / 克制动效)重构界面与手写交互(不复制其任何专有资产)。①**设计系统** `Sources/App/DesignSystem.swift`:语义色 background1–4 / foreground1–4 / accent / accentContainer / onAccent / secondary / success·caution·alert·incorrect + 内容色(ink/coral/sage/sky/terracotta);间距阶梯(2–48);圆角 sharp/regular/comfy;语义字号;`dsCard()` 纸感卡片;`DS.uiBackground1` 供 UIKit。②**手写工具会话** `PencilToolSession`:钢笔/铅笔/荧光笔/橡皮 + 墨色 6 色/荧光 5 色 + 笔宽三档(按工具分档),UserDefaults 持久;`makeTool()` → PKInkingTool/PKEraserTool。③**浮动工具带** `PencilPaletteView`:标记模式左下浮动胶囊(四工具 + 墨色点 + 笔宽三线 + 撤销/重做),点墨色展开调色盘,可拖动(@AppStorage 记忆),弹簧短动画,≥36pt 热区 + accessibilityLabel。④**画布接线**:PencilOverlayProvider 移除系统 PKToolPicker,新增 `currentTool/setTool/undo/redo`(活跃画布 = `canvasViewDidBeginUsingTool` 回调);协调器 `applyToolSession/undoInk/redoInk`,进入标记模式即套用;SwiftUI onChange(工具/颜色/笔宽)即时同步全部页画布;新页画布用当前笔具创建。⑤**Pencil 系统手势**:装回 `UIPencilInteraction`(无工具面板后无冲突)——挤压 = 切换标记/选词模式,轻点两下 = 橡皮 ⇄ 上一支笔。⑥**纸感表面**:PDFView `pageShadowsEnabled=true` + 暖纸背景;导航栏 `toolbarBackground` 暖色;分页胶囊改用 background4。⑦**文档库重构**:List → ScrollView + LazyVStack 纸感卡片(图标瓦片 accentContainer + 标题 headline + 副文 caption + chevron),暖纸背景,自绘空状态(96pt 图标瓦片 + 主按钮),导入浮层纸卡化。**坑**:ForEach 枚举元组不能 `{ index, color in }`(SE-0110)→ `{ pair in pair.offset/pair.element }`;v0.10「挤压交给系统」的前提是 PKToolPicker 在——换自绘工具带后必须自己接管 UIPencilInteraction。⚠️ 待真机:工具带手感/拖动、荧光笔叠色、双击/挤压映射、深色模式纸感、页面阴影观感。
