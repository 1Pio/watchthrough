# Review and evidence for watchthrough 0.2

This review compares the original `ff459ab` release (0.1.0) with the
`responsive-evidence` implementation. The original checkout and installed command
were preserved. Changes were developed in a separate worktree on the owner's
repository. This is a local evidence tool: its success is a useful, trustworthy
answer with reusable source knowledge, not the number of media artifacts produced.

## Assessment of the original intention and implementation

The original design already had the right boundary: one Swift executable, installed
FFmpeg/FFprobe, local-first speech adapters, canonical transcripts, selected frames,
captioned sheets, source research, and agent interpretation. Commit `6927ccd`
explicitly added full-transcript ownership and strict caption fallback. The skill
was intended to fit inside broader agent tasks and support delegation without
losing the source's full argument.

The principal performance defect was eager work. Preparation decoded a full frame
index, decoded a second pass for visual-change samples, and decoded the broad
interval between overview targets. A transcript-only question paid for those
passes. Shrinking output thumbnails alone could not fix that input-decoding cost.
The traced 120-second fixture confirms three full-media passes; the raw process
recipes are retained with the benchmark evidence.

Other findings were repeated local-ASR capability checks, optional speaker analysis
running merely because its models were cached, provider/secret work in cached
analysis status, missing true post-seek frame verification, unbounded portrait
sheet geometry, and no supported durable-note/cleanup lifecycle. The previous
intra-coded test fixtures did not exercise long-GOP seeking adequately.

The implementation therefore keeps the useful native foundations and changes when
work happens, how selected frames prove their identity, and how useful knowledge
survives cleanup. [The design contract](redesign.md) records the baseline locations
and intended acceptance conditions.

## Resulting agent workflow

`prepare` now produces source identity, metadata, and the requested local transcript.
Visual-first work can defer speech. Valid sources lacking duration metadata use
a decoded fallback, with a warning explaining the exceptional preparation cost.
That fallback preserves compatibility without persisting an unrequested global
index. A complete transcript has an explicit owner;
independent visual inspection may proceed meanwhile. Whole-video synthesis must
combine that owner's note with inspected visual evidence and relevant context.

Overview, event scanning, and global decoded indexing are separate requested
stages. A time range normally requires only local decoding. Dense nearby targets
share that decode; sparse distant targets seek independently. Packets distinguish
observed integer PTS/time base, regional decoded steps, and established global
ordinals. They do not invent frame numbers from average FPS.

The default overview is 12 samples at a 720-pixel long edge; detail probes default
to 1920 and can request more. Sheets have bounded geometry, preserve display aspect
ratio, and offer JPEG or PNG. Decoder/filter/encoder pools default to two threads
and reduce to one under Low Power Mode or serious thermal pressure. Work remains
serial by default. These controls limit concurrency, not the OS's total activity.

A useful authored note includes the full spoken/script summary, relevant inspected
visuals, source references, and actual coverage gaps. `retain` archives it with the
complete available canonical transcript and selected evidence in an immutable,
checksummed snapshot. Including a packet expands its frame/sheet dependencies.
`cleanup` previews first and uses native Trash only after verifying a matching
archive and rejecting unsafe paths, unknown files, corruption, or active writers.

## Measurement method

Measurements were serial on this Mac: Apple M5 Pro, 15 CPU cores, 24 GB memory,
macOS 26.6; FFmpeg/FFprobe 8.1.1 and MacParakeet 2.3.1. The baseline executable and
candidate are frozen and SHA256-recorded. Fixtures have source hashes, generation
commands, independent decoded reference timestamps, and machine-readable results.

"Cold" means a new analysis directory. It does not mean flushed disk caches or an
unloaded speech model. Wall time and `wait4` CPU seconds exclude correctness-probe
work. CPU accounting includes waited-for descendants. Peak RSS is the kernel's
process high-water measurement, not simultaneous summed process-tree memory.
There was no physical temperature, energy, battery, or UI-latency instrumentation.
CPU reductions are not measurements of heat or energy.

The synthetic matrix covers slide-like reveals, high-rate motion, 120-second scale,
variable frame rate, nonzero timestamps, and verified rotation. Speech inference is
measured separately from authored sidecars and silent fixtures. Two full CLI
repetitions expose cold/warm behavior; three repetitions per extraction theory and
five per renderer format expose practical tradeoffs. These sample sizes establish
repeatable observations on the tested domain, not universal performance bounds.

