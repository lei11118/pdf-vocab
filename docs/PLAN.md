# 读词(pdf-vocab)开发方案 · M0 时点(已确认)

## 0. 已确认的决定

| 项 | 决定 |
|---|---|
| 仓库 | `lei11118/pdf-vocab`(**公开**;公开仓库的 macOS 构建分钟全免费) |
| 最低系统 | **iPadOS 17.5**(Pencil Pro 挤压/触觉 API 的硬性要求,已核实) |
| 词库 | 默认**内置精简词库**(CI 从 ECDICT 生成,开箱离线可用);支持**单文件导入**扩展词库(选一个文件→自动完成);提供"不内置"构建开关 |
| 分发 | GitHub Actions 出**未签名 IPA** → AltStore / SideStore / Sideloadly 自签安装(免费 Apple ID) |
| App 名 | 读词(Bundle ID `com.lei11118.pdfvocab`,可改) |
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
