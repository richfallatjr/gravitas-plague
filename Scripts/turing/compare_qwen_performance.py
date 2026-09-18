#!/usr/bin/env python3
"""Compare bounded Qwen reports without running a model or promoting a policy.

Pair --baseline and --candidate paths by position. An optional --experiment
JSON names exact expected leaf differences: {"id":"F1", "allowedDifferences":
{"policy.decoderReader":{"baseline":"legacy","candidate":"positional"}},
"pairOrder":[{"baselineRunID":"a","candidateRunID":"b","order":"AB"}]}.
No wildcard exemptions or model/topology/scene/sampling/source waivers exist.
Independent evidence is optional for screening, mandatory for promotion review:
--evidence JSON maps quality/recovery/fullScene/provenance to status, artifact,
sha256, plus quality.tolerancesCommittedBeforeAssessment=true. PCM hashes are
identity/parity data, NOT quality judgments. Exporter never promotes runtime.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import re
import statistics


ROOT = Path(__file__).resolve().parents[2]
MISSING = object()
HASH_KEYS = ("model", "modelConfig", "tokenizer", "decoder", "decoderConfig",
             "characterRuntimes", "referenceCodes", "referenceTextTokens", "speakerEmbedding",
             "voiceMetadata", "voiceVariant", "referenceAudio")
SOURCE_KEYS = ("commit", "trackedDiffSHA256", "relevantSourcesSHA256", "nativeSourcesSHA256", "vendorSourcesSHA256")
OBSERVATION_KEYS = ("deviceModel", "osBuild", "profilerState", "sceneCondition", "coldWarmDefinition", "clockBasis",
                    "initialThermalState", "finalThermalState")
# Older exports did not record phase instrumentation. Two historical unknowns
# remain comparable, but an unknown is never treated as explicitly disabled.
OBSERVATION_CONTROL_KEYS = OBSERVATION_KEYS + ("phaseDiagnosticsEnabled",)
CONTRACT = {"residencyMode": "independentFresh2", "laneCount": 2, "weightStoreCount": 2,
            "decoderCount": 1, "admissionPolicy": "currentOverlap"}


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def load(path):
    return json.loads(Path(path).read_text(), parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"Nonfinite JSON: {value}")))


def known(value):
    return value is not None and value not in ("", "unknown", "unavailable", "unqualified")


def finite(value, positive=False):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and (value > 0 if positive else value >= 0)


def hash_value(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value.lower())


def is_physical_vision_pro(value):
    if not isinstance(value, str):
        return False
    # Keep the descriptive fixture labels, but never accept a simulator/host
    # merely because its label contains "vision" or a hardware identifier.
    return value in {"Vision Pro", "Apple Vision Pro", "Vision Pro M2"} or re.fullmatch(r"RealityDevice[0-9]+,[0-9]+", value) is not None


def flatten(value, prefix=""):
    if isinstance(value, dict):
        result = {}
        for key, child in value.items():
            result.update(flatten(child, f"{prefix}.{key}" if prefix else key))
        return result
    return {prefix: value}


def quantile(values, p):
    ordered = sorted(values)
    position = (len(ordered) - 1) * p
    lower = math.floor(position)
    upper = math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def summary(values, gates, strata=None):
    if not values:
        return None
    rng = random.Random(gates["bootstrap_seed"])
    groups = strata or [values]
    medians = [statistics.median([x for group in groups for x in rng.choices(group, k=len(group))])
               for _ in range(gates["bootstrap_repetitions"])]
    tail = (1 - gates["confidence_level"]) / 2
    return {"count": len(values), "median": statistics.median(values),
            "q1": quantile(values, .25), "q3": quantile(values, .75),
            "IQR": quantile(values, .75) - quantile(values, .25),
            "minimum": min(values), "maximum": max(values),
            "medianUncertaintyInterval": [quantile(medians, tail), quantile(medians, 1-tail)],
            "uncertaintyMethod": gates["uncertainty_method"],
            "bootstrapSeed": gates["bootstrap_seed"], "bootstrapRepetitions": gates["bootstrap_repetitions"],
            "confidenceLevel": gates["confidence_level"], "robustTailPercentileClaim": False}


def _validate_run(report):
    errors = []
    def require(ok, message):
        if not ok:
            errors.append(message)
    if not isinstance(report, dict):
        return ["report must be a JSON object"]
    for key in ("workload", "policy", "buildManifest", "compiledFingerprint", "runtimeContract", "observation", "identitySHA256", "installedPayloadSHA256", "commandBuffers"):
        if report.get(key) is not None and not isinstance(report[key], dict):
            return [f"{key} must be a JSON object"]
    pcm_field = report.get("pcm") or []
    if not isinstance(pcm_field, list) or not all(isinstance(x, dict) for x in pcm_field):
        return ["pcm must be an array of records"]
    require(report.get("schemaVersion") == 1, "unsupported report schema")
    require(known(report.get("runID")), "missing run ID")
    require(report.get("outcome") == "SCOUT_COMPLETED" and not report.get("failure"), "failed/error/budget-stopped attempt")
    for key in ("renderWallSeconds", "rawAudioSeconds", "rawAudioRTF", "loadInclusiveWallSeconds",
                "firstNeededPCMSeconds", "sampledPeakFootprintMiB"):
        require(finite(report.get(key), positive=True), f"missing/nonfinite/invalid metric {key}")
    for key in ("coldLoadSeconds", "residualFootprintMiB", "residualMLXActiveBytes", "residualMLXCacheBytes"):
        require(finite(report.get(key)), f"missing/nonfinite/invalid metric {key}")
    for key in ("workloadSHA256", "policySHA256"):
        require(hash_value(report.get(key)), f"invalid {key}")
    workload = report.get("workload") or {}
    for key in ("id", "characterID", "voiceID", "language", "origin"):
        require(known(workload.get(key)), f"missing workload {key}")
    require(isinstance(workload.get("samplingSeed"), int), "missing sampling seed")
    expected_count = 1 if workload.get("decoderCodes") is not None else len(workload.get("segments") or [])
    pcm = report.get("pcm") or []
    indices = [x.get("segmentIndex") for x in pcm]
    require(expected_count > 0 and len(pcm) == expected_count and all(isinstance(x, int) for x in indices) and sorted(indices) == list(range(expected_count)), "missing/duplicate/out-of-range PCM segments")
    complete = workload.get("requireCompleteSegments")
    require(complete is None or type(complete) is bool, "workload.requireCompleteSegments must be a boolean or null")
    if complete is True:
        maximum_rows = workload.get("maximumRowsPerSegment")
        valid_maximum = type(maximum_rows) is int and 1 <= maximum_rows <= 160
        require(valid_maximum, "complete segments require an integer maximumRowsPerSegment in 1...160")
        timings = report.get("segmentTimings")
        valid_timings = isinstance(timings, list) and all(isinstance(record, dict) for record in timings)
        require(valid_timings, "complete segments require a segmentTimings array of completion records")
        if valid_timings:
            timing_indices = [record.get("segmentIndex") for record in timings]
            valid_indices = all(type(index) is int for index in indices + timing_indices)
            require(valid_indices and len(timing_indices) == len(indices)
                    and len(set(timing_indices)) == len(timing_indices)
                    and sorted(timing_indices) == sorted(indices),
                    "complete segmentTimings must match every PCM segment index exactly once")
            for record in timings:
                require(record.get("reachedEOS") is True,
                        "complete segment requires reachedEOS=true (natural completion)")
                rows = record.get("generatedRowCount")
                require(valid_maximum and type(rows) is int and 1 <= rows <= maximum_rows,
                        "complete segment requires positive integer generatedRowCount within maximumRowsPerSegment")
    audio_seconds = 0.0
    times = {}
    for record in pcm:
        valid = finite(record.get("sampleCount"), True) and finite(record.get("sampleRate"), True) and finite(record.get("readySeconds"))
        require(valid, "invalid/nonfinite PCM record")
        require(hash_value(record.get("pcmSHA256")), "missing PCM identity (not a quality judgment)")
        if valid:
            audio_seconds += record["sampleCount"] / record["sampleRate"]
            if isinstance(record.get("segmentIndex"), int):
                times[record["segmentIndex"]] = record["readySeconds"]
    ordered = report.get("orderedPCMReady") or []
    require(len(ordered) == expected_count and all(finite(x) for x in ordered), "missing/pending/nonfinite ordered readiness")
    if set(times) == set(range(expected_count)) and expected_count:
        expected = [max(times[j] for j in range(i+1)) for i in range(expected_count)]
        require(ordered == expected, "ordered readiness is not prefix maximum of actual segment-ready times")
        require(report.get("firstNeededPCMSeconds") == expected[0], "first-needed PCM is not segment zero readiness")
    if finite(report.get("rawAudioSeconds"), True):
        require(math.isclose(audio_seconds, report["rawAudioSeconds"], rel_tol=1e-9, abs_tol=1e-9), "raw audio duration disagrees with PCM samples/rate")
    if finite(report.get("renderWallSeconds"), True) and finite(report.get("rawAudioRTF"), True) and audio_seconds > 0:
        require(math.isclose(report["rawAudioRTF"], report["renderWallSeconds"] / audio_seconds, rel_tol=1e-8), "RTF must be wall time / raw audio duration")
    identity = report.get("identitySHA256") or {}
    for key in HASH_KEYS:
        require(hash_value(identity.get(key)), f"missing model/voice identity {key}")
    manifest = report.get("buildManifest") or {}
    source = manifest.get("source") or {}
    for key in SOURCE_KEYS:
        require(known(source.get(key)), f"missing source/dirty identity {key}")
        if key != "commit":
            require(hash_value(source.get(key)), f"invalid source/dirty hash {key}")
    require(bool(report.get("binaryUUIDs")) and sorted(report.get("binaryUUIDs") or []) == sorted(manifest.get("binaryUUIDs") or []), "installed binary UUIDs unknown or differ from manifest")
    require(hash_value((manifest.get("compile") or {}).get("commandsSHA256")), "missing effective compile-command evidence")
    require(bool(manifest.get("toolchain")), "missing SDK/toolchain identity")
    for key in ("models", "voices"):
        digest = (report.get("installedPayloadSHA256") or {}).get(key)
        require(hash_value(digest) and digest == (manifest.get(key) or {}).get("sha256"), f"installed {key} payload identity mismatch")
    fingerprint = report.get("compiledFingerprint") or {}
    require(fingerprint.get("translationUnit") == "mlx/mlx/backend/metal/allocator.cpp", "missing allocator-owned fingerprint")
    require(fingerprint.get("hardeningMode") in ("debug", "extensive", "fast"), "unknown/disabled hardening")
    require(fingerprint.get("internalAssertionsEnabled") == (fingerprint.get("hardeningMode") == "debug"), "hardening mode and internal assertions disagree")
    for key in ("compiler", "architecture", "libcxxVersion", "experimentID"):
        require(known(fingerprint.get(key)), f"missing compiled fingerprint {key}")
    for key in ("optimized", "ndebug", "mlxTesting", "internalAssertionsEnabled"):
        require(isinstance(fingerprint.get(key), bool), f"missing effective build flag {key}")
    contract = report.get("runtimeContract") or {}
    isolated = contract.get("residencyMode") == "isolatedDecoder"
    expected_contract = dict(CONTRACT, residencyMode="isolatedDecoder", laneCount=0, weightStoreCount=0) if isolated else CONTRACT
    for key, value in expected_contract.items():
        require(contract.get(key) == value, f"runtime contract violated: {key}")
    for key in ("resolvedCommandBufferProfile", "recoveryDefines", "seedPolicy", "executionPolicy"):
        require(bool(contract.get(key)), f"missing runtime control {key}")
    require(contract.get("playbackRateApplied") is False, "RTF includes changed playback rate")
    require(contract.get("executionPolicy") == report.get("policy") and contract.get("policySHA256") == report.get("policySHA256"), "inconsistent execution policy")
    observation = report.get("observation") or {}
    for key in OBSERVATION_KEYS:
        require(known(observation.get(key)), f"missing observation {key}")
    if "phaseDiagnosticsEnabled" in observation:
        phase_enabled = observation["phaseDiagnosticsEnabled"]
        require(isinstance(phase_enabled, bool), "observation.phaseDiagnosticsEnabled must be a boolean when present")
        if phase_enabled is True:
            require(isinstance(report.get("phaseDiagnostics"), dict), "enabled phase diagnostics require a phaseDiagnostics report object")
        elif phase_enabled is False:
            require(report.get("phaseDiagnostics") is None, "disabled phase diagnostics require an absent or null phaseDiagnostics report")
    require(observation.get("initialThermalState") == observation.get("finalThermalState"), "thermal transition: retain attempt, rerun matched stable or separate stress population")
    metrics = report.get("commandBuffers") or {}
    accounting = metrics.get("fullRunAccounting") or {}
    require(bool(accounting) and not metrics.get("captureError"), "missing/error full-run command-buffer telemetry")
    require(accounting.get("pendingCount") == 0, "pending command buffers at capture finish")
    for key in ("submittedCount", "completedCount", "failureCount"):
        require(isinstance(metrics.get(key), int) and metrics[key] >= 0, f"missing/invalid {key}")
        require(metrics.get(key) == (accounting.get("aggregate") or {}).get(key), f"tail/full-run {key} disagreement")
    require(metrics.get("submittedCount", 0) > 0 and metrics.get("submittedCount") == metrics.get("completedCount"), "incomplete command-buffer accounting")
    require(metrics.get("failureCount") == 0, "command-buffer failure present")
    for key in ("maximumGPUSeconds", "maximumKernelSeconds"):
        require(finite(metrics.get(key)), f"missing/nonfinite command-buffer metric {key}")
    require(isinstance(accounting.get("missingGPUTimestampCount"), int) and
            isinstance(accounting.get("invalidGPUTimestampCount"), int), "missing GPU timestamp coverage accounting")
    return errors


def validate_run(report):
    try:
        return _validate_run(report)
    except (KeyError, TypeError, AttributeError, ValueError, OverflowError) as error:
        return [f"malformed report structure: {type(error).__name__}: {error}"]


def controls(report):
    manifest = report.get("buildManifest") or {}
    return {"source": manifest.get("source"), "toolchain": manifest.get("toolchain"),
            "buildConfiguration": manifest.get("buildConfiguration"),
            "compile": manifest.get("compile"), "compiledFingerprint": report.get("compiledFingerprint"),
            "identitySHA256": report.get("identitySHA256"), "installedPayloadSHA256": report.get("installedPayloadSHA256"),
            "workload": report.get("workload"), "workloadSHA256": report.get("workloadSHA256"),
            "policy": report.get("policy"), "policySHA256": report.get("policySHA256"),
            "runtimeContract": report.get("runtimeContract"),
            "observation": {key: (report.get("observation") or {}).get(key) for key in OBSERVATION_CONTROL_KEYS}}


def allowed_path(path):
    return path.startswith(("policy.", "runtimeContract.executionPolicy.", "compile.")) or path in {
        "policySHA256", "runtimeContract.policySHA256", "buildConfiguration",
        "compiledFingerprint.hardeningMode", "compiledFingerprint.internalAssertionsEnabled",
        "compiledFingerprint.experimentID", "compiledFingerprint.optimized", "compiledFingerprint.optimizeSize",
        "compiledFingerprint.ndebug", "compiledFingerprint.mlxTesting"}


def differences(baseline, candidate, experiment):
    left, right = flatten(controls(baseline)), flatten(controls(candidate))
    allowed = experiment.get("allowedDifferences", {})
    result = []
    for path in sorted(set(left) | set(right)):
        a, b = left.get(path, MISSING), right.get(path, MISSING)
        if a == b:
            continue
        expected = allowed.get(path)
        accepted = bool(experiment.get("id")) and allowed_path(path) and expected == {"baseline": a, "candidate": b}
        result.append({"path": path, "baseline": None if a is MISSING else a, "candidate": None if b is MISSING else b, "expectedExperimentDifference": accepted})
    return result


def evidence_review(evidence, root):
    result = {}
    for category in ("quality", "recovery", "fullScene", "provenance"):
        entry = evidence.get(category) or {}
        if not isinstance(entry, dict):
            entry = {}
        path = root / (entry.get("artifact") or "")
        valid = entry.get("status") == "PASS" and path.is_file() and hash_value(entry.get("sha256")) and sha256(path) == entry.get("sha256")
        if category == "quality":
            valid = valid and entry.get("tolerancesCommittedBeforeAssessment") is True
        result[category] = {"verifiedArtifact": bool(valid), "claimedStatus": entry.get("status", "MISSING"),
                            "artifact": entry.get("artifact"), "sha256": entry.get("sha256")}
    return result


def compare(baseline, candidate, gates, experiment=None, evidence=None, evidence_root=ROOT):
    experiment, evidence = experiment or {}, evidence or {}
    # Malformed files remain rejected attempts, not exceptions or silently
    # excluded pairs. Keep originals in CLI artifact references and hashes.
    def structural_run(value):
        if not isinstance(value, dict):
            return {"failure": "report is not a JSON object"}
        for key in ("workload", "policy", "buildManifest", "compiledFingerprint", "runtimeContract", "observation", "identitySHA256", "installedPayloadSHA256", "commandBuffers"):
            if value.get(key) is not None and not isinstance(value[key], dict):
                return {"runID": value.get("runID"), "failure": f"{key} is not a JSON object"}
        return value
    baseline = [structural_run(x) for x in baseline]
    candidate = [structural_run(x) for x in candidate]
    policy = gates["comparison"]
    errors, pairs = [], []
    if not baseline or len(baseline) != len(candidate):
        errors.append("nonempty equally sized paired input lists required; no unmatched attempt can be dropped")
    allowed = experiment.get("allowedDifferences", {})
    for path, expected in allowed.items():
        if not experiment.get("id") or not allowed_path(path) or not isinstance(expected, dict) or set(expected) != {"baseline", "candidate"}:
            errors.append(f"invalid experiment exemption: {path}")
    seen_ids = set()
    for index, (a, b) in enumerate(zip(baseline, candidate)):
        problems = [f"baseline: {e}" for e in validate_run(a)] + [f"candidate: {e}" for e in validate_run(b)]
        for run in (a, b):
            rid = run.get("runID")
            if rid in seen_ids:
                problems.append("duplicate run ID (reusing one attempt is not repetition)")
            seen_ids.add(rid)
        delta = differences(a, b, experiment)
        problems += [f"unmatched control: {d['path']}" for d in delta if not d["expectedExperimentDifference"]]
        pair = {"pairIndex": index, "baselineRunID": a.get("runID"), "candidateRunID": b.get("runID"),
                "characterID": (a.get("workload") or {}).get("characterID"),
                "workloadSHA256": a.get("workloadSHA256"), "controlDifferences": delta, "errors": problems,
                "source": (a.get("buildManifest") or {}).get("source"),
                "baselinePolicySHA256": a.get("policySHA256"), "candidatePolicySHA256": b.get("policySHA256"),
                "baselineOrderedPCMReady": a.get("orderedPCMReady"), "candidateOrderedPCMReady": b.get("orderedPCMReady")}
        if not problems:
            pair.update(wallRatio=b["renderWallSeconds"] / a["renderWallSeconds"],
                        rawRTFRatio=b["rawAudioRTF"] / a["rawAudioRTF"],
                        firstNeededPCMRatio=b["firstNeededPCMSeconds"] / a["firstNeededPCMSeconds"],
                        peakFootprintRatio=b["sampledPeakFootprintMiB"] / a["sampledPeakFootprintMiB"],
                        orderedPCMReadyRatios=[y/x if x else (1 if y == 0 else None) for x, y in zip(a["orderedPCMReady"], b["orderedPCMReady"])],
                        rawOutputIdenticalLength=[(x["sampleCount"], x["sampleRate"]) for x in sorted(a["pcm"], key=lambda x:x["segmentIndex"])] == [(x["sampleCount"], x["sampleRate"]) for x in sorted(b["pcm"], key=lambda x:x["segmentIndex"])])
        pairs.append(pair)
    for pair in pairs:
        errors.extend(f"pair {pair['pairIndex']}: {error}" for error in pair["errors"])
    # One experiment/population per invocation. Matching within one pair is
    # insufficient when other pairs quietly use different builds or policies.
    for side, runs in (("baseline", baseline), ("candidate", candidate)):
        if not runs:
            continue
        def population(run):
            values = controls(run)
            values.pop("workload", None)
            values.pop("workloadSHA256", None)
            values["identitySHA256"] = {k: (run.get("identitySHA256") or {}).get(k) for k in ("model", "modelConfig", "tokenizer", "decoder", "decoderConfig", "characterRuntimes")}
            return values
        anchor = population(runs[0])
        if any(population(run) != anchor for run in runs[1:]):
            errors.append(f"{side}: mixed source/model/policy/build/device/thermal populations; compare separately")
    # Preserve every attempt; refuse to compute an attractive subset after a failure.
    valid = not errors
    by_voice = {}
    aggregate = None
    review, pending = [], []
    if valid:
        for character in sorted({p["characterID"] for p in pairs}):
            selected = [p for p in pairs if p["characterID"] == character]
            if len({p["workloadSHA256"] for p in selected}) != 1:
                errors.append(f"{character}: mixed workloads inside repetition population")
            by_voice[character] = {metric: summary([p[metric] for p in selected], policy)
                                  for metric in ("wallRatio", "rawRTFRatio", "firstNeededPCMRatio", "peakFootprintRatio")}
        aggregate = summary([p["wallRatio"] for p in pairs], policy,
                            strata=[[p["wallRatio"] for p in pairs if p["characterID"] == voice] for voice in sorted(by_voice)])
        for character, metrics in by_voice.items():
            if metrics["firstNeededPCMRatio"]["median"] > 1 + gates["screening"]["latency_median_regression_review_percent"] / 100:
                review.append(f"{character}: first-needed PCM median regresses >5%")
            if metrics["peakFootprintRatio"]["median"] > 1 + gates["screening"]["peak_footprint_growth_review_percent"] / 100:
                review.append(f"{character}: peak footprint median grows >5%; requires explicit memory tradeoff and scene stress evidence")
            selected = [p for p in pairs if p["characterID"] == character]
            for segment in range(len(selected[0]["orderedPCMReadyRatios"])):
                ratios = [p["orderedPCMReadyRatios"][segment] for p in selected]
                if None in ratios or statistics.median(ratios) > 1.05:
                    review.append(f"{character}: ordered PCM segment {segment} median regresses >5%")
        if any(not p["rawOutputIdenticalLength"] for p in pairs):
            pending.append("Output duration changed: wall-time win is not same-work proof; fixed-work parity and content/quality review required")
    required_count = gates["screening"]["minimum_valid_paired_repetitions"]
    missing_repetitions = [voice for voice in policy["required_character_ids"] if sum(p["characterID"] == voice for p in pairs) < required_count]
    if missing_repetitions:
        pending.append(f"At least {required_count} valid pairs required for each of all five voices; incomplete: {', '.join(missing_repetitions)}")
    orders = {(x.get("baselineRunID"), x.get("candidateRunID")): x.get("order") for x in experiment.get("pairOrder", [])}
    matched_orders = [orders.get((p["baselineRunID"], p["candidateRunID"])) for p in pairs]
    interleaved = all(x in ("AB", "BA") for x in matched_orders) and set(matched_orders) == {"AB", "BA"}
    if not interleaved:
        pending.append("Paired interleaved AB/BA ordering not documented for every attempt")
    inspected = evidence_review(evidence, Path(evidence_root))
    for key, entry in inspected.items():
        if not entry["verifiedArtifact"]:
            pending.append(f"Independent {key} evidence missing/unverified")
        if entry["claimedStatus"] == "FAIL":
            errors.append(f"Independent {key} qualification failed")
    if not baseline or any(not is_physical_vision_pro((x.get("observation") or {}).get("deviceModel")) for x in baseline + candidate):
        pending.append("Host/device identity is not verified Vision Pro; host result cannot qualify headset performance")
    if any((x.get("runtimeContract") or {}).get("residencyMode") != "independentFresh2" for x in baseline + candidate):
        pending.append("Isolated decoder is not the concurrent Fresh2 production workload")
    if any("isolated" in str((x.get("observation") or {}).get("sceneCondition", "")).lower() for x in baseline + candidate):
        pending.append("Isolated workload is not sustained full-scene qualification")
    if any(x.get("qualityEvidence") is not None for x in baseline + candidate):
        pending.append("Quality evidence capture retains PCM/code arrays; repeat without capture for performance promotion")
    clear_win = aggregate and aggregate["median"] <= 1 - gates["screening"]["minimum_median_improvement_percent"] / 100 and aggregate["medianUncertaintyInterval"][1] < 1
    changed_work = valid and any(not p["rawOutputIdenticalLength"] for p in pairs)
    screen = "INVALID" if errors else "REGRESSION_REVIEW" if review else "OUTPUT_LENGTH_REVIEW" if changed_work else "INSUFFICIENT_REPETITIONS" if missing_repetitions or not interleaved else "PERFORMANCE_SCREEN_PASSED" if clear_win else "NO_CLEAR_IMPROVEMENT"
    result = {"schemaVersion": 1, "experimentID": experiment.get("id"), "comparability": "INVALID" if errors else "COMPARABLE",
            "performanceScreen": screen, "promotionStatus": "REJECTED" if errors else "DEVICE_QUALIFICATION_PENDING",
            "automaticPromotion": False, "readyForManualQualificationReview": not errors and not review and not pending and bool(clear_win),
            "errors": errors, "reviewRequired": review, "pendingQualification": pending,
            "pairCount": len(pairs), "pairs": pairs, "byCharacter": by_voice, "pooledPairedWallRatio": aggregate,
            "evidence": inspected, "qualityFromPCMHash": False,
            "interpretation": "Ratio = candidate / baseline; below 1 is faster. Pooled pairs are not workload-duration weighting. No robust p95 from five pairs. No device, quality, or safety claims from host timing. No runtime configuration changed."}
    def json_safe(value):
        if isinstance(value, float) and not math.isfinite(value):
            return f"INVALID_NONFINITE:{value}"
        if isinstance(value, dict):
            return {k: json_safe(v) for k, v in value.items()}
        if isinstance(value, list):
            return [json_safe(v) for v in value]
        return value
    return json_safe(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", nargs="+", required=True, type=Path)
    parser.add_argument("--candidate", nargs="+", required=True, type=Path)
    parser.add_argument("--experiment", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--gates", type=Path, default=ROOT / "qwen-performance-gates.json")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    artifacts = []
    def read_report(path, side):
        try:
            value = load(path)
            artifacts.append({"role": side, "path": str(path.resolve()), "sha256": sha256(path)})
            return value
        except (OSError, ValueError) as error:
            artifacts.append({"role": side, "path": str(path.resolve()), "error": str(error)})
            return {"failure": str(error)}
    result = compare([read_report(p, "baseline") for p in args.baseline],
                     [read_report(p, "candidate") for p in args.candidate], load(args.gates),
                     load(args.experiment) if args.experiment else None,
                     load(args.evidence) if args.evidence else None,
                     args.evidence.parent if args.evidence else ROOT)
    result["artifacts"] = artifacts
    result["gatesSHA256"] = sha256(args.gates)
    result["exporterSHA256"] = sha256(__file__)
    for name in ("experiment", "evidence"):
        path = getattr(args, name)
        if path:
            result[name + "Input"] = {"path": str(path.resolve()), "sha256": sha256(path)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")
    print(f"{result['promotionStatus']}: {result['performanceScreen']} ({result['pairCount']} pairs); {args.output}")
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
