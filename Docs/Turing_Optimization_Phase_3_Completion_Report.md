# Turing optimization Phase 3 completion report

## Final status

- Decision: BLOCKED
- Candidate disposition:
  - diagnostic only
- Starting commit: `3f85a367683704eb91b8c747ddc3f58ae24011e6`
- Branch: `main`
- Dirty worktree preserved: yes; no unrelated owner changes were reset, deleted, staged, or committed
- Files added: 39 Phase 3-owned files: 14 package sources, 13 package tests, one app configuration, three app tests, seven host-script/config/test files, and this report
- Files modified: 21 Phase 3-owned files across the app integration, Qwen-native package, vendored MLX diagnostic context, and Phase 2 source audit; pre-existing dirty documentation, story, Mind's Eye, script-point, project-setting, and image changes remain preserved
- Files removed: none
- Owner files reset: none
- Production lane count before/after: 2 / 2
- Production worker count before/after: 2 / 2

## Phase 1 prerequisite

- currentOverlap: retained unchanged as the production/default admission behavior
- decodeExclusive: retained as an explicit qualification/control mode; not promoted
- Current selected admission mode: `currentOverlap`
- Admission tests: PASS; focused Phase 1/Phase 2 regression selection completed 18/18 tests, including two-generation-lease overlap, decode exclusivity, cancellation, stale release, and first-lane-failure handling
- Admission invariants after Phase 3: two generation lanes, two worker tasks, the open segment queue, decoder coordination, callbacks, and admission ownership are unchanged; residency identity is diagnostic context only

## Phase 2 prerequisite

- Non-throwing Metal callback: present in the vendored MLX containment path; source and focused regression checks pass
- Typed MLX failure: `TuringQwenNativeMetalFailure` retained
- Circuit breaker: retained launch-lifetime fail-closed behavior with no shared-residency bypass or fallback
- Selected command-buffer profile: qualification control `operations40Megabytes32`; Debug device builds currently request it, while normal Release remains `deviceDefault`
- Command-buffer tests: PASS in focused host tests; the Phase 2 source audit and 3/3 host tests pass
- Phase 2 unresolved blockers: both device-tested profiles previously produced a Metal command-buffer failure; no safe profile is promoted, and Vision Pro pressure/capture/archive qualification remains outstanding

## Residency architecture

- Selected mode: `independentFresh2` remains the production default; `sharedImmutableFresh2` is an explicit compile-time/qualification candidate
- Shared owner count: candidate contract 1; device evidence not measured
- Shared resource count: candidate contract 1; validated by ownership audit/tests, device evidence not measured
- Shared weight-store count: candidate contract 1; validated by ownership audit/tests, device evidence not measured
- Shared clone-conditioning count: candidate contract 1; validated by ownership audit/tests, device evidence not measured
- Lane engine count: 2
- Lane mutable-state count: 2
- Static prompt-cache owner count: 2
- Talker KV owner count: 2
- Code-predictor KV owner count: 2
- Sampler owner count: 2
- Decoder session count: 1
- Fallback used: false; fallback and reduced shipping topology are rejected

## Immutability audit

- Config immutable: yes; shared resident resources retain a validated configuration through `let`
- Weight dictionary immutable: yes; one private `let` dictionary is loaded once from `model.safetensors`
- Talker weights immutable: yes; resolved handles are retained by the immutable resource owner
- Code-predictor weights immutable: yes; resolved handles are retained by the immutable resource owner
- Shared parameter output/inout uses: none found by the source audit in the shared owner/load/engine binding path
- Shared parameter donation risk: no explicit donation or shared-parameter update path found; on-device concurrent proof remains required
- Mutable caches in shared owner: none; static prompt contexts, talker/code-predictor KV caches, samplers, request state, and release identity are lane-owned
- Sampled qualification guard: PASS implementation/build; under `GR_TURING_QUALIFICATION` it samples embedding, attention, MLP, and code-predictor tensors at first/center/last/seeded-interior positions before and after the two-lane run; deterministic host test passes
- Concurrent read canary: BLOCKED pending the required 25-run Vision Pro canary and sanitizer evidence

