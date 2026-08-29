from __future__ import annotations

from collections import Counter
from .registry import build_registry_payload, validate_registry


def inventory() -> dict:
    payload = build_registry_payload()
    validate_registry(payload)
    unique = Counter(item["speakerCharacterID"] for item in payload["clips"])
    weighted = Counter()
    for item in payload["clips"]: weighted[item["speakerCharacterID"]] += item["weight"]
    return {"status": "PASS", "uniqueClipCount": len(payload["clips"]),
            "weightedEntryCount": sum(weighted.values()),
            "speakerUniqueCounts": dict(unique), "speakerWeightedTotals": dict(weighted)}
