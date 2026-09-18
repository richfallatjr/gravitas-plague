#!/usr/bin/env python3
"""Verify and compare saved native Qwen tokens/PCM identity; never judge quality.

No model, audio processing, or device actions are performed. Token differences
and PCM hashes are observations, not listening acceptance or numerical gates.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys


IDENTITY_KEYS = ("model", "modelConfig", "tokenizer", "decoder", "decoderConfig",
                 "characterRuntimes", "referenceCodes", "referenceTextTokens", "speakerEmbedding",
                 "voiceMetadata", "voiceVariant", "referenceAudio")
POLICY_KEYS = ("policyVersion", "arithmetic", "prefill", "predictor", "workspace", "decoderIO", "kernelSet", "decoderState")
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_WAV_BYTES = 16 * 1024 * 1024 + 4096
UINT64_MAX = (1 << 64) - 1


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()


def hash_value(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def integer(value, minimum=0, maximum=None):
    return type(value) is int and value >= minimum and (maximum is None or value <= maximum)


def read_bytes(path, maximum):
    require(path.is_file() and path.stat().st_size <= maximum, f"Missing or oversized evidence file: {path.name}")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, f"Oversized evidence file: {path.name}")
    return data


def read_json(path):
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    data = read_bytes(path, MAX_JSON_BYTES)
    value = json.loads(data, object_pairs_hook=object_pairs,
                       parse_constant=lambda value: require(False, f"Nonfinite JSON: {value}"))
    require(isinstance(value, dict), f"Evidence JSON must be an object: {path.name}")
    return value, data


def confined_file(root, filename):
    require(isinstance(filename, str) and filename not in ("", ".", "..")
            and not any(c in filename for c in ("/", "\\", ":", "\0")),
            "Evidence filename must be a single local filename")
    path = (root / filename).resolve()
    require(path.parent == root.resolve(), "Evidence filename escapes its evidence directory")
    require(path.is_file(), f"Missing evidence file: {filename}")
    return path


def verify_digest(data, claimed, label):
    require(hash_value(claimed) and digest(data) == claimed, f"{label} hash mismatch")


def workload_digest(value):
    required = {"schemaVersion", "id", "origin", "characterID", "voiceID", "language", "segments",
                "samplingSeed", "maximumRowsPerSegment", "wallCapSeconds", "footprintCapMiB"}
    optional = {"decoderCodes", "decoderReferenceRows", "requireCompleteSegments"}
    require(required.issubset(value) and not set(value) - required - optional, "Unknown/incomplete workload schema")
    normalized = {key: item for key, item in value.items() if key not in optional or item is not None}
    for key in ("wallCapSeconds", "footprintCapMiB"):
        number = normalized[key]
        if isinstance(number, float) and number.is_integer():
            normalized[key] = int(number)
    return digest(canonical(normalized))


def policy_digest(value):
    require(set(value) == set(POLICY_KEYS) and integer(value.get("policyVersion"), 1)
            and all(isinstance(value.get(key), str) and value[key] for key in POLICY_KEYS[1:]),
            "Unknown/incomplete execution policy schema")
    return digest("|".join(str(value[key]) for key in POLICY_KEYS).encode())


def validate_rows(rows, count, label, maximum):
    require(integer(count, maximum=maximum) and isinstance(rows, list) and len(rows) == count,
            f"{label} row count mismatch")
    require(all(isinstance(row, list) and len(row) == 16 and all(
        integer(token, maximum=4095 if column == 0 else 2047) for column, token in enumerate(row)) for row in rows),
        f"{label} must have 16 integer columns: semantic 0...4095, residual 0...2047")


def wav_metadata(data):
    require(len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WAVE"
            and struct.unpack_from("<I", data, 4)[0] == len(data) - 8, "Invalid WAV RIFF header/length")
    chunks, offset = {}, 12
    while offset < len(data):
        require(offset + 8 <= len(data), "Truncated WAV chunk header")
        tag, size = struct.unpack_from("<4sI", data, offset)
        end = offset + 8 + size
        require(end <= len(data), "Truncated WAV chunk")
        if tag in (b"fmt ", b"fact", b"data"):
            require(tag not in chunks, "Duplicate WAV format/fact/data chunk")
            chunks[tag] = data[offset + 8:end]
        offset = end + (size % 2)
    require(offset == len(data) and all(tag in chunks for tag in (b"fmt ", b"fact", b"data")), "Missing WAV format/fact/data chunk")
    require(len(chunks[b"fmt "]) >= 16 and len(chunks[b"fact"]) == 4, "Invalid WAV format/fact chunk")
    encoding, channels, rate, byte_rate, alignment, bits = struct.unpack_from("<HHIIHH", chunks[b"fmt "])
    require(encoding == 3 and channels == 1 and bits == 32 and alignment == 4
            and rate > 0 and byte_rate == rate * 4, "Expected native mono IEEE float32 WAV")
    payload = chunks[b"data"]
    require(len(payload) > 0 and len(payload) % 4 == 0, "Invalid WAV PCM byte length")
    count = len(payload) // 4
    require(struct.unpack("<I", chunks[b"fact"])[0] == count, "WAV fact sample count mismatch")
    return {"sampleCount": count, "sampleRate": rate, "durationSeconds": count / rate,
            "pcmF32LESHA256": digest(payload)}


def load_evidence(path):
    path = Path(path)
    path = path / "evidence.json" if path.is_dir() else path
    manifest, manifest_bytes = read_json(path)
    root = path.parent.resolve()
    require(manifest.get("schemaVersion") == 1 and manifest.get("performancePromotionEligible") is False
            and manifest.get("serializationAfterRenderTiming") is True, "Invalid quality evidence contract")
    require(manifest.get("status") == "UNASSESSED_REQUIRES_LISTENING_AND_TOKEN_COMPARISON", "Incomplete/unavailable evidence manifest")
    for key in ("runID", "characterID", "voiceID", "samplingSeedPolicy"):
        require(isinstance(manifest.get(key), str) and manifest[key], f"Missing evidence {key}")
    require(manifest["samplingSeedPolicy"] == "fixture seed + segment index (UInt64 wrapping addition)", "Unknown sampling seed policy")
    workload, _ = read_json(confined_file(root, manifest.get("workloadFilename")))
    policy, _ = read_json(confined_file(root, manifest.get("policyFilename")))
    require(workload_digest(workload) == manifest.get("workloadSHA256"), "Workload hash mismatch")
    require(policy_digest(policy) == manifest.get("policySHA256"), "Execution policy hash mismatch")
    texts = workload.get("segments")
    maximum_rows = workload.get("maximumRowsPerSegment")
    require(workload.get("requireCompleteSegments") is True and integer(maximum_rows, 1, 160)
            and workload.get("decoderCodes") is None, "Evidence requires full-segment generation workload")
    require(isinstance(texts, list) and 1 <= len(texts) <= 6 and all(isinstance(x, str) and x.strip() for x in texts), "Invalid workload segments")
    require(integer(workload.get("samplingSeed"), maximum=UINT64_MAX), "Invalid UInt64 sampling seed")
    require(manifest.get("maximumRowsPerSegment") == maximum_rows
            and all(manifest[key] == workload[key] for key in ("characterID", "voiceID")), "Workload/manifest voice or row limit mismatch")
    identity = manifest.get("identitySHA256")
    require(isinstance(identity, dict) and all(hash_value(identity.get(key)) for key in IDENTITY_KEYS)
            and all(hash_value(value) for value in identity.values()), "Missing/invalid model, voice, or reference identity")
    segments = manifest.get("segments")
    require(isinstance(segments, list) and len(segments) == len(texts) and all(isinstance(x, dict) for x in segments), "Incomplete segment evidence")
    indices = [x.get("segmentIndex") for x in segments]
    require(all(integer(index) for index in indices) and sorted(indices) == list(range(len(texts))), "Missing/duplicate/out-of-range segment evidence")
    loaded = []
    for segment in sorted(segments, key=lambda value: value["segmentIndex"]):
        index = segment["segmentIndex"]
        require(segment.get("voiceID") == manifest["voiceID"] and segment.get("text") == texts[index], f"Segment {index} voice/text mismatch")
        verify_digest(texts[index].encode(), segment.get("textSHA256"), f"Segment {index} text")
        require(integer(segment.get("samplingSeed"), maximum=UINT64_MAX)
                and segment["samplingSeed"] == (workload["samplingSeed"] + index) & UINT64_MAX, f"Segment {index} sampling seed mismatch")
        require(segment.get("status") == "CAPTURED_UNASSESSED" and segment.get("unavailable") == [], f"Segment {index} evidence unavailable")
        eos = segment.get("reachedEOS")
        require(type(eos) is bool and segment.get("stopReason") == ("naturalEOS" if eos else "didNotReachEOS"), f"Segment {index} missing/inconsistent EOS evidence")
        rows_count = segment.get("generatedRowCount")
        require(integer(rows_count, 1, maximum_rows) and segment.get("codebookCount") == 16, f"Segment {index} invalid generated row/codebook count")
        codes, codes_bytes = read_json(confined_file(root, segment.get("codeRowsFilename")))
        verify_digest(codes_bytes, segment.get("codeRowsFileSHA256"), f"Segment {index} code rows file")
        require(codes.get("schemaVersion") == 1 and all(codes.get(key) == expected for key, expected in
                (("runID", manifest["runID"]), ("voiceID", manifest["voiceID"]), ("segmentIndex", index))), f"Segment {index} code rows identity mismatch")
        generated = codes.get("generatedCodeRows")
        references = codes.get("conditioningReferenceCodeRows")
        decode = codes.get("decodeReferenceCodeRows")
        validate_rows(generated, rows_count, f"Segment {index} generated", 160)
        validate_rows(references, segment.get("conditioningReferenceRowCount"), f"Segment {index} conditioning", 32768)
        decode_count = segment.get("decodeReferenceRowCount")
        validate_rows(decode, decode_count, f"Segment {index} decode reference", 32768)
        require(decode_count <= len(references) and decode == (references[-decode_count:] if decode_count else []), f"Segment {index} decode reference is not the saved conditioning suffix")
        generated_bytes = b"".join(struct.pack("<16i", *row) for row in generated)
        verify_digest(generated_bytes, segment.get("generatedCodesI32LESHA256"), f"Segment {index} generated code payload")
        wav_bytes = read_bytes(confined_file(root, segment.get("wavFilename")), MAX_WAV_BYTES)
        verify_digest(wav_bytes, segment.get("wavFileSHA256"), f"Segment {index} WAV file")
        wav = wav_metadata(wav_bytes)
        require(integer(segment.get("sampleCount"), 1) and integer(segment.get("sampleRate"), 1)
                and all(wav[key] == segment.get(key) for key in ("sampleCount", "sampleRate", "pcmF32LESHA256")), f"Segment {index} WAV/PCM metadata mismatch")
        loaded.append({"metadata": segment, "codes": codes, "wav": wav})
    require(manifest.get("runOutcome") in ("SCOUT_COMPLETED", "FAILED_OR_BUDGET_STOPPED"), "Unknown native run outcome")
    if manifest["runOutcome"] == "SCOUT_COMPLETED":
        require(not manifest.get("runFailure") and all(x["metadata"]["reachedEOS"] is True for x in loaded), "Successful full run lacks natural completion")
    return {"manifest": manifest, "manifestSHA256": digest(manifest_bytes), "path": str(path.resolve()),
            "workload": workload, "policy": policy, "segments": loaded}


def token_difference(baseline, candidate):
    shared_rows = min(len(baseline), len(candidate))
    prefix = 0
    first = None
    for row in range(shared_rows):
        for column in range(16):
            if baseline[row][column] != candidate[row][column]:
                first = {"kind": "token", "rowIndex": row, "codebookColumn": column,
                         "baselineToken": baseline[row][column], "candidateToken": candidate[row][column]}
                break
            prefix += 1
        if first:
            break
    common_equal = first is None
    if first is None and len(baseline) != len(candidate):
        first = {"kind": "rowCount", "rowIndex": shared_rows, "codebookColumn": 0,
                 "baselineToken": baseline[shared_rows][0] if len(baseline) > shared_rows else None,
                 "candidateToken": candidate[shared_rows][0] if len(candidate) > shared_rows else None}
    return {"identicalGeneratedRows": baseline == candidate, "equalCommonPrefix": common_equal,
            "commonPrefixTokenCount": prefix, "commonPrefixWholeRows": prefix // 16,
            "firstTokenDivergence": first}


def compare(baseline_path, candidate_path):
    result = {"schemaVersion": 1, "status": "INVALID_EVIDENCE", "qualityStatus": "NOT_A_QUALITY_PASS",
              "performancePromotionEligible": False, "qualityFromHashes": False, "errors": [], "segments": [],
              "pendingGates": ["Human listening/content acceptance has not been assessed.",
                  "Predeclared numerical tolerances and alignment/error measures have not been assessed.",
                  "Build/device provenance and performance qualification are outside this evidence comparison."],
              "interpretation": "Zero-based row/codebook columns; column 0 is semantic, columns 1...15 residual. EOS is separate metadata, never appended as an invented code row. Equal PCM hashes establish byte identity only."}
    sides = {}
    for label, path in (("baseline", baseline_path), ("candidate", candidate_path)):
        try:
            sides[label] = load_evidence(path)
            side = sides[label]
            result[label] = {"manifest": side["path"], "manifestSHA256": side["manifestSHA256"],
                             "runID": side["manifest"]["runID"], "policySHA256": side["manifest"]["policySHA256"]}
        except (OSError, ValueError, TypeError, KeyError, struct.error) as error:
            result["errors"].append(f"{label}: {error}")
    if result["errors"]:
        return result
    a, b = sides["baseline"], sides["candidate"]
    for key in ("workloadSHA256", "characterID", "voiceID", "samplingSeedPolicy", "maximumRowsPerSegment", "identitySHA256"):
        if a["manifest"][key] != b["manifest"][key]:
            result["errors"].append(f"Unmatched evidence control: {key}")
    if result["errors"]:
        return result
    result["policyDifferences"] = {key: {"baseline": a["policy"][key], "candidate": b["policy"][key]}
                                   for key in POLICY_KEYS if a["policy"][key] != b["policy"][key]}
    for left, right in zip(a["segments"], b["segments"]):
        lm, rm = left["metadata"], right["metadata"]
        index = lm["segmentIndex"]
        for key in ("textSHA256", "samplingSeed", "conditioningReferenceRowCount", "decodeReferenceRowCount"):
            if lm[key] != rm[key]:
                result["errors"].append(f"Segment {index} unmatched control: {key}")
        for key in ("conditioningReferenceCodeRows", "decodeReferenceCodeRows"):
            if left["codes"][key] != right["codes"][key]:
                result["errors"].append(f"Segment {index} unmatched exact reference rows: {key}")
        segment = {"segmentIndex": index, "textSHA256": lm["textSHA256"], "samplingSeed": lm["samplingSeed"],
                   **token_difference(left["codes"]["generatedCodeRows"], right["codes"]["generatedCodeRows"]),
                   "baselineRows": lm["generatedRowCount"], "candidateRows": rm["generatedRowCount"],
                   "baselineReachedEOS": lm["reachedEOS"], "candidateReachedEOS": rm["reachedEOS"],
                   "bothNaturallyCompleted": lm["reachedEOS"] and rm["reachedEOS"],
                   "baselinePCM": left["wav"], "candidatePCM": right["wav"],
                   "identicalPCM": lm["pcmF32LESHA256"] == rm["pcmF32LESHA256"]}
        result["segments"].append(segment)
    if result["errors"]:
        result["segments"] = []
    else:
        result["status"] = "EVIDENCE_COMPARABLE"
        result["allSegmentsNaturallyCompleted"] = all(x["bothNaturallyCompleted"] for x in result["segments"])
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path, help="Evidence directory or evidence.json")
    parser.add_argument("--candidate", required=True, type=Path, help="Evidence directory or evidence.json")
    parser.add_argument("--output", required=True, type=Path, help="New comparison JSON path; never overwritten")
    args = parser.parse_args(argv)
    if args.output.exists():
        parser.error("Use a new output path; comparison evidence must not overwrite earlier files")
    result = compare(args.baseline, args.candidate)
    try:
        with args.output.open("x") as stream:
            json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
    except OSError as error:
        parser.error(str(error))
    print(json.dumps({"status": result["status"], "qualityStatus": result["qualityStatus"], "output": str(args.output)}))
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
