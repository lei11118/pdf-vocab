# Context translation cache and alignment evaluation

## Persistent payload cache

`ContextTranslationService.shared` uses the optional `AppDatabase` backed store. Newly constructed services keep persistence disabled by default, which keeps unit tests and injected translators isolated unless a store is passed explicitly. `clearCache()` keeps its existing in-memory-only behavior; `clearAllCaches()` clears both in-memory and persistent contextual-translation entries.

The disk identity is a SHA-256 digest of canonical JSON containing the document SHA, exact source text, every token ID and UTF-16 span, the verified phrase-group identity when present, source and target language identifiers, backend version, context-alignment algorithm version, and payload-snapshot schema version. Rows reference `document.sha256` with cascade deletion. The store limits each snapshot to 256 KiB and total retained snapshots to 16 MiB, evicting least-recently-used rows transactionally.

The Apple backend identity includes the runtime operating-system version, so an OS upgrade gets a separate cache identity. Language-pack updates can happen independently and are not represented as model-version identities; after a language-pack update, clear the cache and perform a real quality evaluation.

Snapshots keep source and target text plus only the token-ID and phrase-group-ID UTF-16 runs. Text lengths, run counts, identifiers, payload bytes, and composed-character boundaries are bounded and checked before reconstruction. A loaded snapshot is only a candidate: every use still runs `ContextualTranslationAlignment.decode` against the current selection. Corrupt data, missing attributes, or an unaligned current token becomes a cache miss and invokes the translator again. Cache reads and writes are best-effort and do not turn cache failures or a not-yet-imported document into a translation failure.

## G4 alignment metrics

`AlignmentEvaluationMetrics` operates on exact links of `(source occurrence UTF-16 span, target UTF-16 span)`. It scores repeated spellings as separate occurrences and supports phrase links that map several source spans to one target span.

- Precision is exact predicted links divided by predicted links.
- Recall is exact predicted links divided by reference links.
- F1 is `2 × exact links / (predicted links + reference links)`; it is zero when one nonempty set has no matching links and nil only when both link sets are empty.
- Coverage is the proportion of supplied source occurrences with at least one predicted link, whether correct or incorrect.
- Rejection rate is the proportion of supplied source occurrences with no predicted link. Both coverage and rejection rate are nil when no source occurrences were supplied.

`Tests/AlignmentEvaluationTests.swift` and `Tests/ContextTranslationPersistenceTests.swift` use synthetic, explicitly constructed spans and marker attributes. They verify metric arithmetic, cache identity and invalidation, persistence bounds, and migration-table isolation. These fixtures do not measure semantic translation accuracy, do not constitute human gold labels, and do not establish Apple Translation or any model's real-document alignment quality.

## Running the focused tests

On a Mac with Xcode and XcodeGen, first list available iOS Simulator destinations:

```sh
xcrun simctl list devices available
```

After generating the project if needed, run the focused test classes with an available simulator UDID:

```sh
xcodegen generate
xcodebuild test -project PdfVocab.xcodeproj -scheme PdfVocab \
  -destination 'platform=iOS Simulator,id=<available-simulator-udid>' \
  -only-testing:PdfVocabTests/ContextTranslationPersistenceTests \
  -only-testing:PdfVocabTests/AlignmentEvaluationTests
```

## Evidence still needed for semantic-quality claims

Before reporting real-world G4 quality, assemble a permissioned corpus spanning text PDFs, OCR scans, repeated words, verified phrases, inflections, and ambiguous contexts. Annotate source and target spans independently, retain occurrence identity, and record the language pair, OS/model/backend version, selection, output, and explicit rejection. Report precision, recall, F1, coverage, and rejection rate with corpus size and per-category results. Keep synthetic unit fixtures separate from those annotations. Device and language-pack conditions must be recorded for Apple Translation; these tests alone provide no evidence of its semantic accuracy.
