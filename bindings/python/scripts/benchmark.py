#!/usr/bin/env python3
"""
Benchmark suite comparing Zignal against Pillow and OpenCV.

Usage:
    cd bindings/python
    uv run scripts/benchmark.py
    uv run scripts/benchmark.py --image ../../assets/liza.png
    uv run scripts/benchmark.py --json before.json          # save a baseline
    uv run scripts/benchmark.py --compare before.json       # add before/now columns

Pillow and OpenCV are optional; missing libraries show as N/A.

Caveats baked into the comparisons:
  - Zignal and OpenCV run on a thread pool; Pillow is single-threaded.
  - Pillow's GaussianBlur is a repeated box-blur approximation and OpenCV truncates
    the kernel at ~3σ, so the Gaussian rows compare different kernels.
  - Pillow has no Sobel; FIND_EDGES is a 3x3 Laplacian-style kernel.
  - The OpenCV Sobel pipeline includes the numpy magnitude, clip and u8 cast a user
    would need to get the same output.
  - Rotation expands the canvas to fit in all three libraries, so the pixel counts match.
"""

import argparse
import gc
import json
import math
import os
import statistics
import sys
import time
from pathlib import Path
from typing import Any, Callable

import zignal

try:
    import cv2
except ImportError:  # pragma: no cover
    cv2 = None

try:
    import numpy as np
    from PIL import Image as PILImage
    from PIL import ImageFilter as PILFilter
    from PIL import ImageOps as PILOps
except ImportError:  # pragma: no cover
    PILImage = PILFilter = PILOps = None

NAN = float("nan")
MISSING = {"median_ms": NAN, "min_ms": NAN, "runs": 0}


