Date: 2026-10-07 08:19 PDT
Type: coding
Status: blocked

## Objective
Implement Epic 1.0a developer embodiment inspection without creating a second
perception pipeline, and investigate a preview that appears frozen.

## Context
Apple, backend and GUI share the retained vision-enabled iPhone body. Household
server is fixed LAN 192.168.68.59. Preserve existing provisioning/login work.
Use the repository persistent-llm-work-log skill for this engineering record.

## Findings
Real preview advanced around 2.5 fps at 360×640 while awake. The phone locked in
two attempted runs; old frames became stale and DEVICE lease expired. An initial
SwiftUI screen-awake observer did not prevent the second lock. Final wakefulness
control is directly owned by the preview publisher and follows the viewer lease.
Real slow-consumer, fresh verified evidence and simultaneous chat checks passed.

## Decisions
Keep inspection outside frozen V1 and canonical evidence. Bound all buffering,
authorize explicit people/bodies, share one camera session and prioritize photos.
Do not count short or synthetic tests as the required 30-minute hardware soak.
Do not claim a physical moving scene, final-viewer stop or Wi-Fi recovery without
actual checks.

## Changes
Implemented/deployed separate inspection API/proxy and latest-only relay; explicit
developer allowlist; Apple publisher/shared camera/lease-bound wakefulness; GUI
inspector and canonical evidence button. Added focused validation and deployment
documentation. Installed final signed native build. Report in
[epic1-embodiment-inspector-preview.md](epic1-embodiment-inspector-preview.md).
Unrelated AppIcon sizing, login, provisioning and prior embodiment work preserved.
No keys/tokens/cookies or preview media logged; helpers store sanitized metadata.
Disabled inspection proxy request/response buffering and temporary-file spill,
with bounded in-memory request buffering; production nginx check/reload passed.

## Validation
Backend 1217 passed/1 skipped; GUI 10 passed and build passed. Native full simulator
64 passed/8 expected skips; final focused inspection tests pass, including UIKit
idle-timer assertions. Signed phone install and iPad Release build passed. Actual
slow-browser reads skipped intermediate frames with recent capture times. Actual
Capture Evidence verified a fresh photo; chat baseline/active latency comparable.
Virtual 9000-frame bound test retained one frame with zero net traced growth.
See report for exact measured values and distinction from physical acceptance.

## Remaining Issues
Phone currently reports locked. Final publisher-controlled wakefulness needs
hardware verification. Moving-scene confirmation, uninterrupted >=30-minute soak,
actual last-viewer publication stop and actual Wi-Fi interruption/recovery pending.

## Recommended Next Step
With phone unlocked and Home Cortex foreground, restart preview and complete the
remaining physical acceptance. Update report/log only with observed results.
