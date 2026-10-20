# v0.29.0 · 跨页书写四边贯通 · 移除书法笔

## 这一版修什么

### 1. 跨页连续书写会断开 —— 左右必断、上下仍断

v0.28.0 的跨页管道只有 **y 轴**一套:

- 画布只在**上下**留出血(620/620),左右完全没有出血。横向排布(左右翻页)时,
  笔尖一越过页左/页右就被 `PKCanvasView` 的边界裁掉 —— 这是「左右排序必断」的确定性根因。
- 切分也只按 y 阈值切,横向排布下越过左右页边的墨**从来不会被搬走**。
- 邻页按 `index ± 1` 猜。双页并排时 `index+1` 在**右边**而不是下面;横向排布时更是根本没有"下面"。
- 位移按「页高 × 超采样倍数」硬算。竖排等页高时碰巧对,页高/页宽不同、或页与页之间有间距时就错位。

本版把跨页改成**方向无关**的一条管道:

- `InkGeometry` 增加 **`bleedX = 360`**(页面点):画布左右各留出血,页面左上角落在画布
  `(bleedX×scale, bleedTop×scale)`。所有画布↔页面换算统一收口为 `canvasFromPage` / `pageFromCanvas`,
  不再各处手写 `±pageTopY()`。
- `PencilStrokeTools` 新增 `splitRight` / `splitLeft`,与 `splitBelow` / `splitAbove` 共用一套
  `splitRun`:只取**第一段连续越界点**作为溢出段,两端各插一个插值桥接点。
  笔跨出去又折回页内时,折回的那截留在本页,不会被错误搬走(旧实现取"第一个越界点之后的全部")。
- 邻页不再按下标猜,改由**版面几何**决定:取相邻 ±6 页里,页中心方向与越界边一致(轴主导向 0.6)
  且距离最近的一页。纵向连续 → 上下;横向连续 → 左右;双页并排 → 右边 `+1`、下面 `+2`。
- 位移不再用页高硬算,改为两页在 `PDFView` 视图坐标里的 **origin 差**换算
  (`(src.minX - dst.minX) × scale / scaleFactor`),页宽/页高不同、页缝有间距都对得上。
- 一笔同时越过两条边(页角)时按越界量从大到小**逐条边试**,哪条边真有邻页就走哪条;
  目标页仍越界才排队再切一次(最多 4 跳),并有"仍然越界"闸门防止两页间乒乓搬运。
- 湿墨层每次落笔前 `bringSubviewToFront` 重新置顶(PDFKit 翻页/换排布会重建层级)。
- 抬笔后湿墨延迟清除 0.18s → 0.30s,避免"跨页检查还没落位,预览先消失"的闪断。

### 2. 移除书法笔

- 删除 `PencilInkSampler.swift`(`InkSampleGestureRecognizer` / `CalligraphyInkBuilder`)、
  `PencilOverlay` 的整条书法手势/预览/提交路径、`PencilPaletteView` 的书法面板与笔锋预览、
  `PencilToolKind.calligraphy` 以及会话里的 `nibAngleIndex` / `calligraphySmoothing`。
- 兼容旧存档:`PencilToolKind` 用容错解码,旧 `"calligraphy"` 回退为**钢笔**;
  `PencilToolPrefs` 保留 `nibAngleIndex` / `smoothing` 两个键仅为解码旧 v2 blob,
  不会让整份按书工具状态失效。
- 工具带从 8 支笔变为 7 支(钢笔/铅笔/荧光笔/蜡笔/套索/形状/激光笔/橡皮中的书法被去掉)。

## 兼容性

- 手写数据格式不变:`(docSha, page) → PKDrawing`(页面坐标 + `scale`)。旧的上下出血笔记照常读取。
- **画布变宽**:左右各多 `bleedX×scale`,老笔记在页面矩形内的位置不变(换算收口到 `InkGeometry`)。
- 工具状态仍为 v2;书法字段只读不用,不迁移、不丢其它笔的记忆。
- 无新增依赖、无网络请求、Bundle ID 不变。

## 真机验收(重点)

1. **竖排**:页底向下写、下一页页顶向上写;页缝正中画横线。抬笔后两半接上,一次撤销两半同时消失。
2. **横排**:切「横向」排布,页右边缘向右写、下一页左边缘向左写;同样要求连续、可整体撤销。
3. **双页**:跨到右页(横)与跨到下排(竖)都要落位正确。
4. **页角**:在右下角同时越过页底与页右写一笔,页底那一段必须搬走。
5. **书法已移除**:工具带无书法;之前存过书法的书,工具的其它记忆(颜色/笔宽/橡皮/直尺/形状)仍在。

诊断日志关键字:

- `pencil: overflow moved page A -> B below|above|right|left dx=…`
- `pencil: overflow stored page A -> B … (overlay not ready)`
- `pencil: overflow … dropped (page N has no neighbour)`
- `pencil: page N overflow trimmed idx=… kept=… hops=…`
- `pencil: undo push … pages=[…]`
