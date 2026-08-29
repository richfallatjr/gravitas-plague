#!/usr/bin/env python3
"""Validate the shipped Mind's Eye catalog and vignette source assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
from typing import Any
from urllib.parse import unquote


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SOURCE_SIZE = (2304, 1296)
VIEWPORT_SIZE = (1920, 1080)
VIEWPORT_RECT = {"origin": {"x": 192, "y": 108}, "size": {"width": 1920, "height": 1080}}
MOUTH_POSES = ("rest", "small", "wide", "round", "teeth")
IGNORED_PARTS = {".git", "DerivedData", "build", ".build", "TestResults", "xcresult"}


def checked_product(*values: int) -> int:
    result = 1
    for value in values:
        if value < 0 or (value and result > sys.maxsize // value):
            raise OverflowError("integer byte estimate overflow")
        result *= value
    return result


def safe_relative_path(value: Any, suffix: str | None = None) -> bool:
    if not isinstance(value, str) or not value or value.startswith(("/", "~")):
        return False
    if "\\" in value or "\x00" in value or "://" in value:
        return False
    decoded = unquote(value)
    if not decoded or decoded.startswith(("/", "~")) or "\\" in decoded or "\x00" in decoded or "://" in decoded:
        return False
    parts = decoded.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    return suffix is None or decoded.lower().endswith("." + suffix.lower())


def safe_id(value: Any) -> bool:
    return isinstance(value, str) and bool(value) and all(
        character == "_" or "a" <= character <= "z" or "0" <= character <= "9"
        for character in value
    )


def resolve_under(root: Path, relative: str) -> Path:
    if not safe_relative_path(relative):
        raise ValueError("unsafePath")
    root = root.resolve()
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ValueError("unsafePath") from error
    return candidate


def read_json(path: Path) -> Any:
    data = path.read_bytes()
    if not data:
        raise ValueError("emptyJSON")
    return json.loads(data.decode("utf-8"))


def parse_png_header(path: Path) -> dict[str, int]:
    data = path.read_bytes()[:33]
    if len(data) < 33 or data[:8] != PNG_SIGNATURE:
        raise ValueError("invalidPNGSignature")
    length, chunk_type = struct.unpack(">I4s", data[8:16])
    if length != 13 or chunk_type != b"IHDR":
        raise ValueError("missingFirstIHDR")
    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", data[16:29]
    )
    return {
        "width": width,
        "height": height,
        "bitDepth": bit_depth,
        "colorType": color_type,
        "compression": compression,
        "filter": filtering,
        "interlace": interlace,
    }


def run_json_tool(executable: str, arguments: list[str]) -> Any:
    process = subprocess.run(
        [executable, *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode != 0:
        message = process.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(message or f"tool exited {process.returncode}")
    return json.loads(process.stdout.decode("utf-8"))


def decode_pixels(ffmpeg: str, path: Path, pixel_format: str) -> bytes:
    process = subprocess.run(
        [ffmpeg, "-v", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", pixel_format, "-"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode != 0:
        message = process.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(message or f"ffmpeg exited {process.returncode}")
    return process.stdout


class Validator:
    def __init__(self, arguments: argparse.Namespace) -> None:
        self.project_root = Path(arguments.project_root).resolve()
        self.resources_root = Path(arguments.resources_root).resolve()
        self.catalog_relative = arguments.catalog
        self.ffprobe = arguments.ffprobe
        self.ffmpeg = arguments.ffmpeg
        self.check_duplicates = arguments.check_duplicates
        self.errors: list[dict[str, str]] = []
        self.warnings: list[dict[str, str]] = []
        self.packages: list[dict[str, Any]] = []
        self.declared: list[dict[str, Any]] = []

    def diagnostic(
        self,
        code: str,
        message: str,
        *,
        character: str = "",
        vignette: str = "",
        role: str = "",
        path: str = "",
    ) -> None:
        self.errors.append(
            {
                "characterID": character,
                "vignetteID": vignette,
                "assetRole": role,
                "assetPath": path,
                "code": code,
                "message": message,
            }
        )

    def validate(self) -> dict[str, Any]:
        try:
            catalog_path = resolve_under(self.resources_root, self.catalog_relative)
        except ValueError:
            self.diagnostic("unsafePath", "Catalog path is unsafe.", path=self.catalog_relative)
            return self.report()
        if not catalog_path.is_file():
            self.diagnostic("catalogMissing", "Catalog file is missing.", path=self.catalog_relative)
            return self.report()
        try:
            catalog = read_json(catalog_path)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
            self.diagnostic("catalogInvalid", str(error), path=self.catalog_relative)
            return self.report()

        entries = catalog.get("entries") if isinstance(catalog, dict) else None
        if catalog.get("schemaVersion") != 1 or not isinstance(entries, list):
            self.diagnostic("catalogInvalid", "Catalog schemaVersion must be 1 and entries must be an array.", path=self.catalog_relative)
            return self.report()

        characters: set[str] = set()
        vignette_ids: set[str] = set()
        manifest_paths: set[str] = set()
        work: list[tuple[str, str, str]] = []
        for entry in entries:
            if not isinstance(entry, dict):
                self.diagnostic("catalogInvalid", "Catalog entry must be an object.")
                continue
            character = entry.get("characterID", "")
            default = entry.get("defaultVignetteID", "")
            vignettes = entry.get("vignettes")
            if character in characters or not safe_id(character):
                self.diagnostic("catalogInvalid", "Duplicate or invalid character ID.", character=str(character))
                continue
            characters.add(character)
            if not isinstance(vignettes, list) or not vignettes:
                self.diagnostic("catalogInvalid", "Character must declare at least one vignette.", character=character)
                continue
            local_ids: set[str] = set()
            for item in vignettes:
                if not isinstance(item, dict):
                    self.diagnostic("catalogInvalid", "Vignette entry must be an object.", character=character)
                    continue
                vignette = item.get("vignetteID", "")
                manifest = item.get("manifestResourcePath", "")
                if not safe_id(vignette) or vignette in vignette_ids:
                    self.diagnostic("catalogInvalid", "Duplicate or invalid vignette ID.", character=character, vignette=str(vignette))
                    continue
                if not safe_relative_path(manifest, "json") or manifest in manifest_paths:
                    self.diagnostic("catalogInvalid", "Duplicate or unsafe manifest path.", character=character, vignette=vignette, path=str(manifest))
                    continue
                vignette_ids.add(vignette)
                local_ids.add(vignette)
                manifest_paths.add(manifest)
                work.append((character, vignette, manifest))
            if default not in local_ids:
                self.diagnostic("catalogInvalid", "Default vignette is not declared.", character=character, vignette=str(default))

        if self.errors:
            return self.report()
        for character, vignette, manifest in sorted(work):
            self.validate_package(character, vignette, manifest)
        if self.check_duplicates:
            self.validate_duplicate_sources()
        return self.report()

    def validate_package(self, character: str, vignette: str, manifest_relative: str) -> None:
        try:
            manifest_path = resolve_under(self.resources_root, manifest_relative)
        except ValueError:
            self.diagnostic("unsafePath", "Manifest path escaped the resources root.", character=character, vignette=vignette, path=manifest_relative)
            return
        if not manifest_path.is_file():
            self.diagnostic("manifestMissing", "Manifest file is missing.", character=character, vignette=vignette, path=manifest_relative)
            return
        try:
            manifest = read_json(manifest_path)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
            self.diagnostic("manifestInvalid", str(error), character=character, vignette=vignette, path=manifest_relative)
            return

        self.validate_manifest_schema(manifest, character, vignette, manifest_relative)
        layers = manifest.get("layers", {}) if isinstance(manifest, dict) else {}
        eyes = layers.get("eyes", {}) if isinstance(layers, dict) else {}
        mouths = layers.get("mouths", {}) if isinstance(layers, dict) else {}
        role_paths: list[tuple[str, str, tuple[int, int], str]] = []

        def add(role: str, value: Any, size: tuple[int, int], rule: str) -> None:
            if isinstance(value, str):
                role_paths.append((role, value, size, rule))

        add("background", layers.get("background"), SOURCE_SIZE, "background")
        add("characterBase", layers.get("characterBase"), SOURCE_SIZE, "base")
        add("featherMask", layers.get("featherMask"), VIEWPORT_SIZE, "mask")
        for index, value in enumerate(eyes.get("open", []) if isinstance(eyes, dict) else []):
            add(f"eyes.open[{index}]", value, SOURCE_SIZE, "overlay")
        for index, value in enumerate(eyes.get("closed", []) if isinstance(eyes, dict) else []):
            add(f"eyes.closed[{index}]", value, SOURCE_SIZE, "overlay")
        for pose in MOUTH_POSES:
            for index, value in enumerate(mouths.get(pose, []) if isinstance(mouths, dict) else []):
                add(f"mouths.{pose}[{index}]", value, SOURCE_SIZE, "overlay")

        declared_paths = [path for _, path, _, _ in role_paths]
        if len(set(declared_paths)) != len(declared_paths):
            self.diagnostic("duplicateAssetReference", "One PNG is assigned more than once.", character=character, vignette=vignette)

        package_dir = manifest_path.parent.resolve()
        start_error_count = len(self.errors)
        package_assets: list[dict[str, Any]] = []
        for role, relative, expected_size, rule in role_paths:
            metadata = self.validate_png(character, vignette, role, package_dir, relative, expected_size, rule)
            if metadata is not None:
                package_assets.append(metadata)
                self.declared.append(metadata)

        if package_dir.is_dir():
            declared_set = set(declared_paths)
            for child in sorted(package_dir.iterdir(), key=lambda path: path.name):
                if child.is_file() and child.suffix.lower() == ".png" and child.name not in declared_set:
                    self.diagnostic("orphanAsset", "PNG is not declared by manifest.", character=character, vignette=vignette, path=child.name)
                elif child.is_file() and child.name != "manifest.json" and child.suffix.lower() != ".png":
                    self.diagnostic("orphanMetadata", "Unexpected file in vignette package.", character=character, vignette=vignette, path=child.name)

        source_count = sum(1 for asset in package_assets if asset["assetRole"] != "featherMask")
        mask_count = sum(1 for asset in package_assets if asset["assetRole"] == "featherMask")
        source_bytes = checked_product(*SOURCE_SIZE, 4) * source_count
        mask_bytes = checked_product(*VIEWPORT_SIZE, 4) * mask_count
        self.packages.append(
            {
                "characterID": character,
                "vignetteID": vignette,
                "manifest": manifest_relative,
                "valid": len(self.errors) == start_error_count,
                "declaredAssetCount": len(role_paths),
                "validatedAssetCount": len(package_assets),
                "sourceTextureCount": len(role_paths),
                "estimatedRGBA8SourceBytes": source_bytes,
                "estimatedMaskRGBBytes": checked_product(*VIEWPORT_SIZE, 3) * mask_count,
                "estimatedResidentTextureBytes": source_bytes + mask_bytes,
                "assets": sorted(package_assets, key=lambda item: (item["assetRole"], item["assetPath"])),
            }
        )

    def validate_manifest_schema(self, manifest: Any, character: str, vignette: str, path: str) -> None:
        if not isinstance(manifest, dict):
            self.diagnostic("manifestInvalid", "Manifest must be an object.", character=character, vignette=vignette, path=path)
            return
        if manifest.get("schemaVersion") != 1:
            self.diagnostic("unsupportedVersion", "Manifest schemaVersion must be 1.", character=character, vignette=vignette, path=path)
        if manifest.get("vignetteID") != vignette or not safe_id(manifest.get("vignetteID")):
            self.diagnostic("invalidVignetteID", "Manifest vignette ID is invalid or mismatched.", character=character, vignette=vignette, path=path)
        if manifest.get("characterID") != character:
            self.diagnostic("characterMismatch", "Manifest character does not match catalog.", character=character, vignette=vignette, path=path)
        if manifest.get("sourceSize") != {"width": 2304, "height": 1296}:
            self.diagnostic("wrongSourceSize", "Source size must be 2304 x 1296.", character=character, vignette=vignette, path=path)
        if manifest.get("viewportSize") != {"width": 1920, "height": 1080}:
            self.diagnostic("wrongViewportSize", "Viewport size must be 1920 x 1080.", character=character, vignette=vignette, path=path)
        if manifest.get("viewportRect") != VIEWPORT_RECT:
            self.diagnostic("wrongViewportRect", "Viewport rect must be centered at 192,108.", character=character, vignette=vignette, path=path)

        layers = manifest.get("layers")
        if not isinstance(layers, dict):
            self.diagnostic("manifestInvalid", "layers must be an object.", character=character, vignette=vignette, path=path)
            return
        eyes = layers.get("eyes")
        mouths = layers.get("mouths")
        if not isinstance(eyes, dict):
            self.diagnostic("manifestInvalid", "eyes must be an object.", character=character, vignette=vignette, path=path)
            eyes = {}
        if not isinstance(mouths, dict):
            self.diagnostic("manifestInvalid", "mouths must be an object.", character=character, vignette=vignette, path=path)
            mouths = {}
        for key, code in (("open", "missingEyeOpen"), ("closed", "missingEyeClosed")):
            values = eyes.get(key)
            if not isinstance(values, list) or not values:
                self.diagnostic(code, f"eyes.{key} must be a nonempty array.", character=character, vignette=vignette, role=f"eyes.{key}")
        for pose in MOUTH_POSES:
            values = mouths.get(pose)
            if not isinstance(values, list) or not values:
                code = "missingMouth" + pose.title()
                self.diagnostic(code, f"mouths.{pose} must be a nonempty array.", character=character, vignette=vignette, role=f"mouths.{pose}")

        path_values: list[tuple[str, Any]] = [
            ("background", layers.get("background")),
            ("characterBase", layers.get("characterBase")),
            ("featherMask", layers.get("featherMask")),
        ]
        for key in ("open", "closed"):
            path_values.extend((f"eyes.{key}", value) for value in eyes.get(key, []) if isinstance(eyes.get(key), list))
        for pose in MOUTH_POSES:
            path_values.extend((f"mouths.{pose}", value) for value in mouths.get(pose, []) if isinstance(mouths.get(pose), list))
        for role, value in path_values:
            if not safe_relative_path(value, "png"):
                self.diagnostic("unsafePath", "Asset path must be a safe PNG path.", character=character, vignette=vignette, role=role, path=str(value))

        self.validate_tuning(manifest, character, vignette)

    def validate_tuning(self, manifest: dict[str, Any], character: str, vignette: str) -> None:
        def finite(value: float) -> bool:
            return value == value and abs(value) != float("inf")

        try:
            depth = manifest["depth"]
            character_depth = float(depth["cameraToCharacterMeters"])
            background_depth = float(depth["cameraToBackgroundMeters"])
            if not (
                finite(character_depth)
                and finite(background_depth)
                and character_depth > 0
                and background_depth > character_depth
            ):
                raise ValueError
        except (KeyError, TypeError, ValueError, OverflowError):
            self.diagnostic("invalidDepth", "Depth tuning is invalid.", character=character, vignette=vignette)

        try:
            motion = manifest["motion"]
            scale = float(motion["sharedScaleMax"])
            counter = float(motion["backgroundCounterMotion"])
            numeric_motion = [
                float(motion["sharedDriftMaxPixels"]["x"]), float(motion["sharedDriftMaxPixels"]["y"]),
                float(motion["sharedRollMaxDegrees"]), scale,
                float(motion["characterParallaxMaxPixels"]["x"]), float(motion["characterParallaxMaxPixels"]["y"]),
                counter, float(motion["gripCorrectionMaxPixels"]["x"]), float(motion["gripCorrectionMaxPixels"]["y"]),
                float(motion["gripCorrectionMaxDegrees"]),
            ]
            x_envelope = numeric_motion[0] + numeric_motion[4] + numeric_motion[7]
            y_envelope = numeric_motion[1] + numeric_motion[5] + numeric_motion[8]
            if not all(value >= 0 and finite(value) for value in numeric_motion):
                raise ValueError
            if (
                not 1.0 <= scale <= 1.05
                or not 0.20 <= counter <= 0.35
                or numeric_motion[2] > 1.5
                or numeric_motion[9] > 1.0
                or x_envelope > 192
                or y_envelope > 108
            ):
                raise ValueError
        except (KeyError, TypeError, ValueError, OverflowError):
            self.diagnostic("invalidMotion", "Motion tuning is invalid.", character=character, vignette=vignette)

        try:
            blink = manifest["blink"]
            ordinary_min = float(blink["ordinaryIntervalMinSeconds"])
            ordinary_max = float(blink["ordinaryIntervalMaxSeconds"])
            gap_min = float(blink["doubleBlinkGapMinSeconds"])
            gap_max = float(blink["doubleBlinkGapMaxSeconds"])
            probability = float(blink["doubleBlinkProbability"])
            if not (0.5 <= ordinary_min <= ordinary_max <= 5.0 and 0.5 <= gap_min <= gap_max <= 1.0 and 0 <= probability <= 1):
                raise ValueError
            if int(blink["closedFrameMin"]) <= 0 or int(blink["closedFrameMax"]) < int(blink["closedFrameMin"]):
                raise ValueError
        except (KeyError, TypeError, ValueError, OverflowError):
            self.diagnostic("invalidBlink", "Blink tuning is invalid.", character=character, vignette=vignette)

        try:
            placement = manifest.get("placement")
            if placement is not None:
                values = [float(placement[key]) for key in ("cardWidthMeters", "cardHeightMeters", "verticalLiftMeters", "forwardOffsetMeters", "shelfClearanceMeters")]
                if (
                    values[0] <= 0
                    or values[1] <= 0
                    or any(not finite(value) for value in values)
                    or any(value < 0 for value in values[2:])
                ):
                    raise ValueError
        except (KeyError, TypeError, ValueError, OverflowError):
            self.diagnostic("invalidPlacement", "Placement tuning is invalid.", character=character, vignette=vignette)

    def validate_png(
        self,
        character: str,
        vignette: str,
        role: str,
        package_dir: Path,
        relative: str,
        expected_size: tuple[int, int],
        rule: str,
    ) -> dict[str, Any] | None:
        if not safe_relative_path(relative, "png"):
            return None
        try:
            asset_root = self.resources_root if "/" in relative else package_dir
            path = resolve_under(asset_root, relative)
        except ValueError:
            self.diagnostic("unsafePath", "Asset escaped vignette package.", character=character, vignette=vignette, role=role, path=relative)
            return None
        if not path.is_file():
            self.diagnostic("assetMissing", "Declared PNG is missing.", character=character, vignette=vignette, role=role, path=relative)
            return None
        byte_count = path.stat().st_size
        if byte_count == 0:
            self.diagnostic("assetZeroBytes", "Declared PNG is zero bytes.", character=character, vignette=vignette, role=role, path=relative)
            return None
        try:
            header = parse_png_header(path)
        except (OSError, ValueError, struct.error) as error:
            self.diagnostic("invalidPNG", str(error), character=character, vignette=vignette, role=role, path=relative)
            return None
        expected_color_type = 2 if rule == "mask" else 6
        if header["bitDepth"] != 8 or header["colorType"] != expected_color_type or header["compression"] != 0 or header["filter"] != 0 or header["interlace"] not in (0, 1):
            self.diagnostic("invalidPNG", "PNG IHDR format does not match semantic role.", character=character, vignette=vignette, role=role, path=relative)
            return None
        if (header["width"], header["height"]) != expected_size:
            self.diagnostic("wrongDimensions", f"Expected {expected_size[0]} x {expected_size[1]}.", character=character, vignette=vignette, role=role, path=relative)
            return None
        try:
            probe = run_json_tool(
                self.ffprobe,
                ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height,pix_fmt", "-of", "json", str(path)],
            )
            streams = probe.get("streams", [])
            stream = streams[0] if streams else {}
            if stream.get("codec_name") != "png" or (stream.get("width"), stream.get("height")) != expected_size:
                raise ValueError("ffprobe dimensions or codec mismatch")
            pixels = decode_pixels(self.ffmpeg, path, "rgb24" if rule == "mask" else "rgba")
        except (OSError, ValueError, json.JSONDecodeError) as error:
            self.diagnostic("invalidPNG", str(error), character=character, vignette=vignette, role=role, path=relative)
            return None

        alpha_min = alpha_max = nonzero = transparent = lum_min = lum_max = distinct = None
        if rule == "mask":
            if len(pixels) != checked_product(*expected_size, 3):
                self.diagnostic("invalidFeatherMask", "Decoded mask byte count is wrong.", character=character, vignette=vignette, role=role, path=relative)
                return None
            luminances: set[int] = set()
            lum_min, lum_max = 255, 0
            for index in range(0, len(pixels), 3):
                red, green, blue = pixels[index : index + 3]
                if abs(red - green) > 2 or abs(green - blue) > 2 or abs(red - blue) > 2:
                    self.diagnostic("invalidFeatherMask", "Mask RGB channels differ by more than 2.", character=character, vignette=vignette, role=role, path=relative)
                    return None
                value = (red + green + blue) // 3
                lum_min = min(lum_min, value)
                lum_max = max(lum_max, value)
                if len(luminances) < 256:
                    luminances.add(value)
            distinct = len(luminances)
            if lum_min > 8 or lum_max < 247 or distinct < 16:
                self.diagnostic("invalidFeatherMask", "Mask lacks the required black-to-white feather range.", character=character, vignette=vignette, role=role, path=relative)
                return None
        else:
            if len(pixels) != checked_product(*expected_size, 4):
                self.diagnostic("invalidPNG", "Decoded RGBA byte count is wrong.", character=character, vignette=vignette, role=role, path=relative)
                return None
            alpha_values = pixels[3::4]
            alpha_min = min(alpha_values)
            alpha_max = max(alpha_values)
            nonzero = sum(value != 0 for value in alpha_values)
            transparent = sum(value != 255 for value in alpha_values)
            if rule == "background" and (alpha_min != 255 or alpha_max != 255):
                self.diagnostic("invalidBackgroundAlpha", "Background must be fully opaque.", character=character, vignette=vignette, role=role, path=relative)
                return None
            if rule in ("base", "overlay") and nonzero == 0:
                self.diagnostic("invalidOverlayAlpha", "Layer has no visible pixels.", character=character, vignette=vignette, role=role, path=relative)
                return None
            if rule == "overlay" and transparent == 0:
                self.diagnostic("invalidOverlayAlpha", "Eye/mouth overlay contains no transparent pixels.", character=character, vignette=vignette, role=role, path=relative)
                return None

        return {
            "characterID": character,
            "vignetteID": vignette,
            "assetRole": role,
            "assetPath": relative,
            "byteCount": byte_count,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "header": header,
            "ffprobePixelFormat": stream.get("pix_fmt", ""),
            "alphaMinimum": alpha_min,
            "alphaMaximum": alpha_max,
            "nonzeroAlphaPixelCount": nonzero,
            "transparentPixelCount": transparent,
            "luminanceMinimum": lum_min,
            "luminanceMaximum": lum_max,
            "distinctLuminanceCount": distinct,
            "absolutePath": str(path),
        }

    def validate_duplicate_sources(self) -> None:
        declared_by_hash: dict[str, list[dict[str, Any]]] = {}
        for asset in self.declared:
            declared_by_hash.setdefault(asset["sha256"], []).append(asset)
        if not declared_by_hash:
            return
        declared_paths = {Path(asset["absolutePath"]).resolve() for asset in self.declared}
        for path in sorted(self.project_root.rglob("*.png")):
            if any(part in IGNORED_PARTS for part in path.parts) or path.resolve() in declared_paths:
                continue
            try:
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
            except OSError:
                continue
            if digest in declared_by_hash:
                for asset in declared_by_hash[digest]:
                    self.diagnostic(
                        "duplicateSourceAsset",
                        f"Declared asset bytes also exist at {path.relative_to(self.project_root)}.",
                        character=asset["characterID"],
                        vignette=asset["vignetteID"],
                        role=asset["assetRole"],
                        path=asset["assetPath"],
                    )

    def report(self) -> dict[str, Any]:
        for asset in self.declared:
            asset.pop("absolutePath", None)
        key = lambda item: (
            item.get("characterID", ""), item.get("vignetteID", ""),
            item.get("assetRole", ""), item.get("assetPath", ""), item.get("code", "")
        )
        self.errors.sort(key=key)
        self.warnings.sort(key=key)
        self.packages.sort(key=lambda item: (item["characterID"], item["vignetteID"]))
        return {
            "version": 1,
            "catalog": self.catalog_relative,
            "vignetteCount": len(self.packages),
            "declaredAssetCount": sum(package["declaredAssetCount"] for package in self.packages),
            "declaredSourceTextureCount": sum(package["sourceTextureCount"] for package in self.packages),
            "estimatedRGBA8SourceBytes": sum(package["estimatedRGBA8SourceBytes"] for package in self.packages),
            "estimatedMaskRGBBytes": sum(package["estimatedMaskRGBBytes"] for package in self.packages),
            "estimatedResidentTextureBytes": sum(package["estimatedResidentTextureBytes"] for package in self.packages),
            "packages": self.packages,
            "errors": self.errors,
            "warnings": self.warnings,
        }


def executable(value: str | None, fallback_name: str) -> str | None:
    if value and os.access(value, os.X_OK):
        return value
    return shutil.which(value or fallback_name)


def parse_arguments() -> argparse.Namespace:
    script = Path(__file__).resolve()
    project_root = script.parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", default=str(project_root))
    parser.add_argument("--resources-root", default=str(project_root / "Gravitas Plague" / "TuringResources"))
    parser.add_argument("--catalog", default="Turing/MindsEye/catalog.json")
    parser.add_argument("--ffprobe", default="/opt/homebrew/bin/ffprobe")
    parser.add_argument("--ffmpeg", default="/opt/homebrew/bin/ffmpeg")
    parser.add_argument("--json-report")
    parser.add_argument("--check-duplicates", action=argparse.BooleanOptionalAction, default=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    arguments.ffprobe = executable(arguments.ffprobe, "ffprobe")
    arguments.ffmpeg = executable(arguments.ffmpeg, "ffmpeg")
    if not arguments.ffprobe or not arguments.ffmpeg:
        print("CONFIGURATION ERROR: ffprobe and ffmpeg are required.", file=sys.stderr)
        return 2
    if not Path(arguments.resources_root).is_dir():
        print(f"CONFIGURATION ERROR: resources root does not exist: {arguments.resources_root}", file=sys.stderr)
        return 2
    report = Validator(arguments).validate()
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.json_report:
        Path(arguments.json_report).write_text(encoded, encoding="utf-8")
    for issue in report["errors"]:
        print(
            "ERROR {code} {characterID} {vignetteID} {assetRole} {assetPath}: {message}".format(**issue).strip()
        )
    if report["errors"]:
        print(f"Mind's Eye asset validation failed with {len(report['errors'])} error(s).")
        return 1
    print(
        "Mind's Eye asset validation passed: "
        f"{report['vignetteCount']} package(s), {report['declaredAssetCount']} asset(s), "
        f"{report['estimatedResidentTextureBytes']} estimated resident bytes."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
