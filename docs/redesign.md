# Responsive video evidence: design and acceptance contract

This change starts from `ff459ab` (watchthrough 0.1.0). Its purpose is to shorten
the path from an agent's question to trustworthy video evidence on an Apple
Silicon Mac, while preserving reusable local knowledge after disposable analysis
artifacts are moved to Trash. The CLI extracts and records evidence. The calling
agent owns interpretation, source research, and the user's actual task.

## What the original design got right

The project is a private daily-use tool with a small native boundary, rather than
a video platform. It combines local media, honest normalized transcripts, sparse
visual orientation, change candidates, exact frame/range inspection, and agent
delegation. Its important constraints are local-first inference, explicit cloud
authority, complete transcript ownership, timestamp-grounded source notes,
bounded visual packets, and separation of claims from observations.

The existing Swift/CoreGraphics/ImageIO implementation, FFmpeg/FFprobe process
boundary, content identity, atomic publication, file locking, sidecar parsing,
and raw-provider retention are useful foundations. They do not need a daemon,
database, Python environment, or bundled model to become more useful.

## Findings at the baseline

| Finding | Baseline location | Observable consequence |
|---|---|---|
| Preparation always decodes the full frame index. | `Media.swift:99,153-181` | A timestamp or transcript question pays for every decoded frame. |
| A second full decode produces low-resolution event samples. | `Visual.swift:64-71` | Output sampling limits Swift scoring, but does not skip compressed input decoding. |
| Overview extraction decodes continuously between its first and last target. | `Visual.swift:562-599` | Sparse coverage adds another almost full-length decode. |
| FFmpeg decoding/filtering has no explicit thread budget. | `Visual.swift:64-71,580-599` | Short jobs can occupy many cores simultaneously. |
| Local transcription is probed repeatedly and speaker analysis turns on when cached. | `Application.swift:302,504,541`; `Transcript.swift:534-565,605,628` | Diagnostic startup and optional diarization precede useful output. |
| Analysis status checks all providers and resolves the optional cloud secret. | `Application.swift:1028-1120` | Reading a cached folder depends on unrelated tools and private application state. |
| Inspection trusts a post-seek ordinal offset without checking the emitted frame's PTS. | `Visual.swift:562-621` | Reported frame identity can disagree with decoded output; the new VFR fixture reproduces a failure. |
| Sheet height follows the tallest source aspect ratio without a bound. | `Render.swift:132-149` | Extreme portrait media can allocate an unnecessarily large canvas. |
| There is no supported retained-knowledge or cleanup lifecycle. | original CLI and skill | Disposable evidence and valuable learning remain coupled. |

The pre-change integration tests predominantly use intra-coded FFV1 color
fixtures. They prove many path, timing, and process properties but do not prove
pixel identity after long-GOP seeking. The new acceptance matrix must exercise
that distinction.

## New behavior

### Pay for evidence when it is requested

- `prepare` records source identity and container metadata, resolves the requested
  local transcript, and returns its clean text path. It does not generate a frame
  index, event scan, or contact sheets. If a valid container omits duration, a
  decoded fallback recovers it and reports the extra work; no global index is
  persisted unless requested.
- `--defer-transcript` makes visual-first work explicit. `inspect transcript`
  materializes the chosen local transcript later. `--speakers` explicitly requests
  optional speaker analysis.
- `inspect overview` creates a small first-to-tail orientation packet. It reports
  actual observed timestamps and gaps. It cannot prove that a brief insert never
  appeared between samples.
- Timestamp and range inspections seek into the requested region. They preserve
  observed decoded PTS and distinguish regional frame steps from global ordinal
  identity.
- `frame:N` requests the full decoded index when that global identity is needed.
- `inspect events` explicitly requests the full-video change scan. These candidates
  route attention; they do not recognize semantic importance, optical flow, or 3D.
- A successful stage remains reusable independently of later stages. Ordinary
  status and warm reuse use source metadata; explicit verification recomputes the
  content hash. Changed transcription or rendering inputs cannot reuse stale
  captioned packets.

### Keep resource use bounded

Default media work uses a small thread budget and serial extraction. Dense nearby
frames share a bounded decode; sparse far-apart targets should not decode all
intervening content. Raw video decoding participates in the same cancellation
and timeout mechanism as other subprocesses. Portrait and photographic sheets
use bounded geometry; the native encoder's JPEG/PNG choice is measured separately.

