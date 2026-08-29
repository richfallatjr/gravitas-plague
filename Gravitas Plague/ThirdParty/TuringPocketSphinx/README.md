# Turing PocketSphinx runtime alignment dependency

This directory contains the minimal static PocketSphinx 5.1.1 binary used by
Turing's on-device generated-speech phoneme aligner. The source is pinned to
commit `511126b492dcb267cf30d49d631946d7b61a9530`.

Rebuild from the repository root:

```bash
DEVELOPER_DIR=/Users/richardfallat/Downloads/Xcode-beta.app/Contents/Developer \
  "Gravitas Plague/Scripts/runtime_lipsync/build_pocketsphinx_xcframework.sh" \
  --replace
```

PocketSphinx's upstream CMake project assumes it is the top-level source tree.
The build therefore targets only `pocketsphinx` in that project, compiles the
small Turing C bridge separately for each visionOS slice, combines the archives,
and creates the static XCFramework. Programs, examples, tests, and the general
English language model are not included.

Run `verify_pocketsphinx_vendor.py` after every rebuild and update the generated
hashes in `SourceLock.json` only after inspecting the exact output.

License and model notices are preserved in `Licenses`.
