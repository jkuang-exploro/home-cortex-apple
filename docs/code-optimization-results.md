# Optimization implementation and validation

Implementation checkpoint: 2026-10-17 (America/Los_Angeles).
The implementation and offline tests are complete. Physical-device runtime
acceptance remains pending; the registered phone is unavailable.

## Implemented changes

| Plan item | Result |
| --- | --- |
| Runtime lifecycle | `EmbodimentController.reconcileRuntimes()` is the single worker-selection policy; `stopAllRuntimes()` handles shared teardown. Repeated reconciliation does not reset calibration. |
| Configuration and preferences | `applyConfiguration` centralizes confirmed configuration application; `EmbodimentPreferences` retains existing storage keys and body scoping. |
| Setup recovery | Eligibility uses `EmbodimentSetupRecovery`, decoded from the backend's structured enrollment expiry code, independently of display wording. |
| Transport infrastructure | Five transports use identity-scoped `AuthenticatedHTTP` session construction. Streaming JSON consumers share a bounded, cancellation-aware reader. Endpoint rules, timeouts, domain failures and SSE parsing stay in their transports. |
| File boundaries | Inspection transport, setup transport, localization-reference models, pose solver and detector each have their own file. Chat status and message rows have separate views. All extracted sources have explicit Xcode target membership. |
| Local tracking scheduling | Sampling, visual detection, viewer-lease refresh and publication run independently. Slow inspection requests and detector calls cannot stall the sampling worker. |
| Diagnostic delivery | Motion and preview consumers await a latest-value stream with capacity one. Localization coalesces publication triggers and sends at most 2 Hz. Samples and callbacks are fenced by their owning session/generation; preview also fences viewer epochs. |
| Chat updates | Active-turn indices replace transcript searches per delta. Display updates are coalesced over 40 ms and flushed on completion, Stop and failure. An integer revision replaces full-transcript equality for scroll triggers. Periodic status refresh is scoped to the header. |
| Native preview | Calibration displays a rendered `CGImage` without JPEG encode/decode. Compatible remote previews reuse per-frame render/JPEG results. One preview job is allowed; fresh evidence acquisition prevents new preview work. Renewed AR leases update fps and delivery callbacks. |
| Detector and scoring allocations | Actor-owned output storage is reused. Geometry lookups, inverse tag transforms, board groups and edge sizes are cached by complete tag geometry. Fixed C matrices are read directly. Pose scoring avoids residual-array allocations. |
| Instrumentation | Signposts mark frame copy, tag detection, pose solving, AR image encoding, AVFoundation JPEG encoding, fresh AR evidence capture and inspection requests. No image, transcript or credential contents are included. |

## Explicit behavior corrections

Camera OFF now takes effect locally and survives relaunch even when the server
configuration request fails, matching the existing local OFF intent for motion
and localization. Its new body-scoped preference defaults to ON when absent;
existing saved settings need no migration. Server-confirmed grants/configuration
and the local participation preference remain separate. An explicitly successful
Camera ON clears that local OFF preference.

Capability updates now consistently stop localization together with the other
workers before disconnecting the DEVICE session. An unchanged configuration
refresh does not stop and restart healthy tracking. Configuration responses must
match the expected current embodiment before being applied.

## Validation

- Baseline: 114 unit tests, 22 skipped, no failures.
- Final Debug integration: 124 unit tests (22 skips) and 3 UI tests (2 skips), no failures.
- Release: 124 unit tests, 22 environment-dependent skips, no failures; solver comparison passed.
- Generic physical-iOS Release compilation without signing: passed (arm64); no deployment or signing changes.
- Whitespace checks and unique Xcode source-membership checks pass.
- Vendored AprilTag sources, licenses and provenance are unchanged.

New coverage exercises structured versus prose-only expiry errors, duplicate JSON
keys, identity-scoped settings restoration, immediate local OFF after failed
requests, idempotent reconciliation, bounded channel delivery, response limits,
read cancellation, stale preview callbacks, many Unicode deltas, Stop with buffered
text, changed tag geometry, short image buffers, blocked inspection requests and
late detector results after cancellation.

Tests requiring physical camera, provisioned backend identities or optional live
fixtures retain their existing skip conditions. Those skips are not physical
acceptance results.

## Performance measurement

The reproducible synthetic workload contains two boards and eight tags, fixed
corner noise, 100 explicit warmup solves, 1,000 solves per measurement and ten
measured samples. Before the
allocation changes, each call rebuilt catalog state. The optimized production
path reuses prepared geometry across frames; its benchmark follows that path.
Release uses Swift `-O`, whole-module compilation and `ENABLE_TESTABILITY=YES` for
the hosted tests. The simulator is iPhone 18 Pro / iOS 27.0, hosted on this Mac.

| Path | Mean per 1,000 solves | Relative standard deviation |
| --- | --- | --- |
| Original catalog construction/scoring | 73.63 ms | 9.59% |
| Prepared catalog and allocation reductions | 19.83 ms | 0.73% |

The observed mean reduction is about 73% in this workload. The baseline was built
from repository HEAD `07252dd` in an isolated ignored source directory, with the
same synthetic fixture, warmup and iteration counts injected into its test target.
The earlier ten-solve run was replaced by this longer comparison because the
short measurements were noisy. The two long runs were sequential on the same Mac.

These measurements cover synthetic solving, not camera acquisition, AprilTag
pixel detection, battery use or physical localization accuracy. They are too
narrow to establish an end-to-end speedup. Chat update-count coverage verifies
coalescing without imposing a tight wall-clock threshold in CI.

## Physical acceptance and conditional follow-up

The registered physical iPhone is currently unavailable to `devicectl`; no code
was deployed to it. Physical camera sharing, evidence deadlines, preview quality,
energy and thermal behavior remain to be measured on that phone. The signposts
and workloads in the plan provide the capture points for that acceptance run.

The main-actor luma copy, detector decimation/thread settings, pose iteration
limits and numerical perturbation behavior are retained. A numerical rotation
adjustment failed an existing multi-board accuracy test and was reverted. Any
numerical correction requires its own geometry review and acceptance; it is not
part of the allocation optimization. No physical accuracy gate has been opened.

The connection watchdog also remains: its existing monotonic and wall-clock lease
checks and credential-expiry behavior take precedence over reducing its wakeups.
The full transcript no longer participates in the periodic status timer.

Reproduce offline validation with the README's simulator test command. Release
solver measurements can be isolated with:

```sh
xcodebuild -project home-cortex-apple.xcodeproj \
  -scheme home-cortex-apple-unit -configuration Release ENABLE_TESTABILITY=YES \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .local/OptimizationRelease -parallel-testing-enabled NO \
  -only-testing:home-cortex-appleTests/VisualAnchorTests/testPoseSolverPerformanceWithMultipleBoards test
```

Use a fresh result-bundle path for each saved run. Full result bundles and logs
for this session are retained under ignored `.local/optimization/`.
