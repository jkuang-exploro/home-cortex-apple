# Epic 1.0a — Embodiment Inspector and Ephemeral Live Camera Preview

Status: implementation deployed; physical acceptance incomplete.

## Implementation

- Separate `/inspection/v1` API, HTTP GUI proxy and TLS 1.3/mTLS DEVICE proxy.
  Frozen V1 operations/capability vocabulary remain unchanged by inspection.
- Explicit `CORTEX_INSPECTION_PERMISSIONS` person/body allowlist, default deny.
  Existing GUI signed session/bearer identity or mapped software CALLER with live
  owned session authenticates viewers. DEVICE publishing requires its own body,
  live owned session, existing vision.observe receive grant, verified certificate,
  and trusted upstream. GUI never receives operator keys or credentials.
- Closed frame: embodiment_id, camera_id, sequence, captured_at, width, height,
  mime_type=image/jpeg, base64 media. Backend adds received_at. Strict integers,
  duplicate/unknown JSON rejection, matching JPEG dimensions, 98,304-byte decoded
  media limit, 140,000-byte body limit, 960-pixel side/518,400-pixel total limit,
  bounded freshness and maximum 5 fps. No evidence ID or semantic annotations.
- In-memory latest-only relay: one frame and sequence fence per subscribed body,
  at most 16 bodies and 64 leases. Viewer leases last 12 seconds and renew every
  4 seconds. Last-viewer expiry clears frames; restart clears all relay state.
  Old DEVICE session frames cannot appear as current-session frames. Inspection
  proxy request/response buffering and temporary-file spill are disabled explicitly;
  body buffering is capped in memory at the route limit. No preview
  database, disk, evidence, history, LLM, fact, or agent writes.
- One shared Apple AVCaptureSession provides low-rate resized JPEG video samples
  and independent fresh photo exposures. Maximum preview side 640 pixels; the
  portrait iPhone delivered 360×640. One latest-only mailbox, one upload in flight,
  no preview retries; stale/error samples drop. Canonical photo capture skips
  preview encoding until completed. Chat, commands and heartbeat remain separate.
- Apple preview only follows authorized viewer demand while foreground/runtime
  active, with a local expiry watchdog and Pause Developer Preview. Background,
  session loss, expiry and local pause stop capture. Active publication sets the
  UIKit idle timer directly; stopping restores normal locking. The first SwiftUI
  wakefulness implementation did not prevent the observed lock and was replaced.
  Final publisher-controlled setting is tested and installed, but its hardware
  wakefulness behavior still needs an uninterrupted physical check.
- Existing GUI Embodiments detail contains Start/Pause, 2/3/5 fps selection,
  freshness overlay, capture/receipt time, frame age, sequence, observed frame
  rate, canonical DEVICE session/age/lease/version/capabilities. Pause freezes the
  image as PAUSED; offline/failure/aged frames become STALE. Hidden/disposed pages
  release leases. Reconnection resets measured-rate comparison across sessions.
- Capture Evidence posts an empty request to the canonical ObservationExchange,
  dispatches real vision.observe, awaits a fresh DEVICE exposure and verification,
  and displays only canonical metadata. Preview media cannot be promoted.

## Deployment

API, GUI and proxy were deployed at 192.168.68.59, with an explicit developer
allowlist for the retained iPhone body. Existing CA, provisioning identities,
CALLER/DEVICE distinction, canonical body/agent association and unrelated login
changes were preserved. The latest signed iPhone app is installed. No Tailscale
routing is required. No credentials, camera preview media, or GUI cookie were
written by the hardware-check helpers; only sanitized metrics were retained.
Canonical evidence from an explicit Capture Evidence operation follows its normal
persistence policy.

Inspector:
http://192.168.68.59/embodiments/embodiment%3A9439ee2fd3be49e99c4e21004ccfe208

## Validation

