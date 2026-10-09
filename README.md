# Home Cortex for Apple

`home-cortex-apple` is an independent native Swift/SwiftUI iPhone and iPad client. Its project and main shared scheme are named `home-cortex-apple`; the installed app is **Home Cortex**. It uses Client Interface V1 for provisioning/session control and the canonical Home Cortex conversation API over the same mTLS identity.

Sign in with the same email and API key as `home_gui`. The app verifies the household server using its bundled public CA, generates a device-held key, and automatically requests its client certificate. It then authenticates with mTLS and registers/renews a software-only CALLER session. **Connected** requires an authenticated, ACTIVE session with a valid lease. The provisioned app opens a native 老管家 conversation screen. You can separately opt in to an iPhone embodiment with an independent DEVICE credential and session. Its first optional physical capability is a fresh rear-camera still through `vision.observe`. Session/chat requests use mTLS.

## Build and run

Prerequisites: Xcode 16.4 or newer, Swift 6, an installed iOS simulator runtime, and iOS/iPadOS 17.0 or newer. Current validation uses Xcode 27.0 / Swift 6.4. Real enrollment needs the deployed household service and the same mapped email/API key used by Home Cortex web.

```sh
open home-cortex-apple.xcodeproj
xcrun simctl list devices available
xcodebuild -project home-cortex-apple.xcodeproj -scheme home-cortex-apple \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .local/DerivedData build
```

Use a simulator installed on your Mac. In Xcode, select the main scheme and an iPhone or iPad destination, then Run (⌘R).

## Configuration and trust

The installation bundles `Resources/Household.json` and the original **public** household CA in `Resources/HomeCortexCA.txt`, for both Debug and Release:

```json
{
  "server_endpoint": "https://192.168.68.59:8443",
  "bootstrap_endpoint": "https://192.168.68.59:8444",
  "server_hostname": "192.168.68.59",
  "protocol_version": "1.0"
}
```

Connect the phone to the household Wi-Fi and allow Home Cortex local-network access (Settings → Apps → Home Cortex → Local Network). The client connects directly to the fixed LAN IP; it needs no Tailscale connection or DNS. All requests use TLS 1.3, the bundled CA, and certificate IP SAN verification. No system CA installation or manual CA import is required for sign-in.

Tap **Sign in**, enter the web email/API key, and keep the app open during enrollment. The key is cleared from the field on submission, used only for the HTTPS login request, and never stored. The server issues a ten-minute, software-only invitation internally; the phone generates its Secure Enclave key/CSR and requests its certificate automatically. Subsequent sessions and chat use the device certificate. The server binds the new client to the same mapped household person; removing/remapping that GUI identity removes this conversation permission.

Existing credentials using `home-cortex-0` automatically migrate to the LAN endpoint only when their trusted CA matches the bundled CA. Their key, certificate, client ID, expiry, and rejection status are preserved. The server certificate retains the old DNS SAN and adds `192.168.68.59` as an IP SAN using the original CA/server key.

**Sign out** deletes the local device identity/key; the next sign-in obtains a new credential. Local sign-out does not revoke the server credential. **Advanced connection setup** retains manual configuration, CA import, discovery, and operator-invitation enrollment for maintenance. Imported origins must be HTTPS with a matching DNS hostname or valid IPv4 address and no credentials, paths, query, or fragment.

Discovery uses `GET /client-interface/v1/discovery` on **8444** before enrollment and requires protocol `1.0` / envelope schema `1`. Compatible discovery alone never means Connected. Authenticated discovery/session messages use **8443**, which requires mTLS. The deployed proxy deliberately rejects enrollment on 8443.

## Use this iPhone as an embodiment

Open **Home Cortex → Embodiment → Continue → Choose Agent → Choose Sensors → Confirm**.
The server supplies the agents and sensors you are allowed to configure. Camera is
currently the only implemented sensor. If selected, iPhone asks for camera access
after confirmation. Setup continues when access is denied; Camera remains selected
and shows unavailable until permission is restored in iPhone Settings.

The app enrolls automatically with a separate phone-held DEVICE key and certificate.
Chat continues through its existing CALLER identity. No Files, invitation JSON,
AirDrop, SSH or certificate handling is needed. **Online** means the DEVICE has an
ACTIVE session with a valid lease. Failed or interrupted setup offers **Resume
Setup / Retry Saved Setup**, reusing the saved setup ID and exact Keychain CSR.
Start a new attempt only after the server confirms the previous pending attempt
expired; an issued or committed attempt must be recovered instead.

