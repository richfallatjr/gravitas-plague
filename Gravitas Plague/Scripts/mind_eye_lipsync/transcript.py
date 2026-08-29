from __future__ import annotations

from dataclasses import dataclass
import re
import unicodedata


@dataclass(frozen=True, slots=True)
class NormalizedTranscript:
    original: str
    alignment_text: str
    hash_text: str
    token_count: int
    substitutions: tuple[str, ...] = ()


_WHITESPACE = re.compile(r"\s+")
_SMART_APOSTROPHES = str.maketrans({"\u2018": "'", "\u2019": "'", "\u02bc": "'"})
_SMART_QUOTES = str.maketrans({"\u201c": '"', "\u201d": '"'})
_DIGIT_WORDS = {
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
    "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
}
_TEENS = {
    "10": "ten", "11": "eleven", "12": "twelve", "13": "thirteen",
    "14": "fourteen", "15": "fifteen", "16": "sixteen", "17": "seventeen",
    "18": "eighteen", "19": "nineteen",
}


def _expand_number(match: re.Match[str], substitutions: list[str]) -> str:
    value = match.group(0)
    expanded = _TEENS.get(value)
    if expanded is None:
        expanded = " ".join(_DIGIT_WORDS[digit] for digit in value)
    substitutions.append(f"numericExpansion:{value}->{expanded.replace(' ', '_')}")
    return expanded


def normalize_transcript(value: str) -> NormalizedTranscript:
    if not isinstance(value, str):
        raise TypeError("Transcript must be text.")
    original = value
    normalized = unicodedata.normalize("NFKC", value)
    normalized = normalized.translate(_SMART_APOSTROPHES).translate(_SMART_QUOTES)
    substitutions: list[str] = []
    normalized = re.sub(r"(?<=\d)\.(?=\d)", " point ", normalized)
    normalized = normalized.replace("\u2014", " ").replace("\u2013", " ")
    normalized = normalized.replace("\u2026", " ")
    normalized = re.sub(r"[^0-9A-Za-z' -]+", " ", normalized)
    normalized = normalized.replace("-", " ")
    normalized = _WHITESPACE.sub(" ", normalized).strip()
    normalized = re.sub(
        r"\b\d+\b",
        lambda match: _expand_number(match, substitutions),
        normalized,
    )
    normalized = _WHITESPACE.sub(" ", normalized).strip()
    if not normalized:
        raise ValueError("Transcript is empty after normalization.")
    hash_text = normalized.lower()
    return NormalizedTranscript(
        original=original,
        alignment_text=normalized,
        hash_text=hash_text,
        token_count=len(hash_text.split(" ")),
        substitutions=tuple(sorted(set(substitutions))),
    )
