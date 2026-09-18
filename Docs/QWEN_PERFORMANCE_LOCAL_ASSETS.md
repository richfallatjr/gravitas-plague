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
