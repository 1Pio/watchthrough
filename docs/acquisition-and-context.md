# Acquisition and evidence improvements

This iteration follows the 59:44 public-video benchmark of release 0.2.0. Its
ordinary local workflow used 18.01 seconds of command execution after acquisition,
and cached requests took about 25-40 ms. The work below targets observed failures
and growing costs rather than another extraction-engine rewrite.

## Findings and chosen scope

| Finding | Change | Acceptance |
|---|---|---|
| Acquisition required agent-written commands; an outdated client returned 403, a fixed audio ID disappeared, and a generic quality selector chose a large HLS stream. | Add a native acquisition command over maintained yt-dlp, with deterministic single-video options, current format selection, owned resumable output, compact provenance, and an explicit managed-downloader update route. | Acquire the short public test video through the CLI, verify the actual local streams, reuse it without network access, and exercise failures/resume with deterministic subprocess fixtures. |
| Overview images show the start of long surrounding speech intervals, making the caption look contemporaneous with the frame. Long text is clipped. | Keep complete interval text in packets; show a separately timed nearby speech excerpt on sheets, including honest cue precision and visible truncation. | Reproduce the hour-video tail mismatch with a small fixture; verify word/cue boundaries, nearby silence, visible output, and reuse of decoded frames. |
| Explicit status verification checks the manifest's overview but can miss corrupt ordinary inspection images. | Verify each completed owned inspection packet when `--verify` is requested. | A corrupt range/still fails with its path; intact packets pass and are counted; ordinary status keeps its fast path. |
| Looking for reusable frames fully hashes every prior packet before comparing its evidence identity. | Filter by the inexpensive packet identity first, then fully validate candidates. | Unrelated packets do not enter full validation; matching corrupt evidence remains rejected. |
| Inspection results return absolute paths, but retention required the agent to rewrite them as relative paths. | Accept returned absolute `--include` paths inside the same analysis while retaining relative-path support and owned-artifact checks. | Retain the returned packet path directly; reject outside files, traversal, and linked artifacts; preserve selected packet dependencies. |

## Acquisition boundary

Watchthrough should own the stable agent-facing contract: one URL, one output
bundle, a local source path, selected-stream provenance, resumable failure state,
and useful diagnostics. The maintained upstream downloader should continue owning
YouTube extraction, JavaScript challenges, transport retries, and copy-only merges.
Copying a smaller extractor into Swift would transfer a fast-changing maintenance
burden without resolving the observed client-routing failures.

