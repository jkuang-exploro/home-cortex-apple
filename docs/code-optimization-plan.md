# Code simplicity and maintainability plan

Date: 2026-10-11 (America/Los_Angeles).
Implementation checkpoint: 2026-10-17. The maintainability refactors and bounded
runtime, chat, preview and allocation improvements are implemented. See
[implementation and validation results](code-optimization-results.md) for checks,
measurements and the remaining physical-device acceptance work.

The sections below preserve the original design and its acceptance criteria;
statements about the initial code describe the repository before these changes.

The primary goal is to make behavior easier to understand, change and test.
Prefer small refactors with explicit ownership and fewer repeated decisions.
Performance tuning is a later, measurement-driven workstream.

## Recommended sequence

| Order | Change | Concrete outcome | Current status |
| --- | --- | --- | --- |
| 1 | Centralize embodiment runtime lifecycle | One place decides which workers should run | Implemented |
| 2 | Consolidate configuration application and preferences | One path applies saved/server settings consistently | Implemented |
| 3 | Replace text-dependent recovery decisions | Display wording cannot authorize a new enrollment attempt | Implemented |
| 4 | Share transport construction and bounded JSON reads | Common infrastructure with explicit endpoint policies | Implemented |
| 5 | Split files by responsibility and shorten worker methods | Easier navigation and review without new frameworks | Implemented |
| 6 | Profile and optimize remaining hotspots | Release synthetic benchmark and signposts; physical measurements pending | Implemented in part |

## 1. Centralize embodiment runtime lifecycle

`Core/V1/EmbodimentController.swift` repeats starts/stops in
`refreshConfiguration`, capability changes, `provision`, `enableRuntime`,
`disableRuntime` and `setForeground`. The sequences already differ:
`changeMotion` stops motion, inspection and vision before disconnecting, while
camera/localization changes explicitly stop all four workers. Configuration
refresh also invokes localization startup through two branches.

First introduce a named `stopAllRuntimes()` helper without changing call order.
Then derive a small runtime-selection value from foreground state, runtime
preference, credential availability, camera grants and diagnostic selections.
Apply it through one `reconcileRuntimes()` method. Keep connection registration
and disconnect intent explicit in the controller; do not have reconciliation
re-register on every configuration refresh.

Reconciliation must be idempotent: an unchanged selection must not reset the
tracking world or invalidate calibration. A feature's OFF transition stops local
work immediately even if persistence or network operations fail. Starting a
worker may precede an ACTIVE session only where that worker already waits for it.

Characterize existing camera/motion/localization combinations first, including
permission denial. Resolve any inconsistent behavior as a separate, documented
behavior change instead of silently incorporating it into helper extraction.
Add injectable runtime controls only where needed to observe starts, stops and
camera handoff in lifecycle tests.

Acceptance: lifecycle methods contain intent and state updates rather than
repeated worker sequences; repeated reconciliation preserves world/generation;
background, OFF, session replacement and failed configuration updates behave
truthfully; CALLER conversation remains independent of DEVICE runtime.

## 2. Consolidate configuration application and preferences

Configuration assignment and JSON persistence repeat across refresh and all
three feature toggles. Preference keys for runtime configuration, motion,
localization, space selection and pending references are assembled inline.

Extract `applyConfiguration` and body-scoped preference helpers. Preserve the
existing stored keys and Codable payloads so current installations load without
migration. Keep DEVICE credentials and keys in the existing Keychain store.
Separate server-confirmed capability configuration from immediate local OFF
preferences; these have different failure and authorization semantics.

A helper for PATCH/decode may reduce repeated request plumbing, but the public
`changeCamera`, `changeMotion` and `changeLocalization` entry points should still
express their permission and teardown differences. Avoid a boolean-heavy generic
feature-toggle method.

Acceptance: one configuration persistence path; existing saved setup, body,
preferences and pending reference save restore correctly; permission/network or
storage failures do not re-enable a locally disabled feature.

## 3. Replace display-text-dependent setup decisions

`canStartNewAttempt` currently checks whether `setupMessage` contains
`"Setup expired."`. `EmbodimentOnboardingState.failed(String)` and
`EmbodimentSetupFailure(message:)` also represent failures mainly as display text.

Introduce a small typed recovery disposition such as resume, server-confirmed
expired, or unavailable. Derive eligibility to create another attempt from that
state, with localized/display text computed separately. Inspect the actual backend
error contract before decoding an expiry code. If no machine-readable expiry
signal exists, coordinate that narrow API change; never infer permission from
wording or elapsed local time.

Acceptance: editing or translating an error message cannot change eligibility;
unknown, interrupted, issued and committed attempts keep their recovery path;
only explicit backend confirmation permits replacing an expired saved attempt.

## 4. Share narrow transport infrastructure

