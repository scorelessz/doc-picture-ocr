#!/usr/bin/env python3
"""
阶段 5: 生成定向校对界面 (自包含 HTML, 离线可用)

只显示两引擎的分歧处 —— 这是整套方案的价值所在:
不是逐行通读, 而是只看那 2.5% 的可疑字符。

每一条显示: 原图裁切 + 两个引擎的候选(差异高亮) + 可编辑框。
键盘: 1=选左  2=选右  Enter=确认并跳下一条  ←/→=上下条

校对结果存在浏览器 localStorage, 随时可导出 JSON 供阶段 6 合成。

用法:
  .venv/bin/python src/make_review.py work/X.crosscheck.json [--chunk 300]
"""
import base64
import html
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def crop_b64(img_path: Path, box, scale: float = 1.0) -> str:
    """裁出一行的原图, 返回 base64 PNG(内嵌进 HTML, 不依赖外部文件)。"""
    from PIL import Image
    x, y, w, h = box
    with Image.open(img_path) as im:
        x0 = max(0, int(x)); y0 = max(0, int(y))
        x1 = min(im.width, int(x + w)); y1 = min(im.height, int(y + h))
        if x1 <= x0 or y1 <= y0:
            return ""
        crop = im.crop((x0, y0, x1, y1)).convert("L")
        if scale != 1.0:
            crop = crop.resize((int(crop.width * scale), int(crop.height * scale)),
                               Image.LANCZOS)
        buf = io.BytesIO()
        crop.save(buf, format="PNG", optimize=True)
    return base64.b64encode(buf.getvalue()).decode("ascii")


def build_items(cc: dict, limit: int | None = None) -> list[dict]:
    ea, eb = cc["engines"]
    out = []
    for n, it in enumerate(cc["items"]):
        if limit and n >= limit:
            break
        img = ROOT / it["image"]
        if not img.exists():
            continue
        b64 = crop_b64(img, it["crop"])
        if not b64:
            continue
        out.append({
            "i": n, "page": it["page"], "kind": it["kind"],
            "img": b64,
            "a": it.get(ea, ""), "b": it.get(eb, ""),
            "ac": it.get(f"{ea}_conf"), "bc": it.get(f"{eb}_conf"),
            "spans": it.get("spans", []),
        })
    return out


