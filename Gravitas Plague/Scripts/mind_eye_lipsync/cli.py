from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import shutil
import sys
from tempfile import mkdtemp
from typing import Any, Sequence

from .compiler import CompileRequest, compile_pr
from .config import AUDIO_ROOT, DESCRIPTOR_ROOT, PROJECT_ROOT, RESOURCES_ROOT, TOOLCHAIN_ROOT as SOURCE_TOOLCHAIN_ROOT
from .bundle_audit import audit_bundle
from .descriptor_loader import reconcile_descriptor, resolve_descriptor
from .deterministic_json import canonical_json_bytes, write_atomic_json
from .doctor import ToolchainLayout, build_lock, run_doctor
from .errors import ExitCode, MindEyeCompilerError
from .production_batch import ProductionBatchRequest, compile_production_batch
from .quality_aggregate import analyze_quality
from .review_dashboard import build_review_dashboard, serve_review
from .set_compare import compare_sets
from .set_index import write_index
from .set_publisher import publish_set
from .set_validator import validate_set
from .preview_svg import render_preview_svg
from .registry import load_registry
from .report import build_report
from .validator import validate_directory, validate_manifest_file


def _emit(value: Any, *, as_json: bool) -> None:
    if as_json:
        sys.stdout.buffer.write(canonical_json_bytes(value))
    elif isinstance(value, str):
        print(value)
    else:
        for key, item in value.items():
            print(f"{key}: {item}")


def inventory(*, verify_descriptors: bool, verify_audio: bool) -> dict[str, Any]:
    registry = load_registry()
    missing: list[str] = []
    mismatches: list[str] = []
    for entry in registry.entries:
        try:
            descriptor = resolve_descriptor(entry.pr_id)
            reconcile_descriptor(entry, descriptor)
            if verify_audio and not (AUDIO_ROOT / entry.audio_file).is_file():
                missing.append(f"audio:{entry.pr_id}:{entry.audio_file}")
        except Exception as error:
            mismatches.append(f"{entry.pr_id}: {error}")
    if verify_descriptors:
        for exclusion in registry.exclusions:
            path = DESCRIPTOR_ROOT / f"{exclusion.pr_id}.json"
            if not path.is_file():
                missing.append(f"excludedDescriptor:{exclusion.pr_id}:missing")
                continue
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
                if payload.get("prerecordingID") != exclusion.pr_id:
                    mismatches.append(f"excludedDescriptor:{exclusion.pr_id}:ID mismatch")
            except Exception as error:
                mismatches.append(f"excludedDescriptor:{exclusion.pr_id}:{error}")
    counts = Counter(entry.speaker_character_id for entry in registry.entries)
    result = {
        "status": "PASS" if not missing and not mismatches else "FAIL",
        "eligible": len(registry.entries),
        "excluded": len(registry.exclusions),
        "speakerCounts": {
            name: counts.get(name, 0)
            for name in ("big_mike", "rich", "broadcaster", "cateye81", "dad")
        },
        "missing": missing,
        "mismatch": mismatches,
        "eligiblePRIDs": [entry.pr_id for entry in registry.entries],
        "excludedPRIDs": [item.pr_id for item in registry.exclusions],
    }
    if result["status"] != "PASS":
        raise MindEyeCompilerError(
            json.dumps(result, ensure_ascii=False),
            exit_code=ExitCode.VALIDATION_FAILURE,
            diagnostic_code="inventoryMismatch",
        )
    return result


def _compile_request(args: argparse.Namespace, *, output: Path | None = None, workspace: Path | None = None) -> CompileRequest:
    return CompileRequest(
        pr_id=args.pr_id,
        output=output or args.output,
        toolchain_root=args.toolchain_root,
        workspace=workspace or args.workspace,
        manual_override=args.manual_override,
        report_json=args.emit_report_json,
        report_svg=args.emit_report_svg,
        keep_intermediates=args.keep_intermediates,
        force=args.force,
    )


