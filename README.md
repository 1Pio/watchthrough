# watchthrough

watchthrough is a small local command and agent skill for understanding video as joined transcript and visual evidence.

It prepares a local video into a reusable folder containing an honest transcript, sparse beginning-to-tail visual coverage, likely visual-change hints, and targeted captioned strips. An AI agent can scan broadly, inspect exact frames or dense ranges, delegate independent sections, and curate useful knowledge without putting a whole video into one context.

The CLI does deterministic media work. The bundled skill decides what matters, follows sources, and hands curated knowledge to Obsidian or another skill.

## Deliberately small

- One executable.
- Three subcommands: prepare, inspect, status.
- Local video input only.
- FFmpeg and FFprobe are the only required runtime tools.
- No Python environment, Node runtime, database, daemon, GUI, MCP server, or bundled model.
- No automatic upload or paid transcription fallback.

Version 1 targets Apple Silicon macOS 14 or newer.

## Install

Install FFmpeg, clone this repository, then run:

~~~bash
./install.sh
~~~

The installer verifies the committed binary, links it into ~/.local/bin, links the skill into ~/.agents/skills/watchthrough, and runs watchthrough status. It does not use sudo, edit shell configuration, or download dependencies.

## Quick start

~~~bash
watchthrough status
watchthrough prepare "/path/video.mp4"
watchthrough inspect "/path/video.mp4.watchthrough" overview
watchthrough inspect "/path/video.mp4.watchthrough" events
watchthrough inspect "/path/video.mp4.watchthrough" 06:49..07:10 --every 500ms
~~~

Use global --json for the stable agent result contract:

~~~bash
watchthrough --json prepare "/path/video.mp4"
~~~

YouTube acquisition is intentionally documented in [references/youtube.md](references/youtube.md) instead of being coupled to the core command.

## Transcription

--transcriber auto stays local:

1. A source-adjacent SRT, VTT, or canonical JSON sidecar.
2. MacParakeet when installed and capability-compatible.
3. A configured local command adapter.
4. Visual-only preparation with an explicit warning.

ElevenLabs Scribe v2 is available only through explicit --transcriber scribe. Its key can come from the process environment, macOS Keychain, or ~/.config/watchthrough/.env. The tool never places it in process arguments or artifacts.

Downloaded YouTube captions remain language-qualified and non-auto-discoverable. They are not the normal transcript route. Use sufficient local transcription first, use Scribe only with explicit authorization, and promote a vetted YouTube caption to a discoverable sidecar only as the strict last fallback described in [references/youtube.md](references/youtube.md).

The bundled skill has a transcript ownership gate. For one or a few reasonably sized videos, the main agent reads every clean transcript in full before detailed visual or surrounding-context work. For too many or unusually long videos, one transcript-owning subagent reads each full video transcript and returns a complete source note, which the main agent assimilates before visual delegation.

## Development

No third-party Swift package is used.

~~~bash
swift test
swift build -c release
~~~

Synthetic video fixtures are generated with FFmpeg during integration tests. Downloaded media, transcripts, provider responses, comments, and personal paths must never enter this public repository.

## Research decision

Existing tools such as claude-real-video, claude-video, PySceneDetect, summarize, and Framesleuth validate parts of the workflow but do not provide this project’s small persistent evidence and inspection boundary. watchthrough is a clean Swift implementation that invokes user-installed FFmpeg, FFprobe, MacParakeet, and yt-dlp where applicable. No source code from those projects is vendored.

MIT licensed. See [LICENSE](LICENSE).
