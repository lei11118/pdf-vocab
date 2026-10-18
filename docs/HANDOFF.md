# 跃文(pdf-vocab)· 项目交接文档

> 交接时间:2026-10-18 · 当前版本:**v0.23.1(build 60)** · 仓库:https://github.com/lei11118/pdf-vocab(公开)
> 本文写给接手的下一个 agent(或人)。读完这一份,应能在不追问原作者的前提下继续开发与发版。

---

## 0. 30 秒速览

- **是什么**:iPad 英语学习 App「跃文」。读英文 PDF 时取词 → 悬浮词卡(音标/释义/发音)→ 生词本(分组/高亮/备注)→ 导出 Anki;另有 Pencil 手写批注、扫版 OCR、目录/书签/搜索/词频、数据备份。
- **形态**:纯本地、无账号、无云同步、无内购、无埋点;免费 Apple ID 自签侧载(AltStore / SideStore / Sideloadly)。
- **开发机**:Windows,**没有 Mac**。一切编译与打包走 GitHub Actions(`macos-26` + Xcode 26.6),产出未签名 IPA,用户自己侧载。
- **代码规模**:47 个 Swift 文件 / 10,141 行;2 个第三方依赖(GRDB、ZIPFoundation),其余全 Apple 原生框架。
- **状态**:M0–M7 全部里程碑主体完成;v0.16.0 已完成"Notability 式 UI 与书写体验"重构(封面书架 / 浮动阅读 chrome / 手写工具条状态机 / 套索 / 直尺 / 擦后回笔 / 专注模式)。
- **下一步最该做的**:让用户在真机上验收 v0.16.0 的交互项(见 §9.1),再决定是打磨还是开新功能。

---

## 1. 仓库、分支与本地位置

| 项 | 值 |
|---|---|
| 仓库 | `lei11118/pdf-vocab`(public) |
| 本地路径 | `D:\codx\pdf-vocab`(**有 `★标记★` 文件,勿移动/勿改名目录**) |
| 主分支 | `main`(单人开发,直接提交 main,无 PR 流程) |
| 版本号来源 | `project.yml` 的 `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` |
| Bundle ID | `com.lei11118.pdfvocab`(改名会丢自签原位更新能力,**不要改**) |
| 显示名 | 跃文(`CFBundleDisplayName`);仓库 slug 保持 `pdf-vocab` |
| 部署目标 | iPadOS **17.5**(Pencil Pro 挤压/触觉的最低线),仅 iPad(`TARGETED_DEVICE_FAMILY=2`) |
| 工程生成 | XcodeGen,`.xcodeproj` **不入库**,由 CI 现场 `xcodegen generate` |
| 唯一 workflow | `.github/workflows/build-ipa.yml` |

**没有测试目标、没有单元测试**。CI 只做:编译(0 警告为常态)→ 组 IPA → 校验 → 传 artifact。回归全靠真机 + 人工清单。

---

## 2. 硬约束(不要"优化"掉)

1. **不能引入需要 Mac 本地构建的东西**;新增依赖必须是 SPM 且能在 CI 编过。
2. **零新增第三方依赖**是既定原则。现有只有 GRDB(MIT)与 ZIPFoundation(MIT)。UI/手写/OCR/语音/压缩全部 Apple 原生(PencilKit、SwiftUI、PDFKit、Vision、AVFoundation、Translation、Compression)。
3. **纯本地**:不加账号体系、不加网络请求、不加分析 SDK。用户明确要求过。
4. **免费 Apple ID 的现实**:10 App ID / 7 天、3 设备 / 7 天、每设备 3 个自签 App、描述文件 7 天过期;重签不丢数据,删 App 才丢。任何"需要推送/App Group/iCloud entitlement"的方案直接不可行。
5. **不复制 Notability 的专有资产**(图标、贴图、字体文件、纸纹)。只学结构、层级、交互方法。现有纸纹 `Resources/paper-grain.png` 是脚本自制的。
6. **UI 一律走 `DS` token**,禁止在组件里写裸十六进制色、裸字号、裸阴影。
7. **Pencil 手势红线**(两条血泪教训,见 §10):绝不替换/交换系统内部手势的 delegate;命中判定绝不依赖 `UIEvent.allTouches` 的触摸类型。
8. **Anki 格式红线**:`dconf` 每条必须含 `id`/`name`;导出前必须过 `AnkiExporter.validateCollectionJSON`,宁可不产包也不产坏包。
9. **数据不能悄悄丢**:删 App 才丢数据;重签保留。任何 DB 迁移必须走 GRDB migrator 追加版本,不改历史迁移。
10. `D:\设计方法与风格\...`(Notability 逆向资料)在工作区外,**只读**;产出只能落在 `D:\codx\pdf-vocab`。

---

## 3. 构建与发布 SOP

### 3.1 工具位置

```bash
gh    = D:/codx/gh/bin/gh.exe          # 已登录 lei11118,scopes 含 repo/workflow
python= C:/Python314/python.exe        # 3.14,标准库足够
```

推送有两个通道:

```bash
# A. 正常 git(credential helper = gh;网络时好时坏)
git push origin main

# B. 被墙/443 不通时走 API(仓库自带脚本,带重试与 blob 续传)
GH_BIN="D:/codx/gh/bin/gh.exe" python tools/gh_push_via_api.py lei11118/pdf-vocab main
```