## Clone conditioning

- Loader count independent: contract 2, one per independent engine; device count not measured
- Loader count shared: contract 1, owned by the shared residency loader; device count not measured
- Voice identity: validated against the selected clone profile
- Variant identity: validated against the selected clone profile before shared use
- Reference token ownership: one immutable shared conditioning object in the candidate
- Reference-code ownership: one immutable shared conditioning object in the candidate
- Speaker-embedding ownership: one immutable shared conditioning object in the candidate
- Lane prompt contexts separate: yes; two unique static prompt-context identities are required and tested

## Independent Fresh2 baseline

- Runs: 0 Phase 3 controlled device runs
- Unique resource owners: expected 2; host ownership audit passes, device measurement pending
- Unique weight stores: expected 2; host ownership audit passes, device measurement pending
- Pool-ready physical footprint P50/P95: not measured
- Pool-ready MLX active/cache P50/P95: not measured
- Second-instance incremental footprint: not measured
- Minimum available memory: not measured
- Response peak physical footprint: not measured
- Response peak MLX active/cache: not measured
- Session-ready P50/P95: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured
- Aggregate real-time factor: not measured
- Post-unload footprint: not measured
- Output fingerprints: qualification capture implemented; no controlled device artifacts captured
- Crashes/failures: not measured for the Phase 3 baseline

## Shared immutable Fresh2 candidate

- Runs: 0 Phase 3 controlled device runs
- Unique resource owners: expected 1; host ownership audit passes, device measurement pending
- Unique weight stores: expected 1; host ownership audit passes, device measurement pending
- Pool-ready physical footprint P50/P95: not measured
- Pool-ready MLX active/cache P50/P95: not measured
- Second-lane incremental footprint: not measured
- Minimum available memory: not measured
- Response peak physical footprint: not measured
- Response peak MLX active/cache: not measured
- Session-ready P50/P95: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured
- Aggregate real-time factor: not measured
- Post-unload footprint: not measured
- Output fingerprints: qualification capture and comparison tools implemented; no controlled device artifacts captured
- Crashes/failures: not measured for the Phase 3 candidate

## Qualification-only one-lane control

- Compiled only in qualification: yes; construction is behind `GR_TURING_QUALIFICATION`, is not a shipping topology, and is rejected by normal production configuration
- Runs: 0
- Peak footprint: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured
- Aggregate real-time factor: not measured
- Difference from shared two-lane: not measured
- Shipping use: prohibited

## Memory savings

- Independent second-instance delta: not measured
- Shared second-lane delta: not measured
- Required savings gate: `max(256 MB, min(512 MB, independentSecondInstanceDeltaMB * 0.60))`
- Warm-pool savings: not measured
- Response-peak savings: not measured
- Available-memory gain: not measured
- MLX-active savings: not measured
- Reclaimed percentage of second-owner cost: not measured
- Material-savings gate: BLOCKED pending matched Release Vision Pro A/B artifacts

## Output and quality parity

- Text identity: experiment identity validation implemented; device parity not measured
- Seed identity: residency mode is excluded from seed identity and covered by a host contract test; device parity not measured
- Segment ordering: existing scheduler/open-queue path retained; device parity not measured
- EOS identity: not measured
- Row-count identity: not measured
- Codebook-count identity: not measured
- Codebook SHA identity: qualification capture implemented; not measured
- PCM SHA identity: qualification capture implemented; not measured
- Numeric tolerance if needed: no tolerance selected because no device comparison exists
- Duration/peak/RMS: comparison tool implemented; not measured
- Listening comparison: not performed
- Voice/variant contamination: identity checks and lane isolation are implemented; concurrent device proof pending

## Lane isolation

- Engine IDs unique: PASS host ownership contract
- Mutable-state IDs unique: PASS host ownership contract
- Static prompt caches unique: PASS host ownership contract
- Talker KV owners unique: PASS host ownership contract
- Code-predictor KV owners unique: PASS host ownership contract
- Sampler owners unique: PASS host ownership contract
- Lane 0 release while lane 1 active: lease registry permits the remaining lease and forbids early owner finish; focused tests pass
- Cancellation isolation: focused first-lane-failure and admission cancellation tests pass; device failure-path proof pending
- Data race evidence: BLOCKED; no Thread Sanitizer or Vision Pro concurrent canary was available on this host

