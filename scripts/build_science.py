"""Build attributed ECDICT subject subsets from the full source, not the slim DB."""
import json
import re
import sqlite3
import urllib.request
from pathlib import Path
from build_dict import ensure_zip, ensure_db, SRC_DB

DOMAINS = {
    "math": ["数", "数学"], "physics": ["物", "物理", "电"],
    "chemistry": ["化", "化学"], "medicine": ["医", "医学", "药"],
    "biology": ["生", "生物", "植", "动", "微"],
    "computing": ["计", "计算机"], "engineering": ["机", "建", "冶", "化工", "工程"],
    "earth": ["地", "地质", "天", "气象", "矿"],
}

def build():
    ensure_zip(); ensure_db()
    root = Path(__file__).resolve().parents[1]
    source = sqlite3.connect(f"file:{SRC_DB}?mode=ro", uri=True)
    table = next(name for (name,) in source.execute("SELECT name FROM sqlite_master WHERE type='table'")
                 if {'word', 'translation', 'definition'} <= {r[1] for r in source.execute(f'PRAGMA table_info("{name}")')})
    target = root / 'Resources' / 'science.sqlite'
    stage = target.with_suffix('.building')
    if stage.exists(): stage.unlink()
    out = sqlite3.connect(stage)
    out.execute('CREATE TABLE dict(domain TEXT,word TEXT,phonetic TEXT,translation TEXT,definition TEXT,pos TEXT,collins INTEGER,oxford INTEGER,tag TEXT,bnc INTEGER,frq INTEGER,PRIMARY KEY(word,domain))')
    counts = dict.fromkeys(DOMAINS, 0)
    # Match explicit dictionary subject labels only; never infer a field from a word.
    labels = re.compile(r'[\[【]([^\]】]+)[\]】]')
    for row in source.execute(f'SELECT word,phonetic,translation,definition,pos,collins,oxford,tag,bnc,frq FROM "{table}"'):
        word, phonetic, translation, definition, pos, collins, oxford, tag, bnc, frq = row
        if not word or not translation: continue
        found = {x.strip() for label in labels.findall(translation) for x in re.split(r'[,，/、;；]', label)}
        for domain, terms in DOMAINS.items():
            if found.intersection(terms):
                out.execute('INSERT OR IGNORE INTO dict VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                            (domain, word.strip().lower(), phonetic, translation, definition, pos, collins, oxford, tag, bnc, frq))
                counts[domain] += 1
    if any(n == 0 for n in counts.values()):
        raise RuntimeError(f'Missing subject coverage: {counts}')
    out.commit(); out.execute('VACUUM'); out.close(); source.close()
    stage.replace(target)
    attribution = root / 'Resources' / 'ScienceSources'
    attribution.mkdir(exist_ok=True)
    license_url = 'https://raw.githubusercontent.com/skywind3000/ECDICT/master/LICENSE'
    (attribution / 'ECDICT-LICENSE.txt').write_bytes(urllib.request.urlopen(license_url, timeout=60).read())
    (attribution / 'manifest.json').write_text(json.dumps({
        'source': 'https://github.com/skywind3000/ECDICT/releases/tag/1.0.28',
        'license': 'MIT', 'transformation': 'Explicit subject labels from full ECDICT; categories overlap.',
        'counts': counts}, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(counts, sort_keys=True))

if __name__ == '__main__': build()
