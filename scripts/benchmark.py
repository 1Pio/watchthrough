#!/usr/bin/env python3
"""Serial reproducible CLI latency/resource/evidence measurements.

Examples:
  python3 scripts/fixtures.py --output .scratch/fixtures-01
  python3 scripts/benchmark.py --binary /path/watchthrough --label baseline \
      --fixtures .scratch/fixtures-01/fixtures.json --output .scratch/baseline-01

"Cold" means a new analysis directory, not flushed OS disk caches. Metrics use
wait4 rusage, include waited-for descendants, and are recorded outside packet
validation overhead. Maximum RSS is the kernel's per-process high-water measure,
not summed simultaneous process-tree memory or a thermal/power measurement.
Optional --trace-tools measures each FFmpeg/FFprobe call through Python wrappers;
its extra process launch overhead is intentionally excluded from default runs.
All captures are retained. No cleanup or destructive operations occur.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import time


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def directory_size(path):
    files = [item for item in path.rglob("*") if item.is_file()] if path.exists() else []
    return {"bytes": sum(item.stat().st_size for item in files), "files": len(files)}


def measured(command, stdout_path, stderr_path, environment, timeout):
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        start = time.perf_counter()
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, env=environment, start_new_session=True)
        timed_out = False
        while True:
            waited, status, usage = os.wait4(process.pid, os.WNOHANG)
            if waited:
                break
            if time.perf_counter() - start > timeout:
                timed_out = True
                # Signal the CLI, whose own relay terminates its tool groups.
                os.kill(process.pid, signal.SIGTERM)
                _, status, usage = os.wait4(process.pid, 0)
                break
            time.sleep(0.01)
        process.returncode = os.waitstatus_to_exitcode(status)
    return {"argv": command, "wall_seconds": time.perf_counter() - start,
            "user_seconds": usage.ru_utime, "system_seconds": usage.ru_stime,
            "cpu_seconds": usage.ru_utime + usage.ru_stime,
            "max_rss_bytes": usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024),
            "exit_code": process.returncode, "timed_out": timed_out,
            "stdout_bytes": stdout_path.stat().st_size, "stderr_bytes": stderr_path.stat().st_size,
            "stdout_path": str(stdout_path), "stderr_path": str(stderr_path)}


def capture(command):
    result = subprocess.run(command, capture_output=True)
    return {"argv": command, "exit_code": result.returncode,
            "stdout": result.stdout.decode(errors="replace"), "stderr": result.stderr.decode(errors="replace")}


def tool_wrappers(directory, real_tools):
    directory.mkdir()
    for name, executable in real_tools.items():
        wrapper = directory / name
        wrapper.write_text("#!" + sys.executable + "\n" +
            "import json,os,resource,subprocess,sys,time\n" +
            f"root={str(directory)!r}\nreal={executable!r}\n" +
            "start=time.perf_counter()\np=subprocess.Popen([real]+sys.argv[1:])\n" +
            "_,status,u=os.wait4(p.pid,0)\np.returncode=os.waitstatus_to_exitcode(status)\n" +
            "record={'tool':os.path.basename(sys.argv[0]),'argv':[real]+sys.argv[1:],'wall_seconds':time.perf_counter()-start,"
            "'cpu_seconds':u.ru_utime+u.ru_stime,'max_rss_bytes':u.ru_maxrss*(1 if sys.platform=='darwin' else 1024),'exit_code':p.returncode}\n" +
            "with open(os.path.join(root,str(os.getpid())+'.json'),'w') as f: json.dump(record,f)\n"
            "sys.exit(p.returncode)\n")
        wrapper.chmod(0o755)


def validate_packet(result, reference):
    packet_name = result.get("artifacts", {}).get("packet")
    if not packet_name:
        return {"applicable": False}
    packet_path = Path(packet_name)
    packet = json.loads(packet_path.read_text())
    cells = packet.get("cells", [])
    actual = reference["frames"]
    failures = []
    inspected = []
    previous = -math.inf
    for cell in cells:
        pts = cell.get("pts_seconds", cell.get("ptsSeconds"))
        ordinal = cell.get("ordinal")
        matched_ordinal = None
        if pts is None or not math.isfinite(pts) or pts < previous:
            failures.append({"kind": "nonmonotonic_pts", "cell": cell})
        previous = pts if pts is not None else previous
        if ordinal is not None and ordinal >= 0:
            if ordinal >= len(actual) or abs(float(actual[ordinal]["best_effort_timestamp_time"]) - pts) > 0.002:
                failures.append({"kind": "ordinal_pts_mismatch", "ordinal": ordinal, "pts": pts})
            else:
                matched_ordinal = ordinal
        elif pts is not None:
            nearest = min(range(len(actual)), key=lambda index: abs(float(actual[index]["best_effort_timestamp_time"]) - pts))
            if abs(float(actual[nearest]["best_effort_timestamp_time"]) - pts) > 0.002:
                failures.append({"kind": "pts_not_decoded_frame", "pts": pts})
            else:
                matched_ordinal = nearest
        frame_path = packet_path.parent / cell.get("frame_path", cell.get("framePath", ""))
        valid_jpeg = frame_path.is_file() and frame_path.stat().st_size > 32 and frame_path.read_bytes()[:2] == b"\xff\xd8"
        if not valid_jpeg:
            failures.append({"kind": "missing_or_invalid_jpeg", "path": str(frame_path)})
        inspected.append({"ordinal": ordinal, "reference_ordinal": matched_ordinal, "pts": pts, "image": str(frame_path),
                          "sha256": sha256(frame_path) if valid_jpeg else None})
    selector = packet.get("selector", "")
    sampling = packet.get("sampling", "")
    ordinals = [cell.get("ordinal") for cell in cells]
    if sampling in ("1f", "every 1 decoded frame", "every 1 decoded frames", "every 1 frames") and all(ordinal is not None and ordinal >= 0 for ordinal in ordinals):
        if any(right - left != 1 for left, right in zip(ordinals, ordinals[1:])):
            failures.append({"kind": "nonadjacent_dense_frames"})
    if selector == "overview" and cells:
        if abs(inspected[0]["pts"] - float(actual[0]["best_effort_timestamp_time"])) > 0.1:
            failures.append({"kind": "overview_missing_start"})
    if selector.startswith("frame:"):
        requested = int(selector.split(":", 1)[1])
        if len(inspected) != 1 or inspected[0].get("reference_ordinal") != requested:
            failures.append({"kind": "requested_ordinal_mismatch", "requested": requested})
    return {"applicable": True, "passed": not failures, "cell_count": len(cells), "sampling": sampling,
            "sheet_count": len(packet.get("sheets", [])), "failures": failures, "cells": inspected,
            "scope": "PTS matches independent ffprobe decode; image files are nonempty JPEGs. Pixel identity requires --verify-pixels or visual review."}


def verify_pixels(validation, source, ffmpeg, output):
    """Compare every returned JPEG against independent decoded ordinal extraction.

    Lossy JPEG means exact file hashes cannot establish identity. Decode the
    reference and returned image to the same 32x18 RGB grid, then record MAE.
    Sparse/unknown ordinal packets use matching reference PTS via the caller.
    """
    comparisons = []
    for index, cell in enumerate(validation.get("cells", [])):
        ordinal = cell.get("reference_ordinal", cell["ordinal"])
        if ordinal is None or ordinal < 0:
            continue
        expected = subprocess.run([ffmpeg, "-v", "error", "-threads", "2", "-filter_threads", "2", "-i", source,
            "-vf", f"select=eq(n\\,{ordinal}),scale=32:18:flags=area", "-frames:v", "1", "-threads", "2", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"], capture_output=True)
        observed = subprocess.run([ffmpeg, "-v", "error", "-threads", "2", "-filter_threads", "2", "-i", cell["image"],
            "-vf", "scale=32:18:flags=area", "-frames:v", "1", "-threads", "2", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"], capture_output=True)
        good = expected.returncode == observed.returncode == 0 and len(expected.stdout) == len(observed.stdout) == 32 * 18 * 3
        mae = sum(abs(left - right) for left, right in zip(expected.stdout, observed.stdout)) / len(expected.stdout) if good else None
        comparisons.append({"ordinal": ordinal, "mean_absolute_rgb_error": mae, "passed": good and mae < 8,
                            "reference_exit_code": expected.returncode, "image_exit_code": observed.returncode})
    validation["pixel_comparisons"] = comparisons
    validation["pixels_passed"] = bool(comparisons) and all(item["passed"] for item in comparisons)
    validation["scope"] += " Pixel comparison uses independent full decode, display rotation, and 32x18 RGB MAE < 8; not an OCR/readability proof."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--include", help="Comma-separated fixture names; default all")
    parser.add_argument("--operations", default="prepare-cold,prepare-warm,late,dense,range,overview,events,status")
    parser.add_argument("--mode", choices=("all-stages", "transcript"), default="all-stages",
                        help="Transcript mode measures preparation/reuse/status without asking for visuals")
    parser.add_argument("--warm-inspections", action="store_true", help="Repeat each inspection immediately to measure reuse")
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--trace-tools", action="store_true")
    parser.add_argument("--verify-pixels", action="store_true", help="Additional slow correctness probes, outside timing windows")
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    original_binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    original_hash = sha256(original_binary)
    binary = output / ("watchthrough-" + original_hash[:16])
    shutil.copy2(original_binary, binary)
    if sha256(binary) != original_hash:
        raise RuntimeError("Binary changed while being frozen for measurement; rerun to a fresh output directory")
    fixture_document = json.loads(args.fixtures.read_text())
    selected = [fixture for fixture in fixture_document["fixtures"]
                if not args.include or fixture["name"] in args.include.split(",")]
    operations = args.operations.split(",") if args.mode == "all-stages" else ["prepare-cold", "prepare-warm", "status"]
    if any(operation not in {"prepare-cold", "prepare-warm", "late", "dense", "range", "overview", "events", "ordinal", "ordinal-tail", "status"} for operation in operations):
        parser.error("Unknown operation")
    real_tools = {tool: shutil.which(tool) for tool in ("ffmpeg", "ffprobe")}
    metadata = {"schema": "watchthrough.bench.v1", "label": args.label, "binary": str(binary),
                "binary_original": str(original_binary), "binary_sha256": original_hash,
                "platform": platform.platform(), "machine": platform.machine(),
                "logical_cpu_count": os.cpu_count(), "python": sys.version, "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "hardware": capture(["/usr/sbin/sysctl", "hw.model", "hw.memsize", "hw.physicalcpu", "hw.logicalcpu"]),
                "binary_version": capture([str(binary), "--version"]),
                "tools": {tool: capture([executable, "-version"]) for tool, executable in real_tools.items()},
                "fixture_manifest_sha256": sha256(args.fixtures), "fixture_manifest": str(args.fixtures.resolve()),
                "operations": operations, "mode": args.mode, "warm_inspections": args.warm_inspections,
                "repeats": args.repeats, "trace_tools": args.trace_tools,
                "limits": ["Fresh analysis directories; OS caches are not purged.",
                           "Serial jobs; no ASR inference, cloud calls, downloads, or physical heat/power measurement.",
                           "wait4 CPU includes child accounting; max RSS is kernel high-water, not summed process-tree RSS.",
                           "Resource and wall metrics exclude packet/pixel validation and metadata capture."], "runs": []}
    environment = os.environ.copy()
    if args.trace_tools:
        wrappers = output / "tool-traces"
        tool_wrappers(wrappers, real_tools)
        environment["PATH"] = str(wrappers) + os.pathsep + environment.get("PATH", "")
    destination = output / "results.json"

    def save():
        destination.write_text(json.dumps(metadata, indent=2) + "\n")

    for fixture in selected:
        reference = json.loads(Path(fixture["reference"]).read_text())
        if sha256(fixture["path"]) != fixture["sha256"]:
            raise RuntimeError("Fixture hash changed: " + fixture["path"])
        for repetition in range(args.repeats):
            analysis = output / f"{fixture['name']}-{repetition + 1}.watchthrough"
            plan = ["prepare-cold"] + [operation for operation in operations if operation != "prepare-cold"]
            if args.warm_inspections:
                plan = [item for operation in plan for item in
                        ([operation, operation + "-warm"] if operation in ("late", "dense", "range", "overview", "events", "ordinal", "ordinal-tail") else [operation])]
            for operation in plan:
                base_operation = operation[:-5] if operation.endswith("-warm") and not operation.startswith("prepare") else operation
                prefix = f"{fixture['name']}-{repetition + 1}-{operation}"
                if operation.startswith("prepare"):
                    arguments = ["prepare", fixture["path"], "--out", str(analysis), "--transcriber", fixture["transcriber"]]
                elif operation == "status":
                    arguments = ["status", str(analysis)]
                else:
                    selectors = {"late": [f"{fixture['late_timestamp']:.6f}"],
                                 "dense": [f"{fixture['dense_start']:.6f}..{fixture['dense_end']:.6f}", "--every", "1f", "--cells", "15"],
                                 "range": [f"{fixture['range_start']:.6f}..{fixture['range_end']:.6f}", "--every", "500ms", "--cells", "15"],
                                 "ordinal": [f"frame:{fixture['frame_count'] * 3 // 4}"],
                                 "ordinal-tail": [f"frame:{fixture['frame_count'] - 1}"],
                                 "overview": ["overview"], "events": ["events"]}
                    arguments = ["inspect", str(analysis)] + selectors[base_operation]
                before = directory_size(analysis)
                metric = measured([str(binary), "--json"] + arguments,
                                  output / (prefix + ".stdout.json"), output / (prefix + ".stderr.txt"), environment, args.timeout)
                metric.update({"fixture": fixture["name"], "repetition": repetition + 1, "operation": operation,
                               "artifact_before": before, "artifact_after": directory_size(analysis)})
                try:
                    result = json.loads(Path(metric["stdout_path"]).read_text())
                    metric["result_ok"] = result.get("ok")
                    metric["reused"] = result.get("reused")
                    transcript_path = result.get("artifacts", {}).get("transcript_text")
                    metric["transcript_available"] = bool(transcript_path and Path(transcript_path).is_file())
                    if metric["transcript_available"]:
                        metric["transcript_text_bytes"] = Path(transcript_path).stat().st_size
                    metric["validation"] = validate_packet(result, reference)
                    if result.get("ok") and base_operation in ("late", "dense", "range", "overview", "ordinal", "ordinal-tail") and not metric["validation"].get("applicable"):
                        metric["validation"] = {"applicable": True, "passed": False,
                                                "failures": [{"kind": "inspection_packet_missing"}]}
                    if args.verify_pixels and metric["validation"].get("applicable"):
                        verify_pixels(metric["validation"], fixture["path"], real_tools["ffmpeg"], output)
                except (ValueError, OSError, KeyError, TypeError) as error:
                    metric["validation_error"] = str(error)
                metadata["runs"].append(metric)
                save()
                print(json.dumps({key: metric[key] for key in ("fixture", "repetition", "operation", "wall_seconds", "cpu_seconds", "max_rss_bytes", "exit_code")}), flush=True)
                if operation == "prepare-cold" and metric["exit_code"]:
                    break
    groups = {}
    for run in metadata["runs"]:
        groups.setdefault((run["fixture"], run["operation"]), []).append(run)
    metadata["summary"] = [{"fixture": fixture, "operation": operation, "samples": len(runs),
                            **{metric + "_median": statistics.median(run[metric] for run in runs)
                               for metric in ("wall_seconds", "cpu_seconds", "max_rss_bytes", "stdout_bytes")},
                            "all_success": all(run["exit_code"] == 0 and run.get("result_ok") is True for run in runs),
                            "validation_failures": sum(run.get("validation", {}).get("passed") is False
                                                       or run.get("validation", {}).get("pixels_passed") is False
                                                       or bool(run.get("validation_error")) for run in runs)}
                           for (fixture, operation), runs in groups.items()]
    workflows = {}
    for run in metadata["runs"]:
        workflows.setdefault((run["fixture"], run["repetition"]), {})[run["operation"]] = run
    required = ("prepare-cold", "late", "dense", "range", "overview", "events")
    metadata["workflows"] = []
    for (fixture, repetition), runs in workflows.items():
        preparation = runs.get("prepare-cold", {})
        full = all(operation in runs and runs[operation]["exit_code"] == 0 and runs[operation].get("result_ok") is True
                   and runs[operation].get("validation", {}).get("passed") is not False
                   and runs[operation].get("validation", {}).get("pixels_passed") is not False
                   and not runs[operation].get("validation_error") for operation in required)
        metadata["workflows"].append({"fixture": fixture, "repetition": repetition,
            "ready_wall_seconds": preparation.get("wall_seconds"),
            "time_to_transcript_seconds": preparation.get("wall_seconds") if preparation.get("transcript_available") else None,
            "full_workflow_operations": required, "full_workflow_completed": full,
            "full_workflow_wall_seconds": sum(runs[operation]["wall_seconds"] for operation in required) if full else None,
            "full_workflow_cpu_seconds": sum(runs[operation]["cpu_seconds"] for operation in required) if full else None,
            "ordinal_first_wall_seconds": runs.get("ordinal", {}).get("wall_seconds"),
            "ordinal_tail_wall_seconds": runs.get("ordinal-tail", {}).get("wall_seconds"),
            "scope": "Requested task sequence includes preparation and the same five explicit visual requests; warm reuse/status/global ordinal requests excluded. Eager/lazy internals, overview timestamps, and frame-index coverage may differ; this is not identical total computation. Optional ordinal and ordinal-tail operations separately expose global-index materialization."})
    if args.trace_tools:
        metadata["tool_calls"] = [json.loads(path.read_text()) for path in sorted(wrappers.glob("*.json"))]
    save()
    print(json.dumps({"results": str(destination), "runs": len(metadata["runs"])}), flush=True)


if __name__ == "__main__":
    main()
