#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 ECDICT 官方 SQLite 包构建「跃文」内置精简词库(Resources/ecdict.sqlite)。

- 数据源:ECDICT 1.0.28 release 的 ecdict-sqlite-28.zip(内含 stardict.db 全量);
- CI 缓存 zip 到 ~/.cache/pdfvocab/(避免每次重下 ~217MB);
- 精简策略:保留「词频 / BNC / 考试标签 / 柯林斯星级 / 牛津核心」任一命中的词条;
- 另建 form 表(词形 → 词头,覆盖 went→go 等不规则变形);
- 输出 Resources/ecdict.sqlite(不入库;CI 生成后随 App 打包)。
"""

import os
import shutil
import sqlite3
import urllib.request
import zipfile

ZIP_URL = "https://github.com/skywind3000/ECDICT/releases/download/1.0.28/ecdict-sqlite-28.zip"
CACHE_DIR = os.path.expanduser("~/.cache/pdfvocab")
CACHE_ZIP = os.path.join(CACHE_DIR, "ecdict-sqlite-28.zip")
SRC_DB = os.path.join(CACHE_DIR, "stardict.db")
OUT_DIR = "Resources"
OUT = os.path.join(OUT_DIR, "ecdict.sqlite")


def ensure_zip():
    if os.path.exists(CACHE_ZIP) and os.path.getsize(CACHE_ZIP) > 100_000_000:
        print(f"[dict] zip 缓存命中({os.path.getsize(CACHE_ZIP) / 1e6:.0f} MB)")
        return
    os.makedirs(CACHE_DIR, exist_ok=True)
    print(f"[dict] 下载 {ZIP_URL}")
    urllib.request.urlretrieve(ZIP_URL, CACHE_ZIP + ".part")
    os.replace(CACHE_ZIP + ".part", CACHE_ZIP)
    print(f"[dict] 下载完成 {os.path.getsize(CACHE_ZIP) / 1e6:.0f} MB")


def ensure_db():
    if os.path.exists(SRC_DB) and os.path.getsize(SRC_DB) > 50_000_000:
        print(f"[dict] stardict.db 已就绪({os.path.getsize(SRC_DB) / 1e6:.0f} MB)")
        return
    print("[dict] 解压 stardict.db …")
    with zipfile.ZipFile(CACHE_ZIP) as zf:
        member = None
        largest = 0
        for name in zf.namelist():
            info = zf.getinfo(name)
            if name.lower().endswith(".db") and info.file_size > largest:
                member, largest = name, info.file_size
        if member is None:
            raise SystemExit(f"[dict] zip 中没有 .db 文件:{zf.namelist()[:10]}")
        with zf.open(member) as src, open(SRC_DB + ".part", "wb") as dst:
            shutil.copyfileobj(src, dst, 1024 * 1024)
    os.replace(SRC_DB + ".part", SRC_DB)
    print(f"[dict] 解压完成 {os.path.getsize(SRC_DB) / 1e6:.0f} MB")


def to_int(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return 0


def main():
    ensure_zip()
    ensure_db()

    src = sqlite3.connect(f"file:{SRC_DB}?mode=ro", uri=True)
    tables = [r[0] for r in src.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    table = "stardict"
    if table not in tables:
        table = None
        for t in tables:
            cols = {r[1] for r in src.execute(f"PRAGMA table_info({t})")}
            if "word" in cols:
                table = t
                break
    if table is None:
        raise SystemExit(f"[dict] 找不到词表:{tables}")

    cols = {r[1] for r in src.execute(f"PRAGMA table_info({table})")}
    for required in ("word", "translation", "definition"):
        if required not in cols:
            raise SystemExit(f"[dict] 表 {table} 缺少必需列 {required};实际列:{sorted(cols)}")

    def c(name, fallback):
        return name if name in cols else f"({fallback}) AS {name}"

    conds = []
    if "frq" in cols:
        conds.append("CAST(frq AS INTEGER) > 0")
    if "bnc" in cols:
        conds.append("CAST(bnc AS INTEGER) > 0")
    if "tag" in cols:
        conds.append("IFNULL(tag, '') != ''")
    if "collins" in cols:
        conds.append("CAST(collins AS INTEGER) > 0")
    if "oxford" in cols:
        conds.append("CAST(oxford AS INTEGER) > 0")
    if not conds:
        raise SystemExit("[dict] 源库没有任何可用的筛选列")
    where = "word IS NOT NULL AND length(word) <= 40 AND (" + " OR ".join(conds) + ")"

    select_sql = (
        "SELECT word, "
        + ", ".join(
            [
                c("phonetic", "NULL"),
                c("translation", "NULL"),
                c("definition", "NULL"),
                c("pos", "NULL"),
                c("collins", "0"),
                c("oxford", "0"),
                c("tag", "NULL"),
                c("bnc", "0"),
                c("frq", "0"),
                c("exchange", "NULL"),
            ]
        )
        + f" FROM {table} WHERE {where}"
    )

    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.exists(OUT):
        os.remove(OUT)
    out = sqlite3.connect(OUT)
    cur = out.cursor()
    cur.execute("PRAGMA journal_mode=OFF")
    cur.execute("PRAGMA synchronous=OFF")
    cur.execute(
        "CREATE TABLE dict("
        "word TEXT PRIMARY KEY, phonetic TEXT, translation TEXT, definition TEXT, "
        "pos TEXT, collins INTEGER DEFAULT 0, oxford INTEGER DEFAULT 0, tag TEXT, "
        "bnc INTEGER DEFAULT 0, frq INTEGER DEFAULT 0, exchange TEXT)"
    )
    cur.execute("CREATE TABLE form(form TEXT PRIMARY KEY, word TEXT)")

    total = kept = forms = 0
    batch_d, batch_f = [], []
    for row in src.execute(select_sql):
        total += 1
        (word, phonetic, translation, definition, pos, collins_v, oxford_v, tag_v, bnc_v, frq_v, exchange) = row
        word = (word or "").strip().lower()
        if not word or not word.replace("-", "").replace("'", "").replace(".", "").replace(" ", "").isalpha():
            continue
        if not ((translation or "").strip() or (definition or "").strip()):
            continue
        kept += 1
        batch_d.append(
            (
                word,
                (phonetic or "").strip() or None,
                (translation or "").strip() or None,
                (definition or "").strip() or None,
                (pos or "").strip() or None,
                to_int(collins_v),
                to_int(oxford_v),
                (tag_v or "").strip() or None,
                to_int(bnc_v),
                to_int(frq_v),
                (exchange or "").strip() or None,
            )
        )
        exchange_text = (exchange or "").strip()
        if exchange_text:
            for part in exchange_text.split("/"):
                if ":" not in part:
                    continue
                tag_part, form_part = part.split(":", 1)
                form_part = form_part.strip().lower()
                if tag_part != "0" and form_part and form_part != word:
                    batch_f.append((form_part, word))
                    forms += 1
        if len(batch_d) >= 5000:
            cur.executemany("INSERT OR REPLACE INTO dict VALUES(?,?,?,?,?,?,?,?,?,?,?)", batch_d)
            batch_d = []
        if len(batch_f) >= 5000:
            cur.executemany("INSERT OR IGNORE INTO form VALUES(?,?)", batch_f)
            batch_f = []
    if batch_d:
        cur.executemany("INSERT OR REPLACE INTO dict VALUES(?,?,?,?,?,?,?,?,?,?,?)", batch_d)
    if batch_f:
        cur.executemany("INSERT OR IGNORE INTO form VALUES(?,?)", batch_f)
    out.commit()
    cur.execute("VACUUM")
    out.commit()
    out.close()
    src.close()

    size = os.path.getsize(OUT)
    print(f"[dict] 完成:候选={total} 保留={kept} 词形={forms} 大小={size / 1e6:.1f} MB -> {OUT}")
    if kept < 50_000:
        raise SystemExit("[dict] 保留词条过少,筛选可能出错,中止构建")
    if size > 160_000_000:
        print("[dict] 警告:词库偏大(>160MB),考虑收紧筛选条件")


if __name__ == "__main__":
    main()
