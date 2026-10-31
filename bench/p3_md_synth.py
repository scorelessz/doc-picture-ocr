#!/usr/bin/env python3
"""Phase 3 对拍: 随机合成 fused.json 同时喂 src/book_md.py 与 ocr-cli md, md 全文、stats、丢弃明细逐项比。只出数字。

真书几乎走不到书眉、竖排、双栏这些分支(两本基准书的书眉删除数都是 0), 只靠真书对拍等于没验证。
合成件的文字是随机汉字, 不含任何书的内容。种子固定, 同一 --docs 每次生成的文档完全相同。

用法: .venv/bin/python bench/p3_md_synth.py [--docs 400] [--seed 0]
结果写 bench/results/p3-md-synth.json; 中间文件落 work/bench/p3/synth/, 不进仓库。
"""
from __future__ import annotations

import argparse
import collections
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import book_md                                   # noqa: E402

CLI = ROOT / ".build" / "release" / "ocr-cli"
TMP = ROOT / "work" / "bench" / "p3" / "synth"
MD_MARK = "<!-- generated-by: book-line -->"
KEYS = ("pages", "lines_in", "rows", "kept_rows", "paragraphs", "headings", "dropped", "divergent", "low_conf",
        "only_one_engine", "chars", "malformed_lines", "vertical_pages", "two_column_pages", "dropped_detail")

