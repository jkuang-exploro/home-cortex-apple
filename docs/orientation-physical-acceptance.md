# Physical iPhone orientation acceptance

Requires unlocked connected iPhone 12 mini, household Wi-Fi and an authenticated
Home Cortex CALLER/DEVICE. These tests preserve the established embodiment and
restore its original motion selection after the lifecycle and Wi-Fi trials.
They exercise actual production routes; do not run unattended.

Run from the home-cortex-apple repository. Run each trial separately in scheme `home-cortex-apple-unit`, destination
`platform=iOS,id=00008101-000A18C011E8001E`, with
`-parallel-testing-enabled NO -collect-test-diagnostics never`.
Use a unique result bundle and `-only-testing:` for the named method.

| Test in `home-cortex-appleTests/PhysicalMotionTests` | Operator action |
| --- | --- |
| `testNativeInspectorLifecycleAndNonInterference` | Keep phone stationary and app foreground. Verifies native gravity convention, timestamps, actual inspector publication, camera preview, chat, fresh vision.observe, lifecycle reference resets, DEVICE reconnect and OFF. Prints measured rate and stationary angular span; acceptance requires reviewing stability, not only timestamps. |
| `testPhysicalYawPositive90` | Start portrait, display toward you. Wait for “MOTION ROTATION READY”. Keep top edge upright; turn display normal toward your right by about 90°. Positive rotation about body +Z. |
| `testPhysicalPitchPositive90` | Start portrait, display toward you. Wait for READY. Tilt top edge toward you so display faces down by about 90°. Positive rotation about body +Y (viewer-right). |
| `testPhysicalPitchNegative45` | Start portrait, display toward you. Wait for READY. Tilt top edge away by about 45° so display faces partly upward. Negative rotation about body +Y. |
| `testPhysicalRollPositive90` | Start portrait, display toward you. Wait for READY. Rotate in display plane so top edge moves to your left by about 90° (counterclockwise from your view). Positive rotation about body +X (display outward). |
| `testPhysicalCombinedRotation` | After READY, rotate around several axes. At least two displayed Euler axes must exceed 30°; each sample's quaternion must match its Euler reconstruction. |
| `testPhysicalWiFiMotionRecovery` | After “MOTION WIFI INTERRUPTION READY”, turn Wi-Fi off for about 15 seconds, then on, and return to Home Cortex. Verifies replacement CALLER/DEVICE sessions, same body, new local reference, and a fresh inspector sample bound to the new session. |

Return the phone to its initial portrait orientation before each axis trial.
Axis trials use quaternion distance, with a 20° human-operation tolerance,
and require eight consecutive stable samples near the target; this is a functional sign/axis check, not calibrated p95 accuracy.
At pitch ±90°, Euler yaw/roll may become singular; the quaternion comparison
remains valid. These tests never submit local attitude to telemetry.orientation.

Also review the production GUI while Motion & Orientation is ON: local reference
UUID, actual angles, quaternion, measurement age and uncertainty unknown must
appear separately from “Household orientation — unavailable / not calibrated”.
Check ordinary production UI toggle OFF/ON and force-quit/relaunch. Capture
stationary span and actual publication Hz before declaring physical PASS.

The harness keeps the screen awake during trials. A Wi-Fi interruption also breaks
wireless Xcode connectivity; use a USB-connected test runner or an independent
server-side authorized inspector probe for H. The latter must observe absent old
diagnostics, a replacement DEVICE session, the same body, a new reference UUID,
and fresh samples bound to that replacement session. Never count tunnel failure
or an operator confirmation alone as a successful recovery measurement.