def run_bench(
    fn: Callable[[], Any],
    warmup: int = 5,
    min_runs: int = 20,
    target_time: float = 0.5,
) -> dict[str, Any]:
    for _ in range(warmup):
        fn()

    t0 = time.perf_counter()
    fn()
    single_elapsed = time.perf_counter() - t0

    if single_elapsed > 0.2:
        runs = max(5, min_runs // 4)
    elif single_elapsed > 0.05:
        runs = max(10, min_runs // 2)
    elif single_elapsed > 0:
        runs = min(max(min_runs, int(target_time / single_elapsed)), 100)
    else:
        runs = min_runs

    times = []
    gc.disable()
    try:
        for _ in range(runs):
            t_start = time.perf_counter()
            fn()
            times.append((time.perf_counter() - t_start) * 1000.0)
    finally:
        gc.enable()

    return {"median_ms": statistics.median(times), "min_ms": min(times), "runs": runs}


def bench_case(
    case: str,
    zig: Callable[[], Any],
    pil: Callable[[], Any] | None = None,
    cv: Callable[[], Any] | None = None,
    pil_result: dict[str, Any] | None = None,
    cv_result: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """One table row; a library is skipped when it is missing or has no equivalent."""
    if pil_result is None:
        pil_result = run_bench(pil) if (pil is not None and PILImage is not None) else MISSING
    if cv_result is None:
        cv_result = run_bench(cv) if (cv is not None and cv2 is not None) else MISSING
    return {"case": case, "zignal": run_bench(zig), "pillow": pil_result, "opencv": cv_result}


def fmt_ms(ms: float) -> str:
    return "N/A" if math.isnan(ms) else f"{ms:.2f}"


def fmt_ratio(other_ms: float, zg_ms: float) -> str:
    if math.isnan(other_ms) or math.isnan(zg_ms) or zg_ms <= 0:
        return "N/A"
    ratio = other_ms / zg_ms
    if ratio >= 1.0:
        return f"**{ratio:.2f}x faster**"
    return f"{1.0 / ratio:.2f}x slower"


def load_baseline(path: str) -> dict[tuple[str, str], float]:
    with open(path) as f:
        data = json.load(f)
    return {
        (cat["title"], item["case"]): item["zignal"]["median_ms"]
        for cat in data["categories"]
        for item in cat["items"]
    }


def print_table(
    categories: list[dict[str, Any]], baseline: dict[tuple[str, str], float] | None
) -> None:
    for cat in categories:
        print(f"\n### {cat['title']}\n")
        header = ["Operation / Filter", "Zignal (ms)"]
        if baseline is not None:
            header += ["Zignal before (ms)", "Now vs before"]
        header += ["Pillow (ms)", "OpenCV (ms)", "Zignal vs Pillow", "Zignal vs OpenCV"]
        print("| " + " | ".join(header) + " |")
        print("| :--- | " + " | ".join(":---:" for _ in header[1:]) + " |")
        for item in cat["items"]:
            zg_ms = item["zignal"]["median_ms"]
            pil_ms = item["pillow"]["median_ms"]
            cv_ms = item["opencv"]["median_ms"]
            row = [item["case"], fmt_ms(zg_ms)]
            if baseline is not None:
                before = baseline.get((cat["title"], item["case"]), NAN)
                row += [fmt_ms(before), fmt_ratio(before, zg_ms)]
            row += [
                fmt_ms(pil_ms),
                fmt_ms(cv_ms),
                fmt_ratio(pil_ms, zg_ms),
                fmt_ratio(cv_ms, zg_ms),
            ]
            print("| " + " | ".join(row) + " |")


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark Zignal vs Pillow vs OpenCV")
    default_img = Path(__file__).resolve().parents[3] / "assets" / "liza.png"
    parser.add_argument(
        "--image", type=str, default=str(default_img), help=f"input image (default: {default_img})"
    )
    parser.add_argument("--json", type=str, default=None, help="write results to this JSON file")
    parser.add_argument(
        "--compare",
        type=str,
        default=None,
        help="JSON from a previous run to add before/now columns",
    )
    args = parser.parse_args()

    image_path = Path(args.image).resolve()
    if not image_path.exists():
        sys.exit(f"Error: Image not found at {image_path}")

    baseline = load_baseline(args.compare) if args.compare else None

    print("=" * 80)
    print("IMAGE PROCESSING BENCHMARK: Zignal vs Pillow vs OpenCV")
    print("=" * 80)
    print(f"Loading test image: {image_path}")

    zg_rgb = zignal.Image.load(str(image_path))
    zg_gray = zg_rgb.convert(zignal.Gray)
    zg_small = zg_rgb.resize((256, 256), zignal.Interpolation.BILINEAR)
    cols, rows = zg_rgb.cols, zg_rgb.rows

    if PILImage is not None:
        pil_rgb = PILImage.open(str(image_path)).convert("RGB")
        pil_gray = pil_rgb.convert("L")
        pil_small = pil_rgb.resize((256, 256), PILImage.Resampling.BILINEAR)
    if cv2 is not None:
        cv_rgb = cv2.cvtColor(cv2.imread(str(image_path)), cv2.COLOR_BGR2RGB)
        cv_gray = cv2.cvtColor(cv_rgb, cv2.COLOR_RGB2GRAY)
        cv_small = cv2.resize(cv_rgb, (256, 256), interpolation=cv2.INTER_LINEAR)

    print(f"Original size: {cols}x{rows} {zg_rgb.dtype.__name__}")
    print(f"Zignal pool threads: {os.cpu_count()} (sized from the CPU count at import)")
    print(f"OpenCV threads: {cv2.getNumThreads() if cv2 is not None else 'not installed'}")
    print(f"Pillow: {'single-threaded' if PILImage is not None else 'not installed'}")
    print("-" * 80)

    categories = []

    # --------------------------------------------------------------------------
    # 1. RESIZING: Downscale -> 256x256
    # --------------------------------------------------------------------------
    resize_methods = [
        ("Nearest Neighbor", zignal.Interpolation.NEAREST, "NEAREST", "INTER_NEAREST"),
        ("Bilinear", zignal.Interpolation.BILINEAR, "BILINEAR", "INTER_LINEAR"),
        ("Bicubic", zignal.Interpolation.BICUBIC, "BICUBIC", "INTER_CUBIC"),
        ("Lanczos", zignal.Interpolation.LANCZOS, "LANCZOS", "INTER_LANCZOS4"),
    ]

    def resize_category(title, zg_src, pil_src, cv_src, size):
        cat = {"title": title, "items": []}
        for name, zg_m, pil_m, cv_m in resize_methods:
            cat["items"].append(
                bench_case(
                    name,
                    lambda: zg_src.resize(size, zg_m),
                    lambda: pil_src.resize(size, getattr(PILImage.Resampling, pil_m)),
                    lambda: cv2.resize(cv_src, size, interpolation=getattr(cv2, cv_m)),
                )
            )
        return cat

    categories.append(
        resize_category(
            f"Resizing: Downscale ({cols}x{rows} -> 256x256, RGB)",
            zg_rgb,
            pil_rgb if PILImage else None,
            cv_rgb if cv2 else None,
            (256, 256),
        )
    )
    categories.append(
        resize_category(
            "Resizing: Upscale (256x256 -> 1024x1024, RGB)",
            zg_small,
            pil_small if PILImage else None,
            cv_small if cv2 else None,
            (1024, 1024),
        )
    )

    # --------------------------------------------------------------------------
    # 2. BLURRING FILTERS (RGB)
    # --------------------------------------------------------------------------
    cat = {"title": "Blurring Filters (RGB)", "items": []}
    for radius in (3, 15):
        k = 2 * radius + 1
        cat["items"].append(
            bench_case(
                f"Box Blur (r={radius}, {k}x{k})",
                lambda: zg_rgb.box_blur(radius),
                lambda: pil_rgb.filter(PILFilter.BoxBlur(radius)),
                lambda: cv2.blur(cv_rgb, (k, k)),
            )
        )
    for sigma in (1.5, 5.0):
        cat["items"].append(
            bench_case(
                f"Gaussian Blur (σ={sigma}; Pillow: box approx, OpenCV: 3σ kernel)",
                lambda: zg_rgb.gaussian_blur(sigma),
                lambda: pil_rgb.filter(PILFilter.GaussianBlur(sigma)),
                lambda: cv2.GaussianBlur(cv_rgb, (0, 0), sigma),
            )
        )
    # σ=10 is measured once for the reference libraries and shared by the AUTO and FIR rows.
    pil_g10 = (
        run_bench(lambda: pil_rgb.filter(PILFilter.GaussianBlur(10.0))) if PILImage else MISSING
    )
    cv_g10 = run_bench(lambda: cv2.GaussianBlur(cv_rgb, (0, 0), 10.0)) if cv2 else MISSING
    for method_name, method in (
        ("AUTO", zignal.GaussianMethod.AUTO),
        ("FIR", zignal.GaussianMethod.FIR),
    ):
        cat["items"].append(
            bench_case(
                f"Gaussian Blur (σ=10.0, {method_name}; Pillow: box approx, OpenCV: 3σ kernel)",
                lambda: zg_rgb.gaussian_blur(10.0, method),
                pil_result=pil_g10,
                cv_result=cv_g10,
            )
        )
    cat["items"].append(
        bench_case(
            "Median Blur (r=2, 5x5)",
            lambda: zg_rgb.median_blur(2),
            lambda: pil_rgb.filter(PILFilter.MedianFilter(5)),
            lambda: cv2.medianBlur(cv_rgb, 5),
        )
    )
    categories.append(cat)

    # --------------------------------------------------------------------------
    # 3. EDGE DETECTION (Grayscale)
    # --------------------------------------------------------------------------
    cat = {"title": "Edge Detection (Grayscale)", "items": []}

    def cv_sobel_pipeline():
        gx = cv2.Sobel(cv_gray, cv2.CV_32F, 1, 0, ksize=3)
        gy = cv2.Sobel(cv_gray, cv2.CV_32F, 0, 1, ksize=3)
        mag = cv2.magnitude(gx, gy) * 0.25
        return np.clip(mag, 0, 255).astype(np.uint8)

    cat["items"].append(
        bench_case(
            "Sobel Magnitude 3x3 (Pillow: FIND_EDGES kernel; OpenCV: Gx, Gy, magnitude, u8 cast)",
            lambda: zg_gray.sobel(),
            lambda: pil_gray.filter(PILFilter.FIND_EDGES),
            cv_sobel_pipeline,
        )
    )
    cat["items"].append(
        bench_case(
            "Canny Edge Detection (σ=1.4, 50/150; Pillow: none)",
            lambda: zg_gray.canny(1.4, 50, 150),
            None,
            lambda: cv2.Canny(cv_gray, 50, 150),
        )
    )
    categories.append(cat)

    # --------------------------------------------------------------------------
    # 4. GEOMETRIC TRANSFORMS (RGB)
    # --------------------------------------------------------------------------
    cat = {"title": "Geometric Transforms (RGB)", "items": []}
    cat["items"].append(
        bench_case(
            "Horizontal Flip",
            lambda: zg_rgb.flip_left_right(),
            lambda: pil_rgb.transpose(PILImage.Transpose.FLIP_LEFT_RIGHT),
            lambda: cv2.flip(cv_rgb, 1),
        )
    )
    cat["items"].append(
        bench_case(
            "Vertical Flip",
            lambda: zg_rgb.flip_top_bottom(),
            lambda: pil_rgb.transpose(PILImage.Transpose.FLIP_TOP_BOTTOM),
            lambda: cv2.flip(cv_rgb, 0),
        )
    )

    # Zignal always expands the canvas to the rotated bounds, so give Pillow and OpenCV the
    # same output size instead of letting them crop to the input rectangle.
    # zignal takes radians; Pillow and OpenCV take degrees.
    rot_deg = 45.0
    rot_rad = math.radians(rot_deg)
    zg_rot = zg_rgb.rotate(rot_rad, zignal.Interpolation.BILINEAR)
    out_size = (zg_rot.cols, zg_rot.rows)
    if cv2 is not None:
        rot_matrix = cv2.getRotationMatrix2D((cols / 2.0, rows / 2.0), rot_deg, 1.0)
        rot_matrix[0, 2] += (out_size[0] - cols) / 2.0
        rot_matrix[1, 2] += (out_size[1] - rows) / 2.0
    cat["items"].append(
        bench_case(
            f"Rotate 45° (Bilinear, expanded canvas {out_size[0]}x{out_size[1]})",
            lambda: zg_rgb.rotate(rot_rad, zignal.Interpolation.BILINEAR),
            lambda: pil_rgb.rotate(rot_deg, resample=PILImage.Resampling.BILINEAR, expand=True),
            lambda: cv2.warpAffine(cv_rgb, rot_matrix, out_size, flags=cv2.INTER_LINEAR),
        )
    )
    if cv2 is not None:
        crop_matrix = cv2.getRotationMatrix2D((cols / 2.0, rows / 2.0), rot_deg, 1.0)
    cat["items"].append(
        bench_case(
            f"Rotate 45° (Bilinear, cropped to {cols}x{rows})",
            lambda: zg_rgb.rotate(rot_rad, zignal.Interpolation.BILINEAR, expand=False),
            lambda: pil_rgb.rotate(rot_deg, resample=PILImage.Resampling.BILINEAR),
            lambda: cv2.warpAffine(cv_rgb, crop_matrix, (cols, rows), flags=cv2.INTER_LINEAR),
        )
    )
    categories.append(cat)

    # --------------------------------------------------------------------------
    # 5. COLOR & INTENSITY OPERATIONS
    # --------------------------------------------------------------------------
    cat = {"title": "Color & Intensity Processing", "items": []}
    cat["items"].append(
        bench_case(
            "RGB to Grayscale",
            lambda: zg_rgb.convert(zignal.Gray),
            lambda: pil_rgb.convert("L"),
            lambda: cv2.cvtColor(cv_rgb, cv2.COLOR_RGB2GRAY),
        )
    )
    cat["items"].append(
        bench_case(
            "Histogram Equalization (Gray)",
            lambda: zg_gray.equalize(),
            lambda: PILOps.equalize(pil_gray),
            lambda: cv2.equalizeHist(cv_gray),
        )
    )
    cat["items"].append(
        bench_case(
            "Invert Colors (RGB)",
            lambda: zg_rgb.invert(),
            lambda: PILOps.invert(pil_rgb),
            lambda: cv2.bitwise_not(cv_rgb),
        )
    )
    categories.append(cat)

    print_table(categories, baseline)

    if args.json:
        with open(args.json, "w") as f:
            json.dump(
                {"image": str(image_path), "size": [cols, rows], "categories": categories},
                f,
                indent=2,
            )
        print(f"\nResults written to {args.json}")


if __name__ == "__main__":
    main()
