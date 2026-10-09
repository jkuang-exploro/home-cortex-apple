# iPhone orientation foundation

The supported initial body is the iPhone 12 mini with rear built-in wide-angle
camera. This convention is `iphone.body.v1`.

## Body frame and mathematical convention

The origin is the nominal geometric center of the phone's rectangular body box.
It is not an optical center or an IMU position measurement. With the phone in
portrait and the display facing the viewer:

| Body axis | Physical direction | Apple device components |
| --- | --- | --- |
| +X | Outward through display | (0,0,1) |
| +Y | Viewer-right edge | (1,0,0) |
| +Z | Top edge | (0,1,0) |

X cross Y is Z: right handed. Earlier documentation said viewer-left; that
combination was left handed. The stored generic forward/left/up numeric basis
(+x,+y,+z) is unchanged. Embodied left when facing outward corresponds to the
viewer's right. No numeric pose migration is claimed.

Active Hamilton quaternion q(R←B) maps vectors expressed in body B into reference
R. Arrays are [x,y,z,w]. Compose rightmost first:
`q(R←B) = q(R←A) * q(A←B)`. The Apple-from-body basis quaternion is
`[-0.5,-0.5,-0.5,0.5]`. Euler values are intrinsic ZYX:
`q = qZ(yaw) * qY(pitch) * qX(roll)`, radians. Euler angles are a display
parameterization; near pitch ±90° they are ambiguous. Use the quaternion for
composition, interpolation and physical rotation comparisons.

Core Motion supplies its fused device-motion attitude, not separately integrated
raw sensors. We use `xArbitraryZVertical`: native Z is vertical, its horizontal
heading is arbitrary, with no north/household claim. A runtime gravity residual
check verifies q(R←A) rotates the device gravity vector toward (0,0,-1).
This is a convention/availability check, not a quantitative accuracy estimate.

Each start uses a new `motion:<UUID>` and saves the first q(R←B). The displayed
local quaternion is `inverse(q(R←B_initial)) * q(R←B_current)`. Thus reference
L0 is the initial body orientation. Native vertical-reference body quaternion is
also transmitted, with the explicit `xArbitraryZVertical` name. L0 is generally
not gravity aligned. Identity means the initial orientation, never household
north. Network session changes, foreground restarts and ON/OFF restart the frame.

## Camera-to-body extrinsic status

`T(B←C)` is **incomplete**. The rear main camera's nominal viewing direction is
body -X. Its optical center is displaced from the body origin; that metric
translation has not been measured and is unknown. Exact optical rotation,
lens alignment, image orientation and intrinsics are uncalibrated.

Apple documents ARKit camera coordinates as right handed, looking along -Z,
with fixed device-relative axes regardless of UI orientation. In its documented
landscape-left convention +X is along the phone toward its bottom, +Y upward,
and +Z out of the display. For the body convention above, the nominal mapping
is C_X→-B_Z, C_Y→B_Y, C_Z→B_X (a +90° rotation about B_Y). This is a documented
ARKit convention, not a measured transform for our capture pipeline.

The current AVFoundation capture normalizes JPEG image orientation and does not
produce an ARKit optical frame. Therefore the nominal ARKit rotation must not
be applied to JPEG pixel axes as if calibrated. No full extrinsic is returned
by runtime and no guessed camera offset is stored. Epic 1.2 must measure the
camera optical center/rotation and establish the actual image-frame mapping.

## Transport, consent and uncertainty

The same inspection relay carries camera and motion leases independently.
DEVICE mTLS, exact body/session binding and `orientation.local` inspection grant
are required. Viewers require the existing per-person/body inspection permission.
Latest diagnostic only, acquisition target 10 Hz, uploads at most 10 Hz with one
in-flight request, relay capped at 10 Hz. Samples older than 300 ms on the phone
are dropped; the relay rejects capture age over 1 second and expires cached
values after 2 seconds. No replay, facts, evidence promotion, LLM call or durable
motion store. Viewer leases expire after 12 seconds.

User selection is distinct from server grants and native hardware availability.
The app declares NSMotionUsageDescription as Apple documents for motion access.
It does not invoke activity/pedometer authorization or synthesize a Motion & Fitness
permission prompt for the direct device-motion API.
Motion runs only in the foreground and stops on OFF even if the network change
fails. Missing/stale native samples and a failed gravity check are unavailable;
Core Motion does not supply the required per-axis p95, so uncertainty is unknown.

## Canonical orientation

Frozen V1 accepts only household-scoped synthetic/validated orientation with real
producer-supplied per-axis p95. It projects an orientation component in the
existing spatial presence owner, without making position or pose. Read states
are CURRENT (fresh, same active session and available source capability),
LAST_KNOWN (valid but not currently authorized/online), STALE (age >2 seconds),
and UNAVAILABLE (no sample/newest no_estimate). Last valid estimate is retained
separately. A new no_estimate suppresses current state, not the last-known value.
Newest measurement time wins between orientation-only and pose components;
full pose wins an equal-time tie. Updating orientation never changes stored pose
position. Durable orientation projection occurs after journal commit. Restored
samples retain their old session and cannot become CURRENT under a new session.

## Apple sources

- [Processed device motion](https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data)
- [CMMotionManager](https://developer.apple.com/documentation/coremotion/cmmotionmanager)
- [CMAttitude](https://developer.apple.com/documentation/coremotion/cmattitude)
- [xArbitraryZVertical](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe/xarbitraryzvertical)
- [ARCamera transform](https://developer.apple.com/documentation/arkit/arcamera/transform)

Epic 1.2 remains responsible for household alignment and its uncertainty strategy,
calibrated camera extrinsics, and physical canonical orientation acceptance.