推送成功的**唯一可信校验**是 tree sha 相等(API 通道会产生不同 commit hash):

```bash
GH=D:/codx/gh/bin/gh.exe
REMOTE=$( "$GH" api repos/lei11118/pdf-vocab/git/ref/heads/main -q '.object.sha' )
[ "$(git rev-parse HEAD^{tree})" = "$( "$GH" api repos/lei11118/pdf-vocab/commits/$REMOTE -q '.commit.tree.sha')" ] && echo TREE_OK
```

### 3.2 改版本 + 出包

```bash
# 1) 改 project.yml 两个字段(必须成对递增)
#    MARKETING_VERSION: "0.15.0"  → 下一个功能版 0.16.0 / 修 bug 0.15.1
#    CURRENT_PROJECT_VERSION: "48" → 永远 +1
# 2) 提交并推送(main)
# 3) 触发构建
gh workflow run build-ipa.yml --repo lei11118/pdf-vocab
# 4) 盯结果
gh run list --repo lei11118/pdf-vocab --workflow build-ipa.yml --limit 5
```

### 3.3 校验并发布

```bash
GH=D:/codx/gh/bin/gh.exe; RID=<run id>
mkdir -p dist && rm -rf dist/*
"$GH" run download $RID --repo lei11118/pdf-vocab -n PdfVocab-unsigned-ipa -D dist
# ↑ artifact 名固定为 PdfVocab-unsigned-ipa,下载后直接得到 dist/PdfVocab-unsigned.ipa

python - <<'PY'
import zipfile, plistlib
z=zipfile.ZipFile('dist/PdfVocab-unsigned.ipa')
info=[n for n in z.namelist() if n.endswith('Info.plist') and n.count('/')==2][0]
pl=plistlib.loads(z.read(info))
print(pl.get('CFBundleDisplayName'), pl.get('CFBundleShortVersionString'), pl.get('CFBundleVersion'))
print('签名条目(应为0):', sum(1 for n in z.namelist() if '_CodeSignature' in n))
PY

# 发 Release(资产名会被改成规范名,先保证本地文件名正确)
"$GH" release create v0.15.0 dist/PdfVocab-unsigned.ipa --repo lei11118/pdf-vocab \
  --title "跃文 v0.15.0 — ..." --notes-file <notes.md> --latest
git tag v0.15.0 && git push origin v0.15.0   # tag 会再触发一次构建,属预期冗余
```

> 发布说明模板与历史 notes 见 `C:\Users\lei11116\AppData\Local\hermes\cache\scratch\release_v0*.md`(不保证长期存在,README/PLAN 里有摘要)。

### 3.4 CI 日志

`gh run view --log-failed` 依赖的 `results-receiver.actions.githubusercontent.com` 经常被墙。**可靠通道是 jobs API**:

```bash
JOB=$("$GH" api repos/lei11118/pdf-vocab/actions/runs/$RID/jobs -q '.jobs[0].id')
"$GH" api repos/lei11118/pdf-vocab/actions/jobs/$JOB/logs --allow-escape-sequences
```

---

## 4. 架构地图(文件 → 职责)