[yt-dlp](https://github.com/yt-dlp/yt-dlp) was selected because it already owns
extraction, format selection, retries, and merging, and now has target-specific
acquisition proof here. [pytubefix](https://github.com/JuanBindez/pytubefix) retains
Python and declares a Node binary dependency, so it does not simplify setup.
[YouTube.js](https://github.com/LuanRT/YouTube.js) is a broader InnerTube client
requiring a new JavaScript API/player-execution integration.
[YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) offers native Swift stream
extraction, but its optional remote fallback introduces a server dependency when
local extraction fails. Those alternatives were assessed from implementations
and primary documentation, not benchmarked against yt-dlp; none demonstrated a
speed or reliability advantage for this workflow.

Normal acquisition must ignore ambient downloader configuration and plugins,
avoid browser cookies and cloud services, retain native frame rate, and select
formats from current metadata rather than fixed IDs. Resolution and frame rate
take precedence over direct-delivery preferences. Audio language preference must
remain ahead of transport/size preferences. A lower-bitrate language track is not
an acceptable implicit optimization of speech evidence.

The implemented selector is `bv[height<=H]+ba/b[height<=H]`, with
`--format-sort-force -S res,fps,lang,proto`. It selects separate video/audio when
available and otherwise a combined stream within the height cap. Resolution and
frame rate precede audio language preference and transport; remaining codec and
quality choices use upstream sorting. This avoids fixed format IDs, a blanket AVC
preference, and size-first audio selection. Merging/remuxing copies streams into
Matroska without transcoding. An unavailable capped format is an error, not an
implicit quality-policy change.

Dependency installation/update is explicit. When compatible CPython >=3.10 is
already present, the managed downloader uses the official zipimport asset with
`-I`; no pip install, new environment, or general runtime bootstrap is needed.
Without compatible Python it selects the official macOS standalone. Both include
matching EJS. Each package must come from the official release, pass published
SHA256 and version checks before activation, and stay separate from the system
installation. Existing supported JavaScript runtimes remain dependencies.
Successful source reuse must not require a network request or downloader startup.

The package choice follows a concrete launcher test: the verified 2026.08.19
standalone (37,146,048 bytes) failed `--version` inside the current Codex filesystem
sandbox with `Failed to initialize sync semaphore! semctl: Operation not
permitted`, but succeeded outside it. The official zipimport asset (3,072,469
bytes) succeeded inside the sandbox through existing CPython with `-I` in 0.286
seconds. This establishes launcher compatibility for the tested environment;
it does not establish completed YouTube acquisition. PyInstaller's one-directory
macOS ZIP avoids that one-file semaphore path in source, but its 53,923,637-byte
archive and extracted tree add complexity without improving the verified Python
route. It was not executed in this comparison.

Global status exposes the actual executable plus a JSON-encoded argument prefix,
so advanced requests do not assume every downloader artifact is directly
executable. `-I` ignores Python environment variables and user site packages;
system site packages remain accessible. Upstream owns its dependency licensing:
yt-dlp's core is under the Unlicense, the zipimport release includes MIT/ISC
components, and the PyInstaller standalone's combined distribution is GPLv3+.
Watchthrough's Swift code remains separately MIT licensed.

Interrupted work stays in the same owned bundle. Unknown files, symbolic links,
or a different URL/configuration must not be silently overwritten. The completion
receipt is written only after downloader success and local media validation.
Persistent source context excludes signed stream URLs and request inventories.

## Evaluation and verification plan

The live acquisition target is the 4:35 public video
[_6jZlnRsXXQ](https://www.youtube.com/watch?v=_6jZlnRsXXQ). Metadata reports 25 fps.
Its 1080p direct streams show why codec choice needs care: AVC is about 72.82 MB,
VP9 50.29 MB, and AV1 38.32 MB, before audio. The earlier hour-long source had a
smaller AVC representation than VP9. Do not infer a universal codec transfer or
decode-speed advantage from either source alone.

Validate the selected policy with bounded experiments. Avoid adaptive download
profilers, custom JavaScript solvers, a forked extractor, browser automation, and
new optical-flow/indexing systems for this iteration. Their implementation cost
is disproportionate to the remaining demonstrated problem.

After focused regressions pass, run the full Swift suite, build and package the
release, then use that exact executable for live acquisition, complete local
transcription, an overview, short native-frame motion ranges, a detail still,
cache reuse, verification, retention, and cleanup. Open the resulting images and
read the transcript. Reopen durable evidence after cleanup. Record timings and
binary identity, distinguish command time from agent work, and independently
review the integrated changes before committing.

## Primary sources

- [yt-dlp release 2026.08.19](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19): current client-routing changes behind the observed recovery.
- [yt-dlp format selection and sorting](https://github.com/yt-dlp/yt-dlp#format-selection): dynamic selection, protocol ordering, native resolution/frame-rate preferences, and post-processing output.
- [yt-dlp EJS setup](https://github.com/yt-dlp/yt-dlp/wiki/EJS): matching challenge components, official packaging, and supported JavaScript runtimes.
- [yt-dlp release files, licenses, and dependencies](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/README.md#release-files): official zipimport/standalone contracts, third-party attribution, and Python requirements.
- [Official macOS build workflow](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/.github/workflows/build.yml#L342): separate one-directory and one-file packages.
- [PyInstaller 6.22.0 execution dispatch](https://github.com/pyinstaller/pyinstaller/blob/v6.22.0/bootloader/src/pyi_main.c#L694) and [semaphore initialization](https://github.com/pyinstaller/pyinstaller/blob/v6.22.0/bootloader/src/pyi_utils_posix.c#L577): the observed failure belongs to the one-file child-launch path.
- [Python isolated mode](https://docs.python.org/3/using/cmdline.html#cmdoption-I): the scope of `-I`.

## Accepted implementation and measured results

Release 0.3.0 completed the live workflow on macOS 26.6 arm64 with FFmpeg 8.1.1,
MacParakeet 2.3.1, yt-dlp 2026.08.19, and Deno 2.9.3. The packaged executable is
the exact stripped, ad-hoc-signed binary used for this acceptance, SHA256
`6f5e45859cecc8acfcbfec7c55bfc4afdbb48defb91f504ce669536a70ee992f`.
The full Swift suite passed 182 tests with one optional benchmark skipped and no
failures. The installer test passed again after packaging.

| Operation | Command wall time | Observed result |
|---|---:|---|
| Fresh acquisition including managed downloader setup | 11.02 s | 42,202,326-byte source; 1920x1080 AV1 + English Opus, 25 fps, direct formats 399+251; container, streams, native rate, source hash, and end packets validated. |
| Retry the earlier incomplete bundle | 4.01 s | Existing completed media accepted without another media transfer after the output-framing fix. |
| Reuse acquisition after default preparation | 0.026 s | Passed with an intentionally missing downloader override; no downloader startup. |
| Default preparation and complete local transcription | 14.84 s | 5,637-byte word-timed transcript; no full visual index built. The complete clean text was read. |
| Default overview | 1.99 s | 12 samples through the decoded tail, all opened; timed nearby speech and an honest silent tail. |
| One-second native-frame motion probes | 0.30 / 0.25 s | Each returned 26 distinct frames, with 0.04-second spacing; both pages of both ranges inspected. |
| Detail still | 0.18 s | Readable 1920-pixel resolution/variable labels at 03:20. |
| PNG relayout | 0.20 s | The same ordered frame hashes reused, with four newly rendered sheets. |
| Cached overview / motion | 0.032 / 0.027 s | Existing packets reused. |
| Optional full-duration event scan | 8.98 s | 32 routing candidates; individual event packets were not opened. |
| Explicit analysis verification | 0.062 s | All five completed packets counted and verified, plus source and referenced artifacts. |
| Retain / cleanup preview / Trash application | 0.77 / 0.58 / 0.35 s | Returned absolute packet paths accepted; 116 retained files and 11 note links verified after cleanup, source hash unchanged, retained image reopened. |

The primary workflow used 30.54 seconds of command execution including acquisition,
transcription, selected probes, retention, and cleanup. The optional event scan,
diagnostic retries, development, tests, agent reading, and review are additional.
These are single-run observations with potentially warm filesystem/runtime caches,
not a controlled cross-version speedup claim. Local transcription's highest
individual process peak was about 2.92 GB; visual commands stayed below 107 MB by
that measure. It is not an aggregate concurrent-memory measurement.
See [machine-readable acceptance](acquisition-verification.json) for exact values.

The live run caught an assumption absent from the original fixtures: forced
yt-dlp progress can share stdout with `--print` metadata. The final integration
uses a distinct metadata marker, parses streaming lines, forwards bounded progress,
and rejects missing/empty/multiple completion records. Synthetic failures cover
partial fragment resume, false-success media, wrong frame rate/audio, truncation,
unsafe paths, and changed source/context. Real retry acceptance above covers a
completed download awaiting metadata validation, not an intentionally interrupted
network transfer.

Independent review also found that switching two same-version downloader packages
could invalidate the old active pointer before publication. Packages now have
immutable release/asset/digest destinations, with a tested failure at pointer
publication that leaves the prior working package usable. Damaged owned copies
are preserved during repair, and bytes are checked before execution. Existing
0.2 analyses remain readable and eligible for an explicit owned refresh.

Full interval captions remain unchanged in packet text/JSON. Sheets use separately
timed nearby speech, whole cue bounds when word timing is absent, explicit silence
or unavailable timing, and visible truncation. A suspected later-page clipping
issue was disproved with two independent image decoders and byte-identical caption
pixel comparisons; no renderer workaround was added for a presentation artifact.

Source media, full transcript, creator context, local process logs, and durable
evidence remain outside the public repository. Only the implementation, tests,
packaged binary, and sanitized measurements are included here. The live workflow
does not independently validate the video's scientific claims, establish complete
visual coverage between samples, or guarantee future upstream YouTube behavior.
