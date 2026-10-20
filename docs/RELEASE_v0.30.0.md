# v0.30.0 · 跨页书写改为「只渲染、不搬迁」 · 取消双页并排

## 这一版修什么

### 1. 跨页书写仍然断开 —— 这次把整条「切分 + 搬邻页」链路删掉

v0.29.0 补了左右出血、四边切分、按版面几何找邻页、按 origin 差位移,理论上每一步都对,
但真机上仍然会断。复核后确认**不是某一行算错,而是这条链路本身失败面太大**:

- 目标页的 `PDFPageOverlayViewProvider` 叠层可能还没创建(PDFKit 只为可见页建叠层);
- `pdfView.convert(_:from:)` 对尚未落版的页可能返回退化值,邻页就找错/找不到;
- 抬笔后 0.10s 才切分,与湿墨清除、目标页画布就绪之间有竞态;
- 页角一笔同时越两条边、两页尺寸不同、页缝有间距、缩放改变换算……
- 任何一步失败,页缝外那段墨就"消失",表现就是断笔。

本版不再修补这条链路,而是**从根上取消"归属搬迁"**:

- 墨迹**整笔留在落笔的那一页**,允许写到页面矩形之外(四周出血 `bleedX=360 / bleedTop=620 / bleed=620`);
- 新增 `PencilDryInkHost`(`PDFView` 之上的全局干墨层):每个「有页外墨迹」的页建一个**只读 `PKCanvasView`**,
  内容就是该页的 drawing,`layer.mask` 是「画布 − 页面矩形」的静态奇偶遮罩;
- 页内由 PDFKit 的原画布画,页外由镜像画布画 —— **同一个 PencilKit 渲染器、同一套 3× 超采样、同一个仿射变换**,
  所以页缝两侧是同一笔、同一种纹理,不存在"两种渲染拼起来"的接缝;
- 滚动 / 缩放 / 换排布只更新镜像画布的 `transform` 与 `position`(由 `pdfView.convert` 三个基点求出,
  含页旋转),遮罩不动,没有逐帧重建;
- 没有切分、没有搬迁、没有邻页查找,也就没有"搬失败"这种状态。

撤销/存盘回到单页语义:一笔只属于一页,一次撤销整笔(含页外部分)一起消失。

### 2. 取消双页并排

- 页面排布菜单只剩「纵向连续 / 横向连续」;
- 旧的 `readerLayoutMode = "twoUp"` 进入文档时自动回落为纵向连续(`setLayoutMode` 同样兜底);
- 所有页始终以一张连续长纸显示(`pageShadowsEnabled=false`、`displaysPageBreaks=false`、`pageBreakMargins=.zero`)。

## 具体改动

| 文件 | 改动 |
|---|---|
| `Sources/Reader/Pencil/PencilDryInkHost.swift` | **新增**。跨页干墨层:只读镜像画布、静态遮罩、页面变换、滚动/缩放刷新 |
| `Sources/Reader/Pencil/PencilOverlay.swift` | 删除 `moveOverflow / neighborIndex / overflowCandidates / appendToStore / recheckOverflow / transferOverflowIfNeeded / OverflowSide`;新增 `onDrawingChanged`(落笔/擦除/撤销/清空/吸附/形状都同步镜像);`scheduleOverflowCheck` → `schedulePostProcess`(只做直线吸附 + 出血边界诊断) |
| `Sources/Reader/Pencil/PencilStrokeTools.swift` | 删除四边切分 / 插值 / 平移,只保留 `makeStroke` |
| `Sources/Reader/Selection/ReaderCoordinator.swift` | 创建/析构干墨层;滚动、缩放、旋转、换排布时 `refresh()`;删除 `setTwoUp`,`twoUp` 回落纵向 |
| `Sources/Reader/ReaderView.swift` | 删除「双页并排」菜单项;进入文档时迁移旧布局值 |
| `Sources/Reader/AnnotatedPDFExporter.swift` | 导出批注 PDF 时,把上一页页底 / 下一页页顶的越界段补画回本页 |

## 兼容性

- 手写数据格式不变:`(docSha, page) → PKDrawing`(页面坐标 + `scale`)。旧笔记照常读取;
  旧版切到邻页的段本来就是正常笔迹,不需要迁移。
- 工具状态 v2 不变;书法仍是移除状态(旧 `"calligraphy"` 解码为钢笔)。
- 无新增依赖、无网络请求、Bundle ID 不变。

## 已知取舍

- **页外墨迹在邻页"看得见、擦不到"**:它属于落笔页,邻页上只是渲染层(非交互)。
  要擦请回到落笔页。若用户需要,后续再加"跨页橡皮"。
- **批注导出只补纵向越界**:页式 PDF 没有"左右相邻",横向布局下的左右越界不保留。
- **大书内存未压测**:每个有页外墨迹的页多一个只读 tiled canvas,离屏不占栅格,但页数多时实例数会增加。

## 真机验收

1. **竖排**:页底向下写、下一页页顶向上写 —— 书写过程中页缝外始终有墨;抬笔**不回跳**,两半严丝合缝。
2. **横排**:切「横向」,页右边缘向右写、下一页左边缘向左写 —— 同样连续。
3. **滚动 / 缩放**:写完跨页笔后,在 0.5×–4× 之间缩放、上下/左右滚动过页缝,越界那半段应贴着页面走,
   不飘、不消失。
4. **页角**:右下角同时越页底与页右写一笔 —— 页底那段出现在下一页顶部;纵向排布下页右是空白区,
   页右那段留在本页右侧属正常。
5. **撤销**:跨页一笔点一次撤销,整笔(含页外部分)一起消失;重做一起回来。
6. **双页并排已取消**:排布菜单只有纵向/横向;以前选过双页的书进入后是纵向连续。

诊断日志关键字:

- `pencil: dry mirror add page=…`(某页出现页外墨迹,镜像层创建)
- `pencil: wet begin/end`(书写中的湿墨预览)
- `pencil: stroke hit canvas edge (bleed exhausted)`(墨迹超出出血区,已被画布边界裁掉)
- `pencil: undo push …` / `pencil: undo …`