## Iterations and rejected theories

| Theory | Observed result | Decision |
|---|---|---|
| One bounded decode for 13 nearby frames | 0.162 s versus 1.987 s for 13 seeks; about 12.3x faster, with byte-identical JPEG output. | Adopt grouped dense extraction. |
| Always decode the span for sparse targets | Good on the 18-second fixture; at 120 seconds serial seeks used 0.919 s / 1.327 CPU s versus 1.061 s / 2.122 CPU s for the span. | Group nearby requests, seek across large gaps. |
| More decode threads are always appropriate | One/two/four threads used 1.130/0.622/0.343 s and 42.6/58.4/90.3 MiB on one motion operation. | Two is a responsiveness/resource tradeoff; four can be faster. |
| Smaller thumbnails materially fix decode latency | 720 versus 1440 reduced JPEG bytes from 1,006,781 to 337,159 while wall time remained about 0.62 s. | Use smaller overview images for payload/context; retain explicit detail width. |
| Cheaper scale filters provide a clear speed win | Area/bilinear/Lanczos differences were about 2-3%, within this experiment's noise. | Keep Lanczos quality. |
| Hardware decode is automatically faster | VideoToolbox worked outside the sandbox and matched all 36 software JPEGs byte-for-byte. Sparse extraction used 2.366 s / 0.466 CPU s versus software 0.575 s / 1.164 CPU s. | Keep software default; hardware's lower CPU came with about 4.1x wall time. |
| Output ordinal can be inferred from the seek anchor | The baseline VFR dense inspection failed; delayed video and duplicate timestamps also require careful identity handling. | Validate decoded PTS; use a true global-decode fallback for ambiguous duplicates. |

The experiment ledger preserves failed attempts. Initial sandbox VideoToolbox
initialization failures did not establish unsupported hardware; an approved run
outside the sandbox settled that. The original rotation recipe silently produced
an unrotated duplicate; its records remain, but actual rotation claims use the
replacement fixture whose display matrix was probed. Nonzero Matroska seeking first
failed and was corrected with container-relative seeks plus absolute PTS gates.
An additional delayed-video/early-audio regression caught lost container metadata
in the exact-global-frame path and was fixed against an independent full decode.

The first complete release matrix intentionally remains in the evidence bundle:
204 operations, 200 successful, with four failed cold/warm VFR dense requests. It
exposed an MJPEG encoder time-base quantization issue when a stream advertised
24 fps but the selected region contained 60 fps. The final correction records original PTS before assigning JPEG export its own
sequential clock with `setpts=N` and `-enc_time_base:v filter`. This also handles
actual duplicate PTS without altering the evidence timestamps. The failed candidate is retained separately from the
final rerun rather than overwritten.

The same matrix found a short-slide overview regression: 12 samples in 24 seconds
were just over the original two-second grouping threshold. Nine focused runs
compared one full span, four groups of three, and twelve separate seeks. One span
used 0.113 s / 0.185 CPU s versus 0.592 s / 0.609 CPU s for separate seeks. All
returned JPEGs and timestamps matched. Short requested spans now share one decode;
long sparse spans retain the separate-seek strategy.

Hashing had another measurable allocation problem: Foundation's chunk reads left
autoreleased data alive until the surrounding invocation ended. Eighteen isolated
optimized Swift runs compared 8/64/256 MiB inputs. Original peak RSS scaled to
about 263 MiB on 256 MiB input; a per-chunk autorelease pool stayed around 7-8 MiB.
Twelve additional runs on the actual motion/scale sources reduced hashing RSS
from 47/85 MiB to about 7 MiB. Every digest matched an independent Python SHA256.
The production fix is a small loop change; memory evidence stays in isolated
process measurements, while deterministic known-answer tests protect digest and
chunk-boundary correctness.

## Correctness and review

Independent frame tests compare selected JPEG bytes against full decoding, rather
than accepting nonempty images or self-reported timestamps. They exercise long GOPs
and B frames, variable-rate native stepping, duplicate timestamps, true tail
selection, Matroska/transport-stream origins, rotation, and anamorphic geometry.
The anamorphic circle remains round, including after rotation.

