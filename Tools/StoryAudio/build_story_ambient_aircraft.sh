#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/Authoring/Audio/StoryAmbientAircraft/Source"
OUTPUT="$ROOT/Gravitas Plague/TuringResources/Turing/Audio/story-ambient-aircraft"
FILES=(
    helicopter-overhead-02.mp3
    helicopter-overhead-03.mp3
    jet-overhead-02.mp3
)

for tool in ffmpeg ffprobe shasum; do
    command -v "$tool" >/dev/null || {
        echo "Missing required tool: $tool" >&2
        exit 1
    }
done

mkdir -p "$OUTPUT"
find "$OUTPUT" -maxdepth 1 -type f -name '*.wav' -delete

for input_name in "${FILES[@]}"; do
    input="$SOURCE/$input_name"
    output_name="${input_name%.mp3}.wav"
    output="$OUTPUT/$output_name"
    test -f "$input" || {
        echo "Missing authored aircraft source: $input" >&2
        exit 1
    }

    ffmpeg -hide_banner -loglevel error -y \
        -i "$input" \
        -af 'pan=mono|c0=0.5*c0+0.5*c1' \
        -ar 48000 \
        -c:a pcm_s16le \
        "$output"

    format="$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name,sample_rate,channels \
        -of csv=p=0 "$output")"
    test "$format" = "pcm_s16le,48000,1" || {
        echo "Invalid production format for $output_name: $format" >&2
        exit 1
    }

    echo "$output_name"
    echo "  sourceSHA256=$(shasum -a 256 "$input" | awk '{print $1}')"
    echo "  outputSHA256=$(shasum -a 256 "$output" | awk '{print $1}')"
done

count="$(find "$OUTPUT" -maxdepth 1 -type f -name '*.wav' | wc -l | tr -d ' ')"
test "$count" = "3" || {
    echo "Expected exactly 3 production aircraft files, found $count" >&2
    exit 1
}

echo "Installed 3 production aircraft WAVs in $OUTPUT"