## Teardown

- Lane release reports: implemented for both lane-local releases
- Shared leases at ready: contract exactly 2 for shared Fresh2
- Shared leases after finish: contract exactly 0
- Owner snapshot after finish: owner transitions to released and rejects stale access; device evidence pending
- Decoder sessions after finish: contract 0; device evidence pending
- Admission leases after finish: focused admission tests pass; device evidence pending
- Cache-clear count: shared path performs one final clear after lane leases and owner release; load failure/rollback has one separate failure clear; device count pending
- Immediate post-unload footprint: not measured
- 250 ms footprint: not measured
- 1 s footprint: not measured
- 3 s footprint: not measured
- Ten-cycle trend: not measured

## Pressure qualification

- Release no debugger: not run
- Xcode only: not run
- Capture only: not run
- Xcode + capture: not run
- Complete film: not run
- Repeated complete film: not run
- Ten targeted cold responses: not run
- Ten targeted repeated responses: not run
- Signed archive: not run
- Actual TestFlight: not run

## Product regressions

- Authored playback: no intentional change; app regression test source parses, device test pending
- Generated audio: existing generation/decode/callback path retained; device test pending
- Runtime phoneme lip sync: no intentional change; device test pending
- Filler lip sync: no intentional change; device test pending
- Mind’s Eye continuity: no ownership/cadence change; presentation regression test source parses, device test pending
- Actual speaker routing: no intentional change; device test pending
- Story progression: no intentional change; device test pending
- World/portal behavior: no intentional change; device test pending
- Model quality: unchanged by source contract; listening/device parity pending
- Quantization: 4-bit unchanged
- Sampling/seeds: unchanged by source contract; qualification identity and tests preserve them

## Tests and audits

- Shared-owner tests: PASS
- Lease tests: PASS
- Fresh-instance tests: PASS
- Lane-isolation tests: PASS
- Clone-conditioning tests: PASS
- Read-only weight tests: PASS; qualification guard build/test also passes
- Failure-rollback tests: PASS
- Output-parity tests: PASS at contract level; real-model device parity blocked
- Phase 1 regression tests: PASS
- Phase 2 regression tests: PASS
- Presentation regression tests: source parses; Xcode/device execution blocked
- Host scripts: PASS, 3/3 Phase 3 tests and 3/3 Phase 2 tests
- Source audits: PASS for Phase 3 and Phase 2; `git diff --check` passes; model and clone-profile directories are unchanged
- Build: Qwen-native package PASS normally and with `GR_TURING_QUALIFICATION`; app Swift integration parses; full app build BLOCKED because Xcode is not installed. A broad package test run is not claimed because pre-existing tests require a missing tokenizer fixture and a host MLX default Metal library.
- Archive: BLOCKED; Xcode is unavailable

## Phase 4 readiness

- Shared residency promoted: no; candidate remains diagnostic only
- Current selected admission mode: `currentOverlap`
- Current command-buffer profile: Release `deviceDefault`; fixed Phase 3 qualification control `operations40Megabytes32`
- Actual MLX stream/queue identities known: diagnostic fields propagate residency owner, weight-store, and lane-state identity, but matched Phase 3 device artifacts have not been captured
- Two-lane latency benefit: not measured
- Exact Phase 4 starting condition: run matched independent Fresh2, shared immutable Fresh2, and qualification-only one-lane Release experiments on Vision Pro; pass memory, output, concurrency, teardown, capture, repeated-film, archive, and TestFlight-equivalent gates before promotion or further queue/stream optimization

## Blockers

- Vision Pro device access and a full Xcode installation are required for controlled A/B memory/output evidence, the 25-run concurrent canary, sanitizer coverage, latency/RTF measurements, post-unload sampling, debugger/capture pressure, complete-film repetitions, signed archive, and TestFlight-equivalent qualification. The current host exposes only Command Line Tools, so `xcodebuild` cannot build or archive the visionOS app.
