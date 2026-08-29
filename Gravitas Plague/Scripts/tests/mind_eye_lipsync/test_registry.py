from __future__ import annotations

from collections import Counter

import pytest

from mind_eye_lipsync.registry import load_registry


def test_locked_registry_counts_and_safety() -> None:
    registry = load_registry()
    assert len(registry.entries) == 37
    assert len(registry.exclusions) == 8
    assert Counter(entry.speaker_character_id for entry in registry.entries) == {
        "big_mike": 10, "rich": 15, "broadcaster": 5, "cateye81": 5, "dad": 2,
    }
    ids = {entry.pr_id for entry in registry.entries}
    assert "prologue.walkie.bigMike.scriptPoint05.001" in ids
    assert "prologue.walkie.bigMike.scriptPoint05.002" in ids
    assert not ids & registry.excluded_ids


def test_owner_filename_typo_is_preserved() -> None:
    registry = load_registry()
    entry = registry.require_entry("chapter02.hamReceiver.rich.revelation.001")
    assert entry.audio_file == "pr-rich-ham-receiever-what-do-you-believe.mp3"


def test_excluded_pr_cannot_resolve_as_compilable_entry() -> None:
    registry = load_registry()
    with pytest.raises(ValueError):
        registry.require_entry("chapter03.battle.mike.surrender.002")