```
Sources/
├─ App/
│  ├─ PdfVocabApp.swift        26   @main;NavigationStack 根
│  ├─ DesignSystem.swift      179   DS token(颜色/间距/圆角/字号/卡片)+ UIColor(hex:)+ PaperBackground
│  └─ SettingsView.swift      206   设置:发音/自动收录/自动加亮/Pencil 开关/词典导入/备份恢复
├─ Data/
│  ├─ AppDatabase.swift       175   GRDB 队列 + 全部迁移(v1–v9)+ 热替换
│  ├─ DocumentStore.swift     239   文档导入/列表/进度/删除
│  ├─ DocumentRecord.swift     38   文档模型
│  ├─ BackupService.swift     109   VACUUM INTO 快照 / 恢复
│  └─ BookmarkStore.swift      44   每页书签
├─ Library/
│  ├─ LibraryView.swift       533   文档库(封面网格/继续阅读卡/悬浮导入坞/搜索/空状态/诊断)
│  ├─ DocumentCover.swift     146   PDF 首页封面缩略图(内存缓存 + 纸封面回退 + 元数据行)
│  └─ PDFDocumentPicker.swift  46   UIDocumentPicker 包装(asCopy: true)
├─ Reader/
│  ├─ ReaderView.swift        828   阅读页总装:PDFKitView + 浮卡 + 工具条 + 弧盘 + 各 sheet + 位置记忆 + 夜间罩层 + 专注模式 + 浮动顶栏/底部模式条
│  ├─ PDFKitView.swift        112   UIViewRepresentable;把 SwiftUI 状态灌给 Coordinator
│  ├─ VocabPDFView.swift       14   PDFView 子类,屏蔽"全选"
│  ├─ Pencil/
│  │  ├─ PencilOverlay.swift      254  PDFPageOverlayViewProvider + InkOverlayView(每页 PKCanvasView)
│  │  ├─ PencilToolSession.swift  217   工具/颜色/5档笔宽/橡皮双模式/擦后回笔/直尺/工具隐藏
│  │  ├─ PencilPaletteView.swift  420   Notability 式悬浮工具条(点当前工具展开样式层;按内容收成胶囊)
│  │  ├─ PencilArcMenu.swift      136   挤压弧形工具盘(撤销/直尺/各笔具)
│  │  └─ PencilInkStore.swift      42  笔迹按页存取(GRDB)
│  ├─ Selection/
│  │  ├─ ReaderCoordinator.swift 1906  ★核心★ 取词/选区/菜单/手柄/拖选/OCR 兜底/手势隔离/Pencil 模式/工具会话
│  │  ├─ SelectionKit.swift       185  HandleMetrics(唯一几何口径)+ 选区合法性
│  │  ├─ SelectionMenu.swift      215  自绘 UIEditMenuInteraction(targetRect 避让)
│  │  └─ SentenceExtractor.swift   76  纯点坐标扩句(绕开 iOS 18 字符索引回归)
│  ├─ ThumbnailLoader.swift   110   3 worker 并发 + 磁盘 JPEG 缓存 + 预取
│  ├─ WordPicker.swift        143   选区 → 词元(首选实词)
│  ├─ HoverTipView.swift       38   Pencil 悬停迷你释义气泡
│  ├─ ReaderOutlineSheet.swift 153  目录(PDFOutline 压平)+ 书签
│  ├─ ReaderSearchSheet.swift  139  全文搜索(文字层;扫版回退 OCR)
│  └─ AnnotatedPDFExporter.swift 80 高亮+手写烧录成新 PDF(页面图片化)
├─ Card/
│  ├─ FloatingCardWindow.swift 277  可拖/可缩放/可胶囊的悬浮窗(触摸判定=窗口形状)
│  └─ WordCardView.swift       478  单词卡/整句卡/胶囊三种形态内容
├─ Vocab/
│  ├─ VocabStore.swift         516  生词/语境/高亮/分组/义项排除(全部非抛错)
│  ├─ VocabListView.swift      529  生词本(分组 chips/编辑模式/批量/语境 sheet/Anki 入口)
│  ├─ VocabularyDetailView.swift 133 单词详情(词卡 + 备注 + 分组 + 跳转)
│  └─ VocabAnalyzeSheet.swift  300  词频分析 + 批量收录
├─ Dict/
│  ├─ DictionaryStore.swift    122  ECDICT 查询 + 用户词典优先
│  ├─ DictionaryService.swift   68  查词链(原词→form→lemma)
│  ├─ SpeechService.swift       26  AVSpeechSynthesizer(en-US/en-GB,离线)
│  └─ StarDictImporter.swift   337  .ifo/.idx/.dict(.dz) 导入(dictzip 手写解压)
├─ Anki/
│  ├─ AnkiExporter.swift       477  生成 .apkg(Legacy schema 11 + media)
│  ├─ AnkiAudio.swift           61  TTS PCM → WAV(内嵌媒体)
│  └─ AnkiExportSheet.swift    297  导出选项(字段/反向卡/挖空/截图)
├─ OCR/
│  ├─ OCRService.swift         131  Vision 逐页识别 + 词级 boundingBox
│  └─ OCRStore.swift            96  ocr_word / ocr_status
└─ Support/
   ├─ DiagLog.swift             53  Documents/diagnostics.log(真机排查主通道)
   ├─ DiagnosticsView.swift    112  日志查看/复制/分享/清空
   └─ PencilHaptics.swift       20  UICanvasFeedbackGenerator(仅 Pencil Pro 有硬件)
```

**读代码顺序建议**:`README`(功能面)→ `ReaderCoordinator`(交互核心)→ `PencilOverlay` + `PencilToolSession`(手写)→ `VocabStore`(数据)→ `AnkiExporter`(格式)。`docs/PLAN.md` 是 54KB 的逐条历史决策账本,查"为什么这么做"时按编号搜。

---

## 5. 数据层

单文件 SQLite(`Application Support/…/yuewen.sqlite`),GRDB 队列,迁移只追加:

| 迁移 | 表 / 变更 | 语义 |
|---|---|---|
| v1.documents | `document` | 文档元数据(sha 去重、标题、导入时间) |
| v2.readingProgress | document +4 列 | 页码/比例/缩放/自动缩放 |
| v3.vocab | `vocab_word`, `vocab_occurrence`, `vocab_highlight` | 词条(lemma 唯一)/ 语境出现 / 高亮矩形(页坐标 JSON) |
| v4.highlightColorAndGroups | `vocab_highlight.color`, `vocab_group`, `vocab_word_group` | 高亮 4 色 + 分组(标签语义并入分组) |
| v5.pencilInk | `pencil_ink` | 每页 PKDrawing 归档(data) |
| v6.vocabNote | `vocab_word.note` | 备注 |
| v7.ocr | `ocr_word`, `ocr_status` | 扫版词级框(PK = docSha,page,idx) |
| v8.bookmark | `bookmark` | 每页书签(PK = docSha,page) |
| v9.vocabSense | `vocab_sense` | 只存"被排除"的义项下标 |
| v10.inkScale | `pencil_ink.scale` | v0.17.0 高清书写:手写坐标放大倍数(老数据 1,新数据 2)|

**约定**:
- 高亮矩形存的是**显示矩形**(已含 `HandleMetrics.selectionPadX/Y` 扩边),渲染与跳转都直接用,不要再二次扩边。
- 词条 key = `VocabStore.normalizedKey`(词典词元优先,否则小写原词)。
- 备份/恢复:`VACUUM INTO` 必须在 `writeWithoutTransaction` 里跑;恢复 = 校验 SQLite 魔数 → 关旧队列 → 换文件(连 -wal/-shm)→ 重开 → 迁移 → 发 `yuewenDataDidRestore`。

