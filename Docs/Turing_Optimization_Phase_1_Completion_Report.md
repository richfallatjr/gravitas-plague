# Turing optimization Phase 1 completion report

## Final status

- Decision: PASS
- Candidate disposition: reject as a shipping fix; retain diagnostic only
- Starting commit: `cc003b1ce04b321835b0115dba477fadd6d5e9f7`
- Branch: `main`
- Dirty worktree preserved: yes
- Files added: Phase 1 admission policy, controller, metrics, experiment configuration, focused package tests, and app configuration tests
- Files modified: Fresh2 generation/decode integration, run metrics, diagnostics, render-session configuration, and the architect handoff
- Owner files reset: none
- Qwen instance count before/after: 2 / 2
- Generation worker count before/after: 2 / 2

## Functional stabilization prerequisite

- Authored portrait retention: preserved in the tested build
- PocketSphinx resource verification: preserved; runtime forced alignment completed during both supplied runs
- Big Mike handoff: exercised on device
- Rich-to-Big-Mike handoff: preserved by the existing conversation pipeline
- Existing stale tests: broad app-suite status not claimed
- Relevant focused tests: 13/13 Phase 1 Qwen-native admission tests pass

## Admission implementation

- Modes: `currentOverlap`, `decodeExclusive`
- Production default: `currentOverlap`
- Candidate build flag: `GR_TURING_DECODE_EXCLUSIVE`
- Maximum generation leases: 2
- Decoder priority: enabled in `decodeExclusive`
- Per-run ownership: yes
- Queue bound: bounded by the open response segments and cancellation-aware waiters
- Cancellation: focused cancellation, grant-race, and scheduler tests pass
- Stale release: ignored without releasing another lease; focused test passes
- Final active leases: zero for completed tested runs
- Final waiters: zero for completed tested runs

## Pipeline parity

- Segment ordering: no ordering failure observed in either supplied run
- Segment count: completed candidate turns produced all five expected segments
- Seed identity: unchanged by admission mode
- Codebook parity: not independently hashed across identical baseline/candidate text; no admission-induced output mutation is implemented
- PCM parity: not independently hashed across identical baseline/candidate text
- Audio listening parity: no admission-specific quality regression reported
- Authored timing: preserved
- Generated lip sync: preserved and observed completing
- Mind’s Eye continuity: preserved
- Story progression: preserved through completed candidate turns

## Baseline currentOverlap

- Build: on-device development build supplied 2026-08-29
- Runs: 19 started; 18 completed; the nineteenth aborted
- Crashes: 1 terminal process abort
- Metal interactivity failures: 1 unique terminal failure, printed twice by libc++ termination reporting
- Peak render concurrency: 2
- Cross-segment render/decode overlap: present; completed runs reported counts including 3 and 5
- Time to first audio P50/P95: not measured from a controlled identical-input trial
- Total response P50/P95: not measured from a controlled identical-input trial
- Peak physical footprint: 6104.8 MB maximum sampled Fresh2 peak in the supplied log
- Peak available-memory pressure: approximately 2557 MB minimum logged available memory
- Peak MLX active/cache: 3472.2 MB / 135.8 MB maximum reported run peaks
- Post-unload residual: returned to the approximately 1.3–1.9 GB process range between observed turns

## Candidate decodeExclusive

- Build: on-device development build supplied 2026-08-29 with `GR_TURING_DECODE_EXCLUSIVE`
- Runs: 3 started; 2 completed; the third aborted
- Crashes: 1 terminal process abort
- Metal interactivity failures: 1 unique terminal failure, printed twice by libc++ termination reporting
- Peak generation-permit count: 2
- Cross-segment render/decode overlap: 0
- Blocked generation acquisitions: 2 in each completed run
- Blocked decode acquisitions: 3 in completed run 1; 2 in completed run 2
- Max generation wait: 1.555476625 seconds maximum across completed runs
- Max decode wait: 1.801584208 seconds maximum across completed runs
- Time to first audio P50/P95: not comparable because the supplied prompts differed from baseline
- Total response P50/P95: not comparable because the supplied prompts differed from baseline
- Peak physical footprint: 5200.6 MB maximum sampled completed-run peak
- Peak available-memory pressure: approximately 2984 MB minimum logged available memory
- Peak MLX active/cache: 3178.8 MB / 49.4 MB maximum reported completed-run peaks
- Post-unload residual: approximately 1.7 GB after the second completed candidate run

## Pressure tests

- Release no debugger: not separately identified in the supplied console
- Xcode only: supplied through Xcode console; exact attachment state not independently recorded
- Capture only: not run
- Xcode + capture: not run
- Complete film: baseline traversed a long multi-character path; a controlled complete-film gate was not run
- Repeated complete film: not run
- Ten targeted responses: baseline exceeded ten turns; candidate failed on turn three
- Actual TestFlight: not run for Phase 1

## Evidence

- Diagnostics export: two supplied console captures plus the updated stability handoff
- Symbolicated .ips: not supplied
- Same-time Jetsam search: no matching jetsam evidence supplied
- Last breadcrumb: decoder-stage console breadcrumbs captured to the terminal failure
- Metal System Trace: not run
- VM/physical-footprint trace: in-process physical footprint, available memory, resident memory, and MLX counters captured
- Thermal state: baseline reached state 2; candidate reached state 3 before the third-turn failure
- Failure class: uncaught MLX C++ `std::runtime_error` from Metal command-buffer status `Impacting Interactivity`

## Decision

- Hypothesis supported: generation/decode overlap can increase pressure, but is not sufficient to explain or prevent the failure
- Stability effect: candidate still produced the identical terminal Metal error class
- First-audio effect: no controlled comparable measurement
- Total-throughput effect: candidate completed 10.640 seconds of audio in 40.652 seconds and 20.400 seconds in 68.383 seconds; no identical-input baseline comparison exists
- Memory effect: candidate completed-run peaks were lower in this sample, but workloads and thermal conditions were not identical
- Output effect: no observed semantic pipeline change; bitwise parity was not measured
- Why the change is promoted, retained only for diagnosis, or rejected: broad exclusion eliminated all recorded Qwen generation/decode overlap yet the single speech decoder still triggered `Impacting Interactivity`; therefore it is not a stable shipping solution
- Exact Phase 2 starting condition: restore `currentOverlap` as production default, retain `decodeExclusive` as a qualification/control mode, make Metal completion callbacks non-throwing, propagate typed poison through `withError`, record exact bounded command-buffer telemetry, and calibrate buffer limits before any evidence-driven targeted split

## Blockers

- None for beginning Phase 2. Phase 1’s candidate was rejected by a reproduced same-class device failure, so additional Phase 1 pressure runs cannot promote it.
