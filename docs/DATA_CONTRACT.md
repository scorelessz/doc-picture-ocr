# 数据契约与实测经验

从旧 `BOOKS.md` 迁来。Python 实现已下线，文中的 Python 文件名只是历史出处，完整内容见 tag `python-final`。

## 数据契约（字段名固定）

每引擎页 JSON `work/<名>.{vision,rapidocr}.json`：

```json
{"source":"input/x.pdf","engine":"vision","dpi":300,
 "pages":[{"page":1,"width":2480,"height":3508,"pdf_width":595.3,"pdf_height":841.9,
           "zoom":3.4722,"rotation":0,"image":"work/<名>/pages/pg-0001.png",
           "native_text":false,
           "lines":[{"x":0,"y":0,"w":0,"h":0,"conf":0.99,"text":"…"}]}]}
```

融合 JSON `work/<名>.fused.json`：行上多出 `src`(both/vision/rapidocr)、
`alt`(另一引擎的读法)、`flag`(ok/divergent/low_conf)，顶层多出 `stats`。

**坐标约定**：像素 = **视觉**点 × zoom；视觉空间 = `page.rect`（已含 `/Rotate` 的宽高互换），
**不是 mediabox**。原点左上。

## 踩过的坑（实测，改代码前必读）

1. **`search_for()` / `get_text()` 在旋转页返回的是「未旋转」坐标**，不是显示坐标。
   拿它直接和 OCR 的显示空间 bbox 比，实测偏差 269~485 pt —— 会把**正确**的嵌字误报成全错。
   自校验必须先乘 `page.rotation_matrix`。
2. **PyMuPDF 的 `TextWriter` 在带 CropBox 的页上平移量取错轴**（库的 bug，不是调用方的）：
   它补 `page.cropbox_position`（fz 坐标、左上角），而内容流需要 CropBox 在 PDF 空间的**左下角**。
   上下留白相等时才碰巧对；留白 30/60 时纵向偏 **30.55 pt**。`book_pdf.py` 已自行修正。
3. 旋转页嵌字：`set_rotation(0)` → `write_text(matrix = Fu * derot * Fu)` → 还原。
   偏差与未旋转页完全相同（1.9pt）；不传 matrix 则偏 59~143 pt 且文字躺倒。
4. 书眉识别不能只看「跨页重复」：真章节标题的文本可能与书眉**一模一样**。
   唯一可靠信号是字号闸门「书眉绝不比正文大」（`HEAD_MAX_RATIO=1.18`）。
5. 页标记 `<!-- page N -->` 在段落边界处单独成行、在段落内部放行内：
   CommonMark 里单独成行的 HTML 注释会打断段落，把刚合并好的跨页段落又切开。
6. 同一视觉行被切成多块时，按 y 中心排序会让整行内容倒置 —— 必须先按行聚类再按 x 排。

## 已知局限（实现者主动声明的，不是猜测）

- **带劣质文字层的扫描件会被整页跳过**：`native_text` 只看字符数（默认 ≥50），
  不评估文字层质量。遇到「别处 OCR 过、但结果很烂」的 PDF，用 `--force-ocr` 强制重认。
- **磁盘峰值 = 全书页图**：先全渲染再 OCR，不是边渲边认。400 页 A4 约 0.5–1 GB，跑完才清
  （`--keep-pages` 可保留）。内存没问题，磁盘要留空间。
- **拼贴式扫描取不到原生 dpi**（一页由多张小图拼成），退回 300dpi。
- 旋转只实测了 90/270；180 走同一条 `rotation_matrix` 代码路径但未单独验证。
- 术语表 `config/glossary.txt` 是**按剧本整理**的，书籍不一定适用，`--no-glossary` 可关。