After setup, **Embodiment Enabled** stops/resumes the physical runtime while retaining
the phone's identity, agent association and sensor choices. **Camera** updates the
backend authority/configuration without re-enrollment. OS permission is a separate
layer: disabling camera permission in Settings does not turn the Home Cortex
preference off. Existing manually provisioned DEVICE credentials open this same
production screen; an operator-verified backend ownership mapping permits ongoing
management without creating a duplicate body.

The ordinary UI hides manual invitation import. Debug builds retain it inside
**Developer / Recovery Provisioning**; the instructions below are advanced recovery
only. A deliberate server retirement API exists, but a normal-user removal UI is
not yet provided. Enabled OFF never retires or revokes anything.

Deployment/policy/API details are in the backend's
`docs/embodiment-self-provisioning.md`. Acceptance evidence is in
[the development report](.llm/epic3b-production-embodiment-provisioning.md).

## Developer / Recovery Provisioning — CALLER

The provisioner must be authorized for **`embodiment_id: null`**. Epic 3B.1a added that specific provisioning grant to the deployed existing operator, preserving its identity, certificate, and previous MacBook grant. Future deployments can use the backend's `grant-software-provisioning` offline maintenance command; stop the API, take its protected backup, apply the grant, and restart. Do not grant the phone an embodiment or vision permissions to bypass a restriction.

For this development server, create and copy the invitation from the Mac with:

```sh
python3 scripts/create_software_invitation.py
```

This calls the supported backend `invite-software` CLI over SSH and writes `.local/provisioning/apple-invitation.json` with mode 0600 in an ignored 0700 directory. It refuses to overwrite an existing invitation. AirDrop the file to iPhone Files, then select it with **Provision Client**. Keep the app open and phone unlocked. The token expires in ten minutes; if expired, delete both temporary copies and create a fresh invitation.

The equivalent operator-host command is:

```sh
cd /home/jkuang/Workspace/home-cortex
PYTHONPATH=src .venv/bin/python -m scripts.maintenance.client_interface invite-software \
  --root /home/jkuang/.local/share/home-cortex/client-interface \
  --output /home/jkuang/.local/share/home-cortex/client-interface/provisioning/apple-invitation.json
```

For operators using the existing pairing API directly, this example writes the token-bearing response to a private file and never prints it:

```sh
umask 077
OPERATOR_ROOT=/home/jkuang/.local/share/home-cortex/client-interface/operator
INVITATION_FILE=/home/jkuang/.local/share/home-cortex/client-interface/apple-invitation.json
curl --fail-with-body --silent --show-error --tlsv1.3 --proto '=https' \
  --max-redirs 0 --max-time 10 \
  --cacert "$OPERATOR_ROOT/ca.crt" \
  --cert "$OPERATOR_ROOT/client.crt" --key "$OPERATOR_ROOT/client.key" \
  --header 'Content-Type: application/json' \
  --data '{"operation":"create","embodiment_id":null,"purpose":"CALLER","grants":[{"embodiment_id":null,"verb":"session","capability":null}],"expires_in_s":600}' \
  --output "$INVITATION_FILE" \
  https://home-cortex-0:8443/client-interface/v1/pairings
```

Transfer that JSON and the public CA to the phone through an operator-controlled channel. Tap **Provision Client** and select the invitation. The app accepts the exact pairing response above or the existing compact CLI format `{invitation_id, token, bootstrap_endpoint, embodiment_id}` with a null body. Invitations expire within ten minutes. The current MacBook `invite` helper requires a body/vision grants and is unsuitable for this software-only client.

The phone generates a P-256 key in Secure Enclave, signs a PKCS#10 CSR with ECDSA/SHA-256, and posts `{invitation_id, token, csr_pem}` to `/client-interface/v1/enroll` on 8444. The private key never leaves the device. Simulator uses a permanent Keychain-backed key because it has no Secure Enclave. Physical key generation fails visibly if Secure Enclave is unavailable; it does not silently substitute an exportable key.

Provisioning is tracked as Not Provisioned → Invitation selected → Generating device key → Generating CSR → Enrolling → Provisioned, or a visible failure. The screen shows Provisioned separately from connection/session state. Relaunch checks that the matching private key and certificate exist; a remembered client ID alone cannot claim Provisioned. The frozen enrollment response does not include a `purpose` field: CALLER purpose is verified in the invitation and server credential registry, with a null embodiment and exactly one null-body session grant required in the response.