W=list("的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处队南给色光门即保治北造百规热领七海口东导器压志世金增争济阶油思术极交受联什认六共权收证改清己美再采转更单风切打白教速花带安场身车例真务具万每目至达走积示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酸历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严龙飞")
def para(r,n): return "".join(r.choice(W) for _ in range(n))
def gen(seed):
    r=random.Random(seed); n=r.randint(3,14); W_,H=1000+r.randint(-40,40),1400+r.randint(-40,40)
    head=r.choice(["失约之城","第三章 归途","灯下的来信","","City of Promises"]); head2=r.choice(["","灯下的来","第12章 上海"])
    pnstyle=r.choice(["ar","roman","cjk","year","none","deco","wide"]); pages=[]
    rom=["i","ii","iii","iv","v","vi","vii","viii","ix","x","xi","xii","xiii","xiv","xv"]
    cn=["一","二","三","四","五","六","七","八","九","十","十一","十二","十三","十四","十五"]
    for i in range(1,n+1):
        ls=[];kind=r.choices(["body","vert","two","blank"],[8,1,1.5,.5])[0]
        lh=r.choice([38,40,42]);pit=r.choice([55,60,64]);y=200;lm=r.randint(90,110)
        if kind=="vert":
            for c in range(r.randint(3,9)):
                ls.append(dict(x=850-c*90+r.uniform(-3,3),y=100+r.uniform(-5,5),w=38,h=r.uniform(600,1100),text=para(r,r.randint(3,20)),conf=round(r.uniform(.3,1),4),src="both",alt=None,flag="ok"))
            pages.append(dict(page=i,width=W_,height=H,lines=ls));continue
        if kind=="two":
            for k in range(r.randint(6,14)):
                yy=200+k*pit
                ls.append(dict(x=100+r.uniform(-3,3),y=yy+r.uniform(-3,3),w=r.uniform(300,350),h=lh,text=para(r,r.randint(8,16)),conf=.9,src="both",alt=None,flag="ok"))
                ls.append(dict(x=560+r.uniform(-3,3),y=yy+r.uniform(-3,3),w=r.uniform(300,350),h=lh,text=para(r,r.randint(8,16)),conf=.9,src=r.choice(["both","vision"]),alt=None,flag=r.choice(["ok","divergent"])))
        elif kind=="body":
            for k in range(r.randint(1,17)):
                c=r.random()
                x=lm+(r.choice([0,0,0,80]));w=(W_-2*lm-(x-lm))*r.choice([1,1,1,.6,.3]);t=para(r,r.randint(4,30))
                if c<.06:t=r.choice(["第五章 归途","序","后记","前言","二 雪天的客人","二雪天的客人","三、开始","第12节 再会","1. 概述"]);x=W_/2-120;w=240;h=lh*r.choice([1,1.3,1.7])
                else:h=lh+r.uniform(-2,2)
                if c>.94:t=r.choice(["。","·","|||","a","三","——","…","1998","mix","post-","marked","x"]);
                if .5<c<.53: t=para(r,5)+"abc-"
                ls.append(dict(x=x+r.uniform(-4,4),y=y+r.uniform(-3,3),w=max(1,w),h=h,text=(" " if c<.02 else "")+t,conf=round(r.uniform(.2,1),4),src=r.choice(["both","both","both","vision","rapidocr"]),alt=None,flag=r.choice(["ok","ok","divergent","low_conf"])))
                y+=pit*(r.choice([1,1,1,2.2]))
                if r.random()<.1: ls.append(dict(x=x+w+r.uniform(2,120),y=y-pit+r.uniform(-3,3),w=r.uniform(30,200),h=lh,text=para(r,r.randint(1,5)),conf=.8,src="vision",alt=None,flag="ok"))
        if head and r.random()<.8:
            t=head if not head2 or r.random()<.7 else head2
            if r.random()<.2: t=t+str(i)
            ls.append(dict(x=W_/2-90+r.uniform(-6,6),y=60+r.uniform(-4,4),w=180,h=lh*r.choice([.9,1,1,1.3]),text=t,conf=.9,src="both",alt=None,flag="ok"))
        if pnstyle!="none" and r.random()<.9:
            t={"ar":str(i+10),"roman":rom[i-1],"cjk":cn[i-1],"year":str(1990+i),"deco":f"— {i} —","wide":f"（{i}）"}[pnstyle]
            ls.append(dict(x=r.choice([W_/2-20,120,W_-160])+r.uniform(-5,5),y=H-90+r.uniform(-5,5),w=40,h=lh*r.choice([.9,1,1.25]),text=t,conf=.9,src="both",alt=None,flag="ok"))
        r.shuffle(ls) if r.random()<.3 else None
        pages.append(dict(page=i,width=W_,height=H,lines=ls))
    return dict(pages=pages)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--docs", type=int, default=400)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    TMP.mkdir(parents=True, exist_ok=True)
    bad, failed = [], 0
    hits: collections.Counter = collections.Counter()
    for s in range(a.seed, a.seed + a.docs):
        d = gen(s)
        f = TMP / "doc.fused.json"
        f.write_text(json.dumps(d, ensure_ascii=False), "utf-8")
        for marks in (True, False):
            o = book_md.Options(page_marks=marks)
            md = book_md.to_markdown(d, o)
            py = f"{MD_MARK}\n\n{md.lstrip(chr(10))}"
            cmd = [str(CLI), "md", str(f), "--out", str(TMP / "o.md"), "--stats", str(TMP / "s.json"), "--force"]
            if not marks:
                cmd.append("--no-page-marks")
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode:
                failed += 1
                bad.append({"seed": s, "marks": marks, "error": r.stderr.strip()[:160]})
                continue
            sw = (TMP / "o.md").read_text("utf-8")
            st = json.loads((TMP / "s.json").read_text("utf-8"))
            p = o.stats
            same_lines = ([(x["page"], x["reason"], x["text"]) for x in p["dropped_lines"]]
                          == [(x["page"], x["reason"], x["text"]) for x in st["dropped_lines"]])
            if marks:
                hits.update(p["dropped_detail"])
                hits["竖排页"] += len(p["vertical_pages"])
                hits["双栏页"] += len(p["two_column_pages"])
                hits["标题"] += p["headings"]
            diff = [k for k in KEYS if p[k] != st[k]]
            if sw != py or diff or not same_lines:
                bad.append({"seed": s, "marks": marks, "stats_diff": diff, "md_equal": sw == py,
                            "dropped_lines_equal": same_lines})
    out = {"phase": "p3", "docs": a.docs, "seed": a.seed, "runs": a.docs * 2, "failed": failed,
           "mismatches": len(bad), "first_mismatches": bad[:10], "branch_hits": dict(hits)}
    (ROOT / "bench" / "results" / "p3-md-synth.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(json.dumps({k: out[k] for k in ("docs", "runs", "failed", "mismatches", "branch_hits")}, ensure_ascii=False))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
