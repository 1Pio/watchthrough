# watchthrough

Let your agent read, see, and understand video.

Watchthrough pairs a local CLI with an agent skill. It turns local videos and
YouTube links into a transcript, timestamped frames, and contact sheets the agent
can inspect, then keeps the useful evidence with its source note.

After [installing](#install), the workflow is small:

1. **Read the video.** `watchthrough prepare video.mp4` returns an analysis directory and a transcript when a speech engine or sidecar is available.
2. **Get your bearings.** `watchthrough inspect video.mp4.watchthrough overview` makes a 12-frame overview.
3. **Follow the motion.** `watchthrough inspect video.mp4.watchthrough 03:18..03:19 --every 1f` reveals every decoded frame in that second.
4. **Look closer.** `watchthrough inspect video.mp4.watchthrough 03:20 --width 1920` returns a detail frame up to 1920 pixels on its long edge.

Add `--json` to any command for structured results. Follow the returned artifact
paths; the agent reads the transcript and opens the images before answering.

![A section of a video as an agent sees it: timestamped frames with nearby speech](assets/agent-view.png)

*Six frames from 03:18-03:22 of [WeatherNext 3](https://www.youtube.com/watch?v=_6jZlnRsXXQ&t=198s),
Google DeepMind. Unaltered Watchthrough output, with separate frame and speech times.*

`watchthrough inspect ANALYSIS 03:18..03:22 --every 800ms --cells 6 --width 1280 --sheet-format png`
reproduces this view.

## A quick look, then a closer one

| What the agent asks for | Measured time |
|---|---:|
| Every frame in one second | **0.25 s** for 26 frames |
| A previously opened inspection | **27 ms** |
| A whole-video overview | **2 s** for 12 frames |
| Acquire the YouTube video | **11 s**, including downloader setup |
| Transcribe it locally | **15 s** |

These examples use a 4:35 video. Watchthrough seeks to the requested region and
reuses decoded frames when only the layout changes. Whole-video change scans and
global frame indexing run when requested. [v0.3.0](docs/v0.3.0.md) has the measured
workflow; [v0.2.0](docs/v0.2.0.md) compares the earlier implementation.

## Install

You need **Apple Silicon, macOS 14+, and FFmpeg/FFprobe** on your `PATH`.
Clone this repository, enter its directory, and run `./install.sh`.

The installer verifies the packaged executable, links `watchthrough` into
`~/.local/bin`, and installs the [agent skill](skill/SKILL.md) in
`~/.agents/skills/watchthrough`. Keep the checkout in place: both are links to it.
Add `~/.local/bin` to your `PATH` if needed. No service or background process runs.

Local speech uses an existing **MacParakeet** installation by default. You can
also use transcript sidecars or a named command adapter. For an immediate visual
question, `watchthrough prepare video.mp4 --defer-transcript` gets started without
waiting for speech; `watchthrough inspect ANALYSIS transcript` adds it later.
ElevenLabs Scribe is an explicit cloud option, never an automatic fallback.

Run `watchthrough status` when checking dependencies or diagnosing setup.

## Start from YouTube

```sh
watchthrough --json acquire "YOUTUBE_URL" --out ./source
watchthrough --json prepare ./source/download/source.mkv
```

Acquisition keeps native frame rate and caps resolution at 1080p; `--height 720`
or `--height 2160` changes the cap. It selects current formats and merges without
transcoding. Repeat the same command to resume; completed sources reuse locally.

YouTube needs **Deno 2.3+ or Node 22+**, plus current yt-dlp with its matching EJS
component. If yt-dlp is missing or outdated, add `--update-downloader` to explicitly
install a verified copy managed by Watchthrough. With existing Python 3.10+ this
is about **3 MB**; otherwise it selects the standalone macOS package. Ordinary
acquisition does not install code or use browser cookies.

[YouTube reference](skill/references/youtube.md): dependency overrides, source
context, and carefully chosen caption fallbacks.

## Keep what you learned

Write a source note, then retain it with the selected evidence:

```sh
watchthrough retain ANALYSIS --note source-note.md --include PACKET_PATH
watchthrough cleanup ANALYSIS
watchthrough cleanup ANALYSIS --apply
```

`PACKET_PATH` can be the absolute path returned by `inspect`. Selecting a packet
also keeps its frames and sheets. The library preserves the note, full available
transcript, source provenance, and selected evidence with checksums. Cleanup
previews first, then moves the verified analysis cache to system Trash; the source
video and library remain available.

The default library lives at `~/Library/Application Support/watchthrough/library`;
`--library DIRECTORY` selects another location. Use `watchthrough status ANALYSIS --verify` to check the source and every completed inspection packet.

[Retention guide](skill/references/retention.md): source-note template, evidence
links, and the complete cleanup loop. [Recovery guide](skill/references/recovery.md):
interrupted or stale work. [Motion guide](skill/references/motion.md): dense probes,
event routing, and the limits of sparse samples.

## Develop

`swift test -j 2` runs the tests. `swift build -c release -j 2` builds the CLI.
The core uses Foundation, CoreGraphics, CoreText, and installed FFmpeg tools;
there are no third-party Swift packages.

- `Sources/WatchthroughCore/`: orchestration plus media, transcription, storage, and YouTube modules.
- `Tests/`: fixtures and behavioral checks.
- `skill/`: the installable agent workflow and references.
- `scripts/`: synthetic fixtures, benchmarks, and extraction experiments.
- `docs/`: one short evidence note per release.
- `dist/macos-arm64/`: the packaged executable and checksum used by the installer.

For a reproducible benchmark, generate fixtures with `python3 scripts/fixtures.py --output .scratch/fixtures`, then run `python3 scripts/benchmark.py --help`.
Keep source media, transcripts, raw results, and credentials outside version control.

When packaging a release, copy the executable into `dist/macos-arm64/`, remove
debug paths with `strip -S`, re-sign with `codesign --force --sign -`, and regenerate
its SHA256 file. Verify the signature and checksum before committing.

MIT licensed. Downloaded [yt-dlp packages](https://github.com/yt-dlp/yt-dlp#licensing)
have their own licenses and bundled dependencies.