Cache tests cover transcript refresh, immutable transcript runs, changed source
metadata, same-size packet image corruption, caption reflow without another media
decode, and explicit verification. Process tests cover cancellation of child
decoders and streamed frame-index output. Retention tests protect complete
transcript preservation, packet closure, dossier acceptance, path safety, locks,
corruption refusal, and library independence from disposable artifacts.

Independent review found and drove fixes for `.description` dossier rejection,
incomplete retained packet dependencies, ephemeral summary links, lost container
origin during exact-frame extraction, transcript/packet generation-receipt checks
before archiving, and structural packet validation before cached reuse. These
findings are part of the iteration evidence, not omitted failures. A final bounded
compatibility probe reproduced an additional regression: the original prepared a
valid live-muxed Matroska file with 48 frames but no container duration; the new
metadata-only path rejected it. The decoded duration fallback restores that
capability, and tests prove its warning survives transcription and refresh while
ordinary metadata preparation still avoids frame decoding.

## Final measured results

Each cell below is a median of two fresh-analysis repetitions. The requested
sequence is `prepare`, late timestamp, dense native-frame range, sampled range,
overview, and event scan. It excludes warm retries, status, and global ordinal
indexing. The sources match by SHA256, but eager/lazy scheduling and overview
sampling differ; this is the same requested task sequence, not identical total
internal computation.

| Fixture | Prepare, old → new | Prepare peak RSS, old → new | Requested sequence, old → new | Sequence CPU, old → new |
|---|---:|---:|---:|---:|
| Slides, 24 s | 0.729 → 0.131 s | 114.1 → 17.9 MiB | 1.108 → 1.019 s | 1.515 → 0.933 s |
| Motion, 18 s / 60 fps | 1.881 → 0.118 s | 189.1 → 20.5 MiB | 2.339 → 2.462 s | 5.720 → 3.866 s |
| Continuous motion, 120 s | 3.259 → 0.129 s | 149.2 → 18.0 MiB | 3.717 → 3.258 s | 8.899 → 4.467 s |
| Variable frame rate, 12 s | 0.982 → 0.082 s | 118.5 → 20.8 MiB | failed → 1.334 s | failed → 1.536 s |
| Nonzero timestamps, 12 s | 0.840 → 0.112 s | 118.0 → 19.8 MiB | 1.260 → 1.254 s | 2.138 → 1.323 s |
| Verified rotation, 18 s | 2.400 → 0.121 s | 218.1 → 20.6 MiB | 3.129 → 3.044 s | 10.697 → 7.874 s |

Preparation is about 5.5-25x faster across this matrix. Full requested sequences
use 26-50% less measured CPU, with much lower peak RSS. Their wall time improves
by about 0.4-12% on four comparable fixtures; high-rate motion is 5.3% slower.
That tradeoff remains visible rather than changing the thread budget to maximize
one elapsed-time score. Warm inspection medians are 25-26 ms.

Exact global indexing remains real work. The first `frame:N` request's fixture
medians were 0.33-1.24 s in the final candidate versus roughly 0.09-0.14 s on most already
indexed baseline analyses. The baseline paid for that index during preparation.
All 24 additional baseline ordinal/tail calls passed; one slides launch outlier
is retained and flagged in the dataset. No claim that every inspection is faster
is warranted.

The final frozen matrix passed **204/204 operations**, including **144 validated
inspection packets**. Successful packet checks compare PTS and claimed ordinals
with independently decoded references. Separate exact-byte tests establish image
identity for the hard seeking cases and the formerly failing 13-frame VFR range.

## Real local speech, sheet rendering, and cleanup

A real 30-second German audiovisual excerpt was processed locally with the actual
packaged executable. The main agent read the entire returned clean transcript.
All six runs returned the same 340 bytes of clean text and the same 40 word
contents/times when speaker labels were excluded from comparison. The provider
reported `macparakeet` / `parakeet`; no language or more specific model variant was
invented.

| Run | Wall time | Speaker analysis |
|---|---:|---|
| Original, first in final run | 4.590 s | On by the original default |
| New, following | 1.193 s | Off by the new default |
| New, repeat | 0.759 s | Off |
| Original, warm repeat | 3.524 s | On |
| New, matching attribution work | 1.081 s | On explicitly |
| New, matching attribution repeat | 1.084 s | On explicitly |