def _determinism_check(args: argparse.Namespace) -> dict[str, Any]:
    build_root = (PROJECT_ROOT / ".build" / "mind-eye-lipsync" / "determinism").resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    first = Path(mkdtemp(prefix="first.", dir=build_root))
    second = Path(mkdtemp(prefix="second.", dir=build_root))
    try:
        outputs: list[tuple[Path, Path]] = []
        for root in (first, second):
            output = root / f"{args.pr_id}.mouthframes.json"
            report = root / f"{args.pr_id}.report.json"
            request = CompileRequest(
                pr_id=args.pr_id,
                output=output,
                toolchain_root=args.toolchain_root,
                workspace=root / "workspace",
                manual_override=args.manual_override,
                report_json=report,
                report_svg=None,
                keep_intermediates=True,
                force=False,
            )
            compile_pr(request)
            outputs.append((output, report))
        if outputs[0][0].read_bytes() != outputs[1][0].read_bytes():
            raise MindEyeCompilerError(
                "Manifest bytes differ across clean deterministic builds",
                exit_code=ExitCode.DETERMINISM_FAILURE,
                diagnostic_code="manifestDeterminismMismatch",
            )
        if outputs[0][1].read_bytes() != outputs[1][1].read_bytes():
            raise MindEyeCompilerError(
                "Report bytes differ across clean deterministic builds",
                exit_code=ExitCode.DETERMINISM_FAILURE,
                diagnostic_code="reportDeterminismMismatch",
            )
        return {"status": "PASS", "prID": args.pr_id, "byteIdentical": True}
    finally:
        shutil.rmtree(first, ignore_errors=True)
        shutil.rmtree(second, ignore_errors=True)


def _compile_all_plan(args: argparse.Namespace) -> dict[str, Any]:
    if args.expected_count != 37:
        raise MindEyeCompilerError(
            "The locked Phase 6 registry requires --expected-count 37",
            exit_code=ExitCode.VALIDATION_FAILURE,
            diagnostic_code="expectedCountMismatch",
        )
    if args.jobs != 1:
        raise MindEyeCompilerError(
            "Phase 6 requires --jobs 1 for deterministic serial authoring",
            exit_code=ExitCode.VALIDATION_FAILURE,
            diagnostic_code="unsafeConcurrency",
        )
    registry = load_registry()
    output_directory = args.output_directory.resolve()
    plans = []
    would_overwrite = 0
    for entry in registry.entries:
        output = output_directory / f"{entry.pr_id}.mouthframes.json"
        exists = output.exists()
        would_overwrite += int(exists)
        plans.append({"prID": entry.pr_id, "output": output.as_posix(), "wouldOverwrite": exists})
    result = {
        "status": "PASS",
        "dryRun": args.dry_run,
        "planned": len(plans),
        "excluded": len(registry.exclusions),
        "wouldOverwrite": would_overwrite,
        "jobs": 1,
        "plans": plans,
    }
    if not args.dry_run:
        raise MindEyeCompilerError(
            "Non-dry compile-all must use --production-mode and Phase 7 staging paths",
            exit_code=ExitCode.VALIDATION_FAILURE,
            diagnostic_code="productionModeRequired",
        )
    return result