Thread limits constrain CPU concurrency, not temperature. Hardware acceleration
is a measured candidate, not an assumed improvement. Tests must record unsupported
hardware paths and equivalent-output costs rather than hiding software fallback.

### Retain knowledge before cleanup

`retain` stores an agent-authored Markdown summary, the full canonical transcript
when available, source provenance, selected inspected evidence, and explicitly
provided description/comment/source dossiers in a dedicated durable library. Each
snapshot is immutable and has a checksummed inventory. The note distinguishes the
spoken/script summary from inspected visual observations and uninspected gaps.

`cleanup` first produces a dry-run result. Applying it requires a verified durable
snapshot that matches the current source and analysis. It uses the operating
system Trash and preserves source media and durable knowledge. Unknown user files,
unsafe paths, incomplete archives, and active analysis writers prevent cleanup.

## Agent workflow

The main agent normally reads the complete clean transcript once. A transcript
that is too large for the available context has one complete transcript owner;
the main agent assimilates that owner's compact source note. Search is navigation,
not proof of full transcript coverage. Independent visual questions can proceed
while transcript ownership is being completed; whole-video conclusions require
the combined source note.

Talking heads favor transcript-led probes. Slide decks favor stable states and
progressive reveals. Screencasts need clear text plus intermediate state changes.
Fast animation needs short native-frame sequences. Moving-camera footage needs
adjacent frames across enough time to distinguish parallax, blur, cuts, and
object/camera motion. Monocular frames alone do not establish metric 3D geometry.

Delegates receive one bounded question, source identity, local transcript context,
and selected packet paths. They return observations, timestamps, supporting
artifacts, and uncertainty. They do not receive every transcript or start another
preparation of the same video.

## Reuse decisions

| Existing capability | Decision |
|---|---|
| FFmpeg / FFprobe | Keep installed tools; use bounded seeking and observed PTS instead of rebuilding media infrastructure. |
| CoreGraphics / ImageIO / CoreText | Keep native image layout and encoding; bound canvases and compare sheet encoders. |
| MacParakeet | Keep the installed local adapter; reuse capabilities, request model status instead of broad health, make diarization explicit. |
| AVAssetImageGenerator / VideoToolbox | Evaluate format coverage, actual time, CPU, and output transfer cost before selecting a native/hardware path. |
| FFmpeg `scdet` / PySceneDetect | Reuse established scene-change concepts; retain explicit semantic/recall limits and compare before replacing a working detector. |
| PyAV | Do not impose a Python/C-extension runtime on the normal path merely to access the same decoding primitives. |
| whisper.cpp / WhisperKit | Useful explicit local adapters for language/model needs; embedding them requires separate model lifecycle and cold/warm measurements. |
| OpenCV flow / COLMAP | Specialist follow-up on bounded exported frames when the user's question calls for it, not preparation dependencies. |

Primary references and evaluated tradeoffs are recorded in the final review.

## Acceptance

1. Preserve a frozen baseline executable, source commit, fixture hashes, tool
   versions, raw outputs, and repeatable benchmark commands.
2. Compare cold analysis creation and warm reuse separately. "Cold" means a new
   analysis directory, not a flushed OS cache or unloaded speech model.
3. Record wall time, CPU seconds, peak-RSS semantics, output size, and actual
   subprocess commands. Do not equate CPU seconds with measured energy or heat.
4. Exercise long-GOP H.264, high frame rate, VFR, nonzero timestamps, rotation,
   silence, progressive reveals, exact global ordinals, and dense local strides.
5. Compare selected images against an independent decode, including the failing
   baseline VFR path; a nonempty JPEG and self-reported ordinal are insufficient.
6. Test source changes, cache identity, concurrent ownership, interruptions,
   partial/corrupt artifacts, and safe retention/cleanup behavior.
7. Run at least one real local speech example separately from synthetic sidecar
   benchmarks. State what the transcription test proves and what is unmeasured.
8. Open actual generated sheets and frames, use them to answer bounded video
   questions, retain a useful durable note, and demonstrate it survives cleanup.
9. Review the integrated implementation independently and resolve material
   findings before presenting the final version.

No finite fixture matrix proves support for every possible video. Report the
tested domain, regressions, failed theories, residual costs, and remaining gaps.
