# watchthrough

A local command and agent skill for understanding video through transcript and
visual evidence. Prepare a source, read its transcript, inspect the parts that
matter, and keep a useful source note after disposable artifacts move to Trash.

Version 0.3 adds native YouTube acquisition, clearly timed sheet captions, complete
inspection verification, and efficient reuse across a growing study. Expensive
media work remains demand-driven. Preparation returns metadata
and the requested local transcript. Overview sheets, change scans, and global
frame indexing run only when requested. Short dense ranges share one bounded
decode; selected frames record their observed presentation timestamps. A valid
source with no duration metadata uses a decoded fallback and reports that extra
work; it does not persist an unrequested global index.

The CLI handles extraction, caching, and evidence receipts. The agent decides what
to inspect, interprets the source, and answers the user's actual question.

## Install

Requires Apple Silicon, macOS 14 or newer, and FFmpeg/FFprobe on PATH. Install those
tools, clone this repository, then run:

~~~bash
./install.sh
~~~

The installer verifies the committed binary and its signature, links the command
into `~/.local/bin` and the skill into `~/.agents/skills/watchthrough`, then checks
readiness. It does not use sudo, edit shell configuration, or download dependencies.
An existing link to another checkout is reported rather than silently replaced.

The local analysis command has no daemon, database, Python environment, bundled
speech model, or automatic upload. Online acquisition additionally uses yt-dlp
and an existing supported Deno or Node runtime. Its optional managed downloader
uses the small official zipimport package with existing CPython >=3.10, or the
official macOS standalone package when compatible Python is absent. Both include
matching EJS. No pip install or new Python environment is needed; the installer
does not fetch either package.

## Acquire a YouTube source

~~~bash
watchthrough --json acquire "https://www.youtube.com/watch?v=VIDEO_ID" \
  --out "/path/source-bundle"
~~~

Follow the returned `artifacts.source` path into `prepare`. The acquisition command
selects current formats, preserves frame rate and original/default audio preference,
caps height at 1080 by default, and merges without transcoding. `--height` changes
the cap. It prefers direct delivery within the same resolution/frame-rate tier.
It does not assume that AVC or the smallest audio stream is always appropriate.

If the downloader is missing or predates the tested client fixes, repeat the
command with `--update-downloader`. This explicitly fetches the current official
release package, checks its published SHA256 and version, and activates a separate
managed copy while keeping the previous one. The system's installed yt-dlp remains
untouched. Normal acquisition does not install or update executable code.

Repeat the same URL, options, and output path after an interruption to resume.
Completed bundles are verified and reused without contacting YouTube or starting
the downloader. An explicit update flag still performs the requested tool update.
The returned context and description files contain useful creator provenance;
signed stream URLs, request inventories, cookies, and downloaded captions are not
part of the normal bundle. See [references/youtube.md](references/youtube.md) for
source research, dependency overrides, and the caption fallback policy.

## Ask for evidence as needed

~~~bash
watchthrough --json prepare "/path/video.mp4"
watchthrough --json inspect "/path/video.mp4.watchthrough" overview
watchthrough --json inspect "/path/video.mp4.watchthrough" 06:49..06:51 --every 100ms
watchthrough --json inspect "/path/video.mp4.watchthrough" 06:50.250 --width 3840
watchthrough --json inspect "/path/video.mp4.watchthrough" 00:10..00:11 --every 1f
~~~

Follow the returned artifact paths. The skill normally has the main agent read the
entire clean transcript once. For unusually long transcripts or many sources, one
delegate per source reads the full transcript and returns a compact source note.
Independent visual questions can proceed meanwhile; whole-video synthesis joins
the transcript, inspected visuals, and source context.

For immediate visual work, use `prepare VIDEO --defer-transcript`, followed later
by `inspect ANALYSIS transcript`. Use `inspect ANALYSIS events` for an optional
full-video change scan. `inspect ANALYSIS frame:18720` explicitly builds the full
decoded index to establish a global frame ordinal. Timestamp and regional `1f`
probes normally avoid that cost and label their ordinal basis honestly.

Overview defaults to 12 images at a 720-pixel long edge. Targeted probes default to
1920 pixels; `--width` changes the long edge. Contact sheets default to JPEG;
`--sheet-format png` selects lossless sheet encoding. Selected frame files remain
separately accessible. Images preserve rotation and display aspect ratio.

Sheet captions show nearby speech with its actual timing bounds. Segment-only
transcripts retain whole-cue bounds; silence and unavailable timing are explicit.
An ellipsis marks a shortened sheet excerpt. Complete interval text remains in the
packet Markdown and JSON. Cell sequence labels identify sheet order, not invented
global frame ordinals.