The returned certificate must match the key and chain to the originally supplied CA. The issued client ID, certificate/chain, trusted CA, key reference, configuration, and earliest certificate/registry expiry are stored in device-only Keychain items. Tokens are retained only while provisioning runs. Remove consumed invitation copies from transfer/operator storage; never commit or log them.

Interrupted enrollment retains the exact CSR/key reference without retaining the token. Re-import the same valid invitation to retry. Once provisioned, relaunch reconnects without another invitation. **Sign out** removes the local credential/key and allows another web-credential sign-in or a fresh manual invitation. Forgetting locally does not revoke the server credential; remembering a client ID grants no authority.

After successful enrollment, remove `apple-invitation.json` from iPhone Files and delete the two temporary copies:

```sh
rm .local/provisioning/apple-invitation.json
ssh jkuang@home-cortex-0 'rm /home/jkuang/.local/share/home-cortex/client-interface/provisioning/apple-invitation.json'
```

Provisioning acceptance evidence is recorded in [.llm/epic3b-provisioning.md](.llm/epic3b-provisioning.md).

## Session lifecycle

`POST /client-interface/v1/messages` carries `session.register`, `session.heartbeat`, and `session.disconnect`. Registration always sends a null embodiment, manifest revision 1, and an empty capability array. Implementation metadata is diagnostic only.

Connection states: unconfigured, provisioning, disconnected, discovering, authenticating, registering, connected, reconnecting, and failed. Discovery is tracked separately. Accepted responses must match the request ID, operation, target, protocol/schema, principal, and session fence.

Heartbeat/lease timing comes from the server. A monotonic watchdog accounts for round-trip time, server/local expiry, and a safety margin. Network loss clears Connected and retries with bounded backoff. Stale/expired fences and backend restart trigger fresh registration. REPLACED stops automatic retry until explicit Connect. Revocation/authorization rejection clears the session and persists a re-provisioning requirement.

Backgrounding clears local ACTIVE authority and stops workers. iOS can suspend the app; the server lease expires naturally. Foregrounding re-registers when reconnection was requested. Explicit Disconnect clears local authority immediately and sends a best-effort disconnect. Generation/cancellation fences prevent late replies from restoring an old session.

## Tests

Product → Test (⌘U), or:

```sh
xcodebuild -project home-cortex-apple.xcodeproj -scheme home-cortex-apple \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .local/DerivedData -resultBundlePath .local/V1Tests.xcresult \
  -parallel-testing-enabled NO test
```

Use a fresh result-bundle path each time. Tests cover configuration, strict versions/closed JSON, backend golden vectors, response correlation, leases, expired/rejected metadata, restart/reconnection/replacement/revocation, stalled requests, CSR signatures, Keychain retry persistence, CA/hostname/expiry rejection, and fresh-client UI/relaunch. UI tests use an isolated Keychain service and never delete real credentials.

Physical hosted unit tests can use `home-cortex-apple-unit`, which excludes the separate UI runner:

```sh
xcodebuild -project home-cortex-apple.xcodeproj -scheme home-cortex-apple-unit \
  -configuration Debug -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  -derivedDataPath .local/DeviceDerivedData -parallel-testing-enabled NO test
```

The full physical UI target needs its own runner provisioning profile. Refresh the Apple account locally in Xcode if profile creation reports a rejected login. Do not share passwords/signing keys.

`LiveDiscoveryTests` is optional and uses the real Debug server without a mock. Copy only the operator's **public CA** to ignored `home-cortex-appleTests/Fixtures/live-ca.txt`, then run the command above with `-only-testing:home-cortex-appleTests/LiveDiscoveryTests`. The test requires compatible trusted discovery while asserting that the app remains unprovisioned. Remove the temporary CA afterward and use a clean derived-data directory for subsequent offline runs. The test skips when that file is absent; never supply a client key, certificate, or invitation as a fixture.

## Physical deployment and acceptance