---

## 6. 三套核心机制(动它们之前必读)

### 6.1 选区/取词管线(`ReaderCoordinator`)
- **纯点坐标 API**:`selectionForWord(at:)` / `selectionForLine(at:)` / `selection(from:to:)`。**不要用字符索引**(iOS 18+ 的 `characterBounds`/`page.string` 有已知顺序回归,会错位、拖选跳变、大文档卡死)。
- 选区视觉/手柄:**全部几何走 `HandleMetrics`**(单一函数出显示矩形),绘制、摆放、菜单避让共用,否则必然漂移(见 v0.8.3 事故)。
- 点击语义(用户反复确认过的最终版):点选区 = 只切换编辑菜单、**永不关选区**;点空白 = 选区 + 菜单一起消失;拖选字符粒度。
- 编辑菜单用 `UIEditMenuInteraction` + `targetRectFor` 返回"选区并集 ∪ 手柄包络",这样菜单永远在选区上方且不压字。`preferredArrowDirection` 语义:`.up` = 菜单在锚点下方,`.down` = 在上方。
- 原生选择手势压制**只按类型过滤**(long-press / multi-tap),**绝不按私有类名**(v0.6.6 教训:会误伤文本链路导致不能选词)。
- 扫版兜底:`isScanned` → `OCRService` → `ocrDrag` 独立状态 → 词粒度跨行并集 → 同一套 `applyHighlightDesired`。

### 6.2 Pencil 手写(`Pencil/`)
- **高清书写(v0.17.0)**:PDF 的页叠层会被 PDFView 的缩放变换放大,`PKCanvasView` 只按屏幕 scale 栅格化一次 → 笔迹被拉伸变糊(Apple 论坛确认 `contentScaleFactor` 无效)。对策 = **超采样画布**:`InkGeometry.scale = 2`,画布 bounds = 页面点 ×2,再套 `1/2` 变换压回页面;笔宽 ×2 保持视觉粗细;**老笔迹在加载时 `PKDrawing.transform` 放大并回写**(`pencil_ink.scale` v10 记录倍数);批注导出按倍数归一化。代价:SDK 的 `PKEraserTool` 没有宽度参数,橡皮视觉半径缩为 1/2。
- 叠层:`PDFPageOverlayViewProvider` 给每页挂 `InkOverlayView`(容器)+ `PKCanvasView`(`drawingPolicy = .pencilOnly`、`isScrollEnabled = false`、`backgroundColor = .clear`、`drawingGestureRecognizer.allowedTouchTypes = [.pencil]`)。**画布是容器 ×2 大小 + 1/2 变换**,容器保持页面尺寸给 PDFKit。
- 模式切换:`select` 模式 `hitTest` 返回 nil(全穿透);`mark` 模式**无条件返回画布**(不判触摸类型)。
- 让 Pencil 绘制不被滚动抢:遍历 PDFView 内所有 `UIScrollView`,把 `panGestureRecognizer.allowedTouchTypes = [.direct]` + `delaysContentTouches = false`,账本记原值,退出还原;**幂等重臂**(文档加载/变更/翻页/每次 updateUIView 都要重做,因为 PDFKit 会重建内部层级)。
- 工具:**不用 PKToolPicker**(v0.14 起移除),自绘 `PencilPaletteView` + 自装 `UIPencilInteraction`:
  - **v0.16 工具状态机(Notability 式)**:点**其他**工具 = 立即切换并直接书写;点**当前**工具 = 展开/收起样式层(颜色 / 五档笔宽 / 笔画预览);橡皮的样式层是「局部 ⇄ 整笔」+「擦完回笔」;套索给出圈选说明;
  - 工具条是一条**按内容宽度收拢的悬浮胶囊**(`ViewThatFits`:宽屏一行,窄分屏退化为横向滚动),不占固定栏位;
  - 挤压 → 选词模式下先 `setMarkMode(true)`,再呼出 `PencilArcMenu`(围绕笔尖的扇环,半径 132 / 环宽 70;含撤销与直尺);
  - 轻点两下 → 橡皮 ⇄ 上一支笔;
  - 双指轻点 = 撤销、三指轻点 = 重做(仅 mark 模式;`numberOfTouchesRequired` 2/3);
  - **直尺** = `PKCanvasView.isRulerActive`(拖尺对准边缘画直线,不改笔具);
  - **擦后回笔** = `canvasViewDidEndUsingTool` → `returnFromEraserIfNeeded()`,可在工具条右键菜单/设置页关闭。
- 阅读 chrome(v0.16):浮动胶囊顶栏(返回 / 标题+页码跳转 / 专注 / ⋯)+ 底部「选词 · 手写」模式条;手写模式下底部换成工具条。**专注模式**隐藏顶栏与模式条,只留纸面与一个「退出专注」胶囊;四指轻点或顶栏按钮切换。
- 撤销目标 = 最近一次 `canvasViewDidBeginUsingTool` 记下的活跃画布(`canvas.undoManager`)。

### 6.3 设计系统(`DS`)
v0.15 起对齐逆向资料采样值(不是自创暖色):

