#!/usr/bin/env python3
"""Bootstrap Depth Anything V2 Small and generate source-aligned wallpaper masks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

MODEL_REVISION = "4472b7362082ad9968fee890ca0f1e5aca36b93d"
MODEL_URL = (
    "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/"
    f"{MODEL_REVISION}/onnx/model.onnx?download=true"
)
MODEL_SHA256 = "afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c"
MODEL_SIZE = 99_060_839
INPUT_SIZE = 518
MODEL_PATCH_SIZE = 14
DEPTH_PIPELINE_VERSION = 2
MASK_PIPELINE_VERSION = 3
REFINEMENT_MAX_DIMENSION = 1920
GUIDED_FILTER_RADIUS = 8
GUIDED_FILTER_EPSILON = 0.001
PYTHON_MIN = (3, 11)
PYTHON_MAX = (3, 14)
PACKAGES = (
    "numpy==2.4.2",
    "onnxruntime==1.28.0",
    "Pillow==12.3.0",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as stream:
        json.dump(value, stream, separators=(",", ":"), sort_keys=True)
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path)


def is_nixos() -> bool:
    """NixOS has no FHS-style /lib, /usr/lib search path, so pip-installed
    manylinux wheels (numpy/onnxruntime/Pillow) can fail to find shared
    libraries such as libstdc++.so.6 at import time even though `pip install`
    itself succeeds."""
    if Path("/etc/NIXOS").exists():
        return True
    try:
        os_release = Path("/etc/os-release").read_text(encoding="utf-8")
    except OSError:
        return False
    return any(line.strip() in ('ID=nixos', 'ID="nixos"') for line in os_release.splitlines())


# stdenv.cc.cc.lib provides libstdc++.so.6 and libgcc_s.so.1 (onnxruntime)
# and libgomp.so.1 (numpy's OpenBLAS threading); zlib covers Pillow/onnxruntime
# fallbacks that aren't always vendored inside the wheel itself.
NIX_LIBRARY_PACKAGES = ("stdenv.cc.cc.lib", "zlib")


def nix_library_cache_path(data_dir: Path) -> Path:
    return data_dir / "runtime" / "nix-library-path.json"


def resolve_nix_library_path(data_dir: Path) -> str:
    cache_path = nix_library_cache_path(data_dir)
    try:
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        cached = None
    if (
        isinstance(cached, dict)
        and cached.get("packages") == list(NIX_LIBRARY_PACKAGES)
        and isinstance(cached.get("libDirs"), list)
    ):
        lib_dirs = [Path(entry) for entry in cached["libDirs"]]
        if lib_dirs and all(path.is_dir() for path in lib_dirs):
            return os.pathsep.join(str(path) for path in lib_dirs)

    store_paths: list[str] = []
    for attribute in NIX_LIBRARY_PACKAGES:
        try:
            result = subprocess.run(
                ["nix-build", "<nixpkgs>", "-A", attribute, "--no-out-link"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        except FileNotFoundError as error:
            raise RuntimeError(
                "nix-build was not found; cannot resolve NixOS runtime libraries "
                "needed by numpy/onnxruntime/Pillow"
            ) from error
        if result.returncode != 0 or not result.stdout.strip():
            raise RuntimeError(
                f"nix-build could not resolve nixpkgs#{attribute}: "
                f"{result.stderr.strip() or 'no output'}"
            )
        store_paths.append(result.stdout.strip().splitlines()[-1])

    lib_dirs = [str(Path(path) / "lib") for path in store_paths]
    atomic_json(
        cache_path,
        {"packages": list(NIX_LIBRARY_PACKAGES), "libDirs": lib_dirs, "resolvedAt": int(time.time())},
    )
    return os.pathsep.join(lib_dirs)


def ensure_nixos_dynamic_linking(data_dir: Path) -> None:
    """On NixOS, re-exec this interpreter with LD_LIBRARY_PATH patched so
    pip-installed manylinux wheels can find libstdc++/libgomp/zlib. Every
    subprocess spawned afterwards (venv creation, pip install, the runtime
    readiness check, and the venv python that runs `generate`) inherits this
    process's environment, so patching it once here is enough for the whole
    plugin -- no changes to service.luau are needed."""
    if os.environ.get("_WALLPAPER_DEPTH_NIXOS_PATCHED") == "1":
        return
    if not is_nixos():
        return
    lib_path = resolve_nix_library_path(data_dir)
    existing = os.environ.get("LD_LIBRARY_PATH", "")
    new_env = dict(os.environ)
    new_env["LD_LIBRARY_PATH"] = f"{lib_path}{os.pathsep}{existing}" if existing else lib_path
    new_env["_WALLPAPER_DEPTH_NIXOS_PATCHED"] = "1"
    os.execve(sys.executable, [sys.executable] + sys.argv, new_env)


def runtime_python(data_dir: Path) -> Path:
    return data_dir / "runtime" / ".venv" / "bin" / "python"


def model_path(data_dir: Path) -> Path:
    return data_dir / "models" / "depth-anything-v2-small" / "model.onnx"


def verify_model(path: Path) -> bool:
    return path.is_file() and path.stat().st_size == MODEL_SIZE and sha256_file(path) == MODEL_SHA256


def runtime_ready(data_dir: Path) -> bool:
    python = runtime_python(data_dir)
    if not python.is_file():
        return False
    result = subprocess.run(
        [str(python), "-c", "import numpy, onnxruntime, PIL"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def emit(value: dict[str, object]) -> None:
    print(json.dumps(value, separators=(",", ":"), sort_keys=True), flush=True)


def download_model(destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".onnx.part")
    temporary.unlink(missing_ok=True)
    request = urllib.request.Request(MODEL_URL, headers={"User-Agent": "Noctalia-Wallpaper-Depth/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as stream:
            while chunk := response.read(1024 * 1024):
                stream.write(chunk)
        if temporary.stat().st_size != MODEL_SIZE:
            raise RuntimeError(
                f"model size mismatch: expected {MODEL_SIZE} bytes, received {temporary.stat().st_size}"
            )
        checksum = sha256_file(temporary)
        if checksum != MODEL_SHA256:
            raise RuntimeError(f"model checksum mismatch: expected {MODEL_SHA256}, received {checksum}")
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def setup(data_dir: Path) -> None:
    operation_path = data_dir / "setup-operation.json"
    atomic_json(
        operation_path,
        {"state": "running", "startedAt": int(time.time()), "modelSize": MODEL_SIZE},
    )
    python_version = sys.version_info[:2]
    if not PYTHON_MIN <= python_version <= PYTHON_MAX:
        raise RuntimeError("Python 3.11 through 3.14 is required")
    runtime_dir = data_dir / "runtime"
    venv = runtime_dir / ".venv"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    if not runtime_ready(data_dir):
        subprocess.run(
            [sys.executable, "-m", "venv", "--clear", str(venv)],
            stdin=subprocess.DEVNULL,
            check=True,
        )
        subprocess.run(
            [
                str(runtime_python(data_dir)),
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "--no-input",
                "--only-binary=:all:",
                *PACKAGES,
            ],
            stdin=subprocess.DEVNULL,
            check=True,
        )
    if not verify_model(model_path(data_dir)):
        download_model(model_path(data_dir))
    if not runtime_ready(data_dir) or not verify_model(model_path(data_dir)):
        raise RuntimeError("setup validation failed")
    status = {
        "ready": True,
        "modelRevision": MODEL_REVISION,
        "modelSha256": MODEL_SHA256,
        "modelSize": MODEL_SIZE,
        "packages": list(PACKAGES),
    }
    atomic_json(data_dir / "setup.json", status)
    atomic_json(
        operation_path,
        {
            "state": "ready",
            "finishedAt": int(time.time()),
            "modelRevision": MODEL_REVISION,
            "modelSize": MODEL_SIZE,
        },
    )
    emit(status)


def status(data_dir: Path) -> None:
    model = model_path(data_dir)
    emit(
        {
            "ready": runtime_ready(data_dir) and verify_model(model),
            "runtimeReady": runtime_ready(data_dir),
            "modelReady": verify_model(model),
            "modelRevision": MODEL_REVISION,
            "modelSize": MODEL_SIZE,
        }
    )


def inference_size(source_width: int, source_height: int) -> tuple[int, int]:
    scale = max(INPUT_SIZE / source_width, INPUT_SIZE / source_height)
    width = max(
        INPUT_SIZE,
        round(source_width * scale / MODEL_PATCH_SIZE) * MODEL_PATCH_SIZE,
    )
    height = max(
        INPUT_SIZE,
        round(source_height * scale / MODEL_PATCH_SIZE) * MODEL_PATCH_SIZE,
    )
    return width, height


def smoothstep(values, low: float, high: float):
    import numpy as np

    if high <= low:
        return (values >= high).astype(np.float32)
    scaled = np.clip((values - low) / (high - low), 0.0, 1.0)
    return scaled * scaled * (3.0 - 2.0 * scaled)


def box_mean(values, radius: int):
    import numpy as np

    padded = np.pad(values, ((radius, radius), (radius, radius)), mode="edge")
    integral = np.pad(padded, ((1, 0), (1, 0)), mode="constant")
    integral = np.cumsum(integral, axis=0, dtype=np.float64)
    integral = np.cumsum(integral, axis=1, dtype=np.float64)
    diameter = radius * 2 + 1
    total = (
        integral[diameter:, diameter:]
        - integral[:-diameter, diameter:]
        - integral[diameter:, :-diameter]
        + integral[:-diameter, :-diameter]
    )
    total *= 1.0 / (diameter * diameter)
    return total.astype(np.float32)


def refine_depth(source_rgb, depth):
    import numpy as np
    from PIL import Image

    source_width, source_height = source_rgb.size
    scale = min(1.0, REFINEMENT_MAX_DIMENSION / max(source_width, source_height))
    refinement_size = (
        max(1, round(source_width * scale)),
        max(1, round(source_height * scale)),
    )
    guide_image = source_rgb.convert("L")
    if guide_image.size != refinement_size:
        guide_image = guide_image.resize(refinement_size, Image.Resampling.LANCZOS)
    guide = np.asarray(guide_image, dtype=np.float32) / np.float32(255.0)
    coarse = np.asarray(
        Image.fromarray(depth).resize(refinement_size, Image.Resampling.BICUBIC),
        dtype=np.float32,
    )

    mean_guide = box_mean(guide, GUIDED_FILTER_RADIUS)
    mean_depth = box_mean(coarse, GUIDED_FILTER_RADIUS)
    correlation_guide = box_mean(guide * guide, GUIDED_FILTER_RADIUS)
    correlation_cross = box_mean(guide * coarse, GUIDED_FILTER_RADIUS)
    variance_guide = correlation_guide - mean_guide * mean_guide
    covariance = correlation_cross - mean_guide * mean_depth
    coefficient_a = covariance / (variance_guide + np.float32(GUIDED_FILTER_EPSILON))
    coefficient_b = mean_depth - coefficient_a * mean_guide
    refined = np.clip(
        box_mean(coefficient_a, GUIDED_FILTER_RADIUS) * guide
        + box_mean(coefficient_b, GUIDED_FILTER_RADIUS),
        0.0,
        1.0,
    ).astype(np.float32)

    if refinement_size != (source_width, source_height):
        refined = np.asarray(
            Image.fromarray(refined).resize((source_width, source_height), Image.Resampling.BICUBIC),
            dtype=np.float32,
        )
    return refined


def prune(directory: Path, maximum: int) -> None:
    if not directory.is_dir():
        return
    files = sorted(
        (path for path in directory.iterdir() if path.is_file()),
        key=lambda path: path.stat().st_mtime_ns,
        reverse=True,
    )
    for path in files[maximum:]:
        path.unlink(missing_ok=True)


def generate(data_dir: Path, wallpaper: Path, threshold: float, feather: float) -> None:
    import fcntl
    import numpy as np
    import onnxruntime as ort
    from PIL import Image

    if not wallpaper.is_file():
        raise RuntimeError("wallpaper is missing or unreadable")
    if not verify_model(model_path(data_dir)):
        raise RuntimeError("model is missing or failed checksum validation; run setup again")
    threshold = min(1.0, max(0.0, threshold))
    feather = min(0.5, max(0.0, feather))
    started = time.monotonic()
    wallpaper_hash = sha256_file(wallpaper)
    cache_key = (
        f"{wallpaper_hash}-{MODEL_SHA256[:16]}-d{DEPTH_PIPELINE_VERSION}-i{INPUT_SIZE}"
    )
    depth_dir = data_dir / "cache" / "depth"
    mask_dir = data_dir / "cache" / "masks"
    depth_dir.mkdir(parents=True, exist_ok=True)
    mask_dir.mkdir(parents=True, exist_ok=True)
    depth_path = depth_dir / f"{cache_key}.npy"
    mask_key = f"{cache_key}-v{MASK_PIPELINE_VERSION}-t{threshold:.4f}-f{feather:.4f}"
    mask_path = mask_dir / f"{mask_key}.png"
    lock_path = data_dir / "runtime" / "generate.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    with lock_path.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache_hit = depth_path.is_file()
        with Image.open(wallpaper) as source:
            source_rgb = source.convert("RGB")
            source_width, source_height = source_rgb.size
            if source_width <= 0 or source_height <= 0:
                raise RuntimeError("wallpaper has invalid dimensions")
            model_width, model_height = inference_size(source_width, source_height)
            if cache_hit:
                depth = np.load(depth_path, allow_pickle=False)
                if depth.shape != (model_height, model_width):
                    depth_path.unlink(missing_ok=True)
                    cache_hit = False
            if not cache_hit:
                resized = source_rgb.resize((model_width, model_height), Image.Resampling.BICUBIC)
                pixels = np.asarray(resized, dtype=np.float32) / np.float32(255.0)
                pixels = (pixels - np.array([0.485, 0.456, 0.406], dtype=np.float32)) / np.array(
                    [0.229, 0.224, 0.225], dtype=np.float32
                )
                tensor = np.transpose(pixels, (2, 0, 1))[None, ...]
                options = ort.SessionOptions()
                options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
                session = ort.InferenceSession(
                    str(model_path(data_dir)), sess_options=options, providers=["CPUExecutionProvider"]
                )
                input_name = session.get_inputs()[0].name
                prediction = session.run(None, {input_name: tensor})[0]
                depth = np.asarray(prediction, dtype=np.float32).squeeze()
                if depth.shape != (model_height, model_width):
                    raise RuntimeError(
                        f"unexpected model output shape: {depth.shape}; "
                        f"expected {(model_height, model_width)}"
                    )
                minimum = float(np.min(depth))
                maximum = float(np.max(depth))
                if not np.isfinite(minimum) or not np.isfinite(maximum) or maximum <= minimum:
                    raise RuntimeError("model returned an invalid depth map")
                depth = (depth - minimum) / (maximum - minimum)
                with tempfile.NamedTemporaryFile("wb", dir=depth_dir, delete=False) as stream:
                    np.save(stream, depth, allow_pickle=False)
                    temporary_depth = Path(stream.name)
                os.replace(temporary_depth, depth_path)

            if mask_path.is_file():
                with Image.open(mask_path) as cached_mask:
                    if cached_mask.size != (source_width, source_height):
                        mask_path.unlink(missing_ok=True)
            if not mask_path.is_file():
                full_size_depth = refine_depth(source_rgb, depth)
                half_feather = feather * 0.5
                alpha = smoothstep(full_size_depth, threshold - half_feather, threshold + half_feather)
                alpha_image = Image.fromarray(np.rint(alpha * 255.0).astype(np.uint8))
                with tempfile.NamedTemporaryFile("wb", dir=mask_dir, delete=False) as stream:
                    alpha_image.save(stream, format="PNG", optimize=True)
                    temporary_mask = Path(stream.name)
                os.replace(temporary_mask, mask_path)

        prune(depth_dir, 8)
        prune(mask_dir, 32)

    emit(
        {
            "cacheHit": cache_hit,
            "elapsedMs": round((time.monotonic() - started) * 1000),
            "height": source_height,
            "maskPath": str(mask_path),
            "modelRevision": MODEL_REVISION,
            "wallpaperPath": str(wallpaper),
            "width": source_width,
        }
    )


def clear_cache(data_dir: Path) -> None:
    shutil.rmtree(data_dir / "cache", ignore_errors=True)
    emit({"cleared": True})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True, type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("setup")
    subparsers.add_parser("status")
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--wallpaper", required=True, type=Path)
    generate_parser.add_argument("--threshold", required=True, type=float)
    generate_parser.add_argument("--feather", required=True, type=float)
    subparsers.add_parser("clear-cache")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    data_dir = args.data_dir.expanduser().resolve()
    try:
        ensure_nixos_dynamic_linking(data_dir)
        if args.command == "setup":
            setup(data_dir)
        elif args.command == "status":
            status(data_dir)
        elif args.command == "generate":
            generate(data_dir, args.wallpaper.expanduser().resolve(), args.threshold, args.feather)
        elif args.command == "clear-cache":
            clear_cache(data_dir)
        return 0
    except Exception as error:  # Keep the Luau-facing failure one line and actionable.
        if args.command == "setup":
            atomic_json(
                data_dir / "setup-operation.json",
                {"state": "error", "finishedAt": int(time.time()), "message": str(error)},
            )
        print(str(error), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
