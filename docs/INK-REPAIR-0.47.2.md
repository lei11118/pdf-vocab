# v0.47.2 / build 90 手写修复记录

针对 2026-10-31 反馈的书写失效、尺子差异、闪退和单指滚动问题。

## 已定位并修改

- `InkPencilGrabRecognizer` 和 `PencilTouchObserver` 原来仅保持 `.possible`，仍可被 PDFKit 的已识别手势阻断。现在明确覆盖双向 prevention 规则，且只收 Pencil、不取消视图触摸。
- `InkMetalCanvasView` 在笔段提交后仍可能处于 pen-down，而 draft 已清空；此时实时预览读取 `live.points[0]` 会越界。改为安全读取首点；模式关闭也结算当前笔段。
- 空顶点帧原来直接返回，无法清掉上一帧的旧墨。现在空帧也提交透明清屏；支持点按成点；黑色取值使用 `UIColor.getRed`。
- Metal 大型顶点流改用 device address space；页面几何在落笔前刷新，PDFKit 重建滚动视图后重新绑定观察者。
- PencilKit 单画布和旧页画布关闭自身的 pan/pinch，手指交给祖先 PDF 滚动视图；隔离收集器跳过 PKCanvasView 子树，不再修改其内部 pan 属性。
- 单画布归档原来在 flush 前清掉最后一段，且擦空页面不回写。现在保存末段并持久化空页。页面到画布使用显式仿射变换，绘制和页面矩形都用本地画布坐标，不再借助负 contentOffset。
- 工具 revision 去重覆盖单画布工具赋值，避免每次 SwiftUI 更新都重新设置 PencilKit 工具。
- PencilKit 路径使用 `isRulerActive` 原生尺子；Metal 路径使用自绘尺子，在落笔时锁定最近尺边，真实与预测采样均实时投影，远离尺边自由书写。支持双指移动与旋转、窗口尺寸变化和角度吸附；退出书写收起尺子。

## 验证入口

自动测试：`Tests/InkRegressionTests.swift`，GitHub Actions `test-ink`。
安装包：`build-ipa`，分支 `codex/fix-ink-input-ruler`。

验证结果：

- [iPad 模拟器回归](https://github.com/lei11118/pdf-vocab/actions/runs/41189590330)：4 项测试全部通过，0 失败，包括运行时 Metal 管线编译。
- [Release archive / IPA 构建](https://github.com/lei11118/pdf-vocab/actions/runs/41189655844)：成功；下载到 `dist/v0.47.2/PdfVocab-unsigned.ipa`。
- 构建对应代码提交 `a1ce270`。模拟器通过不代表真实 Pencil 和手指操作已验收。

模拟器无法代替真实 Pencil 输入。真机验收应分别开启、关闭设置中的自研墨迹引擎，退出并重新进入文档后检查：

1. 写字、慢画、点按成点；抬笔、滚动、重进文档后笔迹仍保留。
2. 手写模式单指滚动、双指缩放，随后继续写字。
3. 打开尺子，移动、旋转，从上下两边画线；远处写字不被拉直；退出手写尺子隐藏。
4. 反复经过页边/页缝、撤销至空白、切换阅读与手写，观察是否闪退或残留幽灵墨。
5. PencilKit 擦掉最后一笔并重进文档，页面仍为空。

自研尺子仍是自绘实现，不等同于苹果原生尺子。此轮修复不能证明所有潜在闪退都已消除，也未扩展 Metal 引擎的橡皮、套索、形状或导出功能。