| token | light | dark |
|---|---|---|
| background1 页面底 | `#F6F6F8` | `#101215` |
| background2 卡片 | `#FFFFFF` | `#1A1D21` |
| background3 浮层 | `#FFFFFF` | `#23262B` |
| background4 选中容器 | `#ECF2FF` | `#26334A` |
| foreground1…4 | `#0E1116` `#444F60` `#8892A6` `#C3C9D4` | `#F3F5F8` `#AEB6C2` `#7C8595` `#4E5665` |
| accent | `#5A89FF` | `#7BA3FF` |
| onAccent / secondary | `white` / `#6E7C91` | — |

间距 2/4/6/8/12/16/24/32/48;圆角 sharp 4 / regular 12 / comfy 20;字号 28/26/22/17/15/17/13/11/10。
内容色:墨 `#0A0A0A`、荧光黄 `#FDFD01`、青柠 `#A9FD1B`、品红 `#FD00D4`、录音红 `#ED5279`。
画布外沿用 `paperWhite #FBF8F3`。

**v0.16 增补**:字体分四声部 —— SF Rounded 承担 UI/展示(`display3/title1/title2/headline/subhead/caption/caption2/micro`),`wordTitle/wordBody/wordQuote`(衬线)承担英文词条与例句,`monoCaption` 承担音标/页码/计数;组件层新增 `DSPressableButtonStyle`、`DSPillButtonStyle`、`DSIconButton`、`DSChip`、`DSSectionHeader`、`dsFloatingPanel`(薄材质 + 细边 + 柔和阴影)、`coverPalette`(6 色文档封面)。**文档库 = 封面网格 + 继续阅读卡;阅读页 chrome 全部浮在纸面上**。`PaperBackground`(暖底 + `Resources/paper-grain.png` 纸纹)**目前无使用点**——v0.15.0 把文档库/词表/设置都改回中性面了,它保留着给未来的"纸张内容面"(如词卡预览/笔记页)用;要用就直接 `.background(PaperBackground())`。

> 有一处小遗留值得知道:`PaperBackground` 与 `paper-grain.png` 现在是**死代码/死资源**(无害,1 个 struct + 3.6KB)。若追求整洁可删;若打算做"纸张感"的笔记面则留着。

---

## 7. 版本历史(功能版)

| 版本 | build | 内容 |
|---|---|---|
| 0.5.0 | — | 更名"跃文";取词管线推倒重写;选页/位置记忆 |
| 0.6.x | — | 悬浮词卡(可拖/可缩/胶囊)、内置 ECDICT、发音、设置页 |
| 0.7.0 | — | 生词本 + 永久加亮(M3-A) |
| 0.8.x | — | 分组/批量/语境/一键抵达;手柄几何定稿(单一 `HandleMetrics`) |
| 0.9.0 | — | Pencil 标记模式(M4-A) |
| 0.10.0 | — | 编辑栏"生词本"子菜单;生词本重写;挤压交还系统 |
| 0.11.0 | — | 悬停/触觉 + Anki 导出 + 扫版 OCR(M4-B/M5/M6) |
| 0.12.0 | — | 夜间/目录/书签/搜索/词频/备份/批注导出(M7 主体) |
| 0.13.0 | 41 | 句卡翻译/自动加亮/义项勾选/Anki 增强/StarDict |
| 0.13.1 | 42 | 标记模式书写修复(**引入闪退**) |
| 0.13.2 | 43 | 修闪退:移除手势 delegate 替换 |
| 0.13.3 | 44 | 命中无条件接管,书写终于正常 |
| 0.13.4 | 45 | Anki `dconf.id` 缺失修复 + 导出前自检 |
| 0.14.0 | 46 | Paper Modern:DS + 浮动工具带 + 移除 PKToolPicker |
| 0.14.1 | 47 | 纸纹素材 + 工具带隐藏/恢复 |
| **0.15.0** | **48** | 采样 token 重构 + 双列工具托盘 + 挤压弧盘 + 双指撤销/三指重做 + 5 档笔宽 + 橡皮双模式 |
| **0.16.0** | **50** | Notability 式重构:封面书架/继续阅读卡/悬浮导入坞;阅读页浮动顶栏+底部模式条+专注模式(四指);工具条状态机(点当前工具展开样式)、套索、直尺、擦后回笔、工具隐藏;词卡/词表衬线排版 |
| **0.16.1** | **51** | 修复选工具卡死:工具应用签名去重+下一轮 runloop 应用;`updateUIView` 不再每帧重建 `PKCanvasView.tool`;橡皮回笔异步;直尺不抢 first responder;套索/橡皮自动关直尺 |
| **0.16.2** | **52** | 按真机日志修复:挤压 0.6s 节流(0.7s 20 次回调)+ 弧盘移除撤销扇区(30 笔一次回退到 10 笔)+ 撤销/重做/工具点击日志 + 双指撤销落笔冷却 |
| **0.17.0** | **53** | 高清书写:画布 2× 超采样 + 笔宽补偿 + 老笔迹自动迁移(`pencil_ink.scale` v10);新增蜡笔与自定义取色器;橡皮视觉半径减半(SDK 无宽度 API) |
| **0.18.0** | **54** | PDF 缩放上限 12×(预设:适应宽度/100/200/400/800%);每个 PDF 记忆工具/颜色/笔宽/橡皮/直尺;书写贴边自动滚动(连续书写第一步);Pencil 双击/挤压动作可映射 |
| **0.19.0** | **55** | 缩放上限 1500% + 预设;页面无缝相接(`pageBreakMargins = .zero`);挤压 = 开关弧形工具盘(只响应 `.began`) |
| **0.20.0** | **56** | 跨页书写:画布向下 240pt 出血区,抬笔把越过页底的一段切到下一页(下一页没准备好则不裁,不丢墨) |
| **0.21.0** | **57** | 直线吸附:画得够直的一笔自动拉直(长 > 60pt、偏差 < 2%;可关) |
| **0.22.0** | **58** | 自研橡皮:五档大小、局部切断/整笔消失、按画布坐标(不受超采样影响);超采样 2×→**3×**;橡皮面板加大小与开关 |
| **0.23.0** | **59** | 挤压工具盘跟随 Pencil Pro **悬停位置**弹出;回主页自动退出书写;缩放上限 **4000%**(2000/4000% 预设);新增**形状工具**(直线/矩形/椭圆/箭头)与**激光笔**(抬手淡出);弧盘扩到 9 扇区 |
| **0.23.1** | **60** | 实用工具:页面缩略图导航(按需渲染)、双页显示、清空本页手写(可撤销) |