def _compile_all_production(args: argparse.Namespace) -> dict[str, Any]:
    if not args.production_mode:
        return _compile_all_plan(args)
    if args.expected_count != 37 or args.jobs != 1:
        raise MindEyeCompilerError(
            "Phase 7 production mode requires --expected-count 37 and --jobs 1",
            exit_code=ExitCode.VALIDATION_FAILURE,
            diagnostic_code="productionModeContract",
        )
    if args.report_directory is None or args.workspace is None:
        raise MindEyeCompilerError(
            "Phase 7 production mode requires --report-directory and --workspace",
            exit_code=ExitCode.VALIDATION_FAILURE,
            diagnostic_code="productionPathsMissing",
        )
    production_target = RESOURCES_ROOT / "Turing" / "MindsEye" / "AudioFrames"
    if args.output_directory.resolve() == production_target.resolve():
        raise MindEyeCompilerError(
            "Production source resources may be changed only by publish-set",
            exit_code=ExitCode.PUBLICATION_FAILURE,
            diagnostic_code="directProductionWriteRejected",
        )
    doctor = run_doctor(ToolchainLayout.at(args.toolchain_root))
    result = compile_production_batch(
        registry=load_registry(),
        request=ProductionBatchRequest(
            output_directory=args.output_directory,
            report_directory=args.report_directory,
            workspace_directory=args.workspace,
            expected_count=args.expected_count,
            jobs=args.jobs,
            collect_errors=args.collect_errors,
            keep_intermediates=args.keep_intermediates,
            resume_valid=args.resume_valid,
        ),
        compiler=lambda request: compile_pr(request, doctor_result=doctor),
        toolchain_root=args.toolchain_root,
    )
    return result.to_dict()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Mind's Eye offline authored lip-sync compiler")
    subcommands = parser.add_subparsers(dest="command", required=True)

    def output_options(command: argparse.ArgumentParser) -> None:
        command.add_argument("--json", action="store_true")

    doctor = subcommands.add_parser("doctor")
    doctor.add_argument("--toolchain-root", type=Path, default=PROJECT_ROOT / ".mind-eye-toolchains")
    output_options(doctor)

    bootstrap = subcommands.add_parser("bootstrap-lock")
    bootstrap.add_argument("--toolchain-root", type=Path, default=PROJECT_ROOT / ".mind-eye-toolchains")
    output_options(bootstrap)

    inventory_parser = subcommands.add_parser("inventory")
    inventory_parser.add_argument("--verify-descriptors", action="store_true")
    inventory_parser.add_argument("--verify-audio", action="store_true")
    output_options(inventory_parser)

    compile_parser = subcommands.add_parser("compile")
    compile_parser.add_argument("--pr-id", required=True)
    compile_parser.add_argument("--output", type=Path, required=True)
    compile_parser.add_argument("--workspace", type=Path)
    compile_parser.add_argument("--toolchain-root", type=Path, default=PROJECT_ROOT / ".mind-eye-toolchains")
    compile_parser.add_argument("--manual-override", type=Path)
    compile_parser.add_argument("--emit-report-json", type=Path)
    compile_parser.add_argument("--emit-report-svg", type=Path)
    compile_parser.add_argument("--keep-intermediates", action="store_true")
    compile_parser.add_argument("--force", action="store_true")
    output_options(compile_parser)

    compile_all = subcommands.add_parser("compile-all")
    compile_all.add_argument("--output-directory", type=Path, required=True)
    compile_all.add_argument("--expected-count", type=int, default=37)
    compile_all.add_argument("--jobs", type=int, default=1)
    errors = compile_all.add_mutually_exclusive_group()
    errors.add_argument("--fail-fast", action="store_true", default=True)
    errors.add_argument("--collect-errors", action="store_true")
    compile_all.add_argument("--dry-run", action="store_true")
    compile_all.add_argument("--force", action="store_true")
    compile_all.add_argument("--report-directory", type=Path)
    compile_all.add_argument("--workspace", type=Path)
    compile_all.add_argument("--resume-valid", action="store_true")
    compile_all.add_argument("--production-mode", action="store_true")
    compile_all.add_argument("--keep-intermediates", action="store_true")
    compile_all.add_argument("--toolchain-root", type=Path, default=PROJECT_ROOT / ".mind-eye-toolchains")
    output_options(compile_all)

    validate = subcommands.add_parser("validate")
    sources = validate.add_mutually_exclusive_group(required=True)
    sources.add_argument("--manifest", type=Path)
    sources.add_argument("--directory", type=Path)
    validate.add_argument("--verify-current-sources", action="store_true")
    validate.add_argument("--expected-count", type=int)
    output_options(validate)

    inspect = subcommands.add_parser("inspect")
    inspect.add_argument("--manifest", type=Path, required=True)
    inspect.add_argument("--report-json", type=Path, required=True)
    inspect.add_argument("--report-svg", type=Path, required=True)
    output_options(inspect)

    deterministic = subcommands.add_parser("determinism-check")
    deterministic.add_argument("--pr-id", required=True)
    deterministic.add_argument("--toolchain-root", type=Path, default=PROJECT_ROOT / ".mind-eye-toolchains")
    deterministic.add_argument("--manual-override", type=Path)
    output_options(deterministic)

    build_index = subcommands.add_parser("build-index")
    build_index.add_argument("--directory", type=Path, required=True)
    build_index.add_argument("--output", type=Path, required=True)
    output_options(build_index)

    validate_set_parser = subcommands.add_parser("validate-set")
    validate_set_parser.add_argument("--directory", type=Path, required=True)
    validate_set_parser.add_argument("--verify-current-sources", action="store_true")
    validate_set_parser.add_argument("--expected-count", type=int, default=37)
    validate_set_parser.add_argument("--json-report", type=Path)
    output_options(validate_set_parser)

    compare = subcommands.add_parser("compare-sets")
    compare.add_argument("--left", type=Path, required=True)
    compare.add_argument("--right", type=Path, required=True)
    compare.add_argument("--json-report", type=Path)
    output_options(compare)

    quality = subcommands.add_parser("quality-summary")
    quality.add_argument("--manifest-directory", type=Path, required=True)
    quality.add_argument("--report-directory", type=Path, required=True)
    quality.add_argument("--output", type=Path, required=True)
    output_options(quality)

    review = subcommands.add_parser("build-review")
    review.add_argument("--manifest-directory", type=Path, required=True)
    review.add_argument("--report-directory", type=Path, required=True)
    review.add_argument("--output-directory", type=Path, required=True)
    output_options(review)

    serve = subcommands.add_parser("serve-review")
    serve.add_argument("--directory", type=Path, required=True)
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=0)
    output_options(serve)

    publish = subcommands.add_parser("publish-set")
    publish.add_argument("--candidate", type=Path, required=True)
    publish.add_argument("--comparison-report", type=Path, required=True)
    publish.add_argument("--quality-report", type=Path, required=True)
    publish.add_argument("--target", type=Path, required=True)
    publish.add_argument("--replace-complete-set", action="store_true")
    output_options(publish)

    bundle = subcommands.add_parser("audit-bundle")
    bundle.add_argument("--app", type=Path, required=True)
    bundle.add_argument("--source-directory", type=Path, required=True)
    bundle.add_argument("--expected-count", type=int, default=37)
    bundle.add_argument("--json-report", type=Path)
    output_options(bundle)
    return parser