This proves successful real local transcription and improved time to its usable
result for this clip. It does not measure isolated speech-engine speed or WER.
The speech runtime had already been used before this final run; speech-model
caches were not cleared. The earlier six-run iteration is also retained, including
its initial 9.851-second original run with runtime/model warm-up. The original
performs eager visual work in both iterations, and child CPU
accounting does not include unrelated system services. Raw provider responses
and transcript contents remain local.

Native sheet encoding was measured in five alternating repetitions per format
on three image classes. JPEG was about 9-24% faster in these cases, but was larger
in all three. It is a latency choice, not a universal compression win:

| Fifteen-cell input | PNG median / bytes | JPEG median / bytes |
|---|---:|---:|
| Synthetic detailed pattern | 106.49 ms / 807,288 | 96.70 ms / 1,266,975 |
| Flat graphic overlay | 25.33 ms / 91,391 | 19.35 ms / 215,098 |
| Dark talking head | 49.47 ms / 312,841 | 40.90 ms / 334,074 |

The actual sheets were opened. PNG remains explicit for lossless labels/graphics;
selected source frames remain available separately. Bounded aspect-fit geometry
and display-size thumbnail decoding also reduce allocation independently of the
chosen encoder.

The packaged command completed the default-library lifecycle with a useful authored
note, the complete transcript, four selected packets and their dependencies, and
two explicit context dossiers. The main agent opened all 12 overview cells, a
detail frame, and 21 distinct native-frame timestamps, including a follow-up that
resolved an initially incomplete visual probe. A cleanup preview verified the
archive, and `cleanup --apply` moved only the generated analysis to native macOS
Trash. Afterwards the original analysis path was absent, the source hash was
unchanged, all **52 retained file checksums** still matched, all **five note links**
resolved, and the full transcript was byte-identical and readable.

The actual source note and media remain in the local dedicated library. The public
verification receipt contains only sanitized outcomes, not the private source
content or paths.

## Independent skill trial

A fresh agent received only the updated skill, the packaged CLI, two source paths,
and bounded questions. It did not read the implementation, tests, fixture recipes,
benchmark manifests, or earlier agent findings. It read the complete four-segment
slide transcript and inspected the actual slide progression, including two native-
frame reveal boundaries. Its separate motion task opened all 13 consecutive frames
in a 200 ms region plus three original detail images, and described screen motion
without inventing 3D geometry.

The trial retained two useful source notes and verified 134 file checksums, 14 note
links, and 121 packet dependencies. No command failed. Its broader slide study
opened 161 sampled cells across 15 sheets; that is delegation/coverage evidence,
not a demonstrated minimum-context strategy. No agent token or elapsed-time saving
is claimed. The main agent received compact notes rather than those image batches.

The trial also found useful friction. A visible final-text reveal was absent from
the event index and was recovered through overview plus a targeted probe. Event
packets' surrounding context produced more frames than the candidate interval
alone implied. The skill now explains that expansion and recommends an explicit
shorter range when appropriate. No-audio retry guidance and ambiguous timing-scope
labels were tightened in the command's result details.

Retention instructions now state explicitly that one packet include automatically
preserves its dependencies. A follow-up used exactly one `--include packet.json`
and verified all 18 retained files, four note links, and 15 dependencies without
manually listing frames. This removes avoidable orchestration work identified by
actual use.

## Reproduction and release identity

The public [measurements.json](measurements.json) contains the individual metrics,
hashes, fixture recipes, rejected theories, all three candidate iterations, and explicit
limitations. [verification.json](verification.json) records tests and native
retention/cleanup acceptance. `scripts/fixtures.py`, `scripts/experiments.py`, and
`scripts/benchmark.py` are the reproducible harnesses. Raw outputs, frozen binaries,
and images are intentionally retained under local `.scratch/` for review; these
development proof artifacts are not the skill's default knowledge library.

The final performance matrix, real ASR, and native retention/Trash acceptance all
ran the exact packaged executable SHA256
`284f0f4a4c87d8524514c20325436b9aaaa171c1d66935bc58e777e4f7a0caa9`.
Release packaging removed debug-only source-path entries with `strip -S` and
re-signed the binary before those runs. Every file-backed Mach-O program section
remained byte-identical to the corresponding unstripped build. Its signature and
committed checksum were verified. Earlier candidate and packaging hashes remain
separately identified in the measurements.