V1, conversation, embodiment setup, inspection and software login repeat TLS 1.3,
ephemeral URLSession configuration, cache/cookie/credential-storage settings and
TLS delegate construction. Several repeat a bounded async byte-to-Data reader.
`TLSDelegate` itself is already shared.

Introduce a small session-construction helper that returns the session and its
owned delegate. Each transport passes explicit origin, trust material, optional
identity, timeouts and connectivity/cache settings. Preserve existing differences,
including setup versus inspection timeout values. Share the bounded body-reader
mechanics where compatible, with each caller retaining its response-size limit,
MIME/status validation and failure mapping.

Endpoint allowlists, V1 correlation/closed-schema checks, conversation SSE framing
and domain response decoding remain visible in their own transports. Keep bootstrap,
CALLER and DEVICE sessions scoped to their identity; do not create a global session.

Acceptance: common session setup has one implementation; trust/redirect,
cancellation, size-limit and endpoint tests pass; SSE blank separators and split
Unicode still decode correctly; timeouts and identity isolation remain explicit.

## 5. Improve file and method boundaries

Use the repository's existing style of concrete types and injected protocols.
Extract only coherent responsibilities that are already identifiable:

- Move `URLSessionInspectionTransport` out of `InspectionPublisher.swift`.
- Split `EmbodimentSetup.swift` into setup models, localization-reference models
  and its transport implementation.
- Split `VisualAnchors.swift` into catalog/geometry models, `VisualPoseSolver`, and
  `VisualAnchorDetector` plus its C handle/frame adapter.
- Split large runtime loops into named steps for session binding, sampling,
  observation handling, viewer lease refresh and publication. Initially preserve
  the same task topology and timing so review stays focused on structure.
- Extract repeated UI sections where a section has its own clear inputs and
  actions; keep workflow decisions in controllers rather than views.

Keep the numeric solver, coordinate conventions, camera ownership and generation
fences unchanged during these moves. Update Xcode source membership explicitly:
the project enumerates source files. Avoid a large directory rename of `Core/V1`
until file responsibilities are clearer and a move has practical value.

The open `AprilTag/common/string_util.c` and `.h` are vendored upstream code,
recorded in `AprilTag/PROVENANCE.md`. Keep that boundary intact. Local adapter
changes belong in `HCDetector` or the Swift detector wrapper where possible.

Acceptance: each file has one recognizable responsibility; reviewers can follow
lifecycle and transport policy without chasing generic abstractions; existing
public entry points and numerical behavior are preserved.

## Validation and delivery

Deliver each numbered item as a separate reviewable patch. Start with lifecycle
helper extraction, then centralize decisions once behavior is covered. Keep any
intentional behavior correction separate from moves and deduplication.

Use existing `EmbodimentTests`, `EmbodimentSetupTests`, `ConnectionControllerTests`,
`ProvisioningTests`, `ConversationTests`, `InspectionTests`, `MotionOrientationTests`,
`VisionTests` and `SpatialLocalizationTests` according to the affected behavior.
Add targeted tests for lifecycle combinations and recovery eligibility; do not
add tests that merely restate a forwarding helper. Run the full offline suite
at integration. Pure file moves need build/source-membership verification.

Evaluate maintainability by concrete review questions: Is there one lifecycle
policy? Can a new diagnostic be added without editing several start/stop blocks?
Does configuration persistence have one path? Can display wording change control
flow? Are domain validation and asynchronous ownership still easy to inspect?
Use these outcomes rather than total line-count reduction as the success measure.

## Performance workstream and physical acceptance

After structural changes, collect a Release baseline on the same physical iPhone.
Debug explicitly uses Swift `-Onone` and C optimization level `0`; resolved Release
Swift settings use `-O` and whole-module compilation. Use Apple's
[SwiftUI profiling guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
to inspect long/frequent view updates, alongside CPU and allocation measurements.

Candidates from inspection, to prioritize only after measurement:

- Separate localization polling/detection from awaited inspection network work;
  the current single worker waits for both. Preserve latest-only bounded work.
- Reduce 100 ms upload polling and narrowly scope chat's one-second `TimelineView`;
  preserve observable lease/credential expiry before removing time-based refresh.
- Avoid two transcript ID searches and full-array change/scroll observation on
  every chat delta; preserve partial text, completion, Unicode and size limits.
- Remove native calibration preview's JPEG encode/decode round trip and share
  compatible preview work; keep fresh evidence capture separate and prioritized.
- Measure full-luma copies, per-frame catalog rebuilding and solver scratch
  allocations before changing decimation, thread counts or numerical iteration
  limits. Preserve ambiguity and coherent-board conflict detection.

Release synthetic measurements are recorded in the results document. Physical
camera, energy and accuracy improvements have not been established. Canonical pose
publication remains governed by the existing extrinsic and uncertainty gates.
