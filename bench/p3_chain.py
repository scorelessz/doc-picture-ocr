#!/usr/bin/env python3
"""Phase 3 完整链路: Swift 融合(新规则) → Swift md 与 Python 链路的 md 逐块比。

要先跑 bench/p3_fuse_parity.py 生成 work/bench/p3/<tag>-new.fused.json。
结果(只有数字)写 bench/results/p3-chain.json; 差异明细(含原文)留在 work/bench/p3/<tag>-chain-diff.jsonl, 不进仓库。
"""
import json,subprocess,sys,difflib,collections
from pathlib import Path
R=Path(__file__).resolve().parent.parent; sys.path.insert(0,str(R/'src'))
import book_md
from rapidfuzz.distance import Levenshtein as L
T=R/'work/bench/p3'; CLI=R/'.build/release/ocr-cli'
out={"phase":"p3","name":"full-chain"}
for tag,stem in (('en','City of Broken Promises'),('zh','失约之城')):
    py=json.load(open(R/f'work/bench/{stem}.fused.json'))
    o=book_md.Options(); pm=f"<!-- generated-by: book-line -->\n\n{book_md.to_markdown(py,o).lstrip(chr(10))}"
    r=subprocess.run([str(CLI),'md',str(T/f'{tag}-new.fused.json'),'--out',str(T/f'{tag}-chain.swift.md'),'--stats',str(T/f'{tag}-chain.stats.json'),'--force'],capture_output=True,text=True); assert r.returncode==0,r.stderr
    sm=(T/f'{tag}-chain.swift.md').read_text('utf-8'); st=json.load(open(T/f'{tag}-chain.stats.json'))
    A=pm.split('\n\n'); B=sm.split('\n\n')
    sm_=difflib.SequenceMatcher(None,A,B,autojunk=False)
    ops=[];C=collections.Counter()
    for tagop,i1,i2,j1,j2 in sm_.get_opcodes():
        if tagop=='equal': continue
        a='\n\n'.join(A[i1:i2]); b='\n\n'.join(B[j1:j2])
        for x in L.opcodes(a,b):
            if x.tag=='equal': continue
            C[x.tag]+=1; C['chars_del']+=x.src_end-x.src_start; C['chars_ins']+=x.dest_end-x.dest_start
            ops.append({"engine":tag,"page":0,"truth":a[x.src_start:x.src_end],"hyp":b[x.dest_start:x.dest_end],"ctx":a[max(0,x.src_start-10):x.src_end+10],"tag":x.tag})
    with open(T/f'{tag}-chain-diff.jsonl','w',encoding='utf-8') as f:
        for e in ops: f.write(json.dumps(e,ensure_ascii=False)+'\n')
    out[tag]={"py_chars":len(pm),"swift_chars":len(sm),"delta":len(sm)-len(pm),"ops":dict(C),"py_paragraphs":o.stats['paragraphs'],"swift_paragraphs":st['paragraphs'],"py_rows":o.stats['rows'],"swift_rows":st['rows'],"py_dropped":o.stats['dropped'],"swift_dropped":st['dropped'],"py_headings":o.stats['headings'],"swift_headings":st['headings'],"identical":pm==sm}
    print(tag,out[tag])
(R/'bench/results/p3-chain.json').write_text(json.dumps(out,ensure_ascii=False,indent=1)+'\n','utf-8')
