---
name: 跃文 · Research Atlas
description: 原生 iPad 阅读与词汇学习的研究图册
colors:
  hero: "#183F34"
  hero-dark: "#304D3D"
  on-hero: "rgb(98% 97% 92%)"
  accent: "#245C4A"
  accent-dark: "#A4D1B6"
  on-accent: "#FFFFFF"
  on-accent-dark: "#183B2C"
  signal: "#975334"
  signal-dark: "#E1AF8A"
  background1: "#F3F0E9"
  background1-dark: "#182420"
  background2: "#FFFDF8"
  background2-dark: "#22332D"
  background3: "#FFFDF8"
  background3-dark: "#293D35"
  background4: "#DFEAE3"
  background4-dark: "#2E4B40"
  foreground1: "#203D34"
  foreground1-dark: "#EDF3EC"
  foreground2: "#50635B"
  foreground2-dark: "#B7CBC0"
  foreground3: "#626D64"
  foreground3-dark: "#ABBEB2"
  foreground4: "#C3C9D4"
  foreground4-dark: "#4E5665"
  paper-fixed: "#FBF8F3"
  relief-dark: "#C2C4B7"
  relief-dark-dark: "#101B15"
  success: "#267148"
  success-dark: "#55C289"
  caution: "#90601D"
  caution-dark: "#E3A94D"
  alert: "#B32E49"
  alert-dark: "#FF6E8C"
  incorrect: "#C74440"
  incorrect-dark: "#E06B67"
typography:
  display3:
    fontFamily: "iOS system serif"
    fontWeight: 700
  title1:
    fontFamily: "iOS system default"
    fontWeight: 600
  title2:
    fontFamily: "iOS system default"
    fontWeight: 600
  body:
    fontFamily: "iOS system default"
  wordTitle:
    fontFamily: "iOS system serif"
    fontWeight: 700
  wordCard:
    fontFamily: "iOS system serif"
    fontWeight: 700
  wordBody:
    fontFamily: "iOS system serif"
  monoCaption:
    fontFamily: "iOS system monospaced"
    fontWeight: 600
rounded:
  sharp: "10px"
  regular: "14px"
  comfy: "20px"
  pill: "999px"
spacing:
  x4s: "2px"
  x3s: "4px"
  x2s: "6px"
  xs: "8px"
  s: "12px"
  m: "16px"
  l: "24px"
  xl: "32px"
  xxl: "48px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    rounded: "18px"
    padding: "0px 24px"
  button-secondary:
    backgroundColor: "{colors.background1}"
    textColor: "{colors.foreground1}"
    rounded: "18px"
  search-field:
    backgroundColor: "{colors.background1}"
    textColor: "{colors.foreground1}"
    rounded: "{rounded.regular}"
  chip-selected:
    backgroundColor: "{colors.background4}"
    textColor: "{colors.accent}"
    rounded: "{rounded.pill}"
    padding: "0px 12px"
    height: "30px"
  paper-card:
    backgroundColor: "{colors.background2}"
    rounded: "{rounded.comfy}"
    padding: "{spacing.m}"
---

# Design System: 跃文 · Research Atlas

## Overview

**Creative North Star: "研究图册"**

以田野研究图册的层次、纸面和留白组织真实文档与词汇。暖纸底、墨绿重点、系统衬线词条形成稳定的阅读秩序；操作区使用原生语义字体和 SF Symbols。首页继续阅读为主区，词汇与图谱提供可操作的次级入口；具体页面构图见 `docs/ui-068-direction.md`，不把单页构图强制用于所有页面。

