# Isolated PP-FormulaNet Core ML qualification experiment

This workflow measures one fixed, Apache-2.0 Core ML candidate outside the app. It does not add model import, an inference runtime, or model weights to the iOS target or IPA. The experiment downloads only the allowlisted files in [`scripts/math_model_candidate.json`](../scripts/math_model_candidate.json); it does not download `layout.mlpackage`, execute repository scripts, or copy OhMyShot runtime code.

## Fixed sources and file integrity

- Core ML conversion: [`MoraxCheng/ohmyshot-ppformulanet-plus-l-coreml`](https://huggingface.co/MoraxCheng/ohmyshot-ppformulanet-plus-l-coreml/tree/a994339cda5fe6ba90170981219395dfb025332b) at `a994339cda5fe6ba90170981219395dfb025332b`.
- Source-weight provenance only: [`PaddlePaddle/PP-FormulaNet_plus-L_safetensors`](https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-L_safetensors/tree/6cc004a8e91ea3f3819b05317f40b290cbe99c2b) at `6cc004a8e91ea3f3819b05317f40b290cbe99c2b`. The workflow does not download these safetensors.
- The conversion's pinned [`LICENSE.txt`](https://huggingface.co/MoraxCheng/ohmyshot-ppformulanet-plus-l-coreml/blob/a994339cda5fe6ba90170981219395dfb025332b/LICENSE.txt) is checked as Apache-2.0. The repository's license applies to those model artifacts; no source code from the conversion repository is imported or executed.
- Processor settings come from the pinned upstream `processor_config.json`. Runtime preprocessing uses `transformers==5.18.0`'s `PPFormulaNetImageProcessor`; the script does not implement crop, resize, thumbnail, pad, rescale, or normalization itself.

The manifest pins ten files: the two Core ML package manifests, their model specifications and weight blobs, `tokens.txt`, `config.json`, `LICENSE.txt`, and the upstream processor config. Their combined declared size is 184,930,188 bytes, below the hard 256 MiB total limit. Four LFS-backed model files use the exact SHA-256 values from the Hugging Face revision API. All non-LFS files were downloaded at their pinned revisions and hashed from the raw response bytes. The executable validates the fixed repository/revision pair, exact path allowlist, sizes, hash provenance, every SHA-256, and the directory tree; it rejects absolute/traversal paths, symlinks, unexpected files, and oversized entries. The original Paddle weights are recorded for provenance only and must remain marked `downloaded: false`.

The model cache key includes both fixed revisions. Cache entries are rechecked before use; the model cache is under the runner temp directory and is never included in the uploaded artifact.

## Actual macOS inference

Run the [qualification workflow](../.github/workflows/qualify-math-model.yml) on `macos-26` with Xcode 26.6 and Python 3.12. It supports manual dispatch and a push trigger restricted to branch `codex/v062-interaction-rebuild` and changes to the workflow, qualification script, or candidate manifest. The isolated venv pins `coremltools==9.0`, `torch==2.14.1`, `torchvision==0.29.2`, `transformers==5.18.0`, and `matplotlib==3.11.2`; `pip freeze --all` records resolver versions in the uploaded artifact. No app runtime dependency is added.

The script renders five 192 dpi white-background mathtext inputs: `F=ma`, `E=mc^2`, `\frac{1}{2}`, `\sum_{i=1}^{n} i`, and `\frac{\partial^2\psi}{\partial x^2}`. For each image it calls the pinned `PPFormulaNetImageProcessor` with `return_tensors="pt"`, then converts `pixel_values` to the exact dtype and shape declared by the Core ML encoder spec. Encoder and decoder load with `CPU_ONLY`. The script records actual input/output/state tensor names, shapes, and dtypes and aborts if the observed signatures disagree with the pinned expectations. Decoder calls use a fresh Core ML state per image, start token 2 at position 0, a causal mask, EOS token 2, and at most 256 decoding steps. Generated IDs are decoded only with `tokenizers.decoders.ByteLevel`; the `tokens.txt` strings are not concatenated as Unicode.

Each sample has a 90 second best-effort deadline checked before and after model calls; Python's signal cannot guarantee immediate interruption while native Core ML code is blocked. The 35 minute GitHub job timeout is the outer hard limit. If a timeout or another error occurs, the JSON retains all token IDs and any decodable partial output produced so far, marks that sample failed, and the workflow fails. The report records model-load and inference-stage peak RSS separately, plus per-sample elapsed time, expected LaTeX, raw predicted LaTeX, token IDs, normalized strings, and exact-match result.

Exact match removes whitespace only from these synthetic math strings before comparing literal LaTeX. It performs no AST comparison, symbol repair, inferred annotation, or structural scoring. The workflow's `passed` status means only that all five self-generated fixtures completed and matched after that whitespace normalization. Any mismatch or inference failure leaves the actual report and fixture PNGs in the always-uploaded artifact and makes the workflow fail.

## Local static validation

Windows can check syntax and verify the allowlisted small downloads without loading Core ML:

```powershell
python -c "import ast,pathlib; ast.parse(pathlib.Path('scripts/qualify_math_model.py').read_text(encoding='utf-8')); print('AST_OK')"
python scripts/qualify_math_model.py --validate-downloads-only --small-files-only --model-dir "$env:TEMP\ppformulanet-small-file-check"
```

The small-file mode verifies the pinned manifests, model specifications, tokenizer, configs, license, and processor config. It does not run inference and cannot establish that Core ML compiles on macOS.

## Evidence limits

These five formulas are generated by the qualification script and are not human-annotated samples. Whitespace-normalized exact match is a small decoding smoke check, not semantic accuracy, structural accuracy, a production model qualification, or evidence of iPad performance. An actual result must come from a completed macOS Core ML run. Real G4 claims still require an independently annotated corpus and device evidence; this workflow alone supplies neither.
