# Evidence and curation protocol

Use this protocol when the user wants deep understanding, comparison, durable notes, or a downstream skill. A quick factual video question can use a proportionate subset.

## Start with an explicit lens

Record:

- The learning question.
- The desired output.
- What would count as sufficient evidence.
- Any named moments, concepts, visuals, or claims.

Do not let the initial question prevent relevant contradictions or important adjacent evidence from surfacing.

## Transcript ownership gate

Complete transcript coverage before detailed visual inspection, surrounding-context research, or any visual/research subagent is started.

- For one or a few reasonably sized videos, the main agent reads each entire clean canonical transcript from beginning to end and creates its source note.
- For too many or unusually long videos, assign one transcript-owning subagent per video. That owner reads the full transcript and returns one complete coverage/source note. Do not split one video among partial transcript owners by default.
- The main agent reads and assimilates every returned source note before delegating visual probes or source research.
- Search and indexing help navigate a transcript. They never establish complete coverage by themselves.

## Source pass

For each source:

1. Record source identity and transcript provenance.
2. Satisfy the transcript ownership gate and record beginning-to-end coverage.
3. View all overview strips from beginning through decoded tail.
4. Review the ranked event list as hints.
5. Create a short source note before cross-source synthesis.

A useful source note contains:

~~~text
source:
question:
transcript provider and precision:
transcript coverage receipt:
visual coverage:
key claims:
visual observations:
referenced sources:
contradictions or uncertainty:
follow-up inspections:
~~~

## Evidence ledger

Type every material entry:

- speaker_claim
- visual_observation
- creator_metadata
- comment_claim
- external_finding
- agent_inference

Retain:

~~~text
source id
timestamp or range
claim or observation
visual artifact path when relevant
confidence and uncertainty
external source when relevant
contradictions
~~~

Do not turn a speaker’s confident statement into an established fact. Do not infer motion or causality from one still when a short strip is available.

## Coverage ledger

Track:

- Transcript coverage by the main reader or one transcript owner per video, plus timing precision and any explicit unreadable gap.
- Overview first PTS, last PTS, and largest gap.
- Candidate events reviewed.
- Exact frames or ranges inspected.
- Known gaps, failed extractions, illegible text, or unresolved references.

Use bounded language such as “the complete overview was reviewed with a largest gap of 18.4 seconds.” Do not say “every meaningful frame was reviewed.”

## Choosing the next probe

- Speech points to the screen: inspect that timestamp.
- Overview shows a new graphic or state: inspect before, during, and after.
- Candidate is a brief spike: use a decoded-frame stride.
- Small text is unreadable: request the exact timestamp/frame rather than creating a denser low-resolution strip.
- A stable slide evolves: inspect the reveal range.
- Evidence repeats: stop spending frames and record sufficient coverage.

Keep packets bounded. Split independent ranges rather than generating hundreds of cells in one artifact.

For a highly specific visual subagent, pass the assimilated source note plus enough local transcript context for that question, timestamp, or range. Do not attach every video transcript or make the visual subagent rediscover the source’s spoken argument.

## Multi-source synthesis

Finish and assimilate transcript-complete source notes independently before visual delegation or comparison. Then organize:

- Agreement.
- Complementary detail.
- Direct contradiction.
- Different definitions or scope.
- Evidence quality differences.
- Open questions.

Do not use view or like counts as evidence that a claim is correct.

## Downstream handoff

For Obsidian, preserve provenance and selected visuals but curate the material into a useful note. Do not dump the full transcript.

For /write-a-skill, include:

- Operational synthesis.
- Evidence-backed rules and judgment.
- Examples and counterexamples.
- Contradictions and failure modes.
- Open questions.
- User-specific context.
- Selected visuals that teach something words cannot.

The receiving skill should not need to understand watchthrough internals.
