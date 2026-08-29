from __future__ import annotations

import math
import wave
from pathlib import Path
import numpy as np


def read_pcm16(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as stream:
        if stream.getnchannels() != 1 or stream.getsampwidth() != 2 or stream.getframerate() != 48_000:
            raise ValueError("Filler timeline WAV must be mono 48 kHz PCM16")
        count = stream.getnframes()
        samples = np.frombuffer(stream.readframes(count), dtype="<i2").astype(np.float64) / 32768.0
    return samples, count


def _stabilize_activity(raw: list[bool]) -> list[bool]:
    active = raw[:]
    # Reject bursts shorter than 30 ms and fill inactive gaps shorter than 50 ms.
    for target, minimum in ((True, 3), (False, 5)):
        start = 0
        while start < len(active):
            end = start + 1
            while end < len(active) and active[end] == active[start]: end += 1
            if active[start] == target and end - start < minimum:
                replacement = not target
                for index in range(start, end): active[index] = replacement
            start = end
    padded = active[:]
    for index, value in enumerate(active):
        if value:
            for neighbor in range(max(0, index - 2), min(len(active), index + 3)):
                padded[neighbor] = True
    return padded


def analyze(samples: np.ndarray, frame_count: int, profile: str, verbal: bool = False) -> tuple[list[str], list[int]]:
    if frame_count < 1: raise ValueError("Empty filler audio")
    if verbal: raise ValueError("Verbal fillers must use the pinned MFA compiler")
    window, hop = 960, 480
    hann = np.hanning(window).astype(np.float64)
    rms, peak, zcr, diff, centroid, flux = [], [], [], [], [], []
    prior_spectrum = None
    for start in range(0, len(samples), hop):
        chunk = samples[start:min(len(samples), start + window)]
        if len(chunk) < window: chunk = np.pad(chunk, (0, window - len(chunk)))
        rms_value = math.sqrt(float(np.mean(chunk * chunk)))
        rms.append(20.0 * math.log10(max(1e-9, rms_value)))
        peak.append(float(np.max(np.abs(chunk))))
        zcr.append(float(np.mean(np.signbit(chunk[1:]) != np.signbit(chunk[:-1]))))
        difference_rms = math.sqrt(float(np.mean(np.diff(chunk) ** 2)))
        diff.append(min(1.0, difference_rms / max(1e-9, rms_value * 2.0)))
        spectrum = np.abs(np.fft.rfft(chunk * hann))
        total = float(np.sum(spectrum))
        centroid.append(float(np.dot(np.arange(len(spectrum)), spectrum) / max(1e-12, total)) / max(1, len(spectrum) - 1))
        if prior_spectrum is None:
            flux.append(0.0)
        else:
            positive = np.maximum(0.0, spectrum - prior_spectrum)
            flux.append(float(np.sqrt(np.mean(positive * positive))) / max(1e-12, float(np.mean(spectrum))))
        prior_spectrum = spectrum
    floor, ceiling = np.percentile(rms, [20, 95])
    dynamic = max(18.0, float(ceiling - floor))
    threshold = max(-72.0, float(floor + max(6.0, 0.30 * dynamic)))
    active_windows = _stabilize_activity([value >= threshold for value in rms])
    poses, masks = [], []
    for frame in range(frame_count):
        index = min(len(rms) - 1, (frame * 800 + 400) // hop)
        on = active_windows[index]
        if not on:
            poses.append("rest"); masks.append(0); continue
        energy = min(1.0, max(0.0, (rms[index] - threshold) / max(6.0, dynamic)))
        noisy = zcr[index] > 0.16 or diff[index] > 0.24 or centroid[index] > 0.22
        onset = index == 0 or not active_windows[index - 1] or flux[index] > 1.25
        mask = 1 | 2 | (4 if noisy else 0) | (8 if centroid[index] > 0.22 else 0) | (16 if onset else 0) | 32
        if profile == "tongueClick": pose = "teeth" if onset or flux[index] > 0.9 or peak[index] > .4 else "small"
        elif profile == "closedHum": pose = "small"
        elif profile == "exhale": pose = "teeth" if noisy else ("round" if energy > .25 else "small")
        elif profile == "inhale": pose = "teeth" if noisy else ("wide" if energy > .3 else "small")
        elif profile == "cough": pose = "teeth" if noisy and not onset else "wide"
        else: pose = "round" if energy < .5 else "wide"
        poses.append(pose); masks.append(mask)
    # Enforce semantic minimum holds using only adjacent active frames.
    minimum_holds = {"rest": 1, "small": 2, "wide": 3, "round": 3, "teeth": 2}
    for index in range(1, len(poses) - 1):
        if poses[index] == "rest": continue
        if poses[index - 1] == poses[index + 1] != "rest": poses[index] = poses[index - 1]
    cursor = 0
    while cursor < len(poses):
        end = cursor + 1
        while end < len(poses) and poses[end] == poses[cursor]: end += 1
        pose = poses[cursor]
        needed = minimum_holds[pose] - (end - cursor)
        extension = end
        while needed > 0 and extension < len(poses) and poses[extension] != "rest":
            poses[extension] = pose
            masks[extension] |= 32
            extension += 1
            needed -= 1
        cursor = max(end, extension)
    return poses, masks
