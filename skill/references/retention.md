# Durable source notes and cleanup

Load before finishing a video task. The default library is
`~/Library/Application Support/watchthrough/library`; `--library DIRECTORY`
selects a different dedicated location. Keep notes and retained evidence here
rather than coupling them to a temporary analysis or dumping transcripts into
Obsidian or another downstream skill.

## Reuse earlier learning

For a known source, search `summary.md` files in this library by title, canonical
URL, or task keyword before acquiring and processing it again. Read the matching
note and check its source identity, transcript provenance, inspected intervals,
and gaps. Follow its local evidence links and `transcript/transcript.txt` when the
current question needs them. A matching topic is not a matching source; use the
receipt's source hash when comparing a local file. Retrieve fresh metadata or new
frames only when the current task exceeds the retained coverage. An archived note
does not establish that online descriptions or comments are still current.

## Write the useful note

Write an authored Markdown file outside the disposable analysis directory. The
CLI does not summarize the video and cannot judge whether this note is complete.
Use the transcript owner and visual delegates' evidence to cover:

~~~markdown
# Video title

Source: canonical URL or local source identity; creator; publication date if known.
Task: the question this video informed.
Transcript: provider/model/language, timing precision, who read it, and any gaps.

## Spoken content / script
A concise beginning-to-end summary of the video's argument or narrative. Include
key claims, examples, qualifications, and contradictions with timestamps. If
speech is absent or unavailable, say what is actually known.

## Inspected visuals
For each relevant inspected interval: timestamp/range, observation, supporting
retained image link, and how it changes or supports the spoken account.

## Sources and context
Relevant description links, creator corrections, bounded comment findings, and
external verification. Keep their provenance and retrieval time distinct.

## Outcome and coverage
What this video contributed to the user's task. Transcript coverage, overview
coverage/gaps, dense ranges and exact frames inspected, inconclusive probes,
unreadable text, and remaining questions.
~~~

For a bounded question, make the outcome specific and mark limited visual
coverage. An overall spoken-content summary can come from the full transcript
owner without claiming full visual coverage. Keep the note useful independently
of watchthrough command history.

## Retain selected evidence

~~~bash
watchthrough --json retain ANALYSIS --note /path/source-note.md \
  --include inspections/PACKET/frames/FRAME.jpg \
  --include inspections/PACKET/packet.json \
  --dossier /path/source.info.json \
  --dossier /path/source.description
~~~

Use actual returned artifact paths, not the placeholder names above. Including
`packet.json` or `packet.md` automatically retains that packet's frames, sheets,
and navigation files. `--include` accepts the returned absolute path or a path
relative to the analysis; paths outside that analysis remain invalid. There is no
need to enumerate `artifactFingerprints` or list every dependent image by hand.
For one isolated still, `--include` also accepts that explicit image alone.
Retain a complete frame sequence when motion is material. Dossiers are explicitly selected,
bounded local text/JSON files. No comments, private metadata, or unrelated files
are fetched automatically.

The snapshot contains `summary.md`, canonical transcript text/JSON when available,
source provenance, selected evidence, and a checksummed receipt. A summary's image
links should use `evidence/<analysis-relative-path>` so they resolve within the
snapshot. Use retained `dossiers/` files and source URLs for context. `retain`
returns the actual snapshot paths; check those paths and open selected retained
images before handing the note to another task. Each retention creates a new
immutable snapshot; it does not overwrite prior learning.

## Clean up regenerated artifacts

~~~bash
watchthrough --json cleanup ANALYSIS
watchthrough --json cleanup ANALYSIS --apply
~~~

Use the same `--library` override if one was used for retention. The preview checks
that the current analysis is covered by an intact retained snapshot. Applying
cleanup moves only the tool-owned analysis to system Trash. The original video
and durable library are preserved. After cleanup, open the retained summary and
transcript to verify that the useful result remains independently readable.

An active writer, changed analysis/source, corrupted snapshot, unsafe path, or
unrecognized user file prevents cleanup. Resolve the reported issue rather than
bypassing the check. Keep analysis caches when another active task needs them;
otherwise the normal finishing step is retention followed by cleanup. Separately
acquired source media can be much larger than the analysis; its removal requires
an explicit ownership/retention decision and uses system Trash as well.