1. Connect/unlock the iPhone, trust the Mac if prompted, and enable Developer Mode if Xcode requests it.
2. Copy `Config/Signing.example.xcconfig` to ignored `Config/Signing.local.xcconfig`; choose your team ID/bundle namespace and keep automatic signing enabled. Select the team in Xcode if necessary.
3. Run on the iPhone. Stop debugging and launch Home Cortex from its Home Screen icon. Verify Not Provisioned before real enrollment.
4. Connect to household Wi-Fi, allow local-network access, and sign in using web credentials. Verify Connected, Protocol 1.0, Session Active, and Embodiment Not enabled.
5. Force quit/relaunch, background/foreground, interrupt/restore Wi-Fi, and perform a coordinated backend restart. Verify truthful state and fresh session fences on recovery.
6. Have the operator revoke only this Apple client's credential through the backend's documented procedure. The current offline journal procedure requires a coordinated service stop/restart. Verify loss of Connected and the re-provisioning requirement.

Actual results/blockers are recorded in [.llm/epic3b-v1-connection.md](.llm/epic3b-v1-connection.md). Simulator/mock lifecycle success does not establish physical mTLS acceptance.

## Ephemeral developer camera preview

In the signed-in web GUI, open **Embodiments → This iPhone → Start Preview**.
The separate `/inspection/v1` surface requires an explicit backend person/body
allowlist and the phone's live vision-enabled DEVICE session. Choose 2, 3, or 5
target fps. Keep Home Cortex open on the phone; active preview keeps the screen
awake. Locking, backgrounding, or **Pause Developer Preview** stops capture.

The inspector shows real capture/receive timestamps, sequence, frame age, and
canonical runtime metadata. **Pause Preview** freezes the visible image with a
PAUSED label. Closing the last viewer stops publication within its short lease.
One shared rear-camera session supplies modest JPEG previews and independent
fresh canonical photos. Preview frames stay in memory, never become evidence,
and never enter chat, facts, or reasoning. **Capture Evidence** separately invokes
real `vision.observe` and reports the verified evidence ID and capture time.

Implementation and physical acceptance are recorded in
[the inspection report](.llm/epic1-embodiment-inspector-preview.md). Backend
deployment/transport details are in `home-cortex/docs/embodiment-inspection.md`.

## Structure and next milestone

`App/` owns the root/lifecycle, `Features/Connection/` owns the UI, `Core/V1/` owns configuration/protocol/transport/state, and `Core/Security/` owns standard CSR packing, certificate validation, and Keychain storage. Assets, public CA, and non-secret installation configuration live in `Resources/`; shared build settings live in `Config/`. No third-party networking or runtime dependency is required.

