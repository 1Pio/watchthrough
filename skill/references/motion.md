# Motion, camera movement, and dense visual evidence

Load for high-rate animation, brief inserts, blur, camera movement, or spatial
questions. Choose a local time range first; preserve native presentation times.

## Probe in stages

1. Find the relevant interval from the question, transcript, overview, or a change
   candidate. A sparse overview can miss an event shorter than its sampling gap.
2. Inspect a short range at 100-500 ms spacing to locate the change.
3. Inspect the decisive fraction of a second with `--every 1f`. These are decoded
   frames within that range, including variable-rate timing. Read the actual PTS
   and reported ordinal basis. Use `frame:N` only when a global decoded ordinal is
   part of the question.
4. Open all returned sheets. If an occlusion, transition, or blur makes one frame
   ambiguous, inspect adjacent frames and a wider time context. Preserve the frame
   sequence that supports the observation, not only a flattering still.
5. Increase `--width` for detail rather than expanding hundreds of low-resolution
   cells. A lossless PNG sheet avoids another lossy sheet encoding, but does not
   restore information already absent from the source or JPEG frame.

## Describe what the evidence supports

Distinguish object motion, apparent camera motion, zoom, edits, and graphical
transforms. Temporal order and screen displacement alone do not prove causality,
physical scale, depth, or a unique camera trajectory. Blur and compression are
missing information; sharpening or interpolation is an inferred derivative.

For a physical camera moving through a scene, inspect overlap across several
frames, parallax between depths, occlusions, stable background features, and cuts.
Animated graphics need not obey physical geometry at all. Do not invent a 3D
reconstruction from a few stills.

When the user's task actually requires quantitative motion or reconstruction,
export selected frames with timestamps to a bounded specialist workflow:

- OpenCV sparse or dense optical flow can measure image displacement under its
  assumptions. It is not metric depth.
- COLMAP can estimate camera poses and structure from suitable overlapping,
  textured views. Fast blur, little translation, repeated textures, dynamic
  objects, and cuts can make that inference unreliable.
- Keep original evidence distinct from flow maps, interpolated frames, depth
  estimates, or reconstructed views; record parameters and validation.

These optional tools are not initialized by watchthrough. Its role is to make the
right original frames and time context available efficiently.

References: [OpenCV optical flow](https://docs.opencv.org/4.13.0/d4/dee/tutorial_optical_flow.html),
[COLMAP capture requirements](https://colmap.github.io/tutorial.html#structure-from-motion).
