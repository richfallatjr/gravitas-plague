#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_DIR="$REPO_ROOT"
DESTINATION_DIR="$REPO_ROOT/Gravitas Plague/TuringResources/Turing/Audio/story-ambient-county"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/story-county.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

files=(
  air-raid-01-county-distant-10.mp3
  air-raid-02-county-distant-10.mp3
  air-raid-03-county-distant-10.mp3
  air-raid-04-county-distant-10.mp3
  car-alarm-01-county-5.mp3
  car-alarm-02-county-5.mp3
  car-alarm-03-county-5.mp3
  car-peel-01-county-1.mp3
  car-peel-02-county-1.mp3
  car-peel-03-county-1.mp3
  car-peel-04-county-1.mp3
  chainsaw-01-county-distance-1.mp3
  chainsaw-02-county-distance-1.mp3
  chainsaw-03-county-distance-1.mp3
  chainsaw-04-county-distance-1.mp3
  clank-01-county-10.wav
  clank-02-county-10.wav
  clank-03-county-10.wav
  dog-01-county-10.mp3
  dog-02-county-10.mp3
  dog-03-county-10.mp3
  dog-04-county-10.mp3
  train-01-county-distant-10.mp3
  train-02-county-distant-10.mp3
  train-03-county-distant-10.mp3
  train-04-county-distant-10.mp3
)

for tool in ffmpeg ffprobe shasum; do
  command -v "$tool" >/dev/null || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

discovered_count="$(find "$SOURCE_DIR" -maxdepth 1 -type f \( -name '*-county-*.mp3' -o -name '*-county-*.wav' \) -print | wc -l | tr -d ' ')"
if [[ "$discovered_count" -ne "${#files[@]}" ]]; then
  echo "Expected ${#files[@]} source MP3/WAV files, found $discovered_count." >&2
  exit 1
fi

for file in "${files[@]}"; do
  source="$SOURCE_DIR/$file"
  output_name="${file%.*}.wav"
  output="$TEMP_DIR/$output_name"
  source_stem="${file%.*}"
  selection_weight="${source_stem##*-}"
  [[ -f "$source" ]] || {
    echo "Missing source audio: $source" >&2
    exit 1
  }
  [[ "$selection_weight" =~ ^([1-9]|10)$ ]] || {
    echo "Invalid filename weight in $file; expected a final 1-10 suffix." >&2
    exit 1
  }

  ffmpeg -hide_banner -loglevel error -y \
    -i "$source" \
    -af 'pan=mono|c0=0.5*c0+0.5*c1' \
    -ar 48000 \
    -c:a pcm_s16le \
    "$output"

  codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$output")"
  sample_rate="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 "$output")"
  channels="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 "$output")"
  duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$output")"

  [[ "$codec" == "pcm_s16le" && "$sample_rate" == "48000" && "$channels" == "1" ]] || {
    echo "Invalid production WAV: $output_name codec=$codec rate=$sample_rate channels=$channels" >&2
    exit 1
  }

  echo "$output_name"
  echo "  sourceSHA256=$(shasum -a 256 "$source" | awk '{print $1}')"
  echo "  outputSHA256=$(shasum -a 256 "$output" | awk '{print $1}')"
  echo "  duration=$duration sampleRate=$sample_rate channels=$channels codec=$codec"
done

mkdir -p "$DESTINATION_DIR"
find "$DESTINATION_DIR" -maxdepth 1 -type f -name '*.wav' -delete
for file in "${files[@]}"; do
  output_name="${file%.*}.wav"
  mv "$TEMP_DIR/$output_name" "$DESTINATION_DIR/$output_name"
done

installed_count="$(find "$DESTINATION_DIR" -maxdepth 1 -type f -name '*.wav' -print | wc -l | tr -d ' ')"
if [[ "$installed_count" -ne "${#files[@]}" ]]; then
  echo "Expected ${#files[@]} production WAVs, found $installed_count." >&2
  exit 1
fi

echo "Installed ${#files[@]} production WAVs in $DESTINATION_DIR"