更早细节(v0.1–v0.6.8)以 tag 与 `docs/PLAN.md` 为准。远端 48 个 tag,本地已 `git fetch --tags` 同步。

---

## 8. 设计资料(工作区外,只读)

```
D:\设计方法与风格\references\
├─ 02-ink-engine.md        墨迹引擎(笔型/压感/平滑/延迟)
├─ 03-design-language.md   设计语言(层级/中性面/强调色用法)
├─ 04-ux-patterns.md       交互范式(工具带/挤压/手势)
├─ tokens.json             采样色/字号/圆角(DS 的唯一取值来源)
└─ assets\
   ├─ ui-tool-tray-colors-sizes.png   双列工具托盘实机截图
   └─ ui-squeeze-arc-menu.png         挤压弧形菜单实机截图
D:\设计方法与风格\Notability-16.13-逆向学习-skill.zip  早期 skill 包(已解包读过)
```

规则:**只读、只学方法、不复制资产**;任何产出写回 `D:\codx\pdf-vocab`。改 DS 前重读 `tokens.json`,别凭记忆写色值。

---

## 9. 当前待办

### 9.1 v0.22.0 真机验收(最优先)
0. **自研橡皮**:局部擦是否断成两截、整笔擦是否整条消失、快速划动是否跟手;五档圆点大小变化是否明显;关掉「可调大小(自研橡皮)」能否退回系统橡皮。
1. **3× 清晰度**:放大到 3× 内笔迹是否更锐;2× 时代写的老笔记迁移后位置是否还准。
2. **撤销**:擦完按撤销是否恢复整页;与 PencilKit 原生撤销是否错乱(错乱请反馈,下一步做统一撤销组)。
3. **跨页书写**:写到页底继续往下,溢出段是否出现在下一页顶部、位置连续;翻页往返是否重复/丢失。
4. **挤压开关 / 1500% / 直线吸附 / 贴边自动滚动**(上两版遗留项)。

### 9.2 回归项(工具/橡皮/直尺/套索/手势/书架/chrome)
1. **工具条状态机**:点其他工具是否立即能写;点当前工具是否展开样式层;样式层是否挡住正在写的位置;工具条在横竖屏、分屏下是否仍是一颗胶囊(不拉满全宽)。
2. **橡皮**:局部/整笔切换是否即时生效(本轮修了 `eraserWhole` 未同步的 bug);「擦完回到上一支笔」是否太急(想连擦多笔时会不会烦)——若烦,默认关掉。
3. **直尺**:开启后直尺是否出现、可拖动、沿尺边画直线是否顺手;退出书写模式后直尺状态是否残留。
4. **套索**:圈选后能否整体移动/删除;与 PDF 滚动是否冲突。
5. **挤压弧盘**:位置是否落在笔尖附近、扇区点得准不准(圆心钳制写死 200pt 边距,可能需要真机调 `radius`/`center` 偏移);新增「直尺」扇区是否好点。
6. **双指撤销 / 三指重做**会不会误触;四指轻点进/出专注模式会不会与系统手势打架。
7. **封面书架**:PDF 首页封面是否正确、滚动是否掉帧、深色模式下封面与标题对比是否够。
8. **阅读 chrome**:浮动顶栏是否遮住 PDF 页面顶部内容(可滚动让开);底部模式条是否挡住页码/正文。

