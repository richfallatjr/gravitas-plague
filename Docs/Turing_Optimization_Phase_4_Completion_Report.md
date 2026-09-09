# Turing optimization Phase 4 completion report

## 2026-09-07 retention clarification

Phase 4 is retained and must not be removed or treated as an abandoned
experiment. The owner explicitly directed the optimization program to advance
to Phase 5 while preserving the Stage 4 streaming work, with one promotion
condition: the live streaming path must not slow Qwen generation or regress
speech continuity.

The current growing-prefix decoder cannot satisfy that condition because it
re-decodes the complete accumulated prefix at every eight-row boundary on the
same MLX/Metal execution path used by both Fresh2 generation lanes. It is kept
as a correctness oracle and integration seam, not forced into audible shipping
playback. Phase 5 therefore measures the current two-lane/default-stream path
against supported lane/stream candidates before any production selection.

This clarification supersedes any wording below that could be read as an
instruction to delete or permanently deactivate Stage 4. It does not authorize
a topology change based on estimates: Fresh2 remains the production control
until automatic BEFORE/AFTER evidence demonstrates neutral-or-better
generation speed, correct speech/order, and acceptable playback continuity.

## Final status

- Decision: BLOCKED for production activation
- Retained result: qualification-only incremental generation, output-processing,
  and spatial PCM transport foundations
- Shipping playback: unchanged file-backed whole-segment path
- Starting commit: `e4c5e5e0047f9f1e76d68f2468d8dc13e5357945`
- Branch: `main`
- Fresh Qwen instance count before/after: 2 / 2
- Generation permit count before/after: 2 / 2
- Production residency mode before/after: `independentFresh2` /
  `independentFresh2`
- Production GPU admission before/after: `currentOverlap` / `currentOverlap`
- Stage 3 engine-owned tokenizer: retained
- Model, quantization, sampling, seeds, 160-row quality ceiling, Foundation
  Models prompting, story segmentation, and authored content: unchanged

Phase 4's production definition is that PCM becomes audible before its
utterance finishes generating. The repository now contains the isolated seams
needed to qualify that design, but the supplied Vision Pro evidence proves the
current generator cannot feed an underrun-free stream. There is consequently
no production activation and no speed claim.

## Device evidence recorded before Phase 4

The complete 2026-09-07 capture is preserved at:

```text
/Users/richardfallat/.codex/attachments/f3a0bf3f-417a-481e-8719-c9136c18c6ab/pasted-text.txt
```

Its two important events have different owners:

1. An earlier Qwen request encountered a real
   `MTLCommandBufferErrorDomain / 1` failure in
   `speechDecoder.decoder.0`. Phase 2R containment unloaded the failed pool,
   reconciled MLX active/cache memory to zero, and a later same-launch Qwen run
   succeeded. This is recovery evidence, not proof that the underlying Metal
   failure is eliminated.
2. The terminal user-visible stall was not Qwen or process death. Dad run
   `2FC698F1-7A17-40CA-A7F5-25A525F3F2C2.legacy` generated, decoded, and
   published all five segments with 23,242 submitted and 23,242 completed
   command buffers, no command-buffer failures, and no admission-invariant
   failures. After the 1.63-second
   `missingFiller.firstSegmentPreroll.generatedReady` timer completed, the
   playback scheduler did not wake. Its cursor remained at segment zero while
   generated segments `[0, 1, 2, 3, 4]` remained pending. Ambient playback and
   the event loop continued until the owner quit.

The terminal stall is therefore recorded as a separate missed scheduler wake
during a cross-flow compute-ahead handoff. It is not used as a reason to alter
Qwen concurrency. Full evidence is also appended to
`Docs/Turing_System_Stability_Architect_Handoff.md`.

## Retained Stage 4 foundations

### Incremental codebook producer

- The real BaseClone autoregressive loop can emit an immutable window after
  every eight committed generated rows and flush a final partial window.
- Eight rows represent 15,360 samples, or 0.64 seconds at 24 kHz.
- Stream identity includes run, segment, lane instance, voice, and recovery
  generation.
- Every window contains an immutable generated prefix plus the exact newly
  committed row range. Rewritten, missing, duplicate, and reordered prefixes
  are rejected.
- Event publication does not await a decoder or audio consumer in the Qwen hot
  loop.
- Per-render streams close on their first unique terminal. Deliberately shared
  collectors close only after the configured number of distinct render
  terminals, so one sibling cannot close another sibling's stream.
- The configuration is `.disabled` by default at both the FreshInstance and
  BaseClone call boundaries. There is no production activation call site.

### Growing-prefix decoder oracle

- A qualification-only decoder can recompute the full
  reference-plus-generated prefix and expose only the new, row-aligned suffix.
- Construction validates the installed speech decoder's 1,920 samples per row
  and 24 kHz output against the Stage 4 constants.
- This is a parity oracle, not the final rolling decoder. It repeats prior
  decoder work, has not passed real-model full-versus-prefix PCM parity, and
  does not yet participate in the production GPU-admission and recovery
  coordinator. It must not run concurrently on device until those ownership
  boundaries are integrated.

### Stateful output processing

- The existing 0.85-rate deterministic WSOLA implementation was moved into a
  shared primitive without changing the shipping output algorithm.
