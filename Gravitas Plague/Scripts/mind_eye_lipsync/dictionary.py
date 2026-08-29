from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re

from .mfa_json import normalize_arpa_phone
from .phones import ARPA_INVENTORY
from .transcript import NormalizedTranscript


@dataclass(frozen=True, slots=True)
class MergedDictionary:
    path: Path
    oov_words: tuple[str, ...]
    g2p_words: tuple[str, ...]
    override_words: tuple[str, ...]


def _base_words(path: Path) -> set[str]:
    words: set[str] = set()
    with path.open(encoding="utf-8", errors="strict") as stream:
        for line in stream:
            fields = line.split()
            if fields:
                words.add(fields[0].lower())
    return words


def _reviewed_overrides(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 2:
            raise ValueError(f"Invalid pronunciation override at line {line_number}")
        word, phones = fields[0].lower(), fields[1:]
        if not re.fullmatch(r"[a-z0-9']+", word) or word in result:
            raise ValueError(f"Unsafe or duplicate pronunciation override: {word}")
        invalid = [phone for phone in phones if normalize_arpa_phone(phone) not in ARPA_INVENTORY]
        if invalid:
            raise ValueError(f"Pronunciation override uses non-ARPA phones: {word}: {invalid}")
        result[word] = " ".join(phones)
    return result


def _generate_pronunciations(
    words: tuple[str, ...],
    *,
    g2p_model: Path,
    extraction_root: Path,
) -> dict[str, str]:
    if not words:
        return {}
    try:
        import pynini
        from montreal_forced_aligner.g2p.generator import scored_top_rewrites
        from montreal_forced_aligner.models import G2PModel
    except ImportError as error:
        raise RuntimeError("Pinned MFA/Pynini G2P environment is unavailable") from error
    model = G2PModel(g2p_model, root_directory=extraction_root)
    allowed = set(model.meta["graphemes"])
    generated: dict[str, str] = {}
    for word in words:
        if any(character not in allowed for character in word):
            raise ValueError(
                f"Pinned G2P cannot resolve unsupported orthography {word!r}; add a reviewed spoken substitution or pronunciation override"
            )
        word_fst = pynini.accep(word, token_type="utf8")
        candidates = scored_top_rewrites(
            word_fst,
            model.fst,
            nshortest=1,
            input_token_type=None,
            output_token_type=model.phone_table,
        )
        if not candidates or not candidates[0].pronunciation.strip():
            raise ValueError(f"Pinned G2P produced no pronunciation for {word!r}")
        phones = candidates[0].pronunciation.split()
        invalid = [phone for phone in phones if normalize_arpa_phone(phone) not in ARPA_INVENTORY]
        if invalid:
            raise ValueError(f"Pinned G2P emitted non-ARPA phones for {word!r}: {invalid}")
        generated[word] = " ".join(phones)
    return generated


def build_merged_dictionary(
    *,
    base_dictionary: Path,
    pronunciation_overrides: Path,
    transcript: NormalizedTranscript,
    g2p_model: Path,
    destination: Path,
    extraction_root: Path,
) -> MergedDictionary:
    words = tuple(sorted(set(transcript.hash_text.split())))
    base_words = _base_words(base_dictionary)
    overrides = _reviewed_overrides(pronunciation_overrides)
    oov = tuple(word for word in words if word not in base_words)
    override_words = tuple(word for word in oov if word in overrides)
    g2p_words = tuple(word for word in oov if word not in overrides)
    generated = _generate_pronunciations(
        g2p_words,
        g2p_model=g2p_model,
        extraction_root=extraction_root,
    )
    additions = {word: overrides[word] for word in override_words}
    additions.update(generated)
    base = base_dictionary.read_bytes()
    if not base.endswith(b"\n"):
        base += b"\n"
    appended = "".join(f"{word}\t{additions[word]}\n" for word in sorted(additions)).encode("utf-8")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp")
    temporary.write_bytes(base + appended)
    temporary.replace(destination)
    return MergedDictionary(destination, oov, g2p_words, override_words)
