#!/usr/bin/env python3
"""Fresh-process, wall-capped native scout. Never invokes legacy quick/full suites.

The native runner checks physical footprint at existing phase boundaries. This
watchdog additionally terminates its own child process on wall/RSS overrun; RSS
is a supplementary host safety bound, not a device physical-footprint metric.
All attempts, including failure and timeout, retain logs and an attempt report.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


COMMAND_BUFFER_PROFILES = (
    "deviceDefault", "operations32Megabytes40", "operations40Megabytes32",
    "operations32Megabytes32", "operations24Megabytes24", "operations16Megabytes16",
)


def native_command(args):
    command = [str(args.binary.resolve()), "--model-root", str(args.model_root.resolve()),
               "--bundle-root", str(args.bundle_root.resolve()), "--workload", str(args.workload.resolve()),
               "--output", str(args.output.resolve()), "--mode", args.mode,
               "--command-buffer-profile", args.command_buffer_profile, "--profiler-state", args.profiler_state]
    if args.policy:
        command += ["--policy", str(args.policy.resolve())]
    return command


def validate_fixture_budgets(fixture):
    """Validate host safety bounds before launching any native process.

    Complete production segments may use the voice's full row budget. The native
    runner additionally verifies that budget against the selected voice config.
    Legacy fixtures retain their shorter scout limit, including an omitted/null
    optional completion requirement.
    """
    if not isinstance(fixture, dict):
        raise ValueError("Fixture must be a JSON object")
    complete = fixture.get("requireCompleteSegments")
    if complete is not None and type(complete) is not bool:
        raise ValueError("requireCompleteSegments must be a boolean or null")
    try:
        rows, wall, memory = (fixture[k] for k in ["maximumRowsPerSegment", "wallCapSeconds", "footprintCapMiB"])
    except KeyError as error:
        raise ValueError(f"Missing fixture budget: {error.args[0]}") from error
    row_limit = 160 if complete is True else 32
    if type(rows) is not int or not 1 <= rows <= row_limit:
        raise ValueError(f"maximumRowsPerSegment must be an integer in 1...{row_limit}")
    if type(wall) not in (int, float) or not 1 <= wall <= 180:
        raise ValueError("wallCapSeconds must be a number in 1...180")
    if type(memory) not in (int, float) or not 256 <= memory <= 6500:
        raise ValueError("footprintCapMiB must be a number in 256...6500")
    return rows, wall, memory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--model-root", required=True, type=Path)
    parser.add_argument("--bundle-root", required=True, type=Path)
    parser.add_argument("--workload", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--mode", choices=["bounded-replay", "decoder-fixed-codes"], default="bounded-replay")
    parser.add_argument("--profiler-state", default="unattached")
    parser.add_argument("--command-buffer-profile", choices=COMMAND_BUFFER_PROFILES,
                        default="operations40Megabytes32",
                        help="Explicit matched profile; deviceDefault matches the current Release selection")
    parser.add_argument("--phase-markers", action="store_true")
    args = parser.parse_args()
    fixture = json.loads(args.workload.read_text())
    try:
        _, wall, memory = validate_fixture_budgets(fixture)
    except ValueError as error:
        parser.error(f"Unsafe fixture budgets: {error}")
    for path in [args.binary, args.model_root, args.bundle_root, args.workload]:
        if not path.exists():
            parser.error(f"Missing {path}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    log_path = args.output.with_suffix(".log")
    attempt_path = args.output.with_suffix(".attempt.json")
    if any(path.exists() for path in [args.output, log_path, attempt_path]):
        parser.error("Use a new output path; attempts must not overwrite earlier evidence")
    command = native_command(args)
    environment = os.environ.copy()
    environment["TURING_QWEN_PHASE_DIAGNOSTICS"] = "1" if args.phase_markers else "0"
    start = time.monotonic()
    reason = None
    peak_rss_mib = 0
    # Hashing provenance precedes the native timed interval. A separate bounded
    # 60-second allowance covers that I/O and teardown; never an unbounded wait.
    total_wall_cap = wall + 60
    with log_path.open("x") as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                 env=environment, start_new_session=True)
        try:
            while child.poll() is None:
                elapsed = time.monotonic() - start
                result = subprocess.run(["ps", "-o", "rss=", "-p", str(child.pid)], capture_output=True, text=True)
                rss = float(result.stdout.strip() or 0) / 1024
                peak_rss_mib = max(peak_rss_mib, rss)
                if elapsed > total_wall_cap or rss > memory:
                    reason = "hostWallCap" if elapsed > total_wall_cap else "hostSupplementaryRSSCap"
                    break
                time.sleep(0.25)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
    attempt = {"schemaVersion": 1, "status": "HOST_VALIDATED" if child.returncode == 0 else "FAILED_OR_BUDGET_STOPPED",
               "qualification": "DEVICE_QUALIFICATION_PENDING", "command": command,
               "workloadFileSHA256": hashlib.sha256(args.workload.read_bytes()).hexdigest(),
               "wallSeconds": time.monotonic() - start, "watchdogWallCapSeconds": total_wall_cap,
               "peakSupplementaryRSSMiB": peak_rss_mib, "terminationReason": reason,
               "exitCode": child.returncode, "phaseMarkers": args.phase_markers,
               "reportExists": args.output.exists(), "log": str(log_path.resolve())}
    attempt_path.write_text(json.dumps(attempt, indent=2, sort_keys=True) + "\n")
    print(json.dumps(attempt))
    return 0 if child.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