def dispatch(args: argparse.Namespace) -> dict[str, Any]:
    if args.command == "doctor":
        return run_doctor(ToolchainLayout.at(args.toolchain_root)).to_dict()
    if args.command == "bootstrap-lock":
        lock = build_lock(ToolchainLayout.at(args.toolchain_root))
        path = SOURCE_TOOLCHAIN_ROOT / "toolchain.lock.json"
        write_atomic_json(path, lock)
        run_doctor(ToolchainLayout.at(args.toolchain_root))
        return {"status": "PASS", "toolchainLock": path.as_posix()}
    if args.command == "inventory":
        return inventory(verify_descriptors=args.verify_descriptors, verify_audio=args.verify_audio)
    if args.command == "compile":
        return compile_pr(_compile_request(args)).to_dict()
    if args.command == "compile-all":
        return _compile_all_plan(args) if args.dry_run else _compile_all_production(args)
    if args.command == "validate":
        if args.manifest:
            payload = validate_manifest_file(args.manifest, verify_sources=args.verify_current_sources)
            return {"status": "PASS", "manifestCount": 1, "prIDs": [payload["prID"]]}
        result = validate_directory(
            args.directory,
            verify_sources=args.verify_current_sources,
            expected_count=args.expected_count,
        )
        return {"status": "PASS", "manifestCount": result.manifest_count, "prIDs": list(result.pr_ids)}
    if args.command == "inspect":
        payload = validate_manifest_file(args.manifest)
        from .hashing import sha256_file
        write_atomic_json(
            args.report_json,
            build_report(payload, manifest_sha256=sha256_file(args.manifest)),
        )
        args.report_svg.parent.mkdir(parents=True, exist_ok=True)
        args.report_svg.write_text(render_preview_svg(payload), encoding="utf-8")
        return {"status": "PASS", "manifest": args.manifest.as_posix(), "reportJSON": args.report_json.as_posix(), "reportSVG": args.report_svg.as_posix()}
    if args.command == "determinism-check":
        return _determinism_check(args)
    if args.command == "build-index":
        payload = write_index(args.directory, args.output)
        return {
            "status": "PASS",
            "output": args.output.as_posix(),
            "entryCount": len(payload["entries"]),
            "manifestSetSHA256": payload["manifestSetSHA256"],
        }
    if args.command == "validate-set":
        result = validate_set(
            args.directory,
            verify_sources=args.verify_current_sources,
            expected_count=args.expected_count,
        )
        payload = result.to_dict()
        if args.json_report:
            write_atomic_json(args.json_report, payload)
        return payload
    if args.command == "compare-sets":
        result = compare_sets(args.left, args.right)
        payload = result.to_dict()
        if args.json_report:
            write_atomic_json(args.json_report, payload)
        return payload
    if args.command == "quality-summary":
        result = analyze_quality(args.manifest_directory, args.report_directory)
        payload = result.to_dict()
        write_atomic_json(args.output, payload)
        return payload
    if args.command == "build-review":
        return build_review_dashboard(
            args.manifest_directory,
            args.report_directory,
            args.output_directory,
        )
    if args.command == "serve-review":
        serve_review(args.directory, host=args.host, port=args.port)
        return {"status": "PASS"}
    if args.command == "publish-set":
        return publish_set(
            candidate=args.candidate,
            comparison_report=args.comparison_report,
            quality_report=args.quality_report,
            target=args.target,
            replace_complete_set=args.replace_complete_set,
        )
    if args.command == "audit-bundle":
        result = audit_bundle(args.app, args.source_directory, expected_count=args.expected_count)
        payload = result.to_dict()
        if args.json_report:
            write_atomic_json(args.json_report, payload)
        return payload
    raise AssertionError(args.command)


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        result = dispatch(args)
        _emit(result, as_json=args.json)
        if result.get("status") == "FAIL":
            if args.command in {"validate-set", "compare-sets"}:
                return int(ExitCode.COMPLETE_SET_MISMATCH)
            if args.command == "quality-summary":
                return int(ExitCode.REVIEW_GATE_FAILURE)
            if args.command == "audit-bundle":
                return int(ExitCode.BUNDLE_AUDIT_FAILURE)
            if args.command == "compile-all":
                return int(ExitCode.ALIGNMENT_QUALITY_FAILURE)
        return int(ExitCode.SUCCESS)
    except MindEyeCompilerError as error:
        diagnostic = {
            "status": "FAIL",
            "code": error.diagnostic_code,
            "message": str(error),
            "exitCode": int(error.exit_code),
        }
        if getattr(args, "json", False):
            sys.stderr.buffer.write(canonical_json_bytes(diagnostic))
        else:
            print(f"{error.diagnostic_code}: {error}", file=sys.stderr)
        return int(error.exit_code)
    except (ValueError, OSError, json.JSONDecodeError) as error:
        command = getattr(args, "command", "")
        exit_code = {
            "validate-set": ExitCode.COMPLETE_SET_MISMATCH,
            "compare-sets": ExitCode.COMPLETE_SET_MISMATCH,
            "publish-set": ExitCode.PUBLICATION_FAILURE,
            "audit-bundle": ExitCode.BUNDLE_AUDIT_FAILURE,
            "quality-summary": ExitCode.REVIEW_GATE_FAILURE,
        }.get(command, ExitCode.VALIDATION_FAILURE)
        diagnostic = {"status": "FAIL", "code": "validationFailure", "message": str(error), "exitCode": int(exit_code)}
        if getattr(args, "json", False):
            sys.stderr.buffer.write(canonical_json_bytes(diagnostic))
        else:
            print(f"validationFailure: {error}", file=sys.stderr)
        return int(exit_code)
    except Exception as error:
        diagnostic = {"status": "FAIL", "code": "internalError", "message": str(error), "exitCode": 5}
        if getattr(args, "json", False):
            sys.stderr.buffer.write(canonical_json_bytes(diagnostic))
        else:
            print(f"internalError: {error}", file=sys.stderr)
        return int(ExitCode.INTERNAL_ERROR)
