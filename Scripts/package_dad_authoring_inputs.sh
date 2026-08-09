#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source_audio="/Users/richardfallat/Projects/dev/turing-native-qwen-cloner/dad-reference-fast.mp3"
variant_root="$repo_root/Gravitas Plague/TuringResources/Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone/variants/dad_reference_fast_01"

expected_sha256="0d3f766e61f9fd4bfad2e16a33b8020dc630201805f02214e36a4bc5e89f602b"
actual_sha256="$(shasum -a 256 "$source_audio" | awk '{print $1}')"
[[ "$actual_sha256" == "$expected_sha256" ]] || {
  print -u2 "Dad source audio checksum mismatch: $actual_sha256"
  exit 1
}

grep -qv '^AUTHOR INPUT REQUIRED:' "$variant_root/ref_text.txt" || {
  print -u2 "Provide the author-approved exact Dad transcript before packaging."
  exit 1
}

original_audio="$variant_root/ref_audio/original/dad-reference-fast.mp3"
normalized_audio="$variant_root/ref_audio/normalized/ref_24000_mono.wav"
mkdir -p "${original_audio:h}" "${normalized_audio:h}"
cp -f "$source_audio" "$original_audio"
cmp -s "$source_audio" "$original_audio" || {
  print -u2 "Packaged Dad source audio is not byte-identical."
  exit 1
}
ffmpeg -hide_banner -loglevel error -y \
  -i "$original_audio" \
  -map_metadata -1 \
  -vn \
  -ac 1 \
  -ar 24000 \
  -c:a pcm_f32le \
  "$normalized_audio"

[[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$normalized_audio")" == "24000" ]]
[[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$normalized_audio")" == "1" ]]
