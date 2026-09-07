# Evidence and curation

Load for substantive study, comparison, durable notes, or downstream curation.
Keep a clear question and an evidence threshold; relevant contradictions can
change the direction of the user's task.

## Source pass

1. Record source identity and transcript provenance. The main agent normally reads
   the entire clean transcript. One complete transcript owner can handle a video
   too large for the main context; assimilate that source note before synthesis.
2. Open the returned overview sheets when broad visual coverage matters. Record
   first/last observed PTS and largest gap. A small overview is orientation, not
   exhaustive coverage.
3. Follow uncertain moments with exact or dense range packets. Open each image
   before using its contents. Record an inconclusive probe and inspect nearby
   frames if the requested moment lands on a transition or illegible state.
4. Request the optional event scan only when its change hints would help. Record
   index candidates separately from event packets actually opened.
5. Combine spoken content, inspected visuals, relevant source context, and gaps
   into one compact source note before cross-video synthesis.

Independent visual inspection or source identification can proceed while a
transcript owner works. Whole-video conclusions require the combined evidence;
a bounded answer must state its smaller coverage.

## Source note and evidence ledger

Keep the source note useful to another agent:

~~~text
source identity / URL / creator:
user question:
transcript provider, model, language, precision, clean file path:
transcript owner and beginning-to-end coverage or explicit gaps:
spoken argument, examples, qualifications, and timestamps:
overview sheets opened; actual endpoints and largest gap:
event index scanned; event packet IDs actually opened:
exact/range packets opened; selected frame paths:
visual observations that affect understanding:
referenced sources and creator corrections:
contradictions, failed probes, missing or illegible evidence:
answer or downstream action supported by this source:
~~~

Type material claims as `speaker_claim`, `visual_observation`, `creator_metadata`,
`comment_claim`, `external_finding`, or `agent_inference`. Attach the timestamp or
range, supporting artifact/source, and any uncertainty. A speaker's confidence or
view count is not verification. One still does not establish motion or causality.

Copy timestamps, provider fields, and artifact paths from CLI results and packets.
The human/agent reader owns claims of reading, opening, or understanding. The CLI
cannot produce those coverage claims automatically.

## Bounded delegation

Send one question or interval, its source note, local transcript context, and
already generated frame/sheet paths. A dense visual delegate returns:

- What visibly changes, in timestamp order.
- Which artifacts support each material observation.
- The distinction between observation and interpretation.
- Unreadable or uninspected gaps and the smallest useful follow-up.

A transcript owner reads the full clean transcript and returns a source note,
not another raw transcript dump. A research delegate follows
[research.md](research.md). Keep media extraction serial by default while reading
and reasoning delegates run independently.

## Synthesis and downstream use

For multiple videos, separate agreement, complementary detail, direct
contradictions, different definitions/scopes, and evidence-quality differences.
Assimilate all transcript-complete source notes before whole-source comparison.

Before finishing, follow [retention.md](retention.md). The dedicated durable
library keeps the full transcript and selected evidence; Obsidian or a downstream
skill receives curated knowledge, examples, contradictions, and open questions.
The receiving task should not need to learn watchthrough internals.
