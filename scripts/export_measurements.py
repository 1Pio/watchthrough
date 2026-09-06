#!/usr/bin/env python3
"""Export a deliberately allowlisted public benchmark evidence document.

Known synthetic benchmark datasets and explicitly allowlisted local workflow
metrics are read. Personal paths, raw stdout/stderr, media, transcript text or
fingerprints, speaker IDs, and raw provider responses are never exported.
Optional --candidate accepts another benchmark.py result using the same public
fixture hashes. This script does not acquire or process media.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics


METRICS = ("wall_seconds", "user_seconds", "system_seconds", "cpu_seconds", "max_rss_bytes",
           "exit_code", "timed_out", "stdout_bytes", "stderr_bytes")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def subset(record, keys):
    return {key: record[key] for key in keys if key in record}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(".scratch"))
    parser.add_argument("--output", type=Path, default=Path("docs/measurements.json"))
    parser.add_argument("--candidate", type=Path, action="append", default=[],
                        help="Repeat to retain measured iterations; the last candidate supplies comparison ratios")
    args = parser.parse_args()
    source = args.source_root.resolve()
    fixture_path = source / "fixtures-rotation-correction-20260906/fixtures.json"
    fixtures = json.loads(fixture_path.read_text())
    fixture_by_path = {fixture["path"]: fixture for fixture in fixtures["fixtures"]}

    def template(command):
        result = []
        for index, value in enumerate(command):
            if index == 0:
                basename = Path(value).name
                result.append(basename if basename in ("ffmpeg", "ffprobe", "python3", "swift") else "watchthrough")
            elif value in fixture_by_path:
                result.append("<FIXTURE:" + fixture_by_path[value]["name"] + ">")
            elif value.startswith("/") or value.startswith(".scratch/"):
                if ".watchthrough" in value:
                    result.append("<ANALYSIS_ARTIFACT>" if Path(value).suffix != ".watchthrough" else "<ANALYSIS>")
                elif value.endswith((".jpg", ".png")):
                    result.append("<OUTPUT_IMAGE_PATTERN>")
                elif value.endswith(".ffconcat"):
                    result.append("<SYNTHETIC_SLIDE_CONCAT>")
                elif value.endswith(".aiff"):
                    result.append("<SYNTHETIC_SPEECH_AUDIO>")
                else:
                    result.append("<LOCAL_PATH>")
            else:
                result.append(value)
        return result

    def validation(record):
        value = record.get("validation", {})
        clean = subset(value, ("applicable", "passed", "cell_count", "sheet_count", "sampling", "pixels_passed"))
        if "failures" in value:
            clean["failures"] = [subset(failure, ("kind", "ordinal", "pts", "requested")) for failure in value["failures"]]
        if "cells" in value:
            clean["cells"] = [subset(cell, ("ordinal", "reference_ordinal", "pts", "sha256")) for cell in value["cells"]]
        if "pixel_comparisons" in value:
            clean["pixel_comparisons"] = [subset(comparison, ("ordinal", "mean_absolute_rgb_error", "passed", "reference_exit_code", "image_exit_code"))
                                          for comparison in value["pixel_comparisons"]]
        return clean

    def benchmark(path, evidence_id):
        raw = json.loads(path.read_text())
        out = {"evidence_id": evidence_id, "raw_source_sha256": digest(path),
               **subset(raw, ("schema", "label", "binary_sha256", "platform", "machine", "logical_cpu_count", "timestamp_utc",
                              "fixture_manifest_sha256", "operations", "mode", "warm_inspections", "repeats", "trace_tools", "limits", "summary"))}
        out["tool_versions"] = {name: record.get("stdout", "").splitlines()[0] for name, record in raw.get("tools", {}).items()
                                if record.get("stdout")}
        out["runs"] = []
        templates = {}
        for run in raw["runs"]:
            key = run["fixture"] + ":" + run["operation"]
            templates.setdefault(key, template(run["argv"]))
            entry = {**subset(run, METRICS + ("fixture", "repetition", "operation", "artifact_before", "artifact_after", "result_ok", "reused", "transcript_available", "transcript_text_bytes")),
                     "command_template": key, "validation": validation(run)}
            if run.get("validation_error"):
                entry["validation_error_present"] = True
            out["runs"].append(entry)
        out["command_templates"] = templates
        if "workflows" in raw:
            out["workflows"] = raw["workflows"]
        else:
            groups = {}
            required = ("prepare-cold", "late", "dense", "range", "overview", "events")
            for run in raw["runs"]:
                groups.setdefault((run["fixture"], run["repetition"]), {})[run["operation"]] = run
            out["workflows"] = []
            for (name, repetition), runs in groups.items():
                completed = all(operation in runs and runs[operation]["exit_code"] == 0 and runs[operation].get("result_ok") for operation in required)
                out["workflows"].append({"fixture": name, "repetition": repetition,
                    "ready_wall_seconds": runs["prepare-cold"]["wall_seconds"],
                    "requested_task_sequence_completed": completed,
                    "requested_task_sequence_wall_seconds": sum(runs[operation]["wall_seconds"] for operation in required) if completed else None,
                    "requested_task_sequence_cpu_seconds": sum(runs[operation]["cpu_seconds"] for operation in required) if completed else None,
                    "operations": required})
        if "tool_calls" in raw:
            out["tool_calls"] = [{**subset(call, METRICS + ("tool",)), "argv_template": template(call["argv"])} for call in raw["tool_calls"]]
        return out

    def experiments(path, evidence_id, environment):
        raw = json.loads(path.read_text())
        out = {"evidence_id": evidence_id, "raw_source_sha256": digest(path), "execution_environment": environment,
               **subset(raw, ("schema", "fixture_manifest_sha256", "repeats", "limits", "summary")),
               "ffmpeg_version": raw["ffmpeg"]["stdout"].splitlines()[0], "runs": [], "command_templates": {}}
        for run in raw["runs"]:
            key = run["variant"]["fixture"] + ":" + run["variant"]["name"]
            out["command_templates"].setdefault(key, [template(command["argv"]) for command in run["commands"]])
            out["runs"].append({**subset(run, ("variant", "repetition", "wall_seconds", "cpu_seconds", "max_rss_bytes", "all_exit_zero", "output_images", "output_bytes", "output_sha256", "expected_pts", "actual_pts", "pts_match", "passed")),
                                "command_template": key,
                                "processes": [subset(command, METRICS + ("pts_receipts",)) for command in run["commands"]]})
        return out

    output = {"schema": "watchthrough.public-measurements.v1", "state": "candidate-pending" if not args.candidate else "candidate-measured",
              "privacy": "Allowlisted metrics, public metadata, and command templates only. No personal absolute paths, raw output, media, transcript text or fingerprints, speaker IDs, or raw provider responses.",
              "reproduction": [
                  ["python3", "scripts/fixtures.py", "--output", "<FIXTURE_DIR>"],
                  ["python3", "scripts/benchmark.py", "--binary", "<BASELINE_BINARY>", "--label", "baseline", "--fixtures", "<FIXTURE_DIR>/fixtures.json", "--output", "<BASELINE_RESULTS>", "--repeats", "2"],
                  ["python3", "scripts/experiments.py", "--fixtures", "<FIXTURE_DIR>/fixtures.json", "--output", "<EXPERIMENT_RESULTS>", "--repeats", "3"]],
              "current_harness_sha256": {name: digest(Path(__file__).parent / name) for name in ("fixtures.py", "benchmark.py", "experiments.py", "export_measurements.py")},
              "limitations": [
                  "Results apply to these synthetic fixtures and this Apple Silicon execution environment, not every video or computer.",
                  "Cold means a fresh analysis directory, not a flushed OS disk cache. Runs are serial; no direct energy, temperature, or responsiveness telemetry was collected.",
                  "wait4 CPU includes waited-for descendants; max RSS is the kernel high-water measure, not summed simultaneous process-tree memory.",
                  "Same requested task sequence does not imply identical total internal work, global-index coverage, overview target timestamps, or semantic visual coverage.",
                  "The synthetic matrix's slides fixture has authored sidecar text but no voice samples because sandboxed say emitted empty audio. That matrix does not evaluate ASR accuracy or inference speed; separately allowlisted real local transcription workflows retain their own limitations.",
                  "Current harness hashes identify reproduction code at export time, not necessarily the script revision used for earlier preserved runs.",
                  "VideoToolbox failed inside sandbox but succeeded outside it. The initial invalid pixel-format experiment is retained only as iteration history, not as hardware evidence."],
              "fixtures": [], "benchmarks": [], "experiments": []}
    for fixture in fixtures["fixtures"]:
        reference = json.loads(Path(fixture["reference"]).read_text())
        stream = reference["streams"][0]
        item = {**subset(fixture, ("name", "sha256", "size_bytes", "purpose", "transcriber", "frame_count", "first_pts", "last_pts", "late_timestamp", "dense_start", "dense_end", "range_start", "range_end", "assertions")),
                "reference_sha256": digest(Path(fixture["reference"])),
                "media": subset(stream, ("codec_name", "width", "height", "avg_frame_rate", "r_frame_rate", "time_base", "duration", "start_time", "nb_frames")),
                "display_rotations": [record["rotation"] for record in stream.get("side_data_list", []) if "rotation" in record]}
        if fixture["name"] == "rotation":
            item["correction"] = "Unrotated duplicate generated by ignored legacy rotation metadata; excluded from actual rotation claims and corrected comparisons."
        output["fixtures"].append(item)
    output["fixture_recipe_templates"] = [template(record["argv"]) for record in fixtures["commands"]
                                           if "argv" in record and Path(record["argv"][0]).name == "ffmpeg"]
    output["fixture_recipe_templates"].append(template(fixtures["correction"]["generation_argv"]))
    for name in ("baseline-20260906", "baseline-trace-20260906", "baseline-rotation-corrected-20260906"):
        output["benchmarks"].append(benchmark(source / name / "results.json", name))
    ordinal_addendum = source / "baseline-ordinal-addendum-20260906/results.json"
    if ordinal_addendum.exists():
        output["benchmarks"].append(benchmark(ordinal_addendum, "baseline-ordinal-addendum-20260906"))
    for name, environment in (("experiments-20260906", "sandboxed; initial hardware variant has invalid output pixel format"),
                              ("experiments-vt-corrected-20260906", "sandboxed; corrected forced hardware mode"),
                              ("experiments-vt-unsandboxed-20260906", "unsandboxed; explicit successful hardware comparison")):
        output["experiments"].append(experiments(source / name / "results.json", name, environment))
    for index, candidate_path in enumerate(args.candidate):
        evidence_id = "candidate" if index == len(args.candidate) - 1 else "candidate-iteration-" + str(index + 1)
        candidate = benchmark(candidate_path.resolve(), evidence_id)
        if candidate["fixture_manifest_sha256"] != digest(fixture_path):
            raise ValueError("Candidate fixture manifest differs from the verified public manifest")
        output["benchmarks"].append(candidate)
    if args.candidate:
        baselines = [item for item in output["benchmarks"] if item["evidence_id"] in ("baseline-20260906", "baseline-rotation-corrected-20260906", "baseline-ordinal-addendum-20260906")]
        original = {(row["fixture"], row["operation"]): row for item in baselines for row in item["summary"]}
        output["comparisons"] = []
        for row in candidate["summary"]:
            previous = original.get((row["fixture"], row["operation"]))
            if not previous:
                continue
            supported = previous["all_success"] and row["all_success"] and not previous["validation_failures"] and not row["validation_failures"]
            comparison = {"fixture": row["fixture"], "operation": row["operation"],
                          "fixture_sha256": next(fixture["sha256"] for fixture in output["fixtures"] if fixture["name"] == row["fixture"]),
                          "successful_counterparts": supported,
                          "baseline_samples": previous["samples"], "candidate_samples": row["samples"],
                          "scope": "Same fixture hash and requested operation. Cold preparation has different eager/lazy work; inspect stages may have deferred costs. Read the complete task-sequence totals and limitations."}
            old_walls = [run["wall_seconds"] for item in baselines for run in item["runs"] if run["fixture"] == row["fixture"] and run["operation"] == row["operation"]]
            new_walls = [run["wall_seconds"] for run in candidate["runs"] if run["fixture"] == row["fixture"] and run["operation"] == row["operation"]]
            comparison["baseline_wall_seconds_samples"] = old_walls
            comparison["candidate_wall_seconds_samples"] = new_walls
            if old_walls and min(old_walls) > 0 and max(old_walls) > 2 * min(old_walls):
                comparison["latency_ratio_caution"] = "Baseline samples vary by more than 2x; retain the observed values but do not infer a stable steady-state speedup from this median."
            for metric in ("wall_seconds", "cpu_seconds", "max_rss_bytes"):
                comparison[metric] = {"baseline_median": previous[metric + "_median"], "candidate_median": row[metric + "_median"],
                                      "baseline_over_candidate": previous[metric + "_median"] / row[metric + "_median"] if supported and row[metric + "_median"] else None}
            output["comparisons"].append(comparison)
        baseline_sequence_runs = [run for item in baselines if item["evidence_id"] != "baseline-ordinal-addendum-20260906" for run in item["runs"]]
        required = ("prepare-cold", "late", "dense", "range", "overview", "events")
        sequence_rows = []
        for fixture_name in sorted({run["fixture"] for run in candidate["runs"]}):
            row = {"fixture": fixture_name}
            for label, runs in (("baseline", baseline_sequence_runs), ("candidate", candidate["runs"])):
                ready = [run for run in runs if run["fixture"] == fixture_name and run["operation"] == "prepare-cold"]
                for metric in ("wall_seconds", "cpu_seconds", "max_rss_bytes"):
                    row[label + "_ready_" + metric + "_median"] = statistics.median(run[metric] for run in ready) if ready else None
                sequences = []
                for repetition in sorted({run["repetition"] for run in ready}):
                    chosen = [run for run in runs if run["fixture"] == fixture_name and run["repetition"] == repetition and run["operation"] in required]
                    if len(chosen) == len(required) and all(run["exit_code"] == 0 and run.get("result_ok") is True and run["validation"].get("passed") is not False for run in chosen):
                        sequences.append({"wall_seconds": sum(run["wall_seconds"] for run in chosen), "cpu_seconds": sum(run["cpu_seconds"] for run in chosen),
                                          "stage_peak_rss_bytes": max(run["max_rss_bytes"] for run in chosen)})
                row[label + "_completed_sequence_repetitions"] = len(sequences)
                for metric in ("wall_seconds", "cpu_seconds", "stage_peak_rss_bytes"):
                    row[label + "_sequence_" + metric + "_median"] = statistics.median(sequence[metric] for sequence in sequences) if sequences else None
            warm = [run for run in candidate["runs"] if run["fixture"] == fixture_name and run["operation"].endswith("-warm") and run["operation"] != "prepare-warm"]
            row["candidate_warm_inspection_wall_seconds_median"] = statistics.median(run["wall_seconds"] for run in warm) if warm else None
            sequence_rows.append(row)
        output["task_sequence_comparison"] = {"operations": required,
            "scope": "Initial readiness is measured separately from the full requested timestamp/range/overview/events sequence. Global ordinal/tail requests and warm reuse are excluded from sequence totals. Stage-peak RSS is the maximum reported per-process high-water across these sequential stages, not summed simultaneous process-tree memory. Failed baseline sequences have no completion-time comparison.",
            "rows": sequence_rows}
    packaging_records = []
    for directory in ("release-proof-20260906", "release-packaged-final-20260906"):
        packaging_path = source / directory / "packaging.json"
        if not packaging_path.exists():
            continue
        packaging = json.loads(packaging_path.read_text())
        measured_packaged = bool(args.candidate and candidate["binary_sha256"] == packaging["after_sha256"])
        packaging_records.append({
            "evidence_id": directory,
            "raw_source_sha256": digest(packaging_path),
            **subset(packaging, ("schema", "operation", "before_sha256", "after_sha256", "before_bytes", "after_bytes", "all_file_backed_sections_identical", "sections")),
            "debug_build_path_entries_before": packaging["old_private_path_occurrences"],
            "debug_build_path_entries_after": packaging["new_private_path_occurrences"],
            "final_benchmark_binary_is_before_packaging_hash": bool(args.candidate and candidate["binary_sha256"] == packaging["before_sha256"]),
            "final_benchmark_binary_is_packaged_hash": measured_packaged,
            "matching_benchmark_evidence_ids": [record["evidence_id"] for record in output["benchmarks"] if record["binary_sha256"] == packaging["after_sha256"]],
            "scope": ("The final performance matrix measured this exact packaged executable. " if measured_packaged else "Preserved packaging evidence; benchmark hashes identify whether a corresponding executable was measured. ") +
                     "Debug symbols were stripped and the executable was signed again; every file-backed program section is byte-identical across this packaging step. Whole-file SHA changed because packaging changed. Workflow acceptance is recorded separately."})
    if packaging_records:
        output["release_packaging"] = packaging_records[-1]
        output["release_packaging_iterations"] = packaging_records[:-1]
    focused_path = source / "slides-grouping-20260906/results.json"
    if focused_path.exists():
        focused = json.loads(focused_path.read_text())
        output["focused_grouping_experiment"] = {"raw_source_sha256": digest(focused_path),
            **subset(focused, ("schema", "source_sha256", "source_duration_seconds", "source_size_bytes", "recipe", "all_passed", "all_images_byte_identical", "summary")),
            "runs": [{**subset(run, ("strategy", "repetition", "wall_seconds", "cpu_seconds", "max_rss_bytes", "images", "image_sha256", "expected_pts", "actual_pts", "passed")),
                      "processes": [{**subset(process, METRICS + ("pts_receipts",)), "argv_template": template(process["argv"])} for process in run["processes"]]}
                     for run in focused["runs"]]}
    hash_path = source / "hash-memory-20260906/results.json"
    actual_hash_path = source / "hash-memory-20260906/actual-sources-results.json"
    if hash_path.exists() and actual_hash_path.exists():
        isolated = json.loads(hash_path.read_text())
        actual = json.loads(actual_hash_path.read_text())
        hash_fields = ("variant", "fixture", "file_bytes", "iteration", "wall_seconds", "cpu_seconds", "max_rss_bytes", "exit_code",
                       "expected_sha256", "observed_sha256", "sha256", "digest_matches")
        clean_isolated = [{**subset(record, hash_fields), "command_template": ["<ISOLATED_HASH_BINARY:" + record["variant"] + ">", "<ZERO_FILE:" + str(record["file_bytes"]) + ">"]}
                          for record in isolated["records"]]
        clean_actual = [{**subset(record, hash_fields), "command_template": ["<ISOLATED_HASH_BINARY:" + record["variant"] + ">", "<FIXTURE:" + record["fixture"] + ">"]}
                        for record in actual]
        groups = {}
        for record in clean_isolated + clean_actual:
            groups.setdefault((record.get("fixture", "zero-bytes"), record["file_bytes"], record["variant"]), []).append(record)
        output["hash_memory_experiment"] = {
            "raw_source_sha256": digest(hash_path), "actual_sources_raw_sha256": digest(actual_hash_path),
            **subset(isolated, ("host", "swift_version", "source_function_sha256", "measure")),
            "isolated_runs": clean_isolated, "actual_source_runs": clean_actual,
            "all_digests_match": all(record["digest_matches"] for record in clean_isolated + clean_actual),
            "summary": [{"input": name, "file_bytes": size, "variant": variant, "samples": len(records),
                         **{metric + "_median": statistics.median(record[metric] for record in records) for metric in ("wall_seconds", "cpu_seconds", "max_rss_bytes")}}
                        for (name, size, variant), records in groups.items()],
            "scope": "Isolated copied hashing function, before and after per-chunk autorelease pools; synthetic zero files plus two existing public synthetic videos. Constant-memory hashing is distinct from whole-CLI peak RSS. Launch outliers are retained; no physical heat or power claim."}
    vfr_path = source / "vfr-timebase-20260906/results.json"
    vfr_proof_path = source / "vfr-timebase-20260906/cli-independent-proof.json"
    if vfr_path.exists() and vfr_proof_path.exists():
        variants = json.loads(vfr_path.read_text())
        proof = json.loads(vfr_proof_path.read_text())
        fixture = fixture_by_path[proof["source"]]
        output["vfr_encoder_timebase_experiment"] = {
            "raw_source_sha256": digest(vfr_path), "independent_proof_raw_sha256": digest(vfr_proof_path),
            "fixture_sha256": fixture["sha256"], "reference_sha256": digest(Path(fixture["reference"])),
            "variants": [{**subset(record, ("name", "exit", "wall_seconds", "images")), "argv_template": template(record["arguments"])} for record in variants],
            "independent_proof": {**subset(proof, ("reference_method", "expected_count", "actual_count", "all_pts_match", "all_images_byte_identical")),
                                  "frames": [subset(frame, ("global_ordinal", "reference_pts", "packet_pts", "pts_match", "actual_sha256", "reference_sha256", "pixels_match")) for frame in proof["frames"]]},
            "scope": "24fps-advertised source contains a 60fps interval. Default MJPEG encoder clock rejects distinct timestamps after quantization. Source/filter clock variants retain all 13 requested frames; the corrected CLI packet is independently checked against a full decode without input seeking."}
    renderer_path = source / "render-benchmark-20260906/results.json"
    renderer = json.loads(renderer_path.read_text())
    output["renderer"] = {"raw_source_sha256": digest(renderer_path), "method": "RenderTests.testOptInRenderBenchmark; one synthetic strip, five iterations per format, debug build.",
                          "runs": [subset(run, ("format", "iteration", "seconds", "bytes")) for run in renderer],
                          "summary": [{"format": kind, "seconds_median": statistics.median(run["seconds"] for run in renderer if run["format"] == kind),
                                       "bytes_median": statistics.median(run["bytes"] for run in renderer if run["format"] == kind)} for kind in ("png", "jpeg")],
                          "limitation": "One synthetic strip cannot establish an optimal format for all imagery. Renderer timings do not measure video decoding."}
    parity = json.loads((source / "experiment-image-parity-20260906.json").read_text())
    hardware_parity = json.loads((source / "experiments-vt-pixel-parity-20260906.json").read_text())
    output["image_parity"] = {
        "software": {"raw_source_sha256": digest(source / "experiment-image-parity-20260906.json"),
                     "compared_runs": sum(record["comparable_to_reference"] for record in parity["records"]),
                     "all_byte_identical": all(record["byte_identical_to_reference"] for record in parity["records"] if record["comparable_to_reference"])},
        "hardware": {"raw_source_sha256": digest(source / "experiments-vt-pixel-parity-20260906.json"),
                     "compared_pairs": len(hardware_parity["records"]),
                     "all_byte_identical": all(record["software_sha256"] == record["hardware_sha256"] for record in hardware_parity["records"]),
                     "max_mean_absolute_rgb_error_at_320x180": hardware_parity["max_mean_absolute_rgb_error"]}}
    decisions = json.loads((source / "experiment-decisions-20260906.json").read_text())
    output["decisions"] = decisions["decisions"]
    output["corrections"] = decisions["corrections"]
    asr_records = []
    for directory in ("real-asr-20260906", "real-asr-release-20260906"):
        asr_path = source / directory / "results.json"
        if not asr_path.exists():
            continue
        asr = json.loads(asr_path.read_text())
        earlier_warmup = directory == "real-asr-20260906"
        asr_records.append({
            "evidence_id": directory,
            "raw_source_sha256": digest(asr_path),
            **subset(asr, ("schema", "source_sha256", "baseline_binary_sha256", "candidate_binary_sha256", "word_content_and_timing_equal_ignoring_speakers", "clean_transcript_text_equal", "word_count")),
            "duration_seconds": 30.016,
            "candidate_matches_final_benchmark_binary": bool(args.candidate and candidate["binary_sha256"] == asr["candidate_binary_sha256"]),
            "runs": [{**subset(run, METRICS + ("label", "order", "ok", "transcript_text_bytes")),
                      "transcript": subset(run["transcript"], ("available", "provider", "model", "speakersAvailable", "timingPrecision"))} for run in asr["runs"]],
            "summary": [{"label": label, "samples": sum(run["label"] == label for run in asr["runs"]),
                         **{metric + "_median": statistics.median(run[metric] for run in asr["runs"] if run["label"] == label) for metric in ("wall_seconds", "cpu_seconds", "max_rss_bytes")}}
                        for label in ("baseline", "candidate", "candidate-speakers")],
            "scope": "Six real local transcription workflow runs on one 30.016-second clip using the packaged candidate identified by this record's hash. All clean transcripts are 340 bytes; 40 word contents and timings match when speaker labels are ignored. Raw text, transcript fingerprints, paths, speaker IDs, and provider responses are deliberately omitted.",
            "limitations": ["Not a word-error-rate or isolated inference-engine benchmark.",
                            ("First baseline run includes initial model warmup and eager visual preparation; process order is preserved." if earlier_warmup else
                             "This release sequence starts after earlier qualification exercised the provider runtime; its first baseline already has the model cached/runtime previously loaded. Eager baseline visual preparation and process order remain part of the workflow timing."),
                            "Default candidate omits speaker diarization. The two candidate-speakers runs separately retain that feature for a closer provider-configuration comparison.",
                            "The source transcript was read in full during workflow acceptance; identical outputs do not independently establish recognition accuracy."]})
    if asr_records:
        output["real_local_transcription"] = asr_records[-1]
        output["real_local_transcription_iterations"] = asr_records[:-1]
    lifecycle_path = source / "real-asr-release-20260906/lifecycle-proof.json"
    if lifecycle_path.exists():
        lifecycle = json.loads(lifecycle_path.read_text())
        output["packaged_workflow_lifecycle"] = {
            "raw_source_sha256": digest(lifecycle_path),
            **subset(lifecycle, ("packaged_binary_sha256", "cleanup_mode", "analysis_original_path_absent", "source_sha256_unchanged",
                                "retained_files_all_checksums_match", "summary_links_resolve_after_cleanup", "full_transcript_bytes",
                                "full_transcript_sha256_unchanged", "all_frame_cells_match_previously_opened_evidence",
                                "overview_cells_opened", "inspected_unique_dense_timestamps")),
            "matches_final_benchmark_binary": bool(args.candidate and candidate["binary_sha256"] == lifecycle["packaged_binary_sha256"]),
            "scope": "The exact packaged candidate retained selected evidence in the default library, moved only generated analysis to macOS system Trash, and reopened the retained note, full transcript, and native dense sheet after cleanup. File checksums, links, and source preservation were checked; private paths and transcript fingerprints are omitted."}
    output["renderer_additional_datasets"] = []
    for directory, label in (("render-photographic-20260906", "flat graphic overlay"), ("render-talking-head-20260906", "dark talking head")):
        path = source / directory / "results.json"
        if path.exists():
            rows = json.loads(path.read_text())
            output["renderer_additional_datasets"].append({"dataset": label, "raw_source_sha256": digest(path),
                "runs": [subset(row, ("format", "iteration", "seconds", "bytes")) for row in rows],
                "summary": [{"format": kind, "seconds_median": statistics.median(row["seconds"] for row in rows if row["format"] == kind),
                             "bytes_median": statistics.median(row["bytes"] for row in rows if row["format"] == kind)} for kind in ("png", "jpeg")],
                "scope": "Five iterations per format. The first dataset's original directory name was misleading: its actual content is a flat graphic overlay. JPEG was faster on the tested sets but produced larger files; PNG remains an explicit option. No universal speed, compression, or visual-quality conclusion."})
    output["counts"] = {
        "benchmark_cli_operations": sum(len(item["runs"]) for item in output["benchmarks"]),
        "controlled_ffmpeg_runs_including_superseded_hardware_attempts": sum(len(item["runs"]) for item in output["experiments"]),
        "focused_slide_grouping_runs": len(output.get("focused_grouping_experiment", {}).get("runs", [])),
        "isolated_hash_runs": len(output.get("hash_memory_experiment", {}).get("isolated_runs", [])),
        "actual_source_hash_runs": len(output.get("hash_memory_experiment", {}).get("actual_source_runs", [])),
        "encoder_timebase_trials": len(output.get("vfr_encoder_timebase_experiment", {}).get("variants", [])),
        "independent_vfr_frame_comparisons": len(output.get("vfr_encoder_timebase_experiment", {}).get("independent_proof", {}).get("frames", [])),
        "renderer_iterations": len(renderer) + sum(len(item["runs"]) for item in output["renderer_additional_datasets"]),
        "real_local_transcription_runs": sum(len(record["runs"]) for record in asr_records),
        "latest_real_local_transcription_runs": len(output.get("real_local_transcription", {}).get("runs", [])),
        "identical_software_image_sequence_runs": output["image_parity"]["software"]["compared_runs"],
        "hardware_software_jpeg_pairs": output["image_parity"]["hardware"]["compared_pairs"]}
    header = ("schema", "state", "counts", "privacy", "release_packaging")
    output = {**subset(output, header), **{key: value for key, value in output.items() if key not in header}}
    encoded = json.dumps(output, indent=2) + "\n"
    forbidden = (r"/Users/", r"/home/", r"/private/", r"/opt/homebrew/", r"file://", r"ELEVENLABS_API_KEY", r"Bearer ")
    for pattern in forbidden:
        if re.search(pattern, encoded):
            raise ValueError("Public export contains a forbidden path or credential marker: " + pattern)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(encoded)
    print(json.dumps({"output": str(args.output), "bytes": len(encoded.encode()), "state": output["state"],
                      "benchmark_runs": sum(len(item["runs"]) for item in output["benchmarks"]),
                      "experiment_runs": sum(len(item["runs"]) for item in output["experiments"])}))


if __name__ == "__main__":
    main()