The final integrated suite executed **133 tests: 132 passed, one opt-in renderer
benchmark skipped, zero failures**. The renderer benchmark was then invoked
explicitly for the three datasets. Independent review was read-only and all its
material findings were resolved; later full-matrix and allocation findings also
have reproduced failures and passing corrections.

## Reuse and framework decisions

| Existing tool or library | Decision and evidence |
|---|---|
| FFmpeg / FFprobe | Retained for installed codec coverage, seeking, filtering, and observed frame metadata. [Pipeline](https://ffmpeg.org/ffmpeg.html#Detailed-description), [seeking](https://ffmpeg.org/ffmpeg.html#Main-options), [probe intervals](https://ffmpeg.org/ffprobe.html#Main-options). |
| CoreGraphics / ImageIO / CoreText | Retained native sheet layout and encoding, with bounded canvas geometry and measured encoder choices. No new runtime. |
| AVAssetImageGenerator | Deferred as a backend candidate; it supports batched requests and actual-time receipts, but tolerance, codec support, and pixel/latency parity need a separate implementation benchmark. [Apple documentation](https://developer.apple.com/documentation/avfoundation/creating-images-from-a-video-asset). |
| VideoToolbox | Tested on this Mac. Lower CPU did not compensate for sparse-operation latency. [FFmpeg hardware caveats](https://ffmpeg.org/ffmpeg.html#Advanced-Video-options), [VT filters](https://ffmpeg.org/ffmpeg-filters.html#VideoToolbox-Video-Filters). |
| MacParakeet | Retained installed local inference. Capability resolution uses model status rather than broad health; one successful probe is reused, and speakers are explicit. [CLI implementation](https://github.com/moona3k/macparakeet/blob/cli-v2.3.1/Sources/CLI/Commands/TranscribeCommand.swift). |
| FFmpeg scdet / PySceneDetect | Useful comparators and scene-change methods; no proven gain justifies replacing the current detector during this refactor. Neither establishes semantic importance. [scdet](https://ffmpeg.org/ffmpeg-filters.html#scdet), [detectors](https://www.scenedetect.com/docs/latest/api/detectors.html). |
| PyAV | Deferred as a default dependency: adds Python/C bindings without eliminating timestamp/keyframe problems. [Container API](https://pyav.basswood.io/docs/stable/api/container.html). |
| whisper.cpp / WhisperKit | Useful optional local adapters for different languages/models. Model lifecycle and matched cold/warm performance need separate evidence before embedding. [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [WhisperKit 1.1.0](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0). |
| OpenCV / COLMAP | Bounded specialist follow-up for optical flow or reconstruction, not eager preparation dependencies. Flow is not metric depth; blurred monocular video does not establish unique 3D geometry. [Optical flow](https://docs.opencv.org/4.13.0/d4/dee/tutorial_optical_flow.html), [capture requirements](https://colmap.github.io/tutorial.html#structure-from-motion). |

## Limits and remaining work

A finite test matrix cannot prove every codec, damaged input, variable-resolution
stream, hour-long transcript, language, HDR appearance, or arbitrary video works.
The tool does not perform semantic motion understanding or 3D reconstruction.
Sparse overview and event samples can miss brief inserts; native-frame probes are
available when such evidence matters. ASR timestamps describe alignment precision,
not measured word accuracy.

Initial content hashing still reads the entire source; global indexing and event
scanning still decode it when requested. Media threading does not control the
installed speech runtime. Very large source files or speech models may dominate
latency and memory. Independent source decoding does not imply that another agent
has actually opened or understood the result.

YouTube page metadata retrieval succeeded during acceptance, but two supported
video-download formats returned HTTP 403. No successful download or YouTube
end-to-end completion is claimed. A real local speech/video source is used for
runtime acceptance instead.

Retention validates ordinary inline Markdown links, not all possible embedded
HTML or Markdown extensions. An interruption after snapshot promotion but before
library index publication can leave a valid orphan snapshot; cleanup fails safe,
but automatic index reconciliation is not implemented. That is a recovery
convenience gap, not evidence loss.