Apple references: [device deployment](https://developer.apple.com/documentation/Xcode/running-your-app-on-simulated-or-physical-devices), [server trust evaluation](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication), [custom trust anchors](https://developer.apple.com/documentation/security/configuring-a-trust), and [certificate/key identities](https://developer.apple.com/documentation/security/secidentitycreate(_:_:_:)).

Sign-in and chat validation are recorded in `.llm/epic3b-login.md` and `.llm/epic3b-chat.md`.

## 老管家 conversation

Once provisioned, the app opens native chat. The status beside 老管家 reflects the
actual ACTIVE V1 session. Connection settings remain available through the gear
button. Sending is enabled only while connected and after server history loads.
Enter Chinese or English text in the multiline composer; the original text goes
to the canonical backend unchanged. Replies stream from real SSE events. Stop
closes the existing response stream; the backend may preserve a partial reply.

Automatic sign-in binds the software client to the GUI household person. For manually enrolled clients, the operator maps the client ID using `CORTEX_CALLER_IDENTITY_MAP` on the server. A valid certificate alone does
not grant conversation authority. Chat uses the existing steward runtime whose
entity is `agent:butler`, and never selects an active embodiment.

Only the selected conversation ID is saved locally, scoped by server and client
ID. Transcripts come from Home Cortex on launch/reconnect. V1 session replacement
does not change the selected conversation. After a timeout/interruption, use
**Reload history** before deciding whether to send again. The backend has no send
idempotency key, so uncertain submissions are never retried automatically.
An unsent local failure may expose **Retry**; it has not reached the backend.

Development and physical acceptance evidence: [.llm/epic3b-chat.md](.llm/epic3b-chat.md).

## Developer / Recovery Provisioning — DEVICE

Chat retains its original **CALLER / null embodiment** credential. The optional
physical role uses **DEVICE / one persistent embodiment**, its own Secure Enclave
key/certificate/client ID, and a separate V1 session. DEVICE Keychain items use the
`.v1.device` namespace; key tags, response targets, enrollment grants, and session
principals are checked against the role. DEVICE cannot use household chat/admin
routes. Session-only DEVICE credentials advertise an empty manifest. The explicit
vision upgrade below adds only `vision.observe`; no microphone, telemetry,
location, pose, or actuator capability is implemented.

In a Debug build, open **Embodiment → Developer / Recovery Provisioning →
Import DEVICE invitation** and choose the operator-issued JSON in Files.
Installation, sign-in and app launch do not enable a new embodiment automatically. The bundled household CA/LAN profile handles trust. The phone
creates a new independent key/CSR and uses the existing V1 enrollment endpoint.
A CALLER invitation, null-body DEVICE, unrelated capability grants, or mismatched
origin is rejected before DEVICE key generation. CALLER credentials are never converted.

The operator prepares one canonical `handheld` body with a random opaque ID and
an `assigned_to` association to `agent:butler`, outside session registration.
The public source profile is `.local/provisioning/iphone-embodiment.json`, also
retained on the operator host. **Keep this profile when regenerating invitations**;
reuse the same ID instead of creating a body on every reconnect. Current geometry
is a nominal box in meters: thickness (x) 0.010, width (y) 0.075, height (z) 0.150,
center (0,0,0). Intrinsic +x is outward through the display, +y toward the viewer-right
edge, +z toward the top edge; +x×+y=+z. The former viewer-left description
was left-handed and has been corrected; the numeric local_frame basis remains unchanged. This establishes only a body frame,
not a global pose or measured localization. Adjust the operator-owned geometry
if a measured bounding box is required later.

For a new deployment, generate and retain a random opaque `embodiment:<uuid>`
profile using the canonical schema above. Against the configured backend DB,
use `scripts.maintenance.embodiments create PROFILE.json`, then `assign BODY_ID
agent:butler`. The existing provisioner needs one additional **provision** grant
for that exact body. Stop the API before applying the offline journal change:

```sh
python -m scripts.maintenance.client_interface grant-device-provisioning \
  --root /operator --embodiment-id BODY_ID \
  --backup-file /operator/maintenance/before-device-grant.json
```

Run in the configured one-off API container as the operator UID with its protected
V1 directory mounted at `/operator`, then restart the API. The command checks the
existing body and valid provisioner, preserves its certificate/key and other
grants, creates a protected backup, and never prints credentials. See backend
`docs/client-interface-deployment.md` for the complete Compose commands.

For the prepared development phone, regenerate an invitation from this Mac:

```sh
python3 scripts/create_device_invitation.py
```

It connects directly to `jkuang@192.168.68.59`, reuses the persistent profile,
invokes `invite-device`, and writes the full V1 invitation to ignored
`.local/provisioning/iphone-device-invitation.json` with mode 0600. It refuses to
overwrite copies. Invitations expire in ten minutes. AirDrop to iPhone Files,
then import through the explicit enable control. Delete consumed/expired
invitation copies on phone/Mac/server; retain the public persistent profile.
The equivalent operator command is:

```sh
PYTHONPATH=src .venv/bin/python -m scripts.maintenance.client_interface invite-device \
  --root /home/jkuang/.local/share/home-cortex/client-interface \
  --embodiment-id BODY_ID --endpoint https://192.168.68.59:8443 \
  --output /home/jkuang/.local/share/home-cortex/client-interface/provisioning/iphone-device-invitation.json
```

The DEVICE invitation/credential has exactly one body-bound **session** grant
and no physical capability grants. **Enabled** means the persistent DEVICE
identity is provisioned; **Online** requires its own authenticated ACTIVE session
with a live lease. Backgrounding, network loss, expired lease, revoked credential,
or backend restart makes runtime offline while retaining the embodiment and
association. Foreground/reconnect registers a fresh fence using the same identity.
REPLACED stops automatic retries; reconnect explicitly. Timing and heartbeat
intervals come from the server. Neither runtime engine keeps a false Connected
label after its lease expires.

**Disable Embodiment Runtime** clears local authority, disconnects only DEVICE,
and persists local participation as disabled. It retains the key/certificate,
body, and association across relaunch. **Enable Embodiment Runtime** resumes
participation. Signing out or revoking CALLER does not erase DEVICE; the DEVICE
section remains accessible from the sign-in screen's Advanced connection setup.
No destructive body removal is provided. Revocation remains the existing operator
V1 procedure, scoped to the exact DEVICE credential ID; coordinate a service
restart for its offline journal mutation. A revoked DEVICE needs operator
re-provisioning before participating again; this ticket provides no automatic
certificate rotation or credential replacement UI.

Validation and physical acceptance status:
[.llm/epic3b-iphone-embodiment-identity.md](.llm/epic3b-iphone-embodiment-identity.md).


## Developer / Recovery Provisioning — Camera upgrade

Vision uses only the DEVICE principal. The original CALLER email/API-key sign-in,
key/certificate and chat remain independent. Existing session-only DEVICE
credentials keep their original authority until you explicitly import an upgrade.

1. On the operator Mac, run `python3 scripts/create_vision_invitation.py`. The
   helper retains the same opaque phone body and association, configures only
   `vision.observe` through canonical body maintenance, and requests a full V1
   DEVICE invitation with exactly `session` plus `receive: vision.observe`.
   `--prepare-only` configures the public profile without issuing an invitation.
2. AirDrop `.local/provisioning/iphone-vision-invitation.json` to iPhone Files.
   Invitations expire after ten minutes. Remove expired/consumed Mac and operator
   invitation copies before regenerating; retain `iphone-embodiment.json`.
3. In a Debug build, open **Embodiment → Developer / Recovery Provisioning → Import DEVICE invitation**.
   The replacement must name the same body. The app generates a new DEVICE key
   and certificate. It retains the body ID independently in DEVICE Keychain so a
   failed upgrade can be retried; CALLER credentials remain unchanged.
4. Turn **Camera** on and grant native camera permission. It is also requested
   when explicitly choosing this upgraded phone in the chat embodiment selector.
   Launching the app, opening chat, or connecting CALLER never requests it.
5. In chat choose **Using embodiment → This iPhone**, point the rear camera at
   the scene, and ask **你现在能看到什么？**. Change the scene, then ask **现在呢？**.
   Selection updates the owned conversation's canonical `active_embodiment_id`;
   it does not change the permanent association to 老管家.

A denied/restricted camera remains supported but temporarily unavailable. Chat
and DEVICE session control continue. Restore access in **Settings → Apps → Home
Cortex → Camera** and return to the app. Availability updates use standard
`session.capabilities`, with revision 1 on each registration and increments of
exactly one within that session. Background/disable cancels capture and command
polling; foreground/recovery registers a fresh fence for the same identity.

The client uses the standard authenticated V1 `/commands` polling and `/messages`
response channel. Each accepted new request takes a rear-primary AVFoundation
photo after validating body/session, authority, availability, arguments and
deadline. It normalizes orientation, encodes a JPEG up to 1280 pixels with a
1 MiB local ceiling (also respecting server discovery limits), hashes the bytes,
and produces the frozen VisualEvidence manifest and evidence ID. The server
verifies bytes/provenance and performs vision reasoning through its existing
pipeline. No Apple-specific vision endpoint, local visual reasoning, continuous
capture, clip buffer, or autonomous promotion is added.

Protected receipts commit before capture and before response upload. Exact
redelivery uses the original response; concurrent redelivery waits for it. A
crash with an uncertain pending receipt returns a sanitized error without taking
another photo. Receipts bind to DEVICE client/body and retain their results for
the request deadline plus 24 hours; capacity is bounded and rejects additional
captures when full. Same-ID changed content is a conflict. Standard V1 error
codes cover permission, temporary unavailability, busy, invalid arguments,
timeout and internal failure.

The previous DEVICE credential is not silently broadened or revoked. After the
replacement has enrolled and passed physical checks, revoke **only the old
DEVICE credential ID** using the backend's documented coordinated operator
procedure. Keep the current DEVICE and CALLER credentials, body and association.

Shared Python/Swift Unicode and ASCII evidence vectors, an actual Swift-produced
synthetic wire artifact verified by the backend, and MacBook protocol/evidence
tests establish conformance. Physical checks and camera/upload timing evidence
are recorded separately in [.llm/epic3b-iphone-vision-observe.md](.llm/epic3b-iphone-vision-observe.md).


### Motion and orientation foundation

“Motion & Orientation” enables foreground Core Motion device attitude and its
local inspection diagnostic, independently of the camera. Home Cortex authorizes
`orientation.local` on the DEVICE credential registry; it is not a V1 capability
or a household orientation grant. Local motion never publishes
`telemetry.orientation` and has no space or invented p95.

Body axes, quaternion math, camera extrinsic limits and Epic 1.2 prerequisites
are defined in [the orientation foundation](docs/orientation-foundation.md).
