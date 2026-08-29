from __future__ import annotations

import pytest

from mind_eye_lipsync.constants import MouthPose, POSE_TO_BIT
from mind_eye_lipsync.frame_expander import apply_coarticulation, expand_frames, frames_sha256
from mind_eye_lipsync.mfa_json import PhoneInterval
from mind_eye_lipsync.phones import PhonePoseMap, load_phone_pose_map, map_phone_intervals
from mind_eye_lipsync.quality import maximum_uncovered_samples
from mind_eye_lipsync.timeline import timeline_for_sample_count
from mind_eye_lipsync.vad import SpeechSpan, map_speech_spans, probability_windows


class FakeModel:
    def __init__(self) -> None:
        self.resets = 0

    def reset_states(self) -> None:
        self.resets += 1

    def __call__(self, samples, sample_rate: int) -> float:
        assert len(samples) == 512
        assert sample_rate == 16_000
        return 0.75


def test_vad_windows_padding_bounds_and_exact_x3_mapping() -> None:
    model = FakeModel()
    windows = probability_windows([0.0] * 513, model)
    assert model.resets == 1
    assert [(window.start_sample_16k, window.end_sample_16k) for window in windows] == [(0, 512), (512, 513)]
    assert all(window.speech_probability == 0.75 for window in windows)
    assert map_speech_spans([(2, 10)], timeline_sample_count=100) == (SpeechSpan(6, 30),)


def test_vad_gap_gate_measures_longest_contiguous_gap_not_cumulative_pauses() -> None:
    ranges = ((0, 100), (250, 350), (500, 600))
    assert maximum_uncovered_samples(0, 600, ranges) == 150


@pytest.mark.parametrize(("phone", "pose"), [
    ("AA0", MouthPose.WIDE), ("OW1", MouthPose.ROUND), ("F", MouthPose.TEETH),
    ("TH", MouthPose.TEETH), ("M", MouthPose.SMALL), ("sil", MouthPose.REST),
])
def test_phone_map(phone: str, pose: MouthPose) -> None:
    mapping = load_phone_pose_map()
    interval = PhoneInterval(phone, phone.rstrip("012"), 0, 800, None)
    result = map_phone_intervals([interval], [SpeechSpan(0, 800)], mapping)
    assert result.spans[0].pose == pose


def test_compounds_and_unknown_vad_fallback() -> None:
    mapping = load_phone_pose_map()
    aw = PhoneInterval("AW1", "AW", 0, 100, None)
    result = map_phone_intervals([aw], [SpeechSpan(0, 100)], mapping)
    assert [span.pose for span in result.spans] == [MouthPose.WIDE, MouthPose.ROUND]
    assert result.spans[0].start_sample == 0 and result.spans[-1].end_sample == 100
    spn = PhoneInterval("spn", "SPN", 100, 200, None)
    speech = map_phone_intervals([spn], [SpeechSpan(100, 200)], mapping)
    silence = map_phone_intervals([spn], [], mapping)
    assert speech.spans[0].pose == MouthPose.WIDE
    assert silence.spans[0].pose == MouthPose.REST


def test_long_aligned_phone_outside_vad_is_suppressed_to_rest() -> None:
    mapping = load_phone_pose_map()
    phone = PhoneInterval("AA1", "AA", 0, 12_001, None)
    result = map_phone_intervals([phone], [], mapping)
    assert result.spans[0].pose == MouthPose.REST
    assert result.warnings == ("alignedPhoneSuppressedOutsideSpeech:AA1:0-12001",)


def test_frame_expansion_coarticulation_and_hash_are_deterministic() -> None:
    mapping = load_phone_pose_map()
    timeline = timeline_for_sample_count(1_601)
    phones = [
        PhoneInterval("AA1", "AA", 0, 800, None),
        PhoneInterval("OW1", "OW", 800, 1_601, None),
    ]
    mapped = map_phone_intervals(phones, [SpeechSpan(0, 1_601)], mapping)
    frames = expand_frames(timeline, mapped.spans, [SpeechSpan(0, 1_601)], speech_overlap_threshold=0.25)
    frames = apply_coarticulation(frames, mapping, silence_barrier_frames=2)
    assert len(frames) == 3
    assert frames[-1].sample_end == 1_601
    assert all(frame.layer_mask == POSE_TO_BIT[frame.pose] for frame in frames)
    assert frames_sha256(frames) == frames_sha256(tuple(frames))


def test_minimum_hold_does_not_erase_only_teeth_evidence() -> None:
    mapping = load_phone_pose_map()
    frames = (
        _frame(0, MouthPose.WIDE, "AA1"),
        _frame(1, MouthPose.TEETH, "F"),
        _frame(2, MouthPose.SMALL, "M"),
    )
    result = apply_coarticulation(frames, mapping, silence_barrier_frames=2)
    assert result[1].pose == MouthPose.TEETH
    assert result[1].source_phone == "F"


def test_anticipation_does_not_cross_two_frame_silence_barrier() -> None:
    mapping = load_phone_pose_map()
    frames = (
        _frame(0, MouthPose.WIDE, "AA1"),
        _frame(1, MouthPose.REST, "sil", speech=False),
        _frame(2, MouthPose.REST, "sil", speech=False),
        _frame(3, MouthPose.ROUND, "OW1"),
    )
    result = apply_coarticulation(frames, mapping, silence_barrier_frames=2)
    assert result[2].pose == MouthPose.REST


def _frame(
    index: int,
    pose: MouthPose,
    phone: str,
    *,
    speech: bool = True,
):
    from mind_eye_lipsync.frame_expander import FrameDecision

    return FrameDecision(
        index,
        index * 800,
        (index + 1) * 800,
        pose,
        POSE_TO_BIT[pose],
        speech,
        phone,
        1,
    )