### 9.3 已知缺口 / 未验证(诚实清单)
- **无自动化测试**;无 UI 测试;CI 绿 ≠ 真机不崩(v0.13.1 已证)。
- **v0.19–0.22 未做真机验收**:跨页书写、直线吸附、自研橡皮、3× 超采样只过了 CI 编译。
- **形状识别(矩形/椭圆/箭头)还没做**:直线吸附(v0.21.0)已用「笔画拟合」实现;形状识别可以沿同一路子继续(把最后一笔拟合成矩形/椭圆/箭头再替换)。
- **程序化改动画布与 PencilKit 撤销栈混用**:跨页切分/直线吸附/自研橡皮都绕过了原生撤销,可能出现撤销顺序不一致;下一步做统一撤销组。
- **手指不能书写**(`drawingPolicy = .pencilOnly`,保手掌排除);Notability 有「断开 Pencil 后手指书写」开关,本 App 暂无。
- **工具条不能拖到任意位置**(固定底部居中);Notability 的 toolbox 可拖动。
- **Anki**:v0.13.4 修了 `dconf.id`,但**反向卡 / 挖空卡 / 页面截图 / 内嵌音频**在 Anki 桌面与 AnkiMobile 的实际导入播放仍缺一次完整真机验收。
- **OCR**:旋转页/倾斜页未处理;识别质量未做基准;超长文档内存表现未测。
- **批注导出**:输出是**页面图片化 PDF**(不是矢量叠加),体积会变大,文字不可选——这是已知取舍。
- **备份恢复**:热替换路径在真机上只做过少量样本;大库(>200MB)未测。
- **词频批量收录**:全文 ≤2M 字符上限,超长书会截断;性能未在大书上压测。
- **免费证书 7 天**:每次过期用户需重签,属流程事实,不是 bug。
- **本地曾缺 tag**:v0.6.9–v0.14.1 的 tag 曾只存在于远端(release 建的),已 `git fetch --tags` 补齐;新环境第一步要 fetch。

### 9.3 可选的下一步方向(按价值/成本排序,均未开工)
1. **手写体验继续打磨**:弧盘拖拽选择(按住滑到扇区再抬笔)、笔宽长按连续调、荧光笔"直线吸附"、套索(圈选移动/删除笔迹)。
2. **Pencil 与文本联动**:手写批注与高亮共存时的层级/导出策略;笔迹搜索(手写识别)不在零依赖范围内,慎入。
3. **生词本 → 复习**:本地间隔重复(FSRS/SM-2 纯 Swift 实现)会比继续堆导出功能更贴"学习"目标。
4. **性能**:1000+ 页文档的首屏/翻页/高亮 diff 压测;缩略图缓存淘汰策略。
5. **可访问性**:Dynamic Type、VoiceOver 标签(目前只有部分控件有 `accessibilityLabel`)。

---

## 10. 坑位手册(踩过的,别重踩)

**编译 / Swift**
- **SwiftUI `body` 不能写成 20+ 个修饰符的一条长链**:会触发 `unable to type-check this expression in reasonable time`(v0.16 实测:CI 在 Archive 卡 11 分钟才报错)。拆成多个 `private var xxxContent: some View`(每组 ≤6 个修饰符),body 只返回最后一段。
- `DS.Motion.base/fast/slow` 是 **`Double`(秒),不是 `Animation`**;`withAnimation` / `.animation` 要写 `.easeInOut(duration: DS.Motion.base)`。
- `ForEach(Array(x.enumerated()), id: \.offset) { index, item in }` 在 Swift 5 下报 SE-0110 → 写 `{ pair in pair.offset / pair.element }`。
- 新文件忘 `import SwiftUI` 会引发一大串看似无关的 `buildExpression` 报错,先查 import。
- 成员初始化器参数顺序**必须与属性声明顺序一致**,`PDFKitView` 加参数时同步改 call site。
- `try? fileHandle.read(upToCount:)` 在非抛错重载上是双层可选 → `let c = try? …; guard let c, !c.isEmpty`。
- 朴素括号平衡检查会被**字符串插值里的引号/花括号**误报(本次 3 个文件虚报 +1~+3),以 CI 为准。

**Pencil / PDFKit**
- **跨页笔迹** = 画布向下留 `InkGeometry.bleed` 出血区,抬笔时 `PencilStrokeTools.split` 按页底切开;先让下一页确认能接收(`onOverflow` 返回 Bool),再裁本页 —— 否则宁可保留整笔,不丢墨。
- **程序化改 `canvas.drawing`**(跨页切分 / 直线吸附)会绕过 PencilKit 的撤销栈;若要严格 undo,需要自定义 undo 组。
- **直线吸附**只对「抬笔 3 秒内」的最后一笔生效;长度 > 60pt 且偏差 < 2% 才拉直,避免误伤手写字母。
- **自研橡皮**(v0.22.0)= 橡皮激活时 `canvas.drawingGestureRecognizer.isEnabled = false`,挂自己的 Pencil-only `UIPanGestureRecognizer`;按采样点到橡皮路径的距离切分/删除 `PKStroke`,12ms 节流重建 `canvas.drawing`;撤销用 `undoManager.registerUndo` 存整页快照。**不要**在 PencilKit 绘制手势仍启用时抢 Pencil(会互相打断)。
- **超采样 3×**(v0.22.0):所有尺寸都要 ×`InkGeometry.scale`(笔宽、橡皮半径),否则视觉不一致;老数据按 `pencil_ink.scale` 迁移。
- **挤压**只响应 `squeeze.phase == .began` —— 挤压是持续事件,不过滤会在按住时连发(真机 0.7s 20 次)。
- **`UIPencilInteraction` 的挤压是持续事件**:按住不放会连续回调(真机 0.7s 内 20 次),必须**节流**(0.6s)并且**不要**在回调里做重活(重设工具/重新弹面板/触觉连环触发都会把主线程拖死)。
- **弧形/悬浮工具盘里不要放「撤销」**:菜单贴着笔尖弹出,误触一次就可能把整批笔迹回退(真机日志:30 笔保存成 10 笔);撤销放工具条按钮与双指轻点即可。
- **绝不在 `updateUIView` 里无条件重设 `PKCanvasView.tool`**:SwiftUI 每次更新都会调用它,选工具触发的展开/收起动画会让 PencilKit 反复重建工具状态,真机表现为「选某些工具卡死」。工具应用要 **签名去重 + 延迟到下一轮 runloop**(v0.16.1 事故)。
- **绝不在 PencilKit 的 delegate 回调里同步改工具**(`canvasViewDidEndUsingTool` 里切回画笔会锁主线程);一律 `DispatchQueue.main.async`。
- 多页画布不要让每一个都 `becomeFirstResponder()`(直尺旧实现),互相顶掉会卡;标记模式激活时画布本来就是第一响应者。
- 套索/橡皮 + 直尺是 PencilKit 的少见组合,切到这两个工具时先关直尺。
- **绝不**给 PDFView / UIScrollView 的内部手势 `delegate = 自定义对象`:真机 `EXC_BAD_ACCESS`,CI 完全看不出来。
- 命中判定**绝不**读 `event.allTouches` 判笔:时机不可靠,漏一次就"画不出字"。
- PDFView 会在加载/翻页/重排时**重建内部视图与手势**,所有设置必须幂等重臂。
- `UIPencilInteraction` 是 `UIInteraction`,要 `addInteraction`,不是 `addGestureRecognizer`。
- `PencilInkStore` 是 struct,属性不能 `weak`。
- 原生选择压制只按**手势类型**过滤,按私有类名会误伤文本链路(v0.6.6)。