HTML_TMPL = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OCR 定向校对</title>
<style>
 :root{--bg:#fff;--fg:#1a1a1a;--mut:#666;--line:#e3e3e3;--card:#fafafa;
       --a:#0b6bcb;--b:#0a7d4f;--warn:#b54708;--sel:#fff3cd}
 @media(prefers-color-scheme:dark){:root:not([data-theme=light]){
       --bg:#16181c;--fg:#e8e8e8;--mut:#9aa0a6;--line:#2c2f36;--card:#1d2026;
       --a:#68a8f0;--b:#4ec98d;--warn:#e8a33d;--sel:#3a3320}}
 :root[data-theme=dark]{--bg:#16181c;--fg:#e8e8e8;--mut:#9aa0a6;--line:#2c2f36;
       --card:#1d2026;--a:#68a8f0;--b:#4ec98d;--warn:#e8a33d;--sel:#3a3320}
 *{box-sizing:border-box}
 body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 -apple-system,
      "PingFang SC","Helvetica Neue",sans-serif;padding:16px}
 .wrap{max-width:900px;margin:0 auto}
 header{position:sticky;top:0;background:var(--bg);padding:10px 0 12px;
        border-bottom:1px solid var(--line);z-index:9}
 h1{font-size:17px;margin:0 0 8px}
 .bar{height:6px;background:var(--line);border-radius:3px;overflow:hidden}
 .bar>i{display:block;height:100%;background:var(--b);width:0;transition:width .2s}
 .meta{color:var(--mut);font-size:13px;margin-top:6px;display:flex;
       gap:14px;flex-wrap:wrap}
 .card{border:1px solid var(--line);border-radius:10px;padding:14px;
       margin:14px 0;background:var(--card)}
 .card.done{opacity:.5}
 .tag{font-size:12px;color:var(--mut)}
 .crop{margin:10px 0;background:#fff;border:1px solid var(--line);
       border-radius:6px;padding:6px;overflow-x:auto}
 .crop img{display:block;max-width:100%;height:auto;image-rendering:crisp-edges}
 .cands{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:10px 0}
 @media(max-width:640px){.cands{grid-template-columns:1fr}}
 .cand{border:1px solid var(--line);border-radius:8px;padding:9px 11px;
       cursor:pointer;background:var(--bg)}
 .cand:hover{border-color:var(--a)}
 .cand.pick{border-color:var(--b);box-shadow:0 0 0 2px color-mix(in srgb,var(--b) 30%,transparent)}
 .cand .who{font-size:12px;color:var(--mut);margin-bottom:4px}
 .cand .txt{font-size:16px;word-break:break-all}
 mark{background:var(--sel);color:inherit;padding:0 1px;border-radius:2px}
 input.fix{width:100%;font:16px/1.5 inherit;padding:9px 11px;border-radius:8px;
       border:1px solid var(--line);background:var(--bg);color:var(--fg)}
 .row{display:flex;gap:8px;align-items:center;margin-top:9px;flex-wrap:wrap}
 button{font:14px inherit;padding:7px 13px;border-radius:7px;cursor:pointer;
        border:1px solid var(--line);background:var(--bg);color:var(--fg)}
 button.pri{background:var(--b);border-color:var(--b);color:#fff}
 .hint{color:var(--mut);font-size:12.5px;margin-left:auto}
 kbd{font:12px ui-monospace,monospace;border:1px solid var(--line);
     border-radius:4px;padding:1px 5px;background:var(--bg)}
</style></head><body><div class="wrap">
<header>
 <h1>OCR 定向校对 <span class="tag">__TITLE__</span></h1>
 <div class="bar"><i id="pb"></i></div>
 <div class="meta">
   <span id="prog">0 / 0</span>
   <span>快捷键 <kbd>1</kbd> 选左 <kbd>2</kbd> 选右 <kbd>Enter</kbd> 确认下一条</span>
   <span style="margin-left:auto"><button onclick="dump()">导出 JSON</button></span>
 </div>
</header>
<div id="list"></div>
</div>
<script>
const DATA = __DATA__, KEY = "ocr-review-" + __KEYID__;
let fixes = {};
try { fixes = JSON.parse(localStorage.getItem(KEY) || "{}"); } catch(e) {}

function hl(s, spans, side){
  if(!spans || !spans.length) return esc(s);
  const marks = new Array(s.length).fill(false);
  for(const sp of spans){
    const p = side==="a" ? sp.a_pos : sp.b_pos;
    const t = side==="a" ? sp.a : sp.b;
    for(let k=0;k<Math.max(1,t.length);k++) if(p+k<s.length) marks[p+k]=true;
  }
  let out="",open=false;
  for(let i=0;i<s.length;i++){
    if(marks[i]&&!open){out+="<mark>";open=true}
    if(!marks[i]&&open){out+="</mark>";open=false}
    out+=esc(s[i]);
  }
  return out+(open?"</mark>":"");
}
function esc(t){return (t||"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}

function render(){
  const L=document.getElementById("list");
  L.innerHTML = DATA.map((d,n)=>{
    const done = fixes[d.i]!==undefined;
    return `<div class="card ${done?"done":""}" id="c${n}">
      <div class="tag">#${n+1} · 第 ${d.page} 页 · ${esc(d.kind)}</div>
      <div class="crop"><img src="data:image/png;base64,${d.img}" alt=""></div>
      <div class="cands">
        <div class="cand" onclick="pick(${n},'a')" id="a${n}">
          <div class="who">Vision ${d.ac!=null?"· "+d.ac:""}</div>
          <div class="txt">${hl(d.a,d.spans,"a")}</div></div>
        <div class="cand" onclick="pick(${n},'b')" id="b${n}">
          <div class="who">PP-OCRv6 ${d.bc!=null?"· "+d.bc:""}</div>
          <div class="txt">${hl(d.b,d.spans,"b")}</div></div>
      </div>
      <input class="fix" id="f${n}" value="${esc(fixes[d.i]!==undefined?fixes[d.i]:d.b)}"
             oninput="touch(${n})">
      <div class="row">
        <button class="pri" onclick="ok(${n})">确认 ✓</button>
        <button onclick="skip(${n})">跳过</button>
        <span class="hint">${done?"已确认":""}</span>
      </div></div>`;
  }).join("");
  bump();
}
function pick(n,side){
  const d=DATA[n];
  document.getElementById("f"+n).value = side==="a"?d.a:d.b;
  document.getElementById("a"+n).classList.toggle("pick",side==="a");
  document.getElementById("b"+n).classList.toggle("pick",side==="b");
}
function touch(n){}
function ok(n){
  fixes[DATA[n].i]=document.getElementById("f"+n).value;
  save(); document.getElementById("c"+n).classList.add("done"); bump();
  const nx=document.getElementById("c"+(n+1));
  if(nx){nx.scrollIntoView({behavior:"smooth",block:"center"});
         document.getElementById("f"+(n+1)).focus()}
}
function skip(n){ delete fixes[DATA[n].i]; save();
  document.getElementById("c"+n).classList.remove("done"); bump() }
function save(){ try{localStorage.setItem(KEY,JSON.stringify(fixes))}catch(e){} }
function bump(){
  const n=Object.keys(fixes).length;
  document.getElementById("prog").textContent=n+" / "+DATA.length;
  document.getElementById("pb").style.width=(100*n/Math.max(1,DATA.length))+"%";
}
function dump(){
  const blob=new Blob([JSON.stringify(fixes,null,1)],{type:"application/json"});
  const a=document.createElement("a");
  a.href=URL.createObjectURL(blob); a.download="review-fixes.json"; a.click();
}
document.addEventListener("keydown",e=>{
  const f=document.activeElement;
  if(!f||!f.classList.contains("fix")) return;
  const n=+f.id.slice(1);
  if(e.key==="Enter"){e.preventDefault();ok(n)}
  else if(e.key==="1"&&f.selectionStart===f.selectionEnd&&f.value===""){pick(n,"a")}
  else if(e.key==="2"&&f.selectionStart===f.selectionEnd&&f.value===""){pick(n,"b")}
});
render();
</script></body></html>
"""


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    ccp = Path(sys.argv[1]).resolve()
    cc = json.loads(ccp.read_text("utf-8"))
    chunk = int(sys.argv[sys.argv.index("--chunk") + 1]) if "--chunk" in sys.argv else 300

    stem = Path(cc["source"]).stem
    items = build_items(cc)
    if not items:
        raise SystemExit("没有可校对的条目")

    outdir = ROOT / "work" / "review"
    outdir.mkdir(parents=True, exist_ok=True)

    parts = [items[i:i + chunk] for i in range(0, len(items), chunk)]
    written = []
    for k, part in enumerate(parts, 1):
        name = f"{stem}.review{'' if len(parts) == 1 else f'.{k}'}.html"
        title = f"{stem}" + (f" ({k}/{len(parts)})" if len(parts) > 1 else "")
        page = (HTML_TMPL
                .replace("__DATA__", json.dumps(part, ensure_ascii=False))
                .replace("__TITLE__", html.escape(title))
                .replace("__KEYID__", json.dumps(f"{stem}-{k}")))
        p = outdir / name
        p.write_text(page, encoding="utf-8")
        written.append(p)
        print(f"  {p.relative_to(ROOT)}  ({len(part)} 条, {p.stat().st_size/1024:.0f} KB)")

    print(f"\n共 {len(items)} 条可疑项 -> {len(written)} 个文件")
    print(f"用浏览器打开: open {written[0].relative_to(ROOT)}")


if __name__ == "__main__":
    main()
