"""RapidOCR 验证脚本：输出识别结果和耗时（检测 + 分类 + 识别）。
用法：.venv/bin/python rapid_ocr.py <图片路径>... [--runs N]
"""
import sys
import time

from rapidocr_onnxruntime import RapidOCR

args = sys.argv[1:]
runs = 5
if "--runs" in args:
    i = args.index("--runs")
    runs = int(args[i + 1])
    del args[i : i + 2]

engine = RapidOCR()

for path in args:
    engine(path)  # 预热，首次调用包含模型加载
    times, result = [], None
    for _ in range(runs):
        t0 = time.perf_counter()
        result, _elapse = engine(path)
        times.append((time.perf_counter() - t0) * 1000)
    print(f"== {path.split('/')[-1]}")
    for box, text, score in sorted(result or [], key=lambda r: r[0][0][1]):
        print(f"  [{float(score):.2f}] {text}")
    print(f"  耗时: 平均 {sum(times) / len(times):.1f} ms, 最小 {min(times):.1f} ms ({runs} 次)\n")
