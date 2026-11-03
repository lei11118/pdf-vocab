# Reader windows and contextual meaning — v0.64.0

All reader-owned panels share ReaderWindowSurface with the word card: the drag strip, round geometry, white corner grip, resize bounds and compact capsule. Expanded panels isolate their NavigationStack, toolbar preferences and dismiss environment in a child UIHostingController. System file/share pickers and system translation language authorization retain native presentation. Nested vocabulary detail, graph, context and Anki configuration panels use this shell when reached from the reader.

The word card again has compact capsule and full card modes. Press minus to compact; double tap the capsule or resize its white grip to expand. Compact mode retains complete definitions in a scrollable area; drag its top edge to move without stealing definition scrolling. Existing reviewed data and dictionary meanings remain available.

Preparation starts on the current page, publishes each page before the next and reprioritizes on navigation. Photo pages are OCR-recognized on a background executor. OCR v4 keeps letters, digits and punctuation and checkpoints individual pages. Translation takes four nearby sentences at a time and avoids dictionary queries across the whole book. A source page does not wait for OCR of the rest of the book. Page preparation and batch timing are logged without document text.

Contextual meanings are occurrence-bound, separate from dictionary senses. On iPadOS 26+ with available Apple Intelligence, a guided on-device response supplies a specific Chinese gloss and contextual clue, or abstains. Otherwise on iPadOS 18+ a single marked occurrence is translated in its original sentence; the gloss is accepted only if exactly one correctly ordered marker pair survives and contains translated Chinese text. Missing, duplicated, reordered and untranslated spans are rejected. Neither method proves correctness; output remains an editable machine suggestion. Old dictionary-overlap hints are removed from the automatic context display while human reviews are preserved. Full sentence translation and all enabled dictionary sources remain visible.

Primary API references:
- https://developer.apple.com/documentation/translation/
- https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models
- https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation

Validation includes real application UI clicks for reading and writing routes and unit/integration tests for raster PDF OCR, current-page streaming, occurrence-based meanings, marker rejection and cache merging. The route-audit launch argument only exists in Debug and bypasses model downloads; it does not test translation quality. Simulator checks do not establish real iPad Pencil behavior, end-to-end translation latency, language model availability or translation accuracy. These require device validation.
