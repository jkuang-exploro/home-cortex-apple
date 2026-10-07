Date: 2026-10-06 22:47 PDT
Type: coding
Status: partial

## Objective
Implement Epic 3B.3a: optional persistent iPhone embodiment, independent DEVICE credential and V1 session, while retaining the existing null-body CALLER chat principal.

## Context
The operator host is reached directly on the fixed household LAN. Existing GUI sign-in, original public CA, caller identity, and conversation implementation are retained. Applied the backend repository persistent work-log skill. The user explicitly selected Enable and attempted invitation import; the initial alert-to-Files presentation did not open reliably.

## Persistent identity and association
Created one canonical `handheld` body, `embodiment:9439ee2fd3be49e99c4e21004ccfe208`, using the existing EmbodimentWritingService, and persisted its canonical `assigned_to` association to `agent:butler`. Its opaque random ID is unrelated to IP, hostname, Apple identifiers, or sessions. Retain the public operator profile `.local/provisioning/iphone-embodiment.json` and its operator-host copy for invitation regeneration. Registration, reconnect, disable, and revocation never create, assign, delete, or unassign the body.

The nominal intrinsic rigid box is x=0.010 m thickness, y=0.075 m width, z=0.150 m height, with zero center. Local forward +x points outward through the display, left +y toward the left edge, up +z toward the top. This uses the canonical geometry/frame schema, without global pose or measured localization. Configured and advertised physical capabilities are empty.

## Provisioning and authority
Added supported backend `grant-device-provisioning` and `invite-device` operator commands. The first verifies the existing canonical body and provisioner, takes a protected backup, adds only that body's provisioning grant, and preserves prior identities/grants/CA. Run it with the API stopped to prevent concurrent single-snapshot writes. Production setup ran as the operator UID and the API was restarted. The invitation command uses trusted TLS 1.3 and the existing pairing protocol, creates an exclusive owner-private output, rejects expanded/mismatched authority, and prints no token.

The Mac helper `scripts/create_device_invitation.py` reuses the retained profile and fixed LAN host. Import requires explicit Enable → Import DEVICE invitation → Files selection. DEVICE accepts only the full closed V1 invitation with the expected origin, DEVICE purpose, non-null typed body, and exactly `{embodiment_id: BODY_ID, verb: session, capability: null}`. No sensor, admin, conversation, or provisioning grants are given to DEVICE. The bundled public CA and LAN configuration handle enrollment trust. No private CA/client key was copied to the Mac or embedded in the app.

Production readback confirmed independent DEVICE `client:bbed5705f01541f4` / `client_credential:bbed5705f01541f4`, bound to the retained body, unrevoked, with only that session grant. The original CALLER was not converted. Consumed Mac/operator invitation files were removed; the phone Files copy should also be deleted.

## Credential and session separation
CALLER keeps its original `.v1` Keychain namespace; DEVICE uses `.v1.device`, its own generated key tag, certificate/client ID, pending CSR, rejection status, and runtime preference. Role and exact namespace ownership are checked on load/save/key lookup/deletion. Existing CALLER JSON remains compatible. Physical generation requires P-256 Secure Enclave; simulator uses its existing permanent Security/Keychain implementation. No key/certificate/client ID is reused.

The DEVICE wrapper owns a separate ConnectionController and never supplies conversation access. Every DEVICE request/response/session target is checked against its body and client. Both principals independently register, heartbeat, renew leases, reconnect, fence replacement, and handle authentication rejection using server timing. The DEVICE manifest is revision 1 with an empty physical capability list.

## iOS and disable behavior
Opt-in participation is durable and defaults to false; installation, caller sign-in, and launch do not enable DEVICE. Embodiment Enabled means the retained body/credential exists. Runtime Online additionally requires enabled participation and a current authenticated ACTIVE lease. Background invalidates in-flight work and local leases; foreground reconnects enabled runtime with the same persistent identity. Network failure/restart/replacement clears live state and reconnects with fresh fencing. Normal iOS suspension is respected.

Disable disconnects only DEVICE and persists disabled participation across relaunch. Its key/certificate/body and canonical association remain. CALLER chat/sign-out is independent. Server DEVICE revocation rejects that principal while retaining the canonical body/association; caller revocation does not mutate the body.

## File-picker correction
Replaced the Enable alert → fileImporter transition with a dedicated Enable Embodiment setup sheet containing its own fileImporter. This avoids competing presentation/dismissal. The UI test verifies actual Files presentation and both cancellation steps, before and after relaunch. The corrected build was installed on the physical iPhone; production enrollment subsequently succeeded.

## Validation
- Backend complete deterministic suite: 1,209 passed, 1 skipped (`.local/3B3a-backend-full.log`). Final operator-focused suite after helper refactoring: 21 passed (`.local/3B3a-operator-final.log`).
- Backend tests cover canonical body/assignment persistence across runtime recreation, dual principals, empty manifest, DEVICE chat/admin denial, role substitution, independent revocation, lease expiry/replacement/fencing, exact grant preservation, and invitation authority/output safety.
- Apple full simulator unit suite: 56 tests, 50 passed, 6 expected optional/live/physical skips, zero failures (`.local/3B3aFinalUnit.xcresult`). After final key-namespace hardening, Security + Embodiment: 11 passed (`.local/3B3a-key-isolation.log`).
- Final simulator Files/setup/cancel/relaunch regression: 1 passed, zero failures (`.local/3B3aPickerFixedUI.xcresult`). The earlier picker test incorrectly queried Browse/Recents as navigation identifiers; corrected to the observed Files accessibility hierarchy.
- Signed iPhone Debug build/install and physical-test compilation succeeded. Final iPad Release build succeeded (`.local/3B3a-ipad-final.log`). Project plist lint and both repository diff checks passed; project dictionary ordering was restored without semantic changes.
- Final production image build/recreation and canonical body/association/least-privilege enrolled DEVICE readback succeeded. Trusted fixed-LAN bootstrap discovery returned HTTP 200 with the original CA and TLS 1.3 after deployment. Existing runtime dispatch has no Apple-specific branch.

## Physical acceptance and blockers
The server confirms real DEVICE enrollment after the picker fix, but this alone does not prove the phone holds the expected Secure Enclave key or maintains an ACTIVE session. Prepared `PhysicalEmbodimentTests` checks real independent keys/certificates/sessions, direct DEVICE chat denial, caller history during DEVICE disable, credential reload, and foreground recovery.

The phone relocked between the unlock check and Xcode test launch. The waiting run was cancelled so it cannot unexpectedly take over the phone later. No successful physical dual-principal test, pre-enable chat acceptance, force-quit/session comparison, Wi-Fi interruption/recovery, or production DEVICE revocation/caller-chat acceptance is claimed. Automated simulator/backend coverage does not substitute for those physical checks. The enrolled DEVICE has not been revoked.

## Known limitations and recommended next step
No physical capability, camera, microphone, telemetry, location, orientation, or pose implementation is present. Native credential rotation/replacement and destructive body removal are outside this ticket. Operator invitation files expire in ten minutes and must be regenerated using the same retained profile. Deleting local invitation copies does not revoke the credential.

Keep the phone unlocked with Home Cortex open, confirm Enabled/Online, run the prepared physical dual-principal test, then coordinate force-quit, Wi-Fi recovery, and exact DEVICE-only revocation with caller chat verification. Update this report with actual observations before marking the whole ticket passed.

APPLE IPHONE EMBODIMENT IDENTITY: BLOCKED
