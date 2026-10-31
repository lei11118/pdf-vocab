"""Build the offline lexical index from versioned, attributed source data."""
import gzip,hashlib,json,sqlite3,urllib.request,xml.etree.ElementTree as ET
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'Resources'/'LexicalSources'
CACHE=ROOT/'tools'/'lexical-cache'

def fetch(url,name):
    CACHE.mkdir(parents=True,exist_ok=True)
    path=CACHE/name
    if not path.exists():
        with urllib.request.urlopen(url,timeout=120) as response: data=response.read()
        path.write_bytes(data)
    return path

def build():
    OUT.mkdir(parents=True,exist_ok=True)
    xml=fetch('https://en-word.net/static/english-wordnet-2025.xml.gz','english-wordnet-2025.xml.gz')
    licenses={
      'OEWN-LICENSE.txt':'https://raw.githubusercontent.com/globalwordnet/english-wordnet/main/LICENSE.md',
      'Princeton-WNDB-LICENSE.txt':'https://raw.githubusercontent.com/globalwordnet/english-wordnet/main/WNDB_License.txt'}
    for name,url in licenses.items(): (OUT/name).write_bytes(fetch(url,name).read_bytes())
    target=OUT/'lexical.sqlite'
    stage=CACHE/'lexical-building.sqlite'
    if stage.exists(): stage.unlink()
    db=sqlite3.connect(stage)
    db.executescript("""
    CREATE TABLE membership(lemma TEXT NOT NULL,synset TEXT NOT NULL,pos TEXT NOT NULL,PRIMARY KEY(lemma,synset));
    CREATE TABLE synset(id TEXT PRIMARY KEY,definition TEXT NOT NULL);
    CREATE TABLE morphology(lemma TEXT NOT NULL,morpheme TEXT NOT NULL,kind TEXT NOT NULL,meaning TEXT NOT NULL,PRIMARY KEY(lemma,morpheme,kind));
    CREATE TABLE source(id TEXT PRIMARY KEY,url TEXT NOT NULL,license TEXT NOT NULL,sha256 TEXT NOT NULL);
    """)
    with gzip.open(xml,'rb') as stream:
        for event,elem in ET.iterparse(stream,events=['end']):
            tag=elem.tag.rsplit('}',1)[-1]
            if tag=='LexicalEntry':
                lemma=elem.find('Lemma')
                if lemma is not None:
                    word=lemma.get('writtenForm','').lower().strip();pos=lemma.get('partOfSpeech','')
                    db.executemany('INSERT OR IGNORE INTO membership VALUES(?,?,?)',[(word,sense.get('synset'),pos) for sense in elem.findall('Sense') if sense.get('synset')])
                elem.clear()
            elif tag=='Synset':
                definition=elem.findtext('Definition','')
                db.execute('INSERT OR REPLACE INTO synset VALUES(?,?)',(elem.get('id'),definition))
                elem.clear()
    data=json.loads((OUT/'morphemes.json').read_bytes())
    for key,entry in data.items():
        meaning='; '.join(str(x) for x in entry.get('meaning',[]))
        for form in entry.get('forms',[]):
            root=form.get('root',key);kind=form.get('loc','root')
            for word in entry.get('examples',[]):
                if isinstance(word,str) and word.strip():
                    stem=str(form.get('form',root)).strip('- ').lower()
                    candidate=word.strip().lower()
                    # Source-listed examples AND a compatible positional form are
                    # required. No suffix stripping / lemma-as-root inference.
                    if not stem: continue
                    if kind=='prefix' and not candidate.startswith(stem): continue
                    if kind=='suffix' and not candidate.endswith(stem): continue
                    if kind not in ('prefix','suffix') and stem not in candidate: continue
                    db.execute('INSERT OR IGNORE INTO morphology VALUES(?,?,?,?)',(word.strip().lower(),root,kind,meaning))
    sources=[('oewn-2025','https://en-word.net/downloads','CC-BY-4.0 and Princeton WordNet License',hashlib.sha256(xml.read_bytes()).hexdigest()),
             ('morphemes','https://github.com/colingoldberg/morphemes','MIT',hashlib.sha256((OUT/'morphemes.json').read_bytes()).hexdigest())]
    db.executemany('INSERT INTO source VALUES(?,?,?,?)',sources)
    db.executescript('CREATE INDEX membership_synset ON membership(synset); CREATE INDEX morphology_root ON morphology(morpheme,kind);')
    stats={name:db.execute('SELECT COUNT(*) FROM '+name).fetchone()[0] for name in ['membership','synset','morphology']}
    db.commit();db.execute('VACUUM');db.close()
    target.write_bytes(stage.read_bytes())
    (OUT/'coverage.json').write_text(json.dumps({'counts':stats,'sources':sources,'policy':'Morphology: explicit source examples only. Synonyms: shared English sense IDs. Chinese gloss matches alone are not confirmed edges.'},indent=2),encoding='utf-8')
    print(json.dumps(stats));print('SQLite bytes',target.stat().st_size)
if __name__=='__main__':build()