这是 iPad 原生 SwiftUI / UIKit 系统，按代码提取并记录，不依赖网页框架、外部字体或 AI 概念图。令牌来源为 `Sources/App/DesignSystem.swift`；交互补充来源为窗口、选区、悬浮释义与图谱组件。当前应用源码 `078c07c` 的模拟器视觉证据见 `.impeccable/review/current078` 的 36 张 PNG，便携交付中对应 `UI-review/`，包含短/长悬浮译文与暗色书架。[完整 CI 41804327055](https://github.com/lei11118/pdf-vocab/actions/runs/41804327055) 通过 82 项单元/集成与 3 项 UI 测试，零失败；[专项验证 41804332164](https://github.com/lei11118/pdf-vocab/actions/runs/41804332164) 通过 1 项 UI 测试，零失败；[归档 41804338082](https://github.com/lei11118/pdf-vocab/actions/runs/41804338082) 成功。模拟器截图和 CI 不构成真实 iPad / Pencil 硬件证据；真机触控、Pencil 手感与跟手帧率仍待单独验收。

**Key Characteristics:**
- 暖纸与墨绿建立内容层级。
- 衬线学习内容与系统操作文字分工。
- 内容面安静，浮动工具保留有限深度。
- 窗口、选区与笔具可同时操作。

## Colors

明色以暖白和墨绿构成纸媒气质；暗色使用墨绿灰分层。frontmatter 中无后缀为明色，`-dark` 为相同语义的暗色值，来自 `DS.dynamic`，不代表额外的独立配色模式。

### Primary

- `hero` / `on-hero`：首页继续阅读的深绿主区和文字。
- `accent` / `on-accent`：主操作、当前工具、链接与交互重点。
- `background4`：浅绿选中容器；对应源码 `accentContainer` 与 `selectedTint` 的同值语义。

### Secondary

- `signal`：铜色辅助信号令牌；不能代替成功、警告或错误的语义色。各视图仍以实际引用为准。
- `success`、`caution`、`alert`、`incorrect`：保留现有结果与反馈语义。

### Neutral

- `background1`：页面底；`background2`：内容卡；`background3`：浮窗工具面。
- `foreground1`、`foreground2`、`foreground3`、`foreground4`：正文、次要说明、弱提示和禁用层级。禁用色不可用于正常正文。
- `paper-fixed`：PDF 阅读纸面固定为浅纸色；不得随暗色界面重映射已有笔迹颜色。
- `relief-dark`：工具面的轻投影来源。

**The Content Color Rule.** 现有笔色、高亮、封面与图谱内容颜色仍保留各自语义；全局改色不得把用户内容重新染成品牌色。frontmatter 聚焦复用界面令牌，并非穷举源码所有内容色。

## Typography

**Display Font:** iOS system serif。**Body Font:** iOS system default。**Label/Mono Font:** iOS system monospaced，仅用于元数据与页码等场景。没有自定义字体文件或网页 fallback 栈。

### Hierarchy

- `display3`、`wordTitle`：`.largeTitle`、serif、bold；分别用于展示标题与大词条。
- `title1`：`.title`、default、semibold；`title2`：`.title2`、default、semibold。
- `headline`、`subhead`、`body`、`caption`：分别对应系统 `.headline`、`.subheadline`、`.body`、`.caption`。
- `caption2`、`micro`：系统 `.caption2` 的 medium / semibold。
- `wordCard`：`.title2` serif bold；`wordBody`：`.body` serif；`wordQuote`：`.callout` serif italic；`wordMeta`：`.subheadline` serif。
- `monoCaption`：`.caption` monospaced semibold。

**The Semantic Type Rule.** 字号和行高由系统语义文本样式与 Dynamic Type 决定，不把默认字号冻结成视觉令牌。frontmatter 省略固定 `fontSize` / `lineHeight` 是有意选择。页头在阅读浮窗中降为 `title2`，正文允许多行；图标尺寸不等于正文字号。

## Layout

SwiftUI 布局使用 pt；frontmatter 的 `px` 仅为 DESIGN.md 可移植格式的一对一数值转录，不表示设备像素。间距使用 `DS.Space` 九档，主要节奏为 4pt，并包含 2pt / 6pt 细调。

全页内容上限 1100pt；容器宽度小于 600pt 时边距 16pt，否则 32pt。书架自适应网格单元宽度为 164–220pt，列间距 20pt、行间距 24pt，封面宽高比 0.72。阅读面保留文档信息、侧边功能和可移动笔具；窄笔具栏拆分工具与操作行。

工作区从容器宽度 900pt 起采用固定导航与文档主区：侧栏宽 224pt，使用 background4，与主区之间为原生分隔线。侧栏和主区分别滚动；侧栏保留全部文档、未归档、生词本、知识图谱及文件夹，不随书架滚动移出视野。主区纵向内容间距 28pt，继续阅读在前，当前文件夹标题、文档数量、添加、搜索及书架随后；搜索时隐藏继续阅读区。小于 900pt 时移除侧栏，文件夹改为书架内的横向滚动条，并显示词汇与图谱动作区。760–899pt 将继续阅读与 280pt 宽动作区并排；更窄容器依次纵向堆叠。

工作区顶栏位于顶部安全区，保留品牌与说明、日期、设置和诊断菜单。品牌为当前实现局部使用的 28pt semibold rounded 系统字，不是新增全局字号令牌；副标题使用 caption。该布局的源码规则已记录，新版横竖屏截图和真实 iPad 操作仍待本轮 CI 与硬件验收；历史 `current078` 截图不能作为此版布局已通过的证据。

图谱网格与节点共享平移及缩放原点。基础间距 32×zoom，通过倍增或减半保持可见间距 20–80pt；线宽 0.5pt，强调色透明度通常 0.10，增加对比度时 0.25。负坐标也沿同一空间坐标计算，网格不应作为交互命中层。

## Elevation & Depth

内容卡依靠面色分层，`PaperCard` 不带常驻投影。浮动工具使用 `DSReliefSurface` 的单向轻投影：`DS.reliefDark` 透明度 0.23、半径 12pt、偏移 (0, 5pt)。输入与按压表面使用次要前景色透明度 0.20 的 1pt 轮廓；增加对比度时补 0.60 透明度的 1pt 边框。源码保留 `Relief` 命名，但当前材质不再是全界面双向新拟态。

**The Quiet Surface Rule.** 内容卡保持平静，浮层才承担主要深度；不为每个嵌套图标叠加双向阴影。按压组件仍保留源码已有的局部轮廓与缩放反馈。

通用时长为 fast 0.16s、base 0.24s、slow 0.34s；spring 为 response 0.30 / dampingFraction 0.86，quickSpring 为 0.22 / 0.90。减少动态效果时取消相应空间变换与弹跳；持续缩放过程禁用装饰动画，PDF 和图谱物理更新不叠加外层弹簧。

## Shapes

共享圆角为 sharp / regular / comfy / pill，数值见 frontmatter。内容卡默认连续圆角 comfy，并限制最大圆角 20pt；一般浮面上限 22pt。按钮常用 18pt，搜索框用 regular，语义标签用真胶囊。浮窗是独立的连续形变组件：高度不超过 120pt 时圆角为半高，120–160pt 向 30pt 连续过渡；不能用固定圆角卡片替代胶囊状态。

## Components

### Buttons

主按钮使用 accent / onAccent，横向内边距 24pt，最小高度 48pt，圆角 18pt。次按钮使用页面底与主文字。通用可按压控件至少 44×44pt，按下缩放 0.975、透明度 0.9；主按钮按下缩放 0.98，relief 按钮为 0.96；禁用透明度 0.38。减少动态效果时保留状态反馈并取消缩放。SF Symbols 和已有无障碍标签跟随功能，不以装饰图取代按钮。

### Chips

`DSChip` 视觉高度 30pt、水平内边距 12pt、图文间距 6pt；选中为浅绿底与 accent，未选为内容面与次文字。可点击 chip 外层使用 `DSPressableButtonStyle`，触控区至少 44pt；不要将 30pt 标签高度误认为触控区高度。

### Cards / Containers

`PaperCard` 默认内边距 16pt，使用 background2。首页继续阅读卡使用 hero / onHero、24pt 内边距、20pt 圆角、最小高度 184pt，展示真实标题、页数和已有进度；窄于 380pt 隐去封面以保障标题空间。不能用虚构数据替换真实内容来营造版面。

### Inputs / Fields

`DSSearchField` 使用系统 body、最小高度 50pt、regular 圆角和轮廓表面；前缘 16pt，末端无清除按钮时 16pt、有按钮时 4pt。清除按钮命中区 44×44pt；焦点轮廓为 accent 透明度 0.60 的 1pt 描边。保留搜索提交语义与辅助功能标签。

### Navigation

页面继续使用原生 NavigationStack、系统菜单和既有业务入口。工作区侧栏使用最小 48pt 高的行：图文间距 10pt、水平与垂直内边距 12pt，选中行为 accent / onAccent 和 12pt 圆角；文件夹保留修改名称、图标和删除的上下文菜单。工作区使用独立的品牌顶栏；其他共享页头保留展示标题、说明和自适应动作区，底部分隔为 accent 透明度 0.22 的 1pt 线。图谱保留原生 inline 导航标题。视觉更新不能删除搜索、文件夹、设置、导出或阅读模式入口。

### Reader Windows

词卡默认 320×430pt，功能窗默认 560×600pt，均受可用空间约束并保存用户尺寸/位置。可紧凑窗口低于 140pt 高进入胶囊，最小尺寸基线为 180×64pt；最小宽度随高度在 96–220pt 区间连续由 180pt 插值至 260pt，不在 140pt 内容阈值处突变。不允许紧凑的窗口最小高度 220pt。

缩放使用持续存在的 UIKit 触摸识别器，记录从按下开始的总位移；`WindowResizeRecognizer: UIGestureRecognizer` 在独立 44×44pt 手柄内从按下立即开始，以窗口坐标记录原始触点及后续总位移，再与起始尺寸相加计算，避免 UIPanGestureRecognizer 起始移动阈值遗漏位移。拖动期间左上角固定。完整与紧凑内容同时保留身份，通过可见性和命中状态切换。窗口边缘可移动，胶囊双击展开；不能在跨阈值时更换缩放识别器。关闭区为 44pt，外部触摸继续交给阅读区域（右下缩放热区是明确保留的方形热区）。

### Selection Toolbar and Arc Palette

顶层选区编辑栏是 UIKit 非模态局部工具面，只命中自身矩形，不借用全屏系统菜单遮罩。动作在横向滚动行内保留；单动作最小 64×44pt，工具栏宽度受可见区域与 430pt 上限约束，高度随系统 subheadline 调整。复制、查询、翻译、生词、高亮、搜索与分享沿用原业务动作。显式打开子菜单或系统分享/查询时仍使用相应原生呈现。

单击不创建新的词选区；双击、长按和链接沿用各自行为。编辑栏显示期间允许移动胶囊与弧形盘。弧形盘的命中区域遵循圆弧，真实触摸超过拖动阈值后移动盘，悬浮负责延展；这些约束需在实际触控中验证。

### Hover Translation

`HoverBubbleLayout` 使用系统 subheadline / caption1 测量词条与全部释义。宽度依内容计算，通常下限 150pt、上限 380pt，并受可用屏宽限制；12pt 内边距，8pt 内容间距，16pt 圆角。高度为实际排版高度，最多 420pt 且受锚点上方空间约束；过长释义在原生 UITextView 内滚动，支持 Dynamic Type，不截断中文释义。气泡锚定单词矩形上沿，向上留 8pt；不足 36pt 高时不显示。短内容不得强行撑满长译文的最大高度。

## Do's and Don'ts

### Do:
- **Do** 从 `DesignSystem.swift` 的语义令牌生成新页面，并同时检查明暗色与 Dynamic Type。
- **Do** 保留真实书名、词条、出处、用户笔迹、图谱与所有已有业务入口。
- **Do** 用实际 SwiftUI 截图检查窄窗、长中文和选中状态，用真实 iPad 验证触控与 Pencil。
- **Do** 把代码检查、截图证据和真机验证分别记录，未验证项明确保留。

### Don't:
- **Don't** 恢复旧版双向全界面新拟态、蓝紫主色或构成主义约束。
- **Don't** 让选区编辑栏的外部遮罩阻断浮窗和弧形盘拖动。
- **Don't** 用固定字号、固定长气泡或单击自动选词破坏当前交互约定。
- **Don't** 把 sidecar 的 HTML/CSS 转译预览当作原生渲染或硬件验证证据。
