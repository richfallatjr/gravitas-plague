# Qwen/MLX performance baseline — 2026-09-17

Status: **DEVICE_QUALIFICATION_PENDING**. The new backend program is not complete.

## Historical observation, not a shipping baseline

Source checkout: `7d71aeaf93b8bf5f4d8b789b3914defdec75ee5f` plus explicitly
recorded dirty work. See `Turing_Qwen_Device_Profiling_2026-09-17.md` for retained
trace interpretation and limitations. The earlier six-segment Big Mike request
reported raw-audio RTF 2.5978, first-needed PCM 28.893 seconds, and request wall
55.496 seconds. Its installed build was not proven to match optimized source.
The trace covered initial generation, not completed decoder stages. Recursive
libc++ tree checking occupied 52.02% of sampled Qwen/MLX CPU time; that percentage
is not a predicted wall-time speedup.

## New controls

- Fresh2 means independent two lanes / two weight stores / one decoder with
  currentOverlap admission. Production policy, model, sampling, authored voice
  payloads, PR ownership and player timing remain unchanged.
- Actual allocator translation-unit fingerprint and running Mach-O UUIDs are
  reported. Debug/Release recovery defines are separate experimental factors.
- The current Debug host binary reports libc++ DEBUG, internal assertions true,
  unoptimized Cmlx. It is not an optimized shipping baseline.
- Phase markers are opt-in. Command-buffer metrics are complete capture-window
  aggregates, including pending/mixed/unattributed/invalid-timestamp counts.
- Native row/phase checks plus the host child-process watchdog enforce bounded
  scouting. They do not promise GPU preemption.

## Workloads

`Tools/Turing/Performance/Workloads/*-short.json` are **new** immutable workloads,
not a reproduction of the historical Big Mike request. Each uses the actual
production voice ID and catalog sampling, with two four-row diagnostic segments.
The original historical request and seed have not been recovered as a fixture.
Four-row scouts are deliberately too short to qualify dialogue quality. Dad and
Rich retain their production EOS-before-decode gate: an early row-cap rejection
is recorded, not bypassed to produce a flattering timing result.

The fixed decoder fixture uses bytes `[0, 512)` (eight rows, 16 Int32LE codes per
row) of Big Mike's `broadcast_reference_fast_01/qwen_artifacts/reference_codes.i32le`.
Full source SHA256: `b866f9d45f4e8dd105979bc397351ecd3ea76ce565ae62fa5653477499edf9c3`.
The first four rows are treated as a reference prefix to exercise the existing
proportional trimmer. This is a fixed-code I/O/parity scout, not synthesized
dialogue, not production reference reduction, and not a useful end-to-end RTF.

## Still required

Source-matched device runs with and without profiler; hardening-only paired A/B;
separately labeled optimized Release baseline; representative short/typical/
long production shapes across all five voices; numerical/audio/recovery checks;
full-scene frame and memory qualification. An isolated app-hosted device run
does not meet full-scene gates. The qualification-only launch is compiled out
unless `GR_QWEN_PERFORMANCE_QUALIFICATION` is explicitly supplied; it adds no
shipping developer button.
