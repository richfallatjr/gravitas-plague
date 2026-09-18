# Qwen performance local assets

No model downloads, replacement stack, asset copies, or voice changes were made.

- Repository: `/Users/richardfallat/Projects/dev/gravitas-plague`
- Native package: `Gravitas Plague/Gravitas Plague/Turing/QwenNative`
- Vendored MLX: `ThirdParty/LocalSwiftPackages/mlx-swift` (installed source APIs)
- Resource root: `Gravitas Plague/TuringResources`
- Model: `Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit`
- Five actual voice roots: `Turing/Voices/Cloned/{BigMike,Broadcaster,CatEye81,Dad,Rich}`
- Xcode: `/Users/richardfallat/Downloads/Xcode.app/Contents/Developer`;
  selected per command, not by changing global xcode-select.
- Headset: connected Vision Pro, visionOS 27.0 build 24M5361a.
- New host artifacts: `/private/tmp/qwen-performance-20260917/`.
- Earlier device trace: `/private/tmp/gravitas-tts-profile-20260917.um2OWO/`.

The runtime tokenizer uses `vocab.json`, `merges.txt`, `tokenizer_config.json`;
there is no `tokenizer.json` in the shipped model. Reports hash each actual input
and a stable aggregate, plus model/config/decoder/voice payload identities.
Identity hashing drains Foundation autoreleased buffers per 1 MiB read; those
reads happen outside the measured synthesis interval.

## Reproduce a bounded host scout

Build the native package with the installed Xcode. Its current SwiftPM backend
puts the executable and Metal resource bundle under `.build/out/Products/Debug`.
Do not use the older benchmark script's quick/full workloads for these scouts.

```sh
DEVELOPER_DIR=/Users/richardfallat/Downloads/Xcode.app/Contents/Developer \
  swift build --package-path 'Gravitas Plague/Gravitas Plague/Turing/QwenNative' -c debug -j 4

python3 Scripts/turing/qwen_bounded_runner.py \
  --binary 'Gravitas Plague/Gravitas Plague/Turing/QwenNative/.build/out/Products/Debug/turing-qwen-benchmark' \
  --model-root 'Gravitas Plague/TuringResources/Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit' \
  --bundle-root 'Gravitas Plague/TuringResources' \
  --workload Tools/Turing/Performance/Workloads/big_mike-decoder-eight-rows.json \
  --mode decoder-fixed-codes --output /private/tmp/qwen-decoder-new-attempt.json
```

Use a fresh output name for every attempt. The F1 candidate adds
`--policy Tools/Turing/Performance/Policies/decoder-positional.json`.
Neither mode changes the production execution policy. The device request uses
the same Codable workload/policy, transferred into the app's
`Documents/QwenQualification` folder and activated only by the explicit
qualification build and `QWEN_PERFORMANCE_REQUEST` launch environment value.

## C1 exact predictor-conversion experiment

Use Release for performance scouts. Focused correctness tests run in Debug
because unrelated existing package tests reference Debug-only recovery/stream
test hooks. Do not add those hooks to production to make Release tests compile.

```sh
DEVELOPER_DIR=/Users/richardfallat/Downloads/Xcode.app/Contents/Developer \
  swift build --package-path 'Gravitas Plague/Gravitas Plague/Turing/QwenNative' \
  -c release -j 4 --product turing-qwen-benchmark

python3 Scripts/turing/qwen_bounded_runner.py \
  --binary 'Gravitas Plague/Gravitas Plague/Turing/QwenNative/.build/out/Products/Release/turing-qwen-benchmark' \
  --model-root 'Gravitas Plague/TuringResources/Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit' \
  --bundle-root 'Gravitas Plague/TuringResources' \
  --workload Tools/Turing/Performance/Workloads/big_mike-short.json \
  --command-buffer-profile deviceDefault \
  --output /private/tmp/qwen-c1-new-control.json
```

For C1, add
`--policy Tools/Turing/Performance/Policies/predictor-conversion-cache.json`
and use a new output path. Alternate control/candidate and candidate/control;
do not run model benchmarks concurrently. `deviceDefault` explicitly matches
the current gameplay selection (40 operations / 40 MB). Older runner requests
still default to 40 operations / 32 MB; do not compare across these settings.
Qualification request JSON now accepts optional `commandBufferProfile` with
the same enum; omitting it preserves its previous 40/32 behavior.

Reports include load/end cache snapshots, source companion inventory, exact
retained bytes, CPU materialization time, owner/generation identity, and hit/
miss counts. Successful C1 scouts require actual post-load hits in both stores.
These counters do not prove eliminated GPU kernel counts. Host report status
remains `DEVICE_QUALIFICATION_PENDING`; production defaults are unchanged.

`big_mike-overlap-4x8.json` is an additional four-segment queue-refill scout.
Its first control/candidate pair still reported zero overlap at decoder
acquisition, so do not infer overlap coverage from its filename. The tiny Dad
and Rich four-row fixtures hit their existing EOS safety policy in both paths;
their next acceptance fixtures must produce complete bounded utterances without
weakening runtime quality policy.

## Largest-cost attribution without relying on a saved Instruments trace

The bounded runner's existing `--phase-markers` option now also records capped
elapsed scopes, stage labels, tensor metadata and drop/pending counters into
`phaseDiagnostics` in its result JSON. The new recorder itself performs no file
I/O; the runner writes the report after synthesis/teardown as before. Ordinary
gameplay remains off. All new reports explicitly record
`observation.phaseDiagnosticsEnabled`; comparisons reject differing or unknown
versus explicit instrumentation states.

Use `big_mike-production-response-full.json` for performance measurements, with
`--phase-markers --command-buffer-profile deviceDefault` and a new output
filename. It replays five exact production segments, requires natural EOS and
full segment coverage, and uses the unchanged production ceiling (160 rows).
Do not substitute the older row-truncated fixtures when reporting full-segment
performance. Those remain only for narrow diagnostics. `segmentTimings` exports
completed-generation/decode timers, actual generated/reference row counts and
EOS evidence. Host scouting is not headset qualification.

The retained scopes are **inclusive elapsed samples**, not CPU time or isolated
GPU time. Two generation lanes can overlap each other and decode; lazy predictor
work may execute at a later talker evaluation. Decoder inner stage/I/O samples
can hit the 32-per-phase cap. Inspect explicit drops and complete outer scopes;
never add overlapping samples or extrapolate a 54% wall-time gain from them.
