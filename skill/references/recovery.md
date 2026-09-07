# Recovery and reuse

Load when preparation or inspection yields, fails, is busy, or needs refreshing.

- Keep the host's original session ID and poll it to final exit and complete JSON.
  Progress text is not the command result. Do not launch a duplicate analysis
  because the first host call yielded.
- If ownership is lost, run `watchthrough --json status ANALYSIS`. Reuse ready
  stages, wait for an active owner, and investigate incomplete or invalid state.
  A deferred stage is intentional, not a failed preparation.
- Use the original analysis path. A separate output path means a deliberate
  separate analysis, not an automatic recovery strategy.
- Read a requested stage's error before retrying. Successful independent stages
  remain useful. Preserve incomplete work until its ownership and cause are clear.
- Ordinary reuse checks source metadata. Use `status ANALYSIS --verify` when a
  full source hash check is warranted, such as suspected replacement or a durable
  handoff. Hash verification reads the whole source and can take time.
- A changed source or transcriber configuration requires an explicit refresh or
  a deliberate new analysis. Do not rewrite canonical transcripts by hand and
  expect cached captions to reflect the edits.
- Inspect the reported artifact paths. `inspect transcript` returns the canonical
  readable transcript; an event index or a path listing is not visual evidence.
- When multiple delegates share a source, give them already generated packets or
  serialize their extraction requests. Parallel reading is cheap; simultaneous
  full-video decoding or transcription can saturate a laptop.