Media work runs serially with a default two-thread budget per codec/filter pool.
Low-power mode or serious thermal pressure reduces that budget to one.
`WATCHTHROUGH_THREADS=1..8` overrides the normal budget. This bounds concurrency;
it is not a guarantee about temperature or system responsiveness.

## Transcript and source context

`--transcriber auto` stays local: a source-adjacent SRT/VTT/canonical JSON sidecar,
then compatible MacParakeet, then a configured local command adapter, otherwise an
explicit visual-only result. Speaker detection is optional via `--speakers`.
Clean text preserves useful timestamps and speaker labels; canonical JSON keeps
the normalized provider record, language, model, and timing precision.

ElevenLabs Scribe requires explicit `--transcriber scribe` and authorization for
upload and cost. Its key can come from the environment, macOS Keychain, or
`~/.config/watchthrough/.env`; it is not put in subprocess arguments or artifacts.

Online acquisition and bounded description/comment research are documented in
[references/youtube.md](references/youtube.md). Local ASR is the normal route.
Downloaded captions stay language-qualified and are a vetted last fallback, not
automatically promoted to authoritative transcription.

## Recover and reuse

`status ANALYSIS` reads readiness without probing unrelated providers or hashing
the whole source. `status ANALYSIS --verify` performs content verification, including
every completed inspection packet, and reports the verified packet count. Changed
source metadata invalidates ordinary reuse; changed transcript or rendering inputs
invalidate affected packets. Packet inventories detect corrupt evidence.

Successful stages survive later failures. A yielded command still has one owner:
poll its existing session instead of starting another preparation. See
[references/recovery.md](references/recovery.md) for stale and interrupted work.

## Retain useful knowledge, then clean up

Write an authored Markdown source note outside the analysis directory, including
the full-script summary, relevant inspected visuals, referenced source information,
and coverage gaps. Then use actual returned evidence paths:

~~~bash
watchthrough --json retain ANALYSIS --note /path/source-note.md \
  --include /path/ANALYSIS/inspections/PACKET/packet.json --dossier /path/source.description
watchthrough --json cleanup ANALYSIS
watchthrough --json cleanup ANALYSIS --apply
~~~

The dedicated library defaults to
`~/Library/Application Support/watchthrough/library`; `--library DIRECTORY`
overrides it. Each immutable snapshot holds `summary.md`, the complete available
canonical transcript, source provenance, selected evidence, explicit dossiers, and
a checksummed receipt. Selecting a packet also retains its frame and sheet
dependencies. Summary links must resolve in the snapshot. The skill searches these
source notes before reprocessing a previously studied video and reuses retained
evidence when its coverage is sufficient.

`--include` accepts returned absolute artifact paths or paths relative to the same
analysis. It rejects outside files, traversal, and linked artifacts. Use
`--dossier` for explicitly selected source context outside the analysis.

Cleanup previews first, then moves only the owned analysis directory to native
system Trash after verifying a matching snapshot. It preserves the source video
and library. Active writers, changed evidence, unsafe paths, corrupt archives, and
unknown user files prevent cleanup. See the note template and exact workflow in
[references/retention.md](references/retention.md).

## Development and evidence

~~~bash
swift test -j 2
swift build -c release -j 2
python3 scripts/fixtures.py --output .scratch/fixtures
python3 scripts/benchmark.py --binary .build/release/watchthrough \
  --label candidate --fixtures .scratch/fixtures/fixtures.json \
  --output .scratch/bench --repeats 2 --warm-inspections
~~~

For a reviewed release, copy the release executable to `dist/macos-arm64/`, remove
debug-only build paths with `strip -S`, re-sign with `codesign --force --sign -`,
and regenerate `watchthrough.sha256` from that directory. Verify the signature and
checksum after packaging. Keep benchmark binary hashes and any packaging changes
in the release evidence.

The implementation uses installed FFmpeg/FFprobe and native CoreGraphics,
ImageIO, and CoreText. No third-party Swift package is used. Local ASR adapters
reuse existing speech runtimes. Optical flow and 3D reconstruction remain explicit
specialist follow-up work on bounded evidence, documented in
[references/motion.md](references/motion.md).

Read [docs/redesign.md](docs/redesign.md) for the baseline findings and acceptance
contract, and [docs/review.md](docs/review.md) for measured results, iterations,
reuse decisions, and limitations. The [0.3 acquisition and evidence report](docs/acquisition-and-context.md)
records the chosen improvements and live short-video acceptance; its
[measurements](docs/acquisition-verification.json) identify the exact packaged binary.
Synthetic fixtures and deterministic tests cover
the tested domain; sparse samples never establish exhaustive visual coverage.

Downloaded media, transcripts, provider responses, comments, and personal paths
must not enter this public repository. MIT licensed; see [LICENSE](LICENSE).
Downloaded yt-dlp packages have their own [upstream licenses](https://github.com/yt-dlp/yt-dlp#licensing),
including bundled third-party components.
