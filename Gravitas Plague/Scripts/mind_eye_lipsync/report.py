from __future__ import annotations

from collections import Counter
from typing import Any, Mapping, Sequence

from .mfa_json import MFAAlignment
from .timeline import DecoderParity
from .vad import VADResult


def build_report(
    manifest: Mapping[str, Any],
    *,
    alignment: MFAAlignment | None = None,
    vad: VADResult | None = None,
    parity: DecoderParity | None = None,
    manifest_sha256: str | None = None,
) -> dict[str, Any]:
    frames = manifest["frames"]
    frame_count = len(frames)
    pose_counts = Counter(str(frame["pose"]) for frame in frames)
    speech_frames = sum(bool(frame["speechActive"]) for frame in frames)
    fallback_frames = int(manifest["summary"]["fallbackFrameCount"])
    longest_phone: dict[str, Any] | None = None
    longest_word: dict[str, Any] | None = None
    if alignment is not None:
        if alignment.phones:
            phone = max(alignment.phones, key=lambda item: item.end_sample - item.start_sample)
            longest_phone = {
                "label": phone.raw_phone,
                "durationSamples": phone.end_sample - phone.start_sample,
            }
        if alignment.words:
            word = max(alignment.words, key=lambda item: item.end_sample - item.start_sample)
            longest_word = {
                "label": word.label,
                "durationSamples": word.end_sample - word.start_sample,
            }
    result: dict[str, Any] = {
        "schemaVersion": 1,
        "prID": manifest["prID"],
        "manifestSHA256": manifest_sha256,
        "speakerCharacterID": manifest["speakerCharacterID"],
        "interactionSurface": manifest["interactionSurface"],
        "sourceDurationSeconds": manifest["timeline"]["durationSeconds"],
        "frameCount": frame_count,
        "wordCount": len(alignment.words) if alignment else manifest["summary"]["alignedWordCount"],
        "phoneCount": len(alignment.phones) if alignment else None,
        "oovWords": manifest["summary"]["oovWords"],
        "g2pWords": manifest["summary"]["g2pWords"],
        "mfaRetryUsed": manifest["analysisProvenance"]["mfa"]["retryUsed"],
        "vadSpeechPercent": round(100 * speech_frames / max(1, frame_count), 6),
        "posePercent": {
            pose: round(100 * pose_counts.get(pose, 0) / max(1, frame_count), 6)
            for pose in ("rest", "small", "wide", "round", "teeth")
        },
        "fallbackPercent": round(100 * fallback_frames / max(1, frame_count), 6),
        "warnings": manifest["summary"]["warnings"],
        "longestPhone": longest_phone,
        "longestWord": longest_word,
        "alignmentVADDisagreementRegions": [
            warning for warning in manifest["summary"]["warnings"]
            if "VAD" in warning or "Speech" in warning or "speech" in warning
        ],
    }
    if parity is not None:
        result["decoderParity"] = {
            "ffmpegSampleCount": parity.ffmpeg_sample_count,
            "appleSampleCount": parity.apple_sample_count,
            "signedDifference": parity.signed_difference,
            "warning": parity.warning,
        }
    if vad is not None:
        result["vadWindowCount"] = len(vad.windows)
        result["vadSpeechSpanCount"] = len(vad.speech_spans)
    return result