| Acceptance | Result | Evidence |
| --- | --- | --- |
| A — recognizable moving preview | Partial | User saw an image but reported it stopped updating. Actual frame sequences increased at about 2.5 fps while awake; moving-scene confirmation after the fix remains pending. |
| B — >=30-minute physical memory run | BLOCKED | Two short real runs stopped when the phone locked. They do not establish the required uninterrupted run. |
| C — slow consumer | PASS | Real iPhone/production GUI: delaying each browser frame read by 2.5 seconds skipped 5–7 intermediate frames; displayed ages were 86–536 ms, with no browser errors or accumulated backlog. |
| D — last inspector closes | Partial | Deterministic lease deletion/expiry and native expiry-watchdog tests pass; actual last-viewer hardware stop remains unverified. |
| E — canonical evidence | PASS | Actual GUI Capture Evidence produced new verified iPhone photo evidence, with capture time later than the displayed preview. |
| F — chat regression | PASS | Actual 老管家 chat returned successfully before and during preview with comparable response times. |
| G — Wi-Fi reconnect | BLOCKED | Actual phone Wi-Fi interruption/restoration has not been performed. |

Real observations:

- Initial preview captured 2026-10-07T07:41:37.971Z; relay received
  07:41:38.104Z: 133 ms capture-to-relay, 128 ms sampled UI frame age.
- Initial fresh evidence captured 07:41:41.618Z and VERIFIED as
  evidence:49d695ba95ea6cf406b572cc28181121; 3.647 seconds after the compared preview.
- Second run preview captured 07:51:26.660Z; received 07:51:26.919Z: 259 ms.
  Fresh evidence captured 07:51:27.584Z and VERIFIED as
  evidence:ba3c99b66baf5ed3dd03f4327a65017f, independent of preview bytes.
- First baseline/active chat: 2699/2619 ms. Second: 2748/2724 ms.
- Second short run: sequence 1 to 212, about 2.5 fps at target 3 fps; sampled
  frame ages mostly 346–801 ms. API RSS was 100,260 KiB at start and 100,600 KiB
  at 64 seconds. These are short-run observations, not 30-minute memory proof.
- Separate synthetic virtual-30-minute/5-fps relay test processed 9000 maximum-size
  envelopes, retained exactly one frame/fence/lease, measured 0-byte net traced
  allocation growth and 239,158-byte peak. It supports structural bounds but is
  explicitly not a physical soak.

Automated checks:

- Full deterministic backend: 1217 passed, 1 skipped; five inspection tests cover
  authentication, scope, closed/bounded frames, memory/lifetime, canonical evidence
  exchange, GUI session and denied routes. Ruff and diff whitespace checks pass.
- Full native simulator: 72 tests, 64 passed, 8 expected skips, zero failures.
  Four focused inspection tests pass after the final wakefulness change, including
  actual UIApplication idle-timer set/reset assertions, no-viewer behavior,
  foreground stop, local pause and network-independent lease expiry.
- GUI: 10 tests pass, production build passes. Synthetic desktop/mobile browser
  checks verify controls, intentional freeze, separate evidence request, no overflow,
  and no JavaScript errors. Synthetic imagery was only for isolated UI/protocol QA.
- Signed physical build/install passes; latest iPad simulator Release build passes.
  Production API/GUI builds and nginx configuration/reload pass, including the
  final inspection-only no-disk-buffering configuration.

## Known limitations and next check

The relay requires one API worker. Mobile capture requires foreground camera
permission and the vision-enabled DEVICE grant. Deliberate locking/backgrounding
must stop preview even with idle locking disabled. The inspector truthfully retains
old images only with stale/paused labeling; it does not perform automatic reasoning.

Unlock the phone and keep Home Cortex open, refresh the signed-in inspector and
start preview. Confirm a recognizable scene changes as the phone moves, then run
an uninterrupted >=30-minute memory check. Pause/close every inspector and confirm
publication stops after the final lease. Interrupt/restore actual Wi-Fi and confirm
same-body DEVICE recovery and new preview frames. These physical checks remain
explicit blockers; no PASS is claimed for an interrupted or synthetic soak.

EMBODIMENT INSPECTOR LIVE PREVIEW: BLOCKED
