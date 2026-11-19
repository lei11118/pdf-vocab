#!/usr/bin/env python3
"""Compare the production Qwen gloss route against reviewed reference phrases."""
import argparse
import hashlib
import json
import re
import socket
import statistics
import subprocess
import textwrap
import time
import unicodedata
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
QWEN_4B_SHA = "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"
RUNTIME = ROOT / "Packages/TranslationRuntime/Sources/LlamaRuntime/MetalTranslationSession.swift"
APP_PROMPT = ROOT / "Sources/ContextReading/LocalContextTranslation.swift"


def read_runtime():
    # Read the same prompt and grammar used by the app. A change in their
    # Swift declarations should fail the audit instead of testing a stale copy.
    code = APP_PROMPT.read_text(encoding="utf-8")
    implementation = code.split("func qwenPrompt(", 1)[1].split("func decode(", 1)[0]
    template = textwrap.dedent(implementation.split('return """\n', 1)[1].split('"""', 1)[0]).strip()
    assert r"\(marked)" in template and r"\(correction)" in template
    recheck = re.search(r'\? ("复核[^"]+")', implementation).group(1)
    runtime = RUNTIME.read_text(encoding="utf-8")
    grammar = textwrap.dedent(runtime.split('shortGlossGrammar = #"""', 1)[1].split('"""#', 1)[0]).strip()
    context_length = int(re.search(r"contextLength = (\d+)", runtime).group(1))
    return template, json.loads(recheck), grammar, context_length


def selected_marks(case):
    text, selection = case["text"], case["selection"]
    end = 0
    for _ in range(case.get("occurrence", 1)):
        start = text.index(selection, end)
        end = start + len(selection)
    def escape(value):
        return value.replace("<", "＜").replace("【", "［").replace("】", "］")
    return f"{escape(text[:start])}【{escape(selection)}】{escape(text[end:])}"


def normalize(meaning):
    return unicodedata.normalize("NFKC", meaning).strip(" \t。.!！“”\"")


def is_weak_negation(source, meaning):
    words = source.lower().replace("’", "'").split()
    return (len(words) >= 2
            and any(word == "not" or word.endswith("n't") for word in words[:-1])
            and meaning in {"不", "没有", "没", "未", "并不", "无"})


def run_case(case, send, template, recheck, grammar):
    source = case["selection"].lower().replace("’", "'")
    lexical = {"don't": "不", "doesn't": "不", "didn't": "没有", "hardly": "几乎不", "scarcely": "几乎不"}
    if source in lexical:
        return lexical[source], []
    marked = selected_marks(case)
    def generate(correction):
        body = template.replace(r"\(correction)", correction).replace(r"\(marked)", marked)
        prompt = "<|im_start|>user\n" + body + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        raw = send("/completion", {
            "prompt": prompt, "grammar": grammar, "n_predict": 96, "temperature": 0,
            "seed": 1234, "cache_prompt": False, "stop": ["<|im_end|>", "<|endoftext|>"],
        })["content"]
        try:
            value = json.loads(raw)["meaning"].strip()
        except (ValueError, TypeError, KeyError, AttributeError):
            return None, raw
        if len(value) > 80 or "\n" in value or not re.search("[\u3400-\u9fff]", value):
            return None, raw
        return value, raw
    meaning, raw = generate("")
    if is_weak_negation(source, meaning):
        checked, retry = generate(recheck)
        return ("无" if is_weak_negation(source, checked) else checked), [raw, retry]
    return meaning, [raw]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--model-sha", default=QWEN_4B_SHA)
    parser.add_argument("--fixture", required=True, nargs="+", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--threads", type=int, default=6)
    args = parser.parse_args()
    with args.model.open("rb") as model:
        if hashlib.file_digest(model, "sha256").hexdigest() != args.model_sha:
            parser.error("Model SHA-256 differs from the declared hash")
    template, recheck, grammar, context_length = read_runtime()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    endpoint = f"http://127.0.0.1:{port}"

    def send(path, payload=None):
        data = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
        request = Request(endpoint + path, data=data, headers={"Content-Type": "application/json"})
        with urlopen(request, timeout=90) as response:
            return json.load(response)

    rows = []
    with args.report.with_suffix(".log").open("w", encoding="utf-8") as log:
        server = subprocess.Popen([str(args.server), "-m", str(args.model), "--host", "127.0.0.1",
            "--port", str(port), "-t", str(args.threads), "-tb", str(args.threads),
            "-c", str(context_length), "-ngl", "0", "-np", "1", "--no-webui"], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline and server.poll() is None:
                try:
                    if send("/health")["status"] == "ok":
                        break
                except (URLError, ConnectionError):
                    time.sleep(0.25)
            else:
                raise RuntimeError(f"llama-server unavailable. See {log.name}")

            for fixture in args.fixture:
                cases = json.loads(fixture.read_text(encoding="utf-8"))
                for case in cases:
                    start = time.monotonic()
                    answer, attempts = run_case(case, send, template, recheck, grammar)
                    expected = case["accepted"] or ["无"]
                    rows.append(dict(case, fixture=fixture.name, meaning=answer, generated=attempts,
                                     wall_ms=round((time.monotonic() - start) * 1000),
                                     exact_reference=answer is not None
                                     and normalize(answer) in {normalize(term) for term in expected}))
                    args.report.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                results = rows[-len(cases):]
                print(f"{fixture.name}: {sum(row['exact_reference'] for row in results)}/{len(cases)} exact; "
                      f"median {statistics.median(row['wall_ms'] for row in results)} ms", flush=True)
        finally:
            server.terminate()
            try:
                server.wait(timeout=4)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main()