- The streaming processor retains cumulative state, emits only a conservative
  immutable prefix, holds the unresolved tail, applies one leading fade and a
  final-only trailing fade, and rejects any previously emitted Float whose bit
  pattern changes.
- Ordered input/output chunk indices and exact sample offsets are enforced.
- Mono and stereo chunk assembly match the retained one-shot implementation
  bit-for-bit in the focused harness.

### Spatial PCM transport

- A fixed-capacity, preallocated, single-producer/single-consumer Float32 ring
  feeds RealityKit's realtime `AudioGeneratorController` callback.
- The producer performs stateful mono 24 kHz to 48 kHz conversion; the realtime
  callback performs no allocation, locking, logging, task creation, or actor
  hop.
- Capacity is eight seconds. The nominal startup watermark is 0.75 seconds, so
  one 0.64-second Qwen window cannot start playback and two windows cross the
  watermark.
- Whole chunks are accepted atomically with bounded backpressure. Sequence
  number and source-frame offset must be exact.
- Seal/drain, pause/resume/stop, first-rendered-PCM clock capture, one logical
  start/completion, and underrun/frame metrics are implemented.
- The generated source remains attached to the same RealityKit spatial emitter
  hierarchy as file-backed device speech.
- The existing `play(_:)` implementation is unchanged, and no flow calls the
  new `openPCMStream`, `appendPCMStream`, or `sealPCMStream` methods.

## Hard queue-economics result

The device trace observed approximately 0.515 seconds of compute per generated
row. One row represents only 0.080 seconds of audio, so the measured lane
produces about 0.155 seconds of speech per wall-clock second.

For the captured 31-row utterance, the implemented eight-row producer can emit
only at cumulative row counts:

```text
8, 16, 24, 31
```

Starting at row 24 would provide 1.920 seconds of audio, but the final seven
rows require approximately 3.605 seconds at the observed cadence. The queue
would underrun by at least 1.685 seconds even if decoding, conversion, GPU
contention, scheduling jitter, and callback overhead were all free. Row 31 is
the first safe emitted boundary, but generation is already complete there, so
it is not streaming.

Starting from the first eight-row/0.64-second window requires generation at no
slower than 0.080 seconds per row merely to avoid a deterministic underrun.
That is approximately 6.44 times faster than the captured 0.515-second row
cadence, before adding the directive's 1.5x-realtime sustained margin. The
nominal 0.75-second PCM watermark cannot change those producer economics.

The activation gate now evaluates actual window-arrival boundaries, including
the final partial window. It rejects non-boundary starts, any start that cannot
survive every later arrival, and whole-utterance starts that do not satisfy the
definition of streaming.

## Safety blockers before any device activation

1. Integrate incremental decoder work into the existing MLX GPU-admission,
   failure epoch, cancellation, and same-launch recovery ownership. The current
   oracle must not bypass those protections.
2. Replace growing-prefix recomputation with measured persistent decoder state
   for transformer and causal convolution history; otherwise repeated decode
   work can erase any latency benefit and increase Metal pressure.
3. Prove real-model PCM parity between one canonical full decode and the
   concatenated incremental suffixes, including boundaries and final flush.
4. Resolve the irreversible quality-policy problem. Today EOS/160-row and
   decoded silence/identity checks occur after generation or decode; production
   playback cannot expose audio that may later be rejected by those gates.
5. Achieve measured generation and decoder cadence that survives the bounded
   queue with zero underruns. The directive's sustained production gate remains
   at least 1.5x realtime.
6. Only then connect codebook events to decoder, streaming WSOLA, the PCM
   endpoint, actual playback clock, lip sync, cancellation, and story
   continuity behind a controlled device qualification mode.

## Verification

- Qwen-native Stage 4 tests: PASS, 6/6
- Existing segment-pipeline regression tests: PASS, 7/7
- Existing first-lane-failure cancellation regression: PASS, 1/1
- Streaming WSOLA standalone parity: PASS for mono and stereo, bit-for-bit
- PCM standalone harness: PASS for ring wrap/order, underrun accounting,
  sequence rejection, unchanged rejected-chunk metrics, and stateful 24-to-48
  kHz conversion; 3,648 source frames produced exactly 7,296 output frames
  including converter drain
- Generic visionOS Debug app build with Xcode 27: PASS
- New app XCTest sources: compiled without diagnostics
- Full app test-target execution: BLOCKED by unrelated stale existing test
  compilation failures
- Full Qwen package execution: BLOCKED on this host when MLX tests requiring the
  default Metal library run; the focused non-MLX suites above pass
- `git diff --check`: PASS
- Real-model incremental PCM parity: not run
- Vision Pro incremental playback: intentionally not run
- Thirty-minute zero-underrun qualification: not run
- Release no-debugger/capture/TestFlight qualification: not run

## Disposition and next phase

The foundations are retained because they create the exact observability and
transport boundaries needed for a future safe implementation while leaving the
stable product untouched. Phase 4 itself is not promoted and must not be
described as a completed runtime speedup.

The next useful optimization work is below this playback layer: measured
persistent decoder state and enough Qwen row-throughput improvement to clear
the queue gate. Another ordinary gameplay run cannot qualify this dormant path;
it would exercise the unchanged shipping path only.
