from __future__ import annotations

from dataclasses import dataclass, replace
import hashlib
import struct
from typing import Sequence

from .constants import (
    EVIDENCE_COARTICULATION,
    EVIDENCE_FALLBACK,
    EVIDENCE_MANUAL_OVERRIDE,
    EVIDENCE_VAD_SILENCE,
    EVIDENCE_VAD_SPEECH,
    MouthPose,
    POSE_TO_BIT,
)
from .phones import PhonePoseMap, PoseSpan
from .timeline import AudioTimeline
from .vad import SpeechSpan, overlap_samples


@dataclass(frozen=True, slots=True)
class FrameDecision:
    frame_index: int
    sample_start: int
    sample_end: int
    pose: MouthPose
    layer_mask: int
    speech_active: bool
    source_phone: str
    evidence_mask: int


_TIE_PRIORITY = {
    MouthPose.TEETH: 5,
    MouthPose.ROUND: 4,
    MouthPose.SMALL: 3,
    MouthPose.WIDE: 2,
    MouthPose.REST: 1,
}


def _select_span(start: int, end: int, spans: Sequence[PoseSpan]) -> PoseSpan | None:
    candidates: list[tuple[int, int, int, int, PoseSpan]] = []
    center = start + (end - start) // 2
    for index, span in enumerate(spans):
        overlap = max(0, min(end, span.end_sample) - max(start, span.start_sample))
        if overlap:
            owns_center = int(span.start_sample <= center < span.end_sample)
            candidates.append((overlap, owns_center, span.start_sample, _TIE_PRIORITY[span.pose], span))
    return max(candidates, key=lambda item: item[:4])[-1] if candidates else None


def expand_frames(
    timeline: AudioTimeline,
    pose_spans: Sequence[PoseSpan],
    speech_spans: Sequence[SpeechSpan],
    *,
    speech_overlap_threshold: float,
) -> tuple[FrameDecision, ...]:
    decisions: list[FrameDecision] = []
    for index in range(timeline.frame_count):
        start, end = timeline.frame_range(index)
        speech_overlap = overlap_samples(start, end, speech_spans)
        speech_active = speech_overlap / (end - start) >= speech_overlap_threshold
        span = _select_span(start, end, pose_spans)
        if span is None:
            pose = MouthPose.WIDE if speech_active else MouthPose.REST
            phone = "spn" if speech_active else "sil"
            evidence = EVIDENCE_FALLBACK | (
                EVIDENCE_VAD_SPEECH if speech_active else EVIDENCE_VAD_SILENCE
            )
        else:
            pose, phone, evidence = span.pose, span.source_phone, span.evidence_mask
        decisions.append(FrameDecision(
            frame_index=index,
            sample_start=start,
            sample_end=end,
            pose=pose,
            layer_mask=POSE_TO_BIT[pose],
            speech_active=speech_active,
            source_phone=phone,
            evidence_mask=evidence,
        ))
    return tuple(decisions)


def _runs(frames: Sequence[FrameDecision]) -> list[tuple[int, int]]:
    if not frames:
        return []
    result: list[tuple[int, int]] = []
    start = 0
    for index in range(1, len(frames) + 1):
        if index == len(frames) or frames[index].pose != frames[start].pose:
            result.append((start, index))
            start = index
    return result


def apply_coarticulation(
    frames: Sequence[FrameDecision],
    mapping: PhonePoseMap,
    *,
    silence_barrier_frames: int,
) -> tuple[FrameDecision, ...]:
    output = list(frames)
    for start, end in list(_runs(output)):
        pose = output[start].pose
        anticipation = mapping.anticipation_frames[pose]
        if anticipation <= 0 or start == 0 or end - start < 1:
            continue
        previous = output[start - 1]
        if previous.pose == MouthPose.REST or pose == MouthPose.REST:
            continue
        target = max(0, start - anticipation)
        if any(
            item.pose == MouthPose.REST and not item.speech_active
            for item in output[max(0, start - silence_barrier_frames):start]
        ):
            continue
        for index in range(target, start):
            item = output[index]
            if (
                item.pose in {MouthPose.TEETH, MouthPose.ROUND}
                and item.source_phone != output[start].source_phone
            ):
                continue
            output[index] = replace(
                item, pose=pose, layer_mask=POSE_TO_BIT[pose],
                source_phone=output[start].source_phone,
                evidence_mask=item.evidence_mask | EVIDENCE_COARTICULATION,
            )
    # Repair single-frame islands without erasing the only teeth/round phone evidence.
    for start, end in list(_runs(output)):
        if end - start != 1 or start == 0 or end == len(output):
            continue
        current, left, right = output[start], output[start - 1], output[end]
        if current.pose in {MouthPose.TEETH, MouthPose.ROUND} and current.source_phone not in {
            left.source_phone, right.source_phone
        }:
            continue
        replacement = left if left.pose == right.pose else (
            left if left.evidence_mask >= right.evidence_mask else right
        )
        output[start] = replace(
            current, pose=replacement.pose, layer_mask=POSE_TO_BIT[replacement.pose],
            source_phone=replacement.source_phone,
            evidence_mask=current.evidence_mask | EVIDENCE_COARTICULATION,
        )
    # Enforce minimum holds by borrowing only adjacent speech frames; never cross long silence.
    for start, end in list(_runs(output)):
        pose = output[start].pose
        needed = mapping.minimum_hold_frames[pose] - (end - start)
        cursor = end
        while needed > 0 and cursor < len(output):
            candidate = output[cursor]
            if candidate.pose == MouthPose.REST and not candidate.speech_active:
                break
            if candidate.pose in {MouthPose.TEETH, MouthPose.ROUND}:
                break
            output[cursor] = replace(
                candidate, pose=pose, layer_mask=POSE_TO_BIT[pose],
                source_phone=output[start].source_phone,
                evidence_mask=candidate.evidence_mask | EVIDENCE_COARTICULATION,
            )
            cursor += 1
            needed -= 1
    return tuple(output)


def apply_manual_overrides(
    frames: Sequence[FrameDecision],
    operations: Sequence[dict[str, object]],
) -> tuple[FrameDecision, ...]:
    output = list(frames)
    previous_end = 0
    for operation in operations:
        start = int(operation["startFrame"])
        end = int(operation["endFrameExclusive"])
        reason = str(operation["reason"]).strip()
        pose = MouthPose(str(operation["pose"]))
        if not reason or start < previous_end or start < 0 or end <= start or end > len(output):
            raise ValueError("Manual overrides must be nonempty, sorted, nonoverlapping, and in range")
        for index in range(start, end):
            item = output[index]
            output[index] = replace(
                item, pose=pose, layer_mask=POSE_TO_BIT[pose],
                evidence_mask=item.evidence_mask | EVIDENCE_MANUAL_OVERRIDE,
            )
        previous_end = end
    return tuple(output)


def frames_sha256(frames: Sequence[FrameDecision]) -> str:
    digest = hashlib.sha256()
    for frame in frames:
        phone = frame.source_phone.encode("utf-8")
        if len(phone) > 0xFFFF or not 0 <= frame.evidence_mask <= 0xFFFF:
            raise ValueError("Frame phone/evidence exceeds binary hash contract")
        digest.update(struct.pack(
            "<IQQBBHH",
            frame.frame_index,
            frame.sample_start,
            frame.sample_end,
            frame.layer_mask,
            int(frame.speech_active),
            frame.evidence_mask,
            len(phone),
        ))
        digest.update(phone)
    return digest.hexdigest()
