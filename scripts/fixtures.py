#!/usr/bin/env python3
"""Create bounded, public synthetic video fixtures; never overwrite existing files.

No network, ASR, or third-party Python packages are used. FFmpeg encoding and
filtering are limited to two threads. The manifest records exact commands,
decoded timestamps, file hashes, and the scope of the synthetic ground truth.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import time


def run(command, records):
    start = time.perf_counter()
    result = subprocess.run(command, capture_output=True)
    records.append({"argv": command, "wall_seconds": time.perf_counter() - start,
                    "exit_code": result.returncode,
                    "stderr": result.stderr.decode(errors="replace")})
    if result.returncode:
        raise RuntimeError(json.dumps(records[-1], indent=2))
    return result.stdout


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


# Small deterministic font, enough to make the synthetic slides independently
# readable without platform fonts, Pillow, ImageMagick, or FFmpeg drawtext.
FONT = {
    "A": "01110 10001 10001 11111 10001 10001 10001", "B": "11110 10001 10001 11110 10001 10001 11110",
    "C": "01111 10000 10000 10000 10000 10000 01111", "D": "11110 10001 10001 10001 10001 10001 11110",
    "E": "11111 10000 10000 11110 10000 10000 11111", "F": "11111 10000 10000 11110 10000 10000 10000",
    "G": "01111 10000 10000 10111 10001 10001 01111", "H": "10001 10001 10001 11111 10001 10001 10001",
    "I": "11111 00100 00100 00100 00100 00100 11111", "J": "00111 00010 00010 00010 10010 10010 01100",
    "K": "10001 10010 10100 11000 10100 10010 10001", "L": "10000 10000 10000 10000 10000 10000 11111",
    "M": "10001 11011 10101 10101 10001 10001 10001", "N": "10001 11001 10101 10011 10001 10001 10001",
    "O": "01110 10001 10001 10001 10001 10001 01110", "P": "11110 10001 10001 11110 10000 10000 10000",
    "Q": "01110 10001 10001 10001 10101 10010 01101", "R": "11110 10001 10001 11110 10100 10010 10001",
    "S": "01111 10000 10000 01110 00001 00001 11110", "T": "11111 00100 00100 00100 00100 00100 00100",
    "U": "10001 10001 10001 10001 10001 10001 01110", "V": "10001 10001 10001 10001 10001 01010 00100",
    "W": "10001 10001 10001 10101 10101 11011 10001", "X": "10001 10001 01010 00100 01010 10001 10001",
    "Y": "10001 10001 01010 00100 00100 00100 00100", "Z": "11111 00001 00010 00100 01000 10000 11111",
    "0": "01110 10001 10011 10101 11001 10001 01110", "1": "00100 01100 00100 00100 00100 00100 01110",
    "2": "01110 10001 00001 00010 00100 01000 11111", "3": "11110 00001 00001 01110 00001 00001 11110",
    "4": "00010 00110 01010 10010 11111 00010 00010", "5": "11111 10000 10000 11110 00001 00001 11110",
    "6": "01110 10000 10000 11110 10001 10001 01110", "7": "11111 00001 00010 00100 01000 01000 01000",
    "8": "01110 10001 10001 01110 10001 10001 01110", "9": "01110 10001 10001 01111 00001 00001 01110",
}


def slide(path, stage):
    width, height = 1280, 720
    pixels = bytearray(bytes((22, 28, 40) if stage < 3 else (235, 230, 216)) * width * height)

    def rect(x, y, w, h, rgb):
        row = bytes(rgb) * w
        for yy in range(y, y + h):
            offset = (yy * width + x) * 3
            pixels[offset:offset + len(row)] = row

    def text(value, x, y, size=8, color=(230, 235, 240)):
        for char in value:
            for yy, row in enumerate(FONT.get(char, "").split()):
                for xx, bit in enumerate(row):
                    if bit == "1":
                        rect(x + xx * size, y + yy * size, size, size, color)
            x += 6 * size

    text("VIDEO EVIDENCE", 70, 60, color=(225, 225, 230) if stage < 3 else (30, 40, 50))
    if stage < 3:
        text("READ THE SCRIPT", 70, 180, size=6)
        if stage >= 1:
            rect(70, 280, 550, 70, (68, 145, 209))
            text("INSPECT THE FRAME", 85, 297, size=5)
        if stage >= 2:
            rect(70, 385, 750, 80, (91, 166, 124))
            text("VERIFY THE TIMING", 85, 407, size=5)
    else:
        text("COMPARISON", 70, 185, size=7, color=(30, 40, 50))
        rect(100, 360, 250, 160, (206, 105, 89))
        rect(440, 280 if stage >= 4 else 410, 250, 240 if stage >= 4 else 110, (72, 132, 184))
        if stage >= 5:
            text("SAVE THE FINDINGS", 70, 600, size=6, color=(30, 40, 50))
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + pixels)


def srt_time(value):
    milliseconds = round(value * 1000)
    seconds, ms = divmod(milliseconds, 1000)
    minutes, sec = divmod(seconds, 60)
    hours, minute = divmod(minutes, 60)
    return f"{hours:02}:{minute:02}:{sec:02},{ms:03}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--include", default="slides,motion,scale,vfr,offset,rotation")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        parser.error("FFmpeg and FFprobe are required")
    records, fixtures = [], []
    includes = set(args.include.split(","))
    base = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-threads", "2", "-filter_threads", "2", "-filter_complex_threads", "2"]
    encode = ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "28", "-threads", "2",
              "-pix_fmt", "yuv420p", "-g", "300", "-keyint_min", "300", "-sc_threshold", "0"]

    def add(name, path, command, purpose, assertions=None, transcriber="none"):
        if command:
            run(command + [str(path)], records)
        probe = json.loads(run([ffprobe, "-v", "error", "-threads", "2", "-select_streams", "v:0",
                               "-show_streams", "-show_frames", "-show_entries",
                               "stream=codec_name,width,height,avg_frame_rate,r_frame_rate,time_base,duration,start_time,nb_frames:stream_side_data:frame=best_effort_timestamp_time,key_frame",
                               "-of", "json", str(path)], records))
        frames = [float(frame["best_effort_timestamp_time"]) for frame in probe["frames"]]
        for assertion in assertions or []:
            if "frame_count" in assertion and len(frames) != assertion["frame_count"]:
                raise RuntimeError("Fixture frame count does not match authored ground truth")
            if "first_pts" in assertion and abs(frames[0] - assertion["first_pts"]) > 0.002:
                raise RuntimeError("Fixture first PTS does not match authored ground truth")
            if assertion.get("distinct_frame_intervals") and len({round(right - left, 2) for left, right in zip(frames, frames[1:])}) < 2:
                raise RuntimeError("Fixture did not preserve variable frame intervals")
            if "display_rotation_degrees" in assertion:
                rotations = [item.get("rotation") for item in probe["streams"][0].get("side_data_list", []) if "rotation" in item]
                if not rotations or abs((rotations[0] - assertion["display_rotation_degrees"]) % 360) > 0.002:
                    raise RuntimeError("Fixture did not preserve requested display rotation")
        reference = output / (name + ".reference.json")
        reference.write_text(json.dumps(probe, indent=2) + "\n")
        fixtures.append({"name": name, "path": str(path), "sha256": sha256(path),
                         "size_bytes": path.stat().st_size, "purpose": purpose,
                         "transcriber": transcriber, "reference": str(reference),
                         "frame_count": len(frames), "first_pts": frames[0], "last_pts": frames[-1],
                         "late_timestamp": frames[max(0, len(frames) - 31)],
                         "dense_start": frames[len(frames) * 3 // 4],
                         "dense_end": frames[min(len(frames) - 1, len(frames) * 3 // 4 + 12)],
                         "range_start": frames[len(frames) // 3],
                         "range_end": frames[min(len(frames) - 1, len(frames) // 3 + 90)],
                         "assertions": assertions or []})
        (output / "fixtures.json").write_text(json.dumps({"schema": "watchthrough.bench.fixtures.v1",
            "platform": platform.platform(), "commands": records, "fixtures": fixtures}, indent=2) + "\n")
        print(json.dumps({"fixture": name, "frames": len(frames), "bytes": path.stat().st_size}), flush=True)

    if "slides" in includes:
        changes = [0, 3, 6, 12, 15, 21]
        concat = output / "slides.ffconcat"
        lines = ["ffconcat version 1.0"]
        for index, start in enumerate(changes):
            image = output / f"slide-{index}.ppm"
            slide(image, index)
            lines.extend([f"file '{image.name}'", f"duration {(changes + [24])[index + 1] - start}"])
        lines.append("file 'slide-5.ppm'")
        concat.write_text("\n".join(lines) + "\n")
        cues = [(0, "Read the script to understand the speaker's claims."),
                (6, "Inspect the frame and verify the timing of each reveal."),
                (12, "Compare the red and blue bars as the chart changes."),
                (18, "Keep the findings and record what remains uncertain.")]
        audios, segments = [], []
        speech = shutil.which("say")
        if speech:
            for index, (start, phrase) in enumerate(cues):
                audio = output / f"speech-{index}.aiff"
                run([speech, "-r", "165", "-o", str(audio), phrase], records)
                audio_probe = json.loads(run([ffprobe, "-v", "error", "-show_entries", "format=duration",
                                              "-of", "json", str(audio)], records))
                duration = float(audio_probe.get("format", {}).get("duration", "0"))
                if duration <= 0:
                    records.append({"warning": "Local say produced no samples; fixture uses authored sidecar and no speech audio. This is not speech-recognition proof."})
                    audios, segments = [], []
                    break
                if duration > 6:
                    raise RuntimeError("Synthetic speech cue exceeds its six-second slot")
                audios.append(audio)
                segments.append((start, start + duration, phrase))
        if not segments:
            segments = [(start, start + 5, phrase) for start, phrase in cues]
        sidecar = output / "slides-24s-720p.srt"
        sidecar.write_text("\n\n".join(f"{index + 1}\n{srt_time(start)} --> {srt_time(end)}\n{text}"
                                      for index, (start, end, text) in enumerate(segments)) + "\n")
        command = base + ["-f", "concat", "-safe", "0", "-i", str(concat)]
        if audios:
            for audio in audios:
                command += ["-i", str(audio)]
            filters = [f"[{index + 1}:a]adelay={index * 6000}:all=1[a{index}]" for index in range(4)]
            filters.append("".join(f"[a{index}]" for index in range(4)) + "amix=inputs=4:normalize=0,apad[a]")
            command += ["-filter_complex", ";".join(filters), "-map", "0:v", "-map", "[a]", "-c:a", "aac"]
        command += ["-r", "30", "-t", "24"] + encode
        add("slides", output / "slides-24s-720p.mp4", command,
            "Readable slides, progressive reveals, chart change, and local synthesized speech with exact cue boundaries; not an ASR accuracy benchmark.",
            [{"visual_changes_seconds": changes[1:]}, {"speech_available": bool(audios)}], "sidecar")

    motion = output / "motion-18s-1080p60.mp4"
    if includes & {"motion", "rotation"}:
        command = base + ["-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=60:d=18"] + encode
        add("motion", motion, command,
            "Sixty decoded frames per second with continuously moving shapes and a long GOP; tests dense frame adjacency and late seeking.")
    if "scale" in includes:
        add("scale", output / "scale-120s-720p30.mp4",
            base + ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=120"] + encode,
            "Two-minute continuous visual motion to expose duration-dependent full-decode preparation cost.")
    if "vfr" in includes:
        add("vfr", output / "vfr-12s-720p.mkv",
            base + ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24:d=6", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=60:d=6",
                    "-filter_complex", "[0:v]settb=AVTB[v0];[1:v]settb=AVTB[v1];[v0][v1]concat=n=2:v=1:a=0[v]",
                    "-map", "[v]", "-fps_mode", "vfr"] + encode,
            "Two frame rates in one timeline; average-FPS arithmetic must not replace decoded timestamps.",
            [{"frame_count": 504}, {"distinct_frame_intervals": True}])
    if "offset" in includes:
        add("offset", output / "offset-12s-720p.mkv",
            base + ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=12", "-vf", "setpts=PTS+5/TB", "-fps_mode", "passthrough"] + encode,
            "Decoded timestamps begin at five seconds, testing input seeking and absolute timeline labels.",
            [{"first_pts": 5.0}])
    if "rotation" in includes:
        add("rotation", output / "rotation-18s-1080p60.mp4",
            base + ["-display_rotation:v:0", "90", "-i", str(motion), "-c", "copy"],
            "Ninety-degree display matrix on the same high-rate footage; display geometry must respect rotation.",
            [{"display_rotation_degrees": 90}])


if __name__ == "__main__":
    main()
