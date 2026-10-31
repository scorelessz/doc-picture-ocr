#!/usr/bin/env python3
"""PP-OCR 的 ONNX 模型转 Core ML(.mlpackage), 附与 onnxruntime 的数值校验和 sha256 清单。

不走 onnx2torch(不支持 SAME_UPPER)。这几个模型的算子集很小, 这里直接把 ONNX 图翻译成 MIL。
输入形状固定: Shape/Reshape 这类动态算子在转换时折叠成常量, Core ML 才能编译到 ANE。

环境(独立 venv, 不进 .venv): coremltools onnx onnxruntime numpy
用法:
  python tools/convert_paddle.py --models <rapidocr/models> --out <目录> \\
      --det 1216x2016,1376x2016 --rec 320,640,960,1280,1600,1920 --cls [--precision float16]
产物(.mlpackage / keys.txt / manifest.json)不进仓库。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import get_new_symbol, types
from onnx import numpy_helper

DET, CLS, REC = "PP-OCRv6_det_small", "ch_ppocr_mobile_v2.0_cls_mobile", "PP-OCRv6_rec_small"


def attrs(n) -> dict:
    return {a.name: onnx.helper.get_attribute_value(a) for a in n.attribute}


def pads(a: dict, kernel, strides, dil=(1, 1)) -> list[int]:
    """返回 MIL 的 [上, 下, 左, 右]。SAME_UPPER 只用在固定步长 1 的层上, 多出来的 1 像素补在下/右。"""
    if a.get("auto_pad", b"NOTSET") in (b"SAME_UPPER", "SAME_UPPER"):
        out = []
        for k, s, d in zip(kernel, strides, dil):
            assert s == 1, "SAME_UPPER 只支持 stride=1"
            t = (k - 1) * d
            out += [t // 2, t - t // 2]
        return out
    p = a.get("pads", [0, 0, 0, 0])
    return [p[0], p[2], p[1], p[3]]


def translate(model: onnx.ModelProto, shape: tuple):
    """把 ONNX 图翻译成 MIL 函数体。值要么是 numpy(常量, 能折叠就折叠), 要么是 MIL Var。

    shape 里可以有 get_new_symbol() 产生的符号维: 检测图没有 Shape/Reshape, 能做成可变尺寸。"""
    g = model.graph
    init = {i.name: numpy_helper.to_array(i) for i in g.initializer}

    @mb.program(input_specs=[mb.TensorSpec(shape=shape, dtype=types.float)],
                opset_version=ct.target.macOS14)
    def prog(x):
        v: dict = dict(init)
        v[g.input[0].name] = x

        def get(name):
            return v[name]

        def const(val):
            return isinstance(val, np.ndarray)

        def arr(val):
            """算子的数值参数统一成 float32 张量。"""
            return val.astype(np.float32) if const(val) else val

        for n in g.node:
            op, a = n.op_type, attrs(n)
            i = [get(s) if s else None for s in n.input]
            name = n.output[0]
            if op == "Constant":
                r = numpy_helper.to_array(a["value"])
            elif op == "Identity":
                r = i[0]
            elif op == "Conv":
                k, s = a["kernel_shape"], a.get("strides", [1, 1])
                d = a.get("dilations", [1, 1])
                kw = {"bias": arr(i[2])} if len(i) > 2 else {}
                r = mb.conv(x=i[0], weight=arr(i[1]), strides=s, pad_type="custom", pad=pads(a, k, s, d),
                            dilations=d, groups=a.get("group", 1), **kw)
            elif op == "ConvTranspose":
                k, s = a["kernel_shape"], a.get("strides", [1, 1])
                kw = {"bias": arr(i[2])} if len(i) > 2 else {}
                r = mb.conv_transpose(x=i[0], weight=arr(i[1]), strides=s, pad_type="custom", pad=pads(a, k, s),
                                      dilations=a.get("dilations", [1, 1]), groups=a.get("group", 1), **kw)
            elif op in ("Add", "Sub", "Mul", "Div", "Pow"):
                if const(i[0]) and const(i[1]):
                    r = {"Add": np.add, "Sub": np.subtract, "Mul": np.multiply, "Div": np.divide,
                         "Pow": np.power}[op](i[0], i[1])
                else:
                    f = {"Add": mb.add, "Sub": mb.sub, "Mul": mb.mul, "Div": mb.real_div, "Pow": mb.pow}[op]
                    r = f(x=arr(i[0]), y=arr(i[1]))
            elif op == "Relu":
                r = mb.relu(x=i[0])
            elif op == "Sigmoid":
                r = mb.sigmoid(x=i[0])
            elif op == "Sqrt":
                r = mb.sqrt(x=i[0])
            elif op == "Erf":
                r = mb.erf(x=i[0])
            elif op == "HardSigmoid":
                r = mb.sigmoid_hard(x=i[0], alpha=float(a["alpha"]), beta=float(a["beta"]))
            elif op == "GlobalAveragePool":
                r = mb.reduce_mean(x=i[0], axes=[2, 3], keep_dims=True)
            elif op == "ReduceMean":
                r = mb.reduce_mean(x=i[0], axes=list(a["axes"]), keep_dims=bool(a.get("keepdims", 1)))
            elif op in ("MaxPool", "AveragePool"):
                k, s = a["kernel_shape"], a.get("strides", [1, 1])
                f = mb.max_pool if op == "MaxPool" else mb.avg_pool
                kw = {"exclude_padding_from_average": True} if op == "AveragePool" else {}
                r = f(x=i[0], kernel_sizes=k, strides=s, pad_type="custom", pad=pads(a, k, s), **kw)
            elif op == "Resize":
                sc = i[2]
                assert a["mode"] in ("nearest", b"nearest") and sc[0] == 1 and sc[1] == 1
                r = mb.upsample_nearest_neighbor(x=i[0], scale_factor_height=float(sc[2]), scale_factor_width=float(sc[3]))
            elif op == "Concat":
                if all(const(t) for t in i):
                    r = np.concatenate(i, axis=a["axis"])
                else:
                    r = mb.concat(values=[arr(t) for t in i], axis=a["axis"])
            elif op == "MatMul":
                r = mb.matmul(x=arr(i[0]), y=arr(i[1]))
            elif op == "Transpose":
                r = mb.transpose(x=i[0], perm=list(a["perm"]))
            elif op == "Softmax":
                r = mb.softmax(x=i[0], axis=a.get("axis", -1))
            elif op == "Clip":
                lo, hi = float(i[1]), float(i[2])
                r = mb.clip(x=i[0], alpha=lo, beta=hi)
            elif op == "BatchNormalization":
                r = mb.batch_norm(x=i[0], gamma=arr(i[1]), beta=arr(i[2]), mean=arr(i[3]), variance=arr(i[4]),
                                  epsilon=float(a.get("epsilon", 1e-5)))
            elif op == "Shape":
                r = np.array(i[0].shape if not const(i[0]) else i[0].shape, dtype=np.int64)
            elif op == "Cast":
                to = {1: np.float32, 6: np.int32, 7: np.int64, 11: np.float64}[a["to"]]
                r = i[0].astype(to) if const(i[0]) else mb.cast(x=i[0], dtype={1: "float32", 6: "int32"}[a["to"]])
            elif op == "Slice":
                st, en = i[1].astype(int), i[2].astype(int)
                ax = i[3].astype(int) if len(i) > 3 and i[3] is not None else np.arange(len(st))
                step = i[4].astype(int) if len(i) > 4 and i[4] is not None else np.ones(len(st), int)
                if const(i[0]):
                    sl = [slice(None)] * i[0].ndim
                    for s0, e0, a0, p0 in zip(st, en, ax, step):
                        sl[a0] = slice(int(s0), int(e0), int(p0))
                    r = i[0][tuple(sl)]
                else:
                    rank = len(i[0].shape)
                    b, e, mask_b, mask_e, stp = [0] * rank, [0] * rank, [True] * rank, [True] * rank, [1] * rank
                    for s0, e0, a0, p0 in zip(st, en, ax, step):
                        a0 = int(a0) % rank
                        dim = i[0].shape[a0]
                        b[a0], e[a0], mask_b[a0], mask_e[a0], stp[a0] = int(s0), min(int(e0), dim), False, False, int(p0)
                    r = mb.slice_by_index(x=i[0], begin=b, end=e, stride=stp, begin_mask=mask_b, end_mask=mask_e)
            elif op == "Squeeze":
                r = np.squeeze(i[0], axis=tuple(a["axes"])) if const(i[0]) else mb.squeeze(x=i[0], axes=list(a["axes"]))
            elif op == "Unsqueeze":
                r = np.expand_dims(i[0], axis=tuple(a["axes"])) if const(i[0]) else mb.expand_dims(x=i[0], axes=list(a["axes"]))
            elif op == "Reshape":
                sh = [int(t) for t in np.asarray(i[1]).ravel()]
                src = i[0].shape
                sh = [int(src[k]) if t == 0 else t for k, t in enumerate(sh)]
                r = i[0].reshape(sh) if const(i[0]) else mb.reshape(x=i[0], shape=sh)
            else:
                raise NotImplementedError(op)
            v[name] = r
        return v[g.output[0].name]

    return prog


def rec_keys(model: onnx.ModelProto) -> list[str]:
    """字表在 ONNX 元数据里。与 RapidOCR 一样: 下标 0 是 blank, 末尾补一个空格。"""
    meta = {p.key: p.value for p in model.metadata_props}
    return ["<blank>"] + meta["character"].splitlines() + [" "]


def convert_one(onnx_path: Path, shape: tuple[int, ...], out: Path, precision: str) -> dict:
    m = onnx.load(onnx_path)
    prog = translate(m, shape)
    ml = ct.convert(prog, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                    compute_precision=ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32,
                    inputs=[ct.TensorType(name="x", shape=shape)])
    ml.save(str(out))
    rng = np.random.default_rng(0)
    x = (rng.random(shape, dtype=np.float32) * 2 - 1).astype(np.float32)
    # 平滑一点的输入更接近真实页图, 纯噪声会放大浮点差
    ref = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"]).run(None, {"x": x})[0]
    got = np.asarray(next(iter(ml.predict({"x": x}).values())))
    return {"file": out.name, "shape": list(shape), "out_shape": list(ref.shape), "got_shape": list(got.shape),
            "max_abs_diff": float(np.abs(ref - got).max()), "mean_abs_diff": float(np.abs(ref - got).mean())}


def convert_flex_det(onnx_path: Path, out: Path, precision: str) -> dict:
    """可变尺寸检测模型: Core ML 不把可变形状放上 ANE, 走 CPU/GPU, 换来任意尺寸都是精确输入。"""
    m = onnx.load(onnx_path)
    prog = translate(m, (1, 3, get_new_symbol(), get_new_symbol()))
    rd = ct.RangeDim(lower_bound=32, upper_bound=8192)
    ml = ct.convert(prog, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                    compute_precision=ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32,
                    inputs=[ct.TensorType(name="x", shape=(1, 3, rd, ct.RangeDim(lower_bound=32, upper_bound=8192)))])
    ml.save(str(out))
    res = []
    rng = np.random.default_rng(0)
    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    for h, w in ((640, 480), (736, 1312), (2016, 896)):
        x = (rng.random((1, 3, h, w), dtype=np.float32) * 2 - 1).astype(np.float32)
        ref = sess.run(None, {"x": x})[0]
        got = np.asarray(next(iter(ml.predict({"x": x}).values())))
        res.append({"shape": [h, w], "got": list(got.shape), "max_abs_diff": float(np.abs(ref - got).max())})
    return {"file": out.name, "flex_checks": res}


def sha_dir(p: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(q for q in p.rglob("*") if q.is_file()):
        h.update(f.relative_to(p).as_posix().encode())
        h.update(f.read_bytes())
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--det", default="", help="逗号分隔的 宽x高")
    ap.add_argument("--rec", default="", help="逗号分隔的宽度")
    ap.add_argument("--cls", action="store_true")
    ap.add_argument("--det-flex", action="store_true", help="可变尺寸检测模型, 兜底任意页面")
    ap.add_argument("--precision", choices=("float16", "float32"), default="float16")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    tag = a.precision.replace("float", "f")
    jobs = []
    for s in filter(None, a.det.split(",")):
        w, h = map(int, s.split("x"))
        jobs.append((DET, (1, 3, h, w), a.out / f"det-{w}x{h}-{tag}.mlpackage"))
    for s in filter(None, a.rec.split(",")):
        jobs.append((REC, (1, 3, 48, int(s)), a.out / f"rec-{s}-{tag}.mlpackage"))
    if a.cls:
        jobs.append((CLS, (1, 3, 48, 192), a.out / f"cls-{tag}.mlpackage"))

    manifest_f = a.out / "manifest.json"
    manifest = json.loads(manifest_f.read_text()) if manifest_f.exists() else {"models": {}}
    src = {n: hashlib.sha256((a.models / f"{n}.onnx").read_bytes()).hexdigest() for n in (DET, CLS, REC)}
    manifest["onnx_sha256"] = src
    (a.out / "keys.txt").write_text("\n".join(rec_keys(onnx.load(a.models / f"{REC}.onnx"))), "utf-8")
    if a.det_flex:
        out = a.out / f"det-flex-{tag}.mlpackage"
        t0 = time.time()
        r = convert_flex_det(a.models / f"{DET}.onnx", out, a.precision)
        r.update(source=DET, seconds=round(time.time() - t0, 1), sha256=sha_dir(out))
        manifest["models"][out.name] = r
        print(json.dumps(r), flush=True)
    for name, shape, out in jobs:
        t0 = time.time()
        r = convert_one(a.models / f"{name}.onnx", shape, out, a.precision)
        r.update(source=name, seconds=round(time.time() - t0, 1), sha256=sha_dir(out))
        manifest["models"][out.name] = r
        print(json.dumps(r), flush=True)
    manifest_f.write_text(json.dumps(manifest, indent=1) + "\n", "utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
