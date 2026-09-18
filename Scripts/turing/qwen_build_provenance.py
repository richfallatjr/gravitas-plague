#!/usr/bin/env python3
"""Capture build evidence and fail closed when an installed run cannot be matched.

capture writes qwen-build-manifest.json after linking, before signing. Complete
compile argv (including expanded response files) is retained in a sidecar; only
its digest and effective summaries are embedded. JSON compilation databases and
verbose Xcode/Swift build logs are accepted. No benchmark or device action runs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import time

SCHEMA = 1
CONTRACT = {"residencyMode": "independentFresh2", "laneCount": 2,
            "weightStoreCount": 2, "decoderCount": 1, "admissionPolicy": "currentOverlap"}
SOURCE_SUFFIXES = {".swift", ".cpp", ".c", ".h", ".hpp", ".metal", ".json", ".sh", ".py", ".pbxproj", ".xcconfig"}


def digest(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def workload_identity(path):
    """Match the bounded Swift Codable fixture, not whitespace in its source file.

    JSONEncoder omits nil optional fields and writes integral Double values as
    integers. Keep this deliberately limited to the checked-in workload schema;
    unknown keys must not disappear silently when establishing identity.
    """
    value = json.loads(Path(path).read_text())
    required = {"schemaVersion", "id", "origin", "characterID", "voiceID", "language",
                "segments", "samplingSeed", "maximumRowsPerSegment", "wallCapSeconds", "footprintCapMiB"}
    optional = {"decoderCodes", "decoderReferenceRows"}
    if not isinstance(value, dict) or not required.issubset(value) or set(value) - required - optional:
        raise ValueError("Workload identity requires the exact bounded Swift Codable schema")
    value = {key: item for key, item in value.items() if key not in optional or item is not None}
    for key in ["wallCapSeconds", "footprintCapMiB"]:
        number = value[key]
        if isinstance(number, float) and number.is_integer():
            value[key] = int(number)
    return digest(canonical(value))


def file_hash(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def run(argv, cwd=None):
    value = subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if value.returncode:
        return None
    return value.stdout.decode(errors="replace").strip()


def expand_response_files(argv, directory, seen=None):
    seen = set() if seen is None else seen
    result = []
    for argument in argv:
        # Mach-O linker install names are dyld tokens, not compiler response files.
        if (not argument.startswith("@") or argument in ("@rpath", "@loader_path", "@executable_path")
                or argument.startswith(("@rpath/", "@loader_path/", "@executable_path/"))):
            result.append(argument)
            continue
        path = (Path(directory) / argument[1:]).resolve()
        if path in seen:
            raise ValueError(f"Recursive response file: {path}")
        if not path.is_file():
            raise ValueError(f"Missing compile response file: {path}")
        result.extend(expand_response_files(shlex.split(path.read_text()), directory, seen | {path}))
    return result


def command_records(path, repo):
    if path is None:
        return []
    path = Path(path)
    if path.suffix == ".json":
        rows = json.loads(path.read_text())
        if not isinstance(rows, list):
            raise ValueError("Compilation database must be an array of actual commands")
    else:
        rows = []
        directory = str(repo)
        for line in path.read_text(errors="replace").splitlines():
            stripped = line.strip()
            if stripped.startswith("cd "):
                parts = shlex.split(stripped)
                if len(parts) == 2:
                    directory = parts[1]
            if re.search(r"(?:^|/)(?:clang\+\+|clang|swiftc|swift-frontend|metal)(?:\s|$)", stripped):
                parts = shlex.split(stripped)
                # Xcode wraps Swift invocation in `builtin-SwiftDriver --`.
                for index, arg in enumerate(parts):
                    if Path(arg).name in {"clang++", "clang", "swiftc", "swift-frontend", "metal"}:
                        rows.append({"directory": directory, "arguments": parts[index:]})
                        break
    result = []
    for row in rows:
        directory = row.get("directory", str(repo))
        args = row.get("arguments") or shlex.split(row["command"])
        expanded = expand_response_files(args, directory)
        result.append({"directory": directory, "arguments": expanded,
                       "sha256": digest(canonical(expanded))})
    return result


def summarize_command(row):
    args = row["arguments"]
    definitions = {}
    conflicts = []
    optimization = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"-D", "-U"} and index + 1 < len(args):
            arg += args[index + 1]
            index += 1
        if arg.startswith("-U"):
            definitions.pop(arg[2:], None)
        elif arg.startswith("-D"):
            name, _, value = arg[2:].partition("=")
            value = value or "1"
            if name in definitions and definitions[name] != value:
                conflicts.append(name)
            definitions[name] = value
        if re.fullmatch(r"-O(?:0|1|2|3|s|z|g|fast|none)?", arg):
            optimization.append(arg)
        index += 1
    hardening = definitions.get("_LIBCPP_HARDENING_MODE")
    # Retain all semantic arguments for the hardening-only isolation check.
    # Only build-output/cache locations and the two named hardening macros are
    # omitted. Optimization/recovery/SDK/testing/Metal flags remain comparable.
    comparable = []
    skip = False
    for arg in args[1:]:
        if skip:
            skip = False
            continue
        if arg in {"-o", "-MF", "-MT", "-serialize-diagnostics", "-index-store-path", "-module-cache-path", "-output-file-map", "-emit-module-path"}:
            skip = True
            continue
        if arg.startswith(("-fmodules-cache-path=", "-D_LIBCPP_HARDENING_MODE=", "-U_LIBCPP_HARDENING_MODE", "-DMLX_TURING_HARDENING_EXPERIMENT=")):
            continue
        comparable.append(arg)
    return {"sha256": row["sha256"], "nonHardeningArguments": comparable, "optimizationFlags": optimization,
            "effectiveOptimization": optimization[-1] if optimization else None,
            "hardeningDefinition": hardening,
            "conflictingDefinitions": sorted(set(conflicts)),
            "defines": definitions,
            "fastMath": any(x in args for x in ["-Ofast", "-ffast-math", "-funsafe-math-optimizations"]),
            "target": next((args[i + 1] for i, x in enumerate(args[:-1]) if x in {"-target", "--target"}), None)}


def compile_evidence(records):
    def selected(predicate):
        return [summarize_command(r) for r in records if predicate(r["arguments"])]
    allocator = selected(lambda a: any(x.endswith("/mlx/backend/metal/allocator.cpp") for x in a))
    native = selected(lambda a: "TuringQwenNative" in a and any("swift" in Path(x).name for x in a[:1]))
    app = selected(lambda a: "Gravitas_Plague" in a and any("swift" in Path(x).name for x in a[:1]))
    metal = selected(lambda a: Path(a[0]).name == "metal")
    return {"commandsSHA256": digest(canonical(records)) if records else None,
            "commandCount": len(records), "allocatorCommands": allocator,
            "nativeSwiftCommands": native, "appSwiftCommands": app, "metalCommands": metal}


def source_identity(repo):
    paths = subprocess.check_output(["git", "ls-files", "-c", "-o", "--exclude-standard", "-z"], cwd=repo).split(b"\0")
    files = {}
    for raw in sorted(set(paths)):
        if not raw:
            continue
        relative = raw.decode()
        path = repo / relative
        if path.is_file() and path.suffix in SOURCE_SUFFIXES:
            files[relative] = file_hash(path)
    diff = subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=repo)
    return {"commit": run(["git", "rev-parse", "HEAD"], repo),
            "dirty": bool(run(["git", "status", "--porcelain"], repo)),
            "trackedDiffSHA256": digest(diff), "relevantSourcesSHA256": digest(canonical(files)),
            "nativeSourcesSHA256": digest(canonical({k: v for k, v in files.items() if "/QwenNative/" in k})),
            "vendorSourcesSHA256": digest(canonical({k: v for k, v in files.items() if k.startswith("ThirdParty/LocalSwiftPackages/mlx-swift/")})),
            "sourceFileCount": len(files)}


def payload_identity(root):
    if root is None or not Path(root).is_dir():
        return None
    root = Path(root)
    files = {str(p.relative_to(root)): {"sha256": file_hash(p), "bytes": p.stat().st_size}
             for p in sorted(root.rglob("*")) if p.is_file() and ".cache" not in p.parts and p.name != ".DS_Store"}
    return {"sha256": digest(canonical(files)), "files": files}


def binary_uuids(binary):
    output = run(["xcrun", "dwarfdump", "--uuid", str(binary)])
    return sorted(set(re.findall(r"UUID: ([0-9A-Fa-f-]{36})", output or "")))


def successful_build_evidence(log_path):
    if not log_path or not Path(log_path).is_file():
        return {"succeeded": False, "logSHA256": None}
    text = Path(log_path).read_text(errors="replace")
    success = re.search(r"^(?:\*\* BUILD SUCCEEDED \*\*|Build complete!.*|Build succeeded.*)$", text, re.MULTILINE)
    failure = re.search(r"^(?:\*\* BUILD FAILED \*\*|error: Build failed.*)$", text, re.MULTILINE)
    return {"succeeded": bool(success) and not bool(failure), "logSHA256": file_hash(log_path)}


def snapshot(args):
    """Run before a fresh qualification build; keep output outside source tree."""
    value = {"schemaVersion": SCHEMA, "source": source_identity(Path(args.repo).resolve()),
             "capturedAtUnixSeconds": time.time()}
    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"sourceSnapshot": str(target), "sourceSHA256": value["source"]["relevantSourcesSHA256"]}))


def capture(args):
    repo = Path(args.repo).resolve()
    records = command_records(args.compile_commands or args.build_log, repo)
    binaries = [Path(p) for p in args.binary]
    identities = sorted(set(u for p in binaries for u in binary_uuids(p)))
    info = {}
    if args.app_bundle:
        info_path = Path(args.app_bundle) / "Info.plist"
        if info_path.exists():
            info = plistlib.loads(info_path.read_bytes())
    current_source = source_identity(repo)
    previous = json.loads(Path(args.source_snapshot).read_text()) if args.source_snapshot else {}
    captured_at = previous.get("capturedAtUnixSeconds")
    build_evidence = successful_build_evidence(args.build_success_log or args.build_log)
    build_evidence.update({
        "sourceSnapshotSHA256": file_hash(args.source_snapshot) if args.source_snapshot else None,
        "sourceUnchangedDuringBuild": bool(previous.get("source")) and previous.get("source") == current_source,
        "binariesBuiltAfterSourceSnapshot": isinstance(captured_at, (int, float)) and bool(binaries) and
            all(p.is_file() and p.stat().st_mtime >= captured_at for p in binaries),
    })
    manifest = {"schemaVersion": SCHEMA, "qualification": "unqualified",
        "source": current_source, "compile": compile_evidence(records), "buildEvidence": build_evidence,
        "toolchain": {"xcode": run(["xcodebuild", "-version"]),
                      "clang": run(["xcrun", "clang++", "--version"]),
                      "swift": run(["xcrun", "swiftc", "--version"]),
                      "sdk": args.sdk, "sdkPath": run(["xcrun", "--sdk", args.sdk, "--show-sdk-path"])},
        "application": {"version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion")},
        "binaryUUIDs": identities,
        "models": payload_identity(args.model_root), "voices": payload_identity(args.voices_root),
        "workloadSHA256": workload_identity(args.workload) if args.workload else None,
        "runtimeContract": json.loads(Path(args.runtime_contract).read_text()) if args.runtime_contract else None,
        "buildConfiguration": args.configuration,
        "experimentID": args.experiment,
        "evidenceNote": "Captured build evidence; device identity and runtime values require installed export verification."}
    manifest["manifestSHA256"] = digest(canonical(manifest))
    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    target.with_suffix(".commands.json").write_text(json.dumps(records, indent=2) + "\n")
    if args.app_bundle:
        (Path(args.app_bundle) / "qwen-build-manifest.json").write_bytes(target.read_bytes())
    print(json.dumps({"output": str(target), "qualification": "unqualified", "compileCommandCount": len(records)}))


def known(value):
    if isinstance(value, (dict, list)):
        return bool(value)
    return value is not None and value not in ("", "unknown", "unavailable", "unqualified")


def verify_manifest(expected, installed):
    errors = []
    def require(condition, message):
        if not condition:
            errors.append(message)
    require(expected.get("schemaVersion") == SCHEMA, "Unsupported build-manifest schema")
    supplied_hash = expected.get("manifestSHA256")
    payload = {k: v for k, v in expected.items() if k != "manifestSHA256"}
    require(supplied_hash == digest(canonical(payload)), "Build manifest digest mismatch")
    embedded = installed.get("buildManifest") or {}
    require(embedded == expected, "Installed embedded build manifest differs from expected build")
    source = expected.get("source") or {}
    for key in ["commit", "trackedDiffSHA256", "relevantSourcesSHA256", "nativeSourcesSHA256", "vendorSourcesSHA256"]:
        require(known(source.get(key)), f"Unknown source identity: {key}")
    build_evidence = expected.get("buildEvidence") or {}
    require(build_evidence.get("succeeded") is True and known(build_evidence.get("logSHA256")),
            "No successful build-log evidence")
    require(build_evidence.get("sourceUnchangedDuringBuild") is True and known(build_evidence.get("sourceSnapshotSHA256")),
            "No matching pre-build source snapshot; post-build source hash alone is insufficient")
    require(build_evidence.get("binariesBuiltAfterSourceSnapshot") is True,
            "Linked binaries predate source snapshot or chronology is unknown; use a fresh qualification build")
    uuids = expected.get("binaryUUIDs") or []
    require(bool(uuids), "Built executable/debug dylib UUIDs unavailable")
    require(sorted(uuids) == sorted(installed.get("binaryUUIDs") or []), "Installed Mach-O UUIDs do not match built binary")
    for name in ["models", "voices"]:
        identity = expected.get(name) or {}
        require(known(identity.get("sha256")) and bool(identity.get("files")), f"Unknown {name} payload identity")
        require(installed.get("installedPayloadSHA256", {}).get(name) == identity.get("sha256") and known(identity.get("sha256")),
                f"Installed {name} payload hash unavailable or different (embedded claims alone are insufficient)")
    require(known(expected.get("workloadSHA256")), "Unknown workload hash")
    require(known(expected.get("workloadSHA256")) and installed.get("workloadSHA256") == expected.get("workloadSHA256"),
            "Installed workload hash unavailable or different")
    fp = installed.get("compiledFingerprint") or {}
    require(fp.get("translationUnit") == "mlx/mlx/backend/metal/allocator.cpp", "Fingerprint is not from allocator translation unit")
    require(fp.get("hardeningMode") in ["fast", "extensive", "debug"], "Allocator hardening unknown or disabled")
    require(known(fp.get("compiler")) and known(fp.get("libcxxVersion")), "Unknown allocator compiler/libc++")
    require(fp.get("internalAssertionsEnabled") == (fp.get("hardeningMode") == "debug"), "Allocator internal-assertion state inconsistent")
    require(fp.get("experimentID") == expected.get("experimentID"), "Compiled experiment does not match manifest")
    named_mode = {"hardening-debug-control": "debug", "hardening-fast-only": "fast"}.get(expected.get("experimentID"))
    require(named_mode is None or fp.get("hardeningMode") == named_mode,
            "Named hardening experiment does not match compiled allocator mode")
    comp = expected.get("compile") or {}
    require(known(comp.get("commandsSHA256")), "No actual compile-command capture")
    for category in ["allocatorCommands", "nativeSwiftCommands", "appSwiftCommands", "metalCommands"]:
        require(bool(comp.get(category)), f"Missing actual compile commands: {category}")
    for command in comp.get("allocatorCommands", []):
        require(bool(command.get("effectiveOptimization")), "Unknown Cmlx optimization")
        require(not command.get("conflictingDefinitions"), "Conflicting Cmlx macro definitions")
        require(not command.get("fastMath"), "Unqualified global fast-math/Ofast Cmlx flags")
        define = command.get("hardeningDefinition")
        names = {"fast": "_LIBCPP_HARDENING_MODE_FAST", "debug": "_LIBCPP_HARDENING_MODE_DEBUG", "extensive": "_LIBCPP_HARDENING_MODE_EXTENSIVE"}
        require(define == names.get(fp.get("hardeningMode")), "Cmlx command and compiled hardening disagree")
        require(fp.get("optimized") == (command.get("effectiveOptimization") not in ["-O0", "-Onone", None]), "Compiled optimization fingerprint disagrees with Cmlx command")
    for category in ["nativeSwiftCommands", "appSwiftCommands"]:
        require(all(known(c.get("effectiveOptimization")) for c in comp.get(category, [])), f"Unknown effective Swift optimization: {category}")
    native_defines = [d for c in comp.get("nativeSwiftCommands", []) for d in c.get("defines", {})]
    recovery = sorted({d for d in native_defines if d.startswith("GR_TURING_METAL_")})
    require(bool(recovery), "Unknown actual native recovery defines")
    contract = installed.get("runtimeContract") or {}
    require(contract == expected.get("runtimeContract"), "Installed runtime contract differs from manifest")
    require(recovery == sorted(contract.get("recoveryDefines") or []), "Actual compile recovery defines differ from runtime contract")
    for key, value in CONTRACT.items():
        require(contract.get(key) == value, f"Critical production contract mismatch/unknown: {key}")
    for key in ["requestedCommandBufferProfile", "resolvedCommandBufferProfile", "executionPolicy", "seedPolicy"]:
        require(known(contract.get(key)), f"Unknown runtime contract: {key}")
    observation = installed.get("observation") or {}
    for key in ["deviceModel", "osBuild", "runID", "clockBasis", "profilerState", "sceneCondition", "initialThermalState", "initialMemoryBytes"]:
        require(known(observation.get(key)), f"Missing run observation: {key}")
    require(known(expected.get("toolchain", {}).get("sdkPath")), "Unknown build SDK")
    return {"schemaVersion": SCHEMA, "qualification": "qualified" if not errors else "unqualified",
            "scope": "build provenance only; not performance/quality promotion", "errors": errors}


def embed(args):
    """Xcode phase: a normal build stays explicitly unqualified until stamped."""
    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    identity = source_identity(Path(args.repo).resolve())
    if args.manifest:
        value = json.loads(Path(args.manifest).read_text())
        if value.get("source") != identity:
            raise ValueError("Supplied provenance belongs to different source/worktree; regenerate after final edits")
    else:
        value = {"schemaVersion": SCHEMA, "qualification": "unqualified", "source": identity,
                 "buildConfiguration": args.configuration,
                 "evidenceNote": "No captured compile commands or linked binary stamp supplied; this build cannot qualify performance."}
        value["manifestSHA256"] = digest(canonical(value))
    target.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    print(f"Qwen build provenance embedded: {value.get('qualification', 'unqualified')}")


def compare_hardening(control, candidate):
    """Require all captured conditions unchanged except named hardening selection."""
    differences = []
    for key in ["source", "models", "voices", "workloadSHA256", "runtimeContract", "buildConfiguration", "toolchain"]:
        if control.get(key) != candidate.get(key):
            differences.append(key)
    def commands(manifest):
        result = []
        for category in ["allocatorCommands", "nativeSwiftCommands", "appSwiftCommands", "metalCommands"]:
            rows = []
            for row in manifest.get("compile", {}).get(category, []):
                data = dict(row)
                data.pop("sha256", None)
                data.pop("hardeningDefinition", None)
                data["defines"] = {k: v for k, v in data.get("defines", {}).items()
                                   if k not in {"_LIBCPP_HARDENING_MODE", "MLX_TURING_HARDENING_EXPERIMENT"}}
                rows.append(data)
            result.append((category, rows))
        return result
    if commands(control) != commands(candidate):
        differences.append("non-hardening compile settings")
    if control.get("experimentID") != "hardening-debug-control" or candidate.get("experimentID") != "hardening-fast-only":
        differences.append("named hardening A/B identity")
    for name, manifest, mode in [("control", control, "_LIBCPP_HARDENING_MODE_DEBUG"),
                                 ("candidate", candidate, "_LIBCPP_HARDENING_MODE_FAST")]:
        rows = manifest.get("compile", {}).get("allocatorCommands", [])
        if not rows or any(row.get("hardeningDefinition") != mode for row in rows):
            differences.append(f"{name} actual hardening mode")
    return {"comparable": not differences, "differences": differences,
            "note": "Also verify each installed export and match scene/thermal/profiler observations."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    group = c.add_mutually_exclusive_group()
    group.add_argument("--compile-commands")
    group.add_argument("--build-log")
    c.add_argument("--binary", action="append", default=[])
    c.add_argument("--model-root")
    c.add_argument("--voices-root")
    c.add_argument("--workload")
    c.add_argument("--runtime-contract")
    c.add_argument("--source-snapshot", help="JSON written by snapshot before the qualification build")
    c.add_argument("--build-success-log", help="Success log if compile commands are supplied separately")
    c.add_argument("--app-bundle")
    c.add_argument("--sdk", default="xros")
    c.add_argument("--configuration", required=True)
    c.add_argument("--experiment", default="shipping-default")
    c.add_argument("--output", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--expected", required=True)
    v.add_argument("--installed-export", required=True)
    v.add_argument("--historical", action="store_true", help="Export unqualified findings without failing the importer")
    ab = sub.add_parser("compare-hardening")
    ab.add_argument("--control", required=True)
    ab.add_argument("--candidate", required=True)
    e = sub.add_parser("embed")
    e.add_argument("--repo", required=True)
    e.add_argument("--output", required=True)
    e.add_argument("--configuration", required=True)
    e.add_argument("--manifest")
    s = sub.add_parser("snapshot")
    s.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    s.add_argument("--output", required=True, help="Write outside the source tree before building")
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            snapshot(args)
        elif args.command == "capture":
            capture(args)
        elif args.command == "embed":
            embed(args)
        elif args.command == "verify":
            result = verify_manifest(json.loads(Path(args.expected).read_text()), json.loads(Path(args.installed_export).read_text()))
            print(json.dumps(result, indent=2))
            return 0 if result["qualification"] == "qualified" or args.historical else 2
        else:
            result = compare_hardening(json.loads(Path(args.control).read_text()), json.loads(Path(args.candidate).read_text()))
            print(json.dumps(result, indent=2))
            return 0 if result["comparable"] else 2
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"qualification": "unqualified", "error": str(error)}), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
