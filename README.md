# 跃文 · pdf-vocab

在 iPad 上读英文 PDF 时,长按/拖选(Pencil 也行)选中单词 → 加亮 → 侧边弹出词典卡牌(音标、发音、释义、例句);
单词可归入分组/标签,最终导出 Anki 卡牌组。Apple Pencil Pro 可用系统原生标记工具直接在 PDF 上批注。

- **纯本地**:无账号、无登录、无云同步、无广告、无内购、无统计埋点;数据全部存在本机
- **自签侧载**:只用免费 Apple ID(AltStore / SideStore / Sideloadly)
- **不需要 Mac**:全部通过 GitHub Actions 出包(未签名 IPA)

> 当前状态:**全部里程碑主体完成(`v0.13.0`)** —— PDF 导入、阅读、取词(**原生同款交互**:编辑栏悬于选区上方、**与拖柄保持间距**;**拖柄 = 加粗竖线(4pt 宽,线长 = 该行选区高、随缩放自适应)+ 圆点(14pt,定尺寸)贴线端、位于选区外;竖线中线骑跨高亮边缘(几何单一口径);热区 ≥44×44,与本体拖动互不冲突**;**字符粒度拖选**)、选页(**缩略图三线程并发 + 磁盘缓存**)、位置记忆;**悬浮词卡**(可拖动 / 可缩放 / **可缩成胶囊迷你**:横排单词+发音+翻译 / 胶囊⇄词卡**拖动中实时交叉过渡** / **触摸判定=窗口形状** / 位置尺寸记忆 / 点 × 或点空白关闭):单词卡 = 音标 / 美音英音发音 / 考试标签 / 柯林斯星级 / 中英释义;整句卡 = 原句 + 词块点查;**内置 ECDICT 精简词库**(离线)+ **词形还原**;发音为系统 TTS;**设置页**(⚙️):选词后自动发音、选中即自动收录;**生词本(v0.10.0 重构)**:编辑栏「生词本」子菜单 = 加入生词本 / 高亮(蓝橙绿粉)/ 取消高亮(高亮隐含收录);列表行 = 单词 + 翻译预览 + 发音 + 跳转;**拖拽单词到分组文件夹**移动分组(长按分组=重命名/删除);点行=详情(词卡+备注+分组+跳转至原文);长按=快捷菜单(备注/移动分组/发音/跳转/删除);出处一键抵达(橙色临时高亮、预览不记进度);「N 处语境」查看整句原句并跳转;**已掌握概念已移除**;**Pencil 标记**:工具栏铅笔按钮切换标记/选词模式——标记模式下 Pencil 直接书写、**挤压呼出系统原生工具面板**、轻点两下切工具(按页叠加、不改原 PDF),手写本地持久化;手指滚动/选词两模式都保留;**Pencil 悬停预览**(选词模式悬停约 0.5s 显示迷你释义气泡 + 词框预览高亮)与**触觉反馈**(选词完成 / 加入生词本,UIPencil 原生 Canvas 触觉,仅 Pencil Pro / 触控板有效);**Anki 导出**(生词本列表右上角:标准 .apkg——genanki 同款 Legacy 格式、字段 = 单词/音标/中英释义/例句/出处/备注/发音,发音为**离线 TTS 合成 WAV** 内嵌,稳定 GUID——重复导出导入自动更新;附 CSV 兜底);**扫描版 OCR**(无文字层 PDF 打开后自动 Vision 逐页识别、词级包围框入库——长按/拖选(**词粒度**)/双击取词、编辑栏「加入生词本/高亮」、整句语境(整行)全链路可用;进度显示,识别一次即缓存)。**M7 阅读增强(`v0.12.0`)**:夜间模式(阅读页 ⋯ 菜单开关)、**目录 + 书签**(PDF 内置目录全量展开跳转;每页书签增删)、**全文搜索**(文字层逐条结果 + 橙色跳转闪显;扫描版自动回退 OCR 词库按行搜索)、**词频分析 · 批量收录**(按出现次数 / 考试标签(中考·高考·四六级·考研·托福·雅思·GRE)/ 柯林斯星级筛选,排除牛津核心基础词与已收录词,勾选后一键入本)、**批注版 PDF 导出**(高亮 + Pencil 手写烧录成新 PDF,原文件不被修改)、**数据备份 / 恢复**(设置页导出整库 zip、从备份热恢复;"删除 App 会丢数据"醒目提醒)。**M7 收官(`v0.13.0`)**:整句卡「翻译」按钮(系统翻译面板,卡片内直接翻);**已收录词自动加亮**(设置开关:打开页面时扫描本页文本,命中已收录词自动补永久高亮;且已收录词再次选中即在**新位置补亮**);**义项勾选**(词卡内逐条勾选要保留的义项,卡片展示与 Anki 导出**同步过滤**——"卡片只保留需要的");**Anki 增强**(附加**反向卡**释义→单词 / **例句挖空卡**(独立 Cloze 模型)/ **页面截图**(原文高亮处裁图入卡)/ 逐字段勾选);**StarDict 词典导入**(设置页导入 .ifo/.idx/.dict(.dz) 三件套或整包 zip;支持 dictzip(.dz) 流式解压;查词优先命中用户词典,可一键移除)。**v0.13.1(紧急修复)**:标记模式 Pencil 书写失效修复(PDFView 内**全部滚动视图**的 pan 收紧为仅手指),文档加载/翻页/重绘后**幂等重臂**,画布命中判定改为「含任一 Pencil 触摸即接管」。**v0.13.2(紧急修复)**:修复 v0.13.1 引入的「切标记模式即闪退」(根因:替换系统内部手势 delegate 违反 UIKit 私有契约;已彻底移除,改为仅用公开属性 `allowedTouchTypes` + `delaysContentTouches`,并加 `[yuewen/pencil]` 日志)。**v0.13.3(紧急修复)**:标记模式书写再加固——画布命中**无条件接管**、绘制手势只收 Pencil、叠层置顶、全链路真机日志(`[yuewen/pencil]`)。**v0.13.4**:Anki 导出修复——牌组配置补必填 `id`(Anki 新后端拒收 `missing field id`)、与 genanki 输出逐键对齐、新增**导出前自检**(缺字段当场报错,不产坏包)。**v0.14.0「Paper Modern」**:依据 Notability 逆向设计方法重构 UI 与手写——语义设计系统(暖纸面/语义色/纸感卡片)、文档库卡片化、**Notability 式浮动工具带**(钢笔/铅笔/荧光笔/橡皮 + 调色盘 + 笔宽 + 撤销重做)、挤压=切模式/双击=橡皮、PDF 纸页阴影。**v0.14.1**:词卡/生词本/设置纸感化(自制纸纹素材 `paper-grain`)、工具带**长按隐藏/⋯恢复**。**v0.15.0**:依据逆向 references 重构——**采样设计语言**(中性面 #F6F6F8/白卡/强调蓝 #5A89FF/选中底 #ECF2FF)、**双列竖向工具托盘**(颜色网格 + 5 档尺寸 + 笔画预览 + 橡皮局部/整笔)、**挤压弧形工具盘**(围绕笔尖)、双指撤销/三指重做。架构与取舍见 [docs/SELECTION-PARITY.md](docs/SELECTION-PARITY.md)。
> 开发方案、核实结论与里程碑见 [docs/PLAN.md](docs/PLAN.md);**换人/换 agent 接手请先读 [docs/HANDOFF.md](docs/HANDOFF.md)**(架构地图、构建发布 SOP、硬约束、坑位手册、待办清单)。

## 获取 IPA

### 方式 A:手动触发 Actions 构建
1. 打开仓库的 **Actions** 标签页 → 选择 **build-ipa** → **Run workflow**
2. 等约 5–15 分钟,构建完成后在该次运行的 **Artifacts** 里下载 `PdfVocab-unsigned-ipa`(zip,内含 .ipa)

### 方式 B:发布版(推荐)
- **Releases** 页面直接下载 `PdfVocab-unsigned.ipa`(推送 tag 如 `v0.1.0` 时自动发布)

## 安装到 iPad(免费 Apple ID)

`.ipa` 是**未签名**的,需要用自己的 Apple ID 现场签名安装。三种方式任选:

### AltStore(推荐:同一 Wi-Fi 下自动 7 天刷新)
1. Windows 电脑安装 [AltServer](https://altstore.io)(需已装 iTunes / Apple 设备驱动)
2. AltServer 菜单栏 → Install AltStore → 选择你的 iPad,把 AltStore 装进 iPad
3. 在 **iPad 的 Safari** 打开本仓库 Release 页,下载 `.ipa` → 分享 → 用 AltStore 打开并安装
4. 首次安装后:iPad 设置 → 通用 → VPN与设备管理 → 信任你的开发者证书
5. 保持 AltServer 与 iPad 在同一 Wi-Fi,AltStore 会自动刷新(也可手动 Refresh All)

### Sideloadly(Windows 直接签名安装)
1. Windows 安装 [Sideloadly](https://sideloadly.io)(同样需要 iTunes / Apple 设备驱动)
2. 用数据线连接 iPad,把 `.ipa` 拖进 Sideloadly,填 Apple ID → Start
3. iPad 上信任证书后即可使用;7 天到期后重跑一次

### SideStore(无需常开电脑)
- 参考 [SideStore 文档](https://docs.sidestore.io) 安装 SideStore 本体(需要一次性配对文件),之后可在 iPad 上直接安装与刷新

## 免费账号限制说明

| 限制 | 值 | 对本项目的影响 |
|---|---|---|
| 描述文件有效期 | 7 天 | 到期 App 打不开;用 AltStore 自动刷新或重新签名即可,**数据不丢** |
| 每设备 App 数 | 3 个 | 一般够用;不够时 AltStore 支持"停用"其他 App |
| App ID | 10 个 / 7 天 | 本项目无 App Extension,只占 1 个 |
| 数据安全 | 删除 App = 数据丢失 | 重签/刷新不会丢;**删 App 前请先导出备份(P2 功能,规划中)** |

## 本地构建(可选,需要 Mac + Xcode)

```bash
brew install xcodegen
xcodegen generate
open PdfVocab.xcodeproj
```

CI 固定工具链(见 `docs/PLAN.md`):`macos-26` 镜像 + Xcode 26.6。

## 目录结构

```
.github/workflows/build-ipa.yml   出包流水线(archive 关签名 → Payload 打包 → Artifact/Release)
project.yml                       XcodeGen 工程定义(SPM 依赖:GRDB、ZIPFoundation)
Sources/App/                      App 入口与界面(随里程碑扩展)
Resources/                        Assets.xcassets、Info.plist(XcodeGen 生成)
docs/PLAN.md                      开发方案:核实结论 / 数据模型 / 里程碑 / 风险
```

## 技术栈与许可证

Swift + SwiftUI + PDFKit / PencilKit / Vision / NaturalLanguage / AVFoundation;
[GRDB.swift](https://github.com/groue/GRDB.swift)(MIT)、[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)(MIT)、
词库数据 [ECDICT](https://github.com/skywind3000/ECDICT)(MIT)。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
