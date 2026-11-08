#!/usr/bin/env python3
"""Run an isolated, pinned Core ML PP-FormulaNet smoke qualification.

The default command is macOS-only and runs actual CPU Core ML inference. The
download-validation and fixture-rendering modes use no Core ML and are useful
for bounded checks on other hosts. This script never packages model weights
into the iOS app and never loads code from the source conversion repository.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterator


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_MANIFEST = SCRIPT_DIR / "math_model_candidate.json"
APPROVED_SOURCES = {
    "coreml": (
        "MoraxCheng/ohmyshot-ppformulanet-plus-l-coreml",
        "a994339cda5fe6ba90170981219395dfb025332b",
    ),
    "weights_reference": (
        "PaddlePaddle/PP-FormulaNet_plus-L_safetensors",
        "6cc004a8e91ea3f3819b05317f40b290cbe99c2b",
    ),
    "processor": (
        "PaddlePaddle/PP-FormulaNet_plus-L_safetensors",
        "6cc004a8e91ea3f3819b05317f40b290cbe99c2b",
    ),
}
APPROVED_PATHS = {
    "coreml": frozenset(
        {
            "encoder.mlpackage/Manifest.json",
            "encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            "decoder.mlpackage/Manifest.json",
            "decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            "tokens.txt",
            "config.json",
            "LICENSE.txt",
        }
    ),
    "processor": frozenset({"processor_config.json"}),
}
LFS_SHA_PATHS = frozenset(
    {
        "encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
    }
)
MAX_TOTAL_BYTES = 256 * 1024 * 1024
MAX_DOWNLOAD_CHUNK_BYTES = 1024 * 1024
MAX_OUTPUT_TOKENS = 256
DEFAULT_SAMPLE_TIMEOUT_SECONDS = 90
TOKEN_SPECIAL_COUNT = 23

SAMPLES: tuple[tuple[str, str], ...] = (
    ("formula_01.png", r"F=ma"),
    ("formula_02.png", r"E=mc^2"),
    ("formula_03.png", r"\frac{1}{2}"),
    ("formula_04.png", r"\sum_{i=1}^{n} i"),
    ("formula_05.png", r"\frac{\partial^2\psi}{\partial x^2}"),
)


class QualificationError(RuntimeError):
    """A pinned artifact, signature, preprocessing, or inference check failed."""


class SampleTimeout(TimeoutError):
    pass


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(MAX_DOWNLOAD_CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_parts(value: str) -> tuple[str, ...]:
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise QualificationError(f"Unsafe manifest path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise QualificationError(f"Unsafe manifest path: {value!r}")
    if path.as_posix() != value:
        raise QualificationError(f"Non-canonical manifest path: {value!r}")
    return path.parts


def validate_manifest(manifest: dict[str, Any]) -> int:
    if manifest.get("manifest_schema_version") != 1:
        raise QualificationError("Unsupported candidate manifest schema")
    if manifest.get("license") != "Apache-2.0":
        raise QualificationError("The candidate license is not pinned to Apache-2.0")
    if manifest.get("size_budget_bytes") != MAX_TOTAL_BYTES:
        raise QualificationError("Manifest size budget differs from the 256 MiB hard limit")

    sources = manifest.get("sources")
    if not isinstance(sources, dict):
        raise QualificationError("Candidate source pins are missing")
    for name, (repo, revision) in APPROVED_SOURCES.items():
        source = sources.get(name)
        if not isinstance(source, dict) or source.get("repo") != repo or source.get("revision") != revision:
            raise QualificationError(f"Unapproved source or revision for {name}")
    if sources["weights_reference"].get("downloaded") is not False:
        raise QualificationError("The original Paddle weights must remain provenance-only")

    files = manifest.get("files")
    if not isinstance(files, list):
        raise QualificationError("Manifest file list is missing")
    observed_paths: dict[str, set[str]] = {name: set() for name in APPROVED_PATHS}
    total_bytes = 0
    sha_pattern = re.compile(r"^[0-9a-f]{64}$")
    for item in files:
        if not isinstance(item, dict):
            raise QualificationError("Manifest file entry is not an object")
        source = item.get("source")
        if source not in APPROVED_PATHS:
            raise QualificationError(f"Unapproved file source: {source!r}")
        path = item.get("path")
        _safe_parts(path)
        if path not in APPROVED_PATHS[source] or path in observed_paths[source]:
            raise QualificationError(f"File is outside the fixed allowlist or duplicated: {path}")
        observed_paths[source].add(path)
        size = item.get("size_bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0 or size > MAX_TOTAL_BYTES:
            raise QualificationError(f"Invalid file size for {path}")
        digest = item.get("sha256")
        if not isinstance(digest, str) or not sha_pattern.fullmatch(digest):
            raise QualificationError(f"Invalid SHA-256 for {path}")
        hash_source = item.get("hash_source")
        if hash_source not in {"hf_lfs_sha256", "downloaded_raw_bytes"}:
            raise QualificationError(f"Missing hash provenance for {path}")
        expected_hash_source = "hf_lfs_sha256" if source == "coreml" and path in LFS_SHA_PATHS else "downloaded_raw_bytes"
        if hash_source != expected_hash_source:
            raise QualificationError(f"Hash provenance differs from Hugging Face metadata for {path}")
        total_bytes += size
        if total_bytes > MAX_TOTAL_BYTES:
            raise QualificationError("Pinned model files exceed the 256 MiB total limit")

    for name, expected in APPROVED_PATHS.items():
        if observed_paths[name] != set(expected):
            missing = sorted(set(expected) - observed_paths[name])
            extra = sorted(observed_paths[name] - set(expected))
            raise QualificationError(f"Allowlist mismatch for {name}; missing={missing}, extra={extra}")
    if manifest.get("total_size_bytes") != total_bytes:
        raise QualificationError("Manifest total_size_bytes does not match its fixed entries")
    if total_bytes >= MAX_TOTAL_BYTES:
        raise QualificationError("Pinned package total must remain below 256 MiB")

    processor = manifest.get("processor_expectations")
    if not isinstance(processor, dict) or processor.get("image_processor_type") != "PPFormulaNetImageProcessor":
        raise QualificationError("Official processor expectations are missing")
    return total_bytes


def _load_manifest(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
        manifest = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise QualificationError(f"Unable to read candidate manifest: {error}") from error
    if not isinstance(manifest, dict):
        raise QualificationError("Candidate manifest root must be an object")
    validate_manifest(manifest)
    return manifest


def _safe_root(root: Path) -> Path:
    absolute = root.expanduser().absolute()
    if absolute.exists() and absolute.is_symlink():
        raise QualificationError(f"Model cache root is a symlink: {absolute}")
    absolute.mkdir(parents=True, exist_ok=True)
    if absolute.is_symlink() or not absolute.is_dir():
        raise QualificationError("Model cache root is not a real directory")
    return absolute


def _target_path(root: Path, relative: str) -> Path:
    parts = _safe_parts(relative)
    current = root
    for part in parts[:-1]:
        current = current / part
        if current.exists() or current.is_symlink():
            if current.is_symlink() or not current.is_dir():
                raise QualificationError(f"Unsafe package directory: {current}")
        else:
            current.mkdir()
    target = current / parts[-1]
    if target.is_symlink():
        raise QualificationError(f"Symlink in model package: {target}")
    return target


def validate_directory(root: Path,
                       allowed_paths: set[str],
                       maximum_bytes: int,
                       allow_missing: bool) -> tuple[set[str], int]:
    if root.is_symlink() or not root.is_dir():
        raise QualificationError("Model cache is not a real directory")
    observed: set[str] = set()
    total = 0
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in list(dirnames):
            child = directory_path / name
            if child.is_symlink():
                raise QualificationError(f"Symlink in model package: {child}")
        for name in filenames:
            child = directory_path / name
            if child.is_symlink() or not child.is_file():
                raise QualificationError(f"Non-regular package entry: {child}")
            relative = child.relative_to(root).as_posix()
            _safe_parts(relative)
            if relative not in allowed_paths:
                raise QualificationError(f"Unexpected package file: {relative}")
            observed.add(relative)
            size = child.stat().st_size
            if size <= 0 or size > maximum_bytes:
                raise QualificationError(f"Package file exceeds bounds: {relative}")
            total += size
            if total > maximum_bytes:
                raise QualificationError("Existing model cache exceeds the 256 MiB total limit")
    if not allow_missing and observed != allowed_paths:
        raise QualificationError("Model cache does not contain exactly the pinned file set")
    return observed, total


def _download_url(source: dict[str, str], relative: str) -> str:
    repo = source.get("repo")
    revision = source.get("revision")
    if (repo, revision) not in set(APPROVED_SOURCES.values()):
        raise QualificationError("Refusing to construct a URL for an unapproved repository revision")
    return f"https://huggingface.co/{repo}/resolve/{revision}/{relative}"


def _download_one(root: Path, entry: dict[str, Any], source_info: dict[str, str]) -> Path:
    relative = entry["path"]
    target = _target_path(root, relative)
    expected_size = entry["size_bytes"]
    expected_sha = entry["sha256"]
    if target.exists():
        if not target.is_file():
            raise QualificationError(f"Pinned file path is not regular: {relative}")
        if target.stat().st_size != expected_size or _sha256_file(target) != expected_sha:
            raise QualificationError(f"Cached file does not match its pinned size/hash: {relative}")
        return target

    temporary_name: str | None = None
    digest = hashlib.sha256()
    total = 0
    request = urllib.request.Request(
        _download_url(source_info, relative),
        headers={"User-Agent": "PdfVocab-MathModelQualification/1.0"},
    )
    try:
        with tempfile.NamedTemporaryFile(prefix=".pinned-download-", dir=target.parent, delete=False) as output:
            temporary_name = output.name
            with urllib.request.urlopen(request, timeout=60) as response:
                while True:
                    chunk = response.read(MAX_DOWNLOAD_CHUNK_BYTES)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > expected_size or total > MAX_TOTAL_BYTES:
                        raise QualificationError(f"Download exceeded its pinned byte limit: {relative}")
                    digest.update(chunk)
                    output.write(chunk)
        if total != expected_size or digest.hexdigest() != expected_sha:
            raise QualificationError(
                f"Pinned download mismatch for {relative}: size={total}/{expected_size}, "
                f"sha256={digest.hexdigest()}"
            )
        os.replace(temporary_name, target)
        temporary_name = None
        return target
    except QualificationError:
        raise
    except Exception as error:
        raise QualificationError(f"Download failed for pinned file {relative}: {error}") from error
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def download_assets(manifest: dict[str, Any],
                    model_dir: Path,
                    small_files_only: bool = False) -> dict[str, Path]:
    root = _safe_root(model_dir)
    entries = manifest["files"]
    selected = [entry for entry in entries if not small_files_only or entry["size_bytes"] <= 1024 * 1024]
    expected = {entry["path"] for entry in selected}
    validate_directory(root, expected, MAX_TOTAL_BYTES, allow_missing=True)
    sources = manifest["sources"]
    files: dict[str, Path] = {}
    for entry in selected:
        files[entry["path"]] = _download_one(root, entry, sources[entry["source"]])
    found, total = validate_directory(root, expected, MAX_TOTAL_BYTES, allow_missing=False)
    expected_total = sum(entry["size_bytes"] for entry in selected)
    if found != expected or total != expected_total:
        raise QualificationError("Downloaded package tree differs from the selected pinned allowlist")
    for entry in selected:
        path = files[entry["path"]]
        if path.stat().st_size != entry["size_bytes"] or _sha256_file(path) != entry["sha256"]:
            raise QualificationError(f"Post-download verification failed: {entry['path']}")
    return files


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


def render_samples(output_dir: Path) -> list[dict[str, Any]]:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    output_dir.mkdir(parents=True, exist_ok=True)
    rendered: list[dict[str, Any]] = []
    for filename, expected_latex in SAMPLES:
        path = output_dir / filename
        figure = plt.figure(figsize=(4.4, 1.2), dpi=192, facecolor="white")
        try:
            figure.text(0.5, 0.5, f"${expected_latex}$", ha="center", va="center", fontsize=24, color="black")
            figure.savefig(path, format="png", dpi=192, facecolor="white", bbox_inches="tight", pad_inches=0.16)
        finally:
            plt.close(figure)
        rendered.append(
            {
                "sample_id": filename.removesuffix(".png"),
                "input_png": filename,
                "expected_latex": expected_latex,
                "fixture_source": "self-generated matplotlib mathtext; not human-annotated",
                "status": "not_run",
            }
        )
    return rendered


def _collect_environment() -> dict[str, Any]:
    packages: dict[str, str | None] = {}
    for name in ("coremltools", "torch", "torchvision", "transformers", "matplotlib", "tokenizers"):
        try:
            packages[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            packages[name] = None
    xcode = None
    if platform.system() == "Darwin":
        try:
            result = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, timeout=10, check=False)
            xcode = result.stdout.strip() or result.stderr.strip()
        except (OSError, subprocess.TimeoutExpired) as error:
            xcode = f"unavailable: {error}"
    return {
        "python": sys.version,
        "platform": platform.platform(),
        "system": platform.system(),
        "machine": platform.machine(),
        "macos_version": platform.mac_ver()[0] or None,
        "xcodebuild_version": xcode,
        "packages": packages,
    }


def _write_pip_freeze(output_dir: Path) -> None:
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pip", "freeze", "--all"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        text = result.stdout
        if result.returncode:
            text += f"\n# pip freeze exited {result.returncode}: {result.stderr.strip()}\n"
    except (OSError, subprocess.TimeoutExpired) as error:
        text = f"# pip freeze unavailable: {error}\n"
    (output_dir / "environment-packages.txt").write_text(text, encoding="utf-8")


def _package_manifest_is_safe(path: Path) -> None:
    try:
        package = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise QualificationError(f"Invalid Core ML package manifest {path.name}: {error}") from error
    entries = package.get("itemInfoEntries")
    if package.get("fileFormatVersion") != "1.0.0" or not isinstance(entries, dict):
        raise QualificationError(f"Unexpected Core ML package manifest: {path.name}")
    paths = {item.get("path") for item in entries.values() if isinstance(item, dict)}
    if paths != {"com.apple.CoreML/model.mlmodel", "com.apple.CoreML/weights"}:
        raise QualificationError(f"Core ML package references an unapproved path: {path.name}")
    for item in entries.values():
        if not isinstance(item, dict) or item.get("author") != "com.apple.CoreML":
            raise QualificationError(f"Unexpected package item in {path.name}")


def _processor_config(model_dir: Path, manifest: dict[str, Any]) -> tuple[Any, dict[str, Any]]:
    import numpy as np  # noqa: F401 - verifies the installed processor runtime
    from transformers import PPFormulaNetImageProcessor

    expected = manifest["processor_expectations"]
    config = json.loads((model_dir / "processor_config.json").read_text(encoding="utf-8"))
    image_config = config.get("image_processor")
    if not isinstance(image_config, dict):
        raise QualificationError("Pinned processor_config.json has no image_processor object")
    if config.get("processor_class") != expected["processor_class"]:
        raise QualificationError("Processor class differs from the pinned expectation")
    for key in (
        "image_processor_type",
        "do_crop_margin",
        "do_resize",
        "do_thumbnail",
        "do_pad",
        "do_rescale",
        "do_normalize",
        "do_align_long_axis",
        "size",
        "image_mean",
        "image_std",
        "resample",
        "return_tensors",
    ):
        if image_config.get(key) != expected.get(key):
            raise QualificationError(f"Pinned processor field mismatch: {key}")
    processor = PPFormulaNetImageProcessor(**image_config)
    return processor, config


COREML_NUMPY_DTYPES = {
    65552: "float16",
    65568: "float32",
    65600: "float64",
    131080: "int8",
    131088: "int16",
    131104: "int32",
    131112: "int64",
    196616: "uint8",
    196624: "uint16",
    196640: "uint32",
    196656: "uint64",
}


def _feature_shape_and_dtype(feature: Any) -> tuple[tuple[int, ...], Any]:
    import numpy as np

    feature_kind = feature.type.WhichOneof("Type")
    if feature_kind == "multiArrayType":
        array_type = feature.type.multiArrayType
    elif feature_kind == "stateType":
        state_kind = feature.type.stateType.WhichOneof("Type")
        if state_kind != "arrayType":
            raise QualificationError(
                f"Unsupported Core ML state signature for {feature.name}: {state_kind}"
            )
        array_type = feature.type.stateType.arrayType
    else:
        raise QualificationError(
            f"Core ML feature {feature.name} is not a multi-array: {feature_kind}"
        )
    shape = tuple(int(value) for value in array_type.shape)
    dtype_name = COREML_NUMPY_DTYPES.get(int(array_type.dataType))
    if not shape or any(dimension <= 0 for dimension in shape) or dtype_name is None:
        raise QualificationError(f"Unsupported tensor signature for {feature.name}: shape={shape}, dtype={array_type.dataType}")
    return shape, np.dtype(dtype_name)


def _feature_map(features: Any) -> dict[str, Any]:
    return {feature.name: feature for feature in features}


def _signature(model: Any, model_name: str) -> dict[str, Any]:
    spec = model.get_spec()
    inputs = _feature_map(spec.description.input)
    outputs = _feature_map(spec.description.output)
    state_features = _feature_map(spec.description.state)
    return {
        "spec": spec,
        "inputs": inputs,
        "outputs": outputs,
        "states": state_features,
        "record": {
            "model": model_name,
            "inputs": {name: _record_feature(feature) for name, feature in inputs.items()},
            "outputs": {name: _record_feature(feature) for name, feature in outputs.items()},
            "states": {name: _record_feature(feature) for name, feature in state_features.items()},
        },
    }


def _record_feature(feature: Any) -> dict[str, Any]:
    shape, dtype = _feature_shape_and_dtype(feature)
    return {"shape": list(shape), "dtype": str(dtype)}


def _validate_signature(signature: dict[str, Any], expected: dict[str, Any], label: str) -> None:
    inputs = signature["inputs"]
    outputs = signature["outputs"]
    states = signature["states"]
    expected_inputs = expected["inputs"]
    expected_outputs = expected.get("outputs", {})
    for name, shape in expected_inputs.items():
        feature = inputs.get(name)
        if feature is None:
            raise QualificationError(f"{label} is missing input {name}")
        actual_shape, _ = _feature_shape_and_dtype(feature)
        if actual_shape != tuple(shape):
            raise QualificationError(f"{label} input {name} shape {actual_shape} != {tuple(shape)}")
    if set(inputs) != set(expected_inputs):
        raise QualificationError(f"{label} has unexpected inputs: {sorted(set(inputs) - set(expected_inputs))}")
    for name, shape in expected_outputs.items():
        feature = outputs.get(name)
        if feature is None:
            raise QualificationError(f"{label} is missing output {name}")
        actual_shape, _ = _feature_shape_and_dtype(feature)
        if actual_shape != tuple(shape):
            raise QualificationError(f"{label} output {name} shape {actual_shape} != {tuple(shape)}")
    if expected_outputs and set(outputs) != set(expected_outputs):
        raise QualificationError(f"{label} has unexpected outputs: {sorted(set(outputs) - set(expected_outputs))}")
    expected_states = set(expected.get("state_names", []))
    if expected_states and set(states) != expected_states:
        raise QualificationError(f"{label} states {sorted(states)} != {sorted(expected_states)}")


def _validate_assets(model_dir: Path, manifest: dict[str, Any]) -> None:
    coreml_files = {item["path"] for item in manifest["files"] if item["source"] == "coreml"}
    for model_name in ("encoder", "decoder"):
        _package_manifest_is_safe(model_dir / f"{model_name}.mlpackage" / "Manifest.json")
    license_text = (model_dir / "LICENSE.txt").read_text(encoding="utf-8", errors="strict")
    if "Apache License" not in license_text or "Version 2.0" not in license_text:
        raise QualificationError("Pinned Core ML package license text is not Apache-2.0")
    config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
    if config.get("tokens", {}).get("encoding") != "byteLevel" or config.get("tokens", {}).get("special") != TOKEN_SPECIAL_COUNT:
        raise QualificationError("Pinned token configuration differs from the expected byte-level vocabulary")
    if config.get("decoder", {}).get("start") != 2 or config.get("decoder", {}).get("end") != 2:
        raise QualificationError("Pinned decoder start/end token IDs differ from the approved configuration")
    if config.get("decoder", {}).get("cache") != 1024:
        raise QualificationError("Pinned decoder cache length differs from the approved configuration")
    if (model_dir / "layout.mlpackage").exists():
        raise QualificationError("layout.mlpackage is not in the approved model allowlist")
    if len(coreml_files) != 9:
        raise QualificationError("The Core ML file allowlist is incomplete")


class RSSSampler:
    """Sample process RSS during one phase without external Python packages."""

    def __init__(self, interval_seconds: float = 0.2) -> None:
        self.interval_seconds = interval_seconds
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.peak_kib = 0
        self.errors: list[str] = []

    def _sample(self) -> None:
        try:
            result = subprocess.run(
                ["ps", "-o", "rss=", "-p", str(os.getpid())],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
            if result.returncode == 0 and result.stdout.strip():
                self.peak_kib = max(self.peak_kib, int(result.stdout.strip().split()[0]))
            elif result.returncode:
                self.errors.append(result.stderr.strip() or f"ps exited {result.returncode}")
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            self.errors.append(str(error))

    def _run(self) -> None:
        while not self._stop.is_set():
            self._sample()
            self._stop.wait(self.interval_seconds)

    def __enter__(self) -> "RSSSampler":
        self._sample()
        self._thread = threading.Thread(target=self._run, name="rss-sampler", daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=4)
        self._sample()

    @property
    def peak_mib(self) -> float | None:
        return round(self.peak_kib / 1024.0, 2) if self.peak_kib else None


@contextmanager
def sample_deadline(seconds: int) -> Iterator[float]:
    if seconds <= 0:
        raise QualificationError("Sample timeout must be positive")
    if not hasattr(signal, "setitimer") or threading.current_thread() is not threading.main_thread():
        raise QualificationError("Per-sample signal timeout requires the macOS main thread")
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)

    def timeout_handler(_signum: int, _frame: Any) -> None:
        raise SampleTimeout(f"sample exceeded {seconds}s")

    signal.signal(signal.SIGALRM, timeout_handler)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield time.monotonic() + seconds
    finally:
        signal.setitimer(signal.ITIMER_REAL, *previous_timer)
        signal.signal(signal.SIGALRM, previous_handler)


def _numpy_dtype(feature: Any) -> Any:
    return _feature_shape_and_dtype(feature)[1]


def _numpy_array_for_feature(value: Any, feature: Any, *, cast: bool = True) -> Any:
    import numpy as np

    shape, dtype = _feature_shape_and_dtype(feature)
    array = np.asarray(value)
    if cast:
        array = array.astype(dtype, copy=False)
    if tuple(array.shape) != shape:
        raise QualificationError(f"Input {feature.name} array shape {tuple(array.shape)} != spec {shape}")
    return array


def _normalized_whitespace(value: str) -> str:
    return "".join(value.split())


def _predict_next_token(output: dict[str, Any], output_name: str, output_feature: Any) -> int:
    import numpy as np

    if output_name not in output:
        raise QualificationError(f"Core ML decoder did not return {output_name}")
    output_values = np.asarray(output[output_name])
    spec_shape, spec_dtype = _feature_shape_and_dtype(output_feature)
    if tuple(output_values.shape) != spec_shape:
        raise QualificationError(
            f"Runtime decoder output shape {tuple(output_values.shape)} differs from spec {spec_shape}"
        )
    if output_name == "next":
        if spec_dtype.kind not in {"i", "u"} or output_values.size != 1 or output_values.dtype.kind not in {"i", "u"}:
            raise QualificationError("The decoder next output must be a single integer token ID by spec and runtime")
        return int(output_values.reshape(-1)[0])
    if output_name != "logits" or spec_dtype.kind != "f" or output_values.dtype.kind != "f":
        raise QualificationError("The decoder logits output must be a floating tensor by spec and runtime")
    logits = output_values.astype(spec_dtype, copy=False)
    if logits.size < 2 or not np.isfinite(logits).all():
        raise QualificationError("Core ML decoder returned empty, non-finite, or scalar logits")
    return int(np.argmax(logits.reshape(-1)))


def _decode_token_ids(token_ids: list[int], token_vocabulary: list[str], byte_level_decoder: Any) -> str:
    values: list[str] = []
    for token_id in token_ids:
        if token_id < TOKEN_SPECIAL_COUNT:
            raise QualificationError(f"Unexpected special token before EOS: {token_id}")
        if token_id >= len(token_vocabulary):
            raise QualificationError(f"Predicted token ID is outside tokens.txt: {token_id}")
        values.append(token_vocabulary[token_id])
    return byte_level_decoder.decode(values)


def _run_one_sample(sample: dict[str, Any],
                    image_path: Path,
                    processor: Any,
                    encoder: Any,
                    encoder_sig: dict[str, Any],
                    decoder: Any,
                    decoder_sig: dict[str, Any],
                    output_name: str,
                    token_vocabulary: list[str],
                    byte_level_decoder: Any,
                    config: dict[str, Any],
                    timeout_seconds: int) -> dict[str, Any]:
    import numpy as np
    import torch
    from PIL import Image

    started = time.monotonic()
    sample["status"] = "running"
    sample["predicted_token_ids"] = []
    sample["decoded_token_ids"] = []
    sample["predicted_latex"] = ""
    try:
        with sample_deadline(timeout_seconds) as deadline:
            def ensure_before_deadline() -> None:
                if time.monotonic() > deadline:
                    raise SampleTimeout(f"sample exceeded {timeout_seconds}s")

            with Image.open(image_path) as image:
                prepared = processor.preprocess(image.convert("RGB"), return_tensors="pt")
            ensure_before_deadline()
            tensor = prepared["pixel_values"]
            if not isinstance(tensor, torch.Tensor):
                raise QualificationError("Official image processor did not return a PyTorch tensor")
            pixel_values = _numpy_array_for_feature(tensor.detach().cpu().numpy(),
                                                    encoder_sig["inputs"]["pixel_values"])
            encoded = encoder.predict({"pixel_values": pixel_values})
            ensure_before_deadline()
            keys_name = config["encoder"]["keys"]
            values_name = config["encoder"]["values"]
            if keys_name not in encoded or values_name not in encoded:
                raise QualificationError("Core ML encoder omitted cross-attention key/value outputs")
            cross_keys = _numpy_array_for_feature(encoded[keys_name], decoder_sig["inputs"][keys_name])
            cross_values = _numpy_array_for_feature(encoded[values_name], decoder_sig["inputs"][values_name])
            state = decoder.make_state()
            start_token = int(config["decoder"]["start"])
            end_token = int(config["decoder"]["end"])
            mask_feature = decoder_sig["inputs"][config["decoder"]["mask"]]
            mask_shape, mask_dtype = _feature_shape_and_dtype(mask_feature)
            if mask_dtype.kind != "f" or len(mask_shape) != 4 or mask_shape[-1] != int(config["decoder"]["cache"]):
                raise QualificationError("Decoder mask spec does not support the pinned causal mask")
            token_id = start_token
            decoded_ids: list[int] = []
            ended = False
            eos_inclusive_ids: list[int] = []
            for position in range(MAX_OUTPUT_TOKENS):
                ensure_before_deadline()
                mask = np.full(mask_shape, -np.inf, dtype=mask_dtype)
                mask[..., : position + 1] = 0
                model_inputs = {
                    config["decoder"]["token"]: _numpy_array_for_feature(
                        np.asarray([[token_id]]), decoder_sig["inputs"][config["decoder"]["token"]]
                    ),
                    config["decoder"]["position"]: _numpy_array_for_feature(
                        np.asarray([position]), decoder_sig["inputs"][config["decoder"]["position"]]
                    ),
                    config["decoder"]["mask"]: mask,
                    keys_name: cross_keys,
                    values_name: cross_values,
                }
                decoded = decoder.predict(model_inputs, state=state)
                ensure_before_deadline()
                token_id = _predict_next_token(decoded, output_name, decoder_sig["outputs"][output_name])
                eos_inclusive_ids.append(token_id)
                sample["predicted_token_ids"] = list(eos_inclusive_ids)
                if token_id == end_token:
                    ended = True
                    break
                decoded_ids.append(token_id)
                sample["decoded_token_ids"] = list(decoded_ids)
                sample["predicted_latex"] = _decode_token_ids(decoded_ids, token_vocabulary, byte_level_decoder)
            sample["eos_seen"] = ended
            sample["decoded_token_ids"] = decoded_ids
            if not ended:
                raise QualificationError(f"Decoder did not emit EOS within {MAX_OUTPUT_TOKENS} steps")
            if not sample["predicted_latex"].strip():
                raise QualificationError("Decoder emitted an empty formula")
            sample["normalized_expected"] = _normalized_whitespace(sample["expected_latex"])
            sample["normalized_prediction"] = _normalized_whitespace(sample["predicted_latex"])
            sample["exact_match"] = sample["normalized_prediction"] == sample["normalized_expected"]
            sample["status"] = "completed"
    except Exception as error:
        sample["status"] = "failed"
        sample["error"] = f"{type(error).__name__}: {error}"
    finally:
        sample["duration_seconds"] = round(time.monotonic() - started, 4)
    return sample


def run_qualification(manifest: dict[str, Any],
                      model_dir: Path,
                      output_dir: Path,
                      sample_timeout_seconds: int) -> dict[str, Any]:
    report: dict[str, Any] = {
        "candidate_id": manifest["candidate_id"],
        "started_at": _utc_now(),
        "status": "running",
        "qualification_scope": "synthetic mathtext whitespace-normalized exact match; not human gold, structural accuracy, or iPad qualification",
        "sources": manifest["sources"],
        "license": manifest["license"],
        "pinned_download_total_bytes": manifest["total_size_bytes"],
        "sample_timeout_seconds": sample_timeout_seconds,
        "max_output_tokens": MAX_OUTPUT_TOKENS,
        "environment": _collect_environment(),
        "samples": [],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    _write_pip_freeze(output_dir)
    rendered = render_samples(output_dir)
    report["samples"] = [
        {
            "sample_id": item["sample_id"],
            "input_png": item["input_png"],
            "expected_latex": item["expected_latex"],
            "fixture_source": item["fixture_source"],
            "status": "not_run",
        }
        for item in rendered
    ]
    _write_json(output_dir / "report.json", report)

    try:
        if platform.system() != "Darwin":
            raise QualificationError("Core ML inference requires macOS; use --validate-downloads-only for static checks")
        files = download_assets(manifest, model_dir)
        _validate_assets(model_dir, manifest)
        import coremltools as ct
        import numpy as np
        import torch
        import torchvision
        from tokenizers import decoders

        processor, _processor_config_data = _processor_config(model_dir, manifest)
        coreml_config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
        token_vocabulary = (model_dir / "tokens.txt").read_text(encoding="utf-8").splitlines()
        if len(token_vocabulary) <= TOKEN_SPECIAL_COUNT:
            raise QualificationError("Pinned token vocabulary is unexpectedly short")
        byte_level_decoder = decoders.ByteLevel()
        report["environment"].update(
            {
                "coremltools_runtime_version": ct.__version__,
                "torch_runtime_version": torch.__version__,
                "torchvision_runtime_version": torchvision.__version__,
                "transformers_runtime_version": importlib.metadata.version("transformers"),
                "tokenizers_runtime_version": importlib.metadata.version("tokenizers"),
            }
        )
        with RSSSampler() as load_sampler:
            load_started = time.monotonic()
            encoder_path = model_dir / "encoder.mlpackage"
            decoder_path = model_dir / "decoder.mlpackage"
            encoder = ct.models.MLModel(str(encoder_path), compute_units=ct.ComputeUnit.CPU_ONLY)
            decoder = ct.models.MLModel(str(decoder_path), compute_units=ct.ComputeUnit.CPU_ONLY)
            encoder_sig = _signature(encoder, "encoder")
            decoder_sig = _signature(decoder, "decoder")
            _validate_signature(encoder_sig, manifest["signature"]["encoder"], "encoder")
            _validate_signature(decoder_sig, manifest["signature"]["decoder"], "decoder")
            output_name = next(
                (name for name in manifest["signature"]["decoder"]["output_name_candidates"] if name in decoder_sig["outputs"]),
                None,
            )
            if output_name is None:
                raise QualificationError("Decoder has neither the pinned next nor logits output")
            if set(decoder_sig["outputs"]) != {output_name}:
                raise QualificationError(f"Decoder outputs differ from the pinned next/logits signature: {sorted(decoder_sig['outputs'])}")
            output_shape, output_dtype = _feature_shape_and_dtype(decoder_sig["outputs"][output_name])
            if output_name == "next":
                if output_dtype.kind not in {"i", "u"} or math.prod(output_shape) != 1:
                    raise QualificationError("Decoder next spec must be a single integer token ID")
            elif output_dtype.kind != "f" or math.prod(output_shape) < 2:
                raise QualificationError("Decoder logits spec must be a floating tensor with multiple values")
            report["model_signature"] = {
                "encoder": encoder_sig["record"],
                "decoder": decoder_sig["record"],
                "decoder_selected_output": output_name,
            }
            report["model_load_duration_seconds"] = round(time.monotonic() - load_started, 4)
            report["model_load_peak_rss_mib"] = load_sampler.peak_mib
            report["model_load_rss_sampling_errors"] = load_sampler.errors

        infer_started = time.monotonic()
        with RSSSampler() as infer_sampler:
            for result in report["samples"]:
                image_path = output_dir / result["input_png"]
                _run_one_sample(
                    result,
                    image_path,
                    processor,
                    encoder,
                    encoder_sig,
                    decoder,
                    decoder_sig,
                    output_name,
                    token_vocabulary,
                    byte_level_decoder,
                    coreml_config,
                    sample_timeout_seconds,
                )
                _write_json(output_dir / "report.json", report)
        report["inference_duration_seconds"] = round(time.monotonic() - infer_started, 4)
        report["inference_peak_rss_mib"] = infer_sampler.peak_mib
        report["inference_rss_sampling_errors"] = infer_sampler.errors
        matches = sum(1 for sample in report["samples"] if sample.get("exact_match") is True)
        failed_samples = [sample["sample_id"] for sample in report["samples"] if sample.get("status") != "completed"]
        report["fixture_exact_match_count"] = matches
        report["fixture_count"] = len(report["samples"])
        report["status"] = "passed" if matches == len(SAMPLES) and not failed_samples else "failed"
        if failed_samples:
            report["reason"] = f"Inference failed for samples: {', '.join(failed_samples)}"
        elif matches != len(SAMPLES):
            mismatches = [sample["sample_id"] for sample in report["samples"] if not sample.get("exact_match")]
            report["reason"] = f"Whitespace-normalized fixture exact match failed for: {', '.join(mismatches)}"
    except Exception as error:
        report["status"] = "failed"
        report["reason"] = f"{type(error).__name__}: {error}"
        for sample in report["samples"]:
            if sample.get("status") == "not_run":
                sample["status"] = "not_run"
                sample["not_run_reason"] = report["reason"]
    finally:
        report["finished_at"] = _utc_now()
        _write_json(output_dir / "report.json", report)
    return report


def _render_only(output_dir: Path) -> dict[str, Any]:
    samples = render_samples(output_dir)
    report = {
        "candidate_id": "pp-formulanet-plus-l-coreml-cpu-smoke",
        "started_at": _utc_now(),
        "finished_at": _utc_now(),
        "status": "not_run",
        "reason": "Fixture rendering only; Core ML inference has not run.",
        "qualification_scope": "synthetic mathtext fixtures only",
        "environment": _collect_environment(),
        "samples": samples,
    }
    _write_pip_freeze(output_dir)
    _write_json(output_dir / "report.json", report)
    return report


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--model-dir", type=Path, default=Path.home() / "Library/Caches/pdf-vocab/math-model-candidate")
    parser.add_argument("--output-dir", type=Path, default=Path("artifacts/math-model-qualification"))
    parser.add_argument("--sample-timeout-seconds", type=int, default=DEFAULT_SAMPLE_TIMEOUT_SECONDS)
    parser.add_argument("--validate-downloads-only", action="store_true",
                        help="Download and hash-check pinned files without loading Core ML or importing model code.")
    parser.add_argument("--small-files-only", action="store_true",
                        help="With --validate-downloads-only, fetch only allowlisted files up to 1 MiB each.")
    parser.add_argument("--render-only", action="store_true",
                        help="Render the five synthetic input fixtures and emit a not_run report, without model inference.")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        manifest = _load_manifest(args.manifest)
        if args.small_files_only and not args.validate_downloads_only:
            raise QualificationError("--small-files-only requires --validate-downloads-only")
        if args.render_only and args.validate_downloads_only:
            raise QualificationError("--render-only and --validate-downloads-only are mutually exclusive")
        if args.render_only:
            report = _render_only(args.output_dir)
            print(json.dumps({"status": report["status"], "rendered": len(report["samples"])}))
            return 0
        if args.validate_downloads_only:
            files = download_assets(manifest, args.model_dir, small_files_only=args.small_files_only)
            result = {
                "status": "verified",
                "files_verified": len(files),
                "total_verified_bytes": sum(path.stat().st_size for path in files.values()),
                "model_revision": APPROVED_SOURCES["coreml"][1],
                "processor_revision": APPROVED_SOURCES["processor"][1],
                "coreml_inference": "not_run",
            }
            print(json.dumps(result, sort_keys=True))
            return 0
        report = run_qualification(manifest, args.model_dir, args.output_dir, args.sample_timeout_seconds)
        print(json.dumps({"status": report["status"], "reason": report.get("reason")}, sort_keys=True))
        return 0 if report["status"] == "passed" else 1
    except Exception as error:
        message = f"{type(error).__name__}: {error}"
        print(message, file=sys.stderr)
        if not args.validate_downloads_only and not args.render_only:
            try:
                args.output_dir.mkdir(parents=True, exist_ok=True)
                failure = {
                    "candidate_id": "pp-formulanet-plus-l-coreml-cpu-smoke",
                    "started_at": _utc_now(),
                    "finished_at": _utc_now(),
                    "status": "failed",
                    "reason": message,
                    "coreml_inference": "not_run_or_incomplete",
                    "environment": _collect_environment(),
                    "samples": [],
                }
                _write_json(args.output_dir / "report.json", failure)
                _write_pip_freeze(args.output_dir)
            except Exception as report_error:
                print(f"Unable to write failure report: {report_error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