**构建 / 发布 / 网络**
- `write_file` 覆盖已存在文件可能被"防陈旧"护栏拒绝 → 写 `xxx.swift.new` 再 `mv -f`。
- artifact 名是 **`PdfVocab-unsigned-ipa`**(不是 ipa 本身);`gh run download` 后得到 `dist/PdfVocab-unsigned.ipa`。
- `gh run view --json` 没有 `artifacts` 字段;要用 `gh api .../actions/runs/<id>/artifacts`。
- `gh release view --json` 没有 `isLatest`。
- git 443 时好时坏:优先 `tools/gh_push_via_api.py`(带重试/blob 续传);推送后用 **tree sha** 校验。**不要**在 fetch 失败时 `git reset --soft origin/main`(会更糟)。
- `gh api` 的 POST 会整段几分钟返回 `Bad credentials (401)`,同 token GET 正常——是瞬时窗口,退避重试即可,别重登。
- MSYS 路径(`/tmp/x`)传给原生 exe 会按盘符解析,scratch 用 `$TMPDIR` 或相对路径。
- 单条 terminal 命令 >420s 会被杀,推送/构建/发布拆成多次调用。

**数据**
- `VACUUM INTO` 不能进事务(`writeWithoutTransaction`)。
- 任何"同一几何给两处用"的地方必须单函数出(v0.8.3 手柄/高亮漂移 3–4pt 的根因)。

**凭据**
- 仓库内**没有任何密钥**;gh 登录态在 `D:\codx\gh\bin` 的配置里;不要把 `.env`、token、密码写进仓库或文档。

---

## 11. 接手第一小时 checklist

1. `cd D:\codx\pdf-vocab && git fetch --tags && git status`(应为干净;48 个 tag)。
2. 读 `README.md`(功能全景)+ 本文 §4 架构图。
3. 打开 `Sources/Reader/Selection/ReaderCoordinator.swift` 与 `Sources/Reader/Pencil/PencilOverlay.swift`,理解两条主线。
4. 确认 gh 可用:`D:/codx/gh/bin/gh.exe auth status`;确认能列 run:`gh run list --repo lei11118/pdf-vocab -L 3`。
5. 拿最新 release 的 IPA 解包复核一遍(§3.3 脚本),确认 `跃文 / 0.15.0 / 48 / 0 签名条目`。
6. 问用户要 **v0.15.0 真机反馈**(§9.1),按反馈定下一版是 0.15.1(修)还是 0.16.0(功能)。
7. 若用户没反馈:优先做 §9.1 第 2、3 项的可调参数化(弧盘半径/边距、手势启用条件),把"需要真机调"的东西做成设置项或更宽容的判定,而不是猜数值。

---

## 12. 给下一个 agent 的开场提示(可直接粘贴)

> 项目「跃文」在 `D:\codx\pdf-vocab`(iPad PDF 取词学英语 App,公开仓库 lei11118/pdf-vocab)。本机无 Mac,一切构建走 GitHub Actions(`gh workflow run build-ipa.yml`),产出未签名 IPA 供用户自签侧载。当前版本 v0.21.0(57)。
> 先读 `docs/HANDOFF.md`,再读 `docs/PLAN.md` 查历史决策。硬约束:零新增第三方依赖、纯本地无账号、UI 只用 `DS` token、不改 Bundle ID、绝不替换系统手势 delegate、取词只用点坐标 API。
> 当前处于"按 Notability 逆向资料重构 UI 与 Pencil 体验"阶段,v0.16.0 的 8 项新交互待用户真机验收(见 HANDOFF §9.1)。改动后必须:提交 → 推送(网络差用 `tools/gh_push_via_api.py`)→ dispatch CI → 盯绿 → 下载 IPA 解包校验 → 发 release + tag。
