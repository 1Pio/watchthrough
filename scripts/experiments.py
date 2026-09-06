#!/usr/bin/env python3
"""Controlled serial FFmpeg experiments with decoded timestamp receipts.

Uses the public fixtures from fixtures.py and records raw output, commands,
wait4 resource usage, and showinfo PTS receipts. Every variant changes one named
dimension from software decode, two threads per stage, Lanczos, 1440px output.
No deletion, downloads, ASR, or external writes. Hardware failure is recorded,
never silently retried as software. Results are tradeoffs, not quality scores.
"""

import argparse
import json
from pathlib import Path
import re
import shutil
import statistics

from benchmark import capture, measured, sha256


def receipts(path):
    raw = path.read_text(errors="replace")
    timebases = re.findall(r"config in time_base:\s*(\d+)/(\d+)", raw)
    ticks = re.findall(r"\bn:\s*\d+\s+pts:\s*(-?\d+)\s+pts_time:", raw)
    if not timebases:
        return []
    numerator, denominator = map(int, timebases[0])
    return [int(tick) * numerator / denominator for tick in ticks]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--include", help="Comma-separated variant names; default all")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    ffmpeg = shutil.which("ffmpeg")
    fixture_document = json.loads(args.fixtures.read_text())
    fixtures = {fixture["name"]: fixture for fixture in fixture_document["fixtures"]}
    document = {"schema": "watchthrough.experiments.v1", "ffmpeg": capture([ffmpeg, "-version"]),
                "fixture_manifest": str(args.fixtures.resolve()), "fixture_manifest_sha256": sha256(args.fixtures),
                "repeats": args.repeats, "runs": [],
                "limits": ["Serial process execution; OS disk caches retained.",
                           "Wall/CPU/RSS include all commands in a multi-seek variant.",
                           "Output PTS are checked against independent full-decode fixture references.",
                           "Resizing variants intentionally produce different pixels; timing parity is checked, text readability requires visual review.",
                           "CPU and RSS are not power or physical temperature measurements."]}
    variants = []
    for fixture in ("motion", "scale"):
        for threads in (1, 2, 4):
            variants.append({"fixture": fixture, "name": "threads-" + str(threads), "threads": threads})
    variants += [{"fixture": "motion", "name": "videotoolbox", "hardware": True},
                 {"fixture": "motion", "name": "sparse-serial-seeks", "strategy": "seeks"},
                 {"fixture": "scale", "name": "sparse-serial-seeks", "strategy": "seeks"},
                 {"fixture": "scale", "name": "sparse-grouped-seeks", "strategy": "groups"},
                 {"fixture": "motion", "name": "dense-full-scan", "dense": True},
                 {"fixture": "motion", "name": "dense-seek-span", "dense": True, "strategy": "groups"},
                 {"fixture": "motion", "name": "dense-serial-seeks", "dense": True, "strategy": "seeks"}]
    for width, flags in ((360, "lanczos"), (720, "lanczos"), (720, "area"), (720, "bilinear"), (1440, "area"), (1440, "bilinear")):
        variants.append({"fixture": "motion", "name": f"scale-{width}-{flags}", "width": width, "flags": flags})
    if args.include:
        variants = [variant for variant in variants if variant["name"] in args.include.split(",")]

    def save():
        (output / "results.json").write_text(json.dumps(document, indent=2) + "\n")

    for variant in variants:
        fixture = fixtures[variant["fixture"]]
        reference = json.loads(Path(fixture["reference"]).read_text())
        pts = [float(frame["best_effort_timestamp_time"]) for frame in reference["frames"]]
        ordinals = list(range(len(pts) * 3 // 4, len(pts) * 3 // 4 + 13)) if variant.get("dense") else [round(index * (len(pts) - 1) / 11) for index in range(12)]
        targets = [pts[ordinal] for ordinal in ordinals]
        strategy = variant.get("strategy", "full")
        if strategy == "seeks":
            groups = [[ordinal] for ordinal in ordinals]
        elif strategy == "groups":
            size = len(ordinals) if variant.get("dense") else 3
            groups = [ordinals[index:index + size] for index in range(0, len(ordinals), size)]
        else:
            groups = [ordinals]
        for repeat in range(args.repeats):
            directory = output / f"{variant['fixture']}-{variant['name']}-{repeat + 1}"
            directory.mkdir()
            runs, received = [], []
            for group_index, group in enumerate(groups):
                threads, width, flags = variant.get("threads", 2), variant.get("width", 1440), variant.get("flags", "lanczos")
                command = [ffmpeg, "-hide_banner", "-loglevel", "info", "-nostdin", "-n", "-copyts", "-threads", str(threads)]
                if variant.get("hardware"):
                    command += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
                if strategy != "full":
                    command += ["-ss", f"{max(0, pts[group[0]] - pts[0] - 0.0001):.9f}"]
                command += ["-i", fixture["path"], "-map", "0:v:0", "-an", "-sn", "-dn", "-filter_threads", str(threads)]
                # Absolute PTS selection after accurate seek avoids frame-rate
                # arithmetic and preserves the same independent reference list.
                select = "+".join(f"lt(abs(t-{pts[ordinal]:.9f})\\,0.00001)" for ordinal in group)
                filters = ["select=" + select, "showinfo=checksum=0"]
                if variant.get("hardware"):
                    filters += ["hwdownload", "format=nv12"]
                filters += [f"scale=min({width}\\,iw):-2:flags={flags}"]
                command += ["-vf", ",".join(filters), "-fps_mode", "passthrough", "-q:v", "2", "-frames:v", str(len(group)),
                            "-threads", str(threads), str(directory / f"group-{group_index:02}-%03d.jpg")]
                stderr = directory / f"group-{group_index:02}.stderr.txt"
                metric = measured(command, directory / f"group-{group_index:02}.stdout.txt", stderr, None, 120)
                got = receipts(stderr)
                received += got
                metric["pts_receipts"] = got
                runs.append(metric)
            images = sorted(directory.glob("*.jpg"))
            correct = len(received) == len(targets) and all(abs(left - right) <= 0.000002 for left, right in zip(received, targets))
            result = {"variant": variant, "repetition": repeat + 1, "commands": runs,
                      "wall_seconds": sum(run["wall_seconds"] for run in runs),
                      "cpu_seconds": sum(run["cpu_seconds"] for run in runs),
                      "max_rss_bytes": max(run["max_rss_bytes"] for run in runs),
                      "all_exit_zero": all(run["exit_code"] == 0 for run in runs),
                      "output_images": len(images), "output_bytes": sum(image.stat().st_size for image in images),
                      "output_sha256": [sha256(image) for image in images],
                      "expected_pts": targets, "actual_pts": received, "pts_match": correct,
                      "passed": correct and len(images) == len(targets) and all(run["exit_code"] == 0 for run in runs)}
            document["runs"].append(result)
            save()
            print(json.dumps({"fixture": fixture["name"], "variant": variant["name"], "repeat": repeat + 1,
                              **{key: result[key] for key in ("wall_seconds", "cpu_seconds", "max_rss_bytes", "output_images", "pts_match", "passed")}}), flush=True)
    grouped = {}
    for run in document["runs"]:
        grouped.setdefault((run["variant"]["fixture"], run["variant"]["name"]), []).append(run)
    document["summary"] = [{"fixture": fixture, "variant": name, "samples": len(runs),
                           **{metric + "_median": statistics.median(run[metric] for run in runs)
                              for metric in ("wall_seconds", "cpu_seconds", "max_rss_bytes", "output_bytes")},
                           "all_passed": all(run["passed"] for run in runs),
                           "decision": "explored; selection requires latency, CPU, fidelity, and workflow tradeoff review"}
                          for (fixture, name), runs in grouped.items()]
    save()


if __name__ == "__main__":
    main()
