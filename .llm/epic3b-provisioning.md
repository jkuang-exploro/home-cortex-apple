# Epic 3B.1a — Trusted V1 software-client provisioning

Date: 2026-10-05, America/Los_Angeles. Backend work is deployed; physical enrollment and relaunch acceptance are pending. This report contains no invitation tokens, private keys, certificates, or secret credential values.

## Production operator change

Inspected `/Users/jiankuang/Workspace/home-cortex`, its AGENTS.md, the required persistent work-log skill, frozen V1 report/profile, and deployed checkout at `/home/jkuang/Workspace/home-cortex` on `jkuang@home-cortex-0` (commit `845d125`). The deployed operator was enabled/not revoked and had only the existing MacBook-scoped provision grant. Production Compose edits pre-existing this task were preserved.

Added a supported, idempotent `grant-software-provisioning` maintenance command. It matches the existing operator certificate fingerprint to an active PROVISIONER, validates its lifetime, preserves all identity metadata and grants, and adds only:

```json
{"embodiment_id": null, "verb": "provision", "capability": null}
```

The API image was built before downtime. Stopped only `cortex-api`, saved the owner-only full journal backup at the operator's `maintenance/before-software-grant-3b1a.json`, applied the command in a one-off container with the operator UID:GID, verified the full saved snapshot, and restarted the API using the existing standard/GPU Compose files. Trusted bootstrap discovery passed after restart. No CA/key rotation, replacement operator, global bootstrap, embodiment creation, assignment change, or actuator grant was performed.

A post-restart comparison against the protected backup verified every pre-existing credential, operator identity/certificate, and prior grant. There were four previous credentials; only the intended grant was added. Production verification/build/maintenance logs are ignored local artifacts under `.local/3b1a-*`.

## General V1 persistence defect

An actual SurrealDB 3.0.5 scratch-table probe confirmed SDK 2's Python None encoding becomes Surreal NONE: an upsert removes explicit nullable object fields. The scratch table was removed. This would corrupt software-client embodiment/grant fields and enrollment retries after restart.

The V1 journal persister now recursively maps None to CBOR simple value 22 (Surreal NULL) before upsert, preserving the frozen JSON semantics and existing storage shape. This is scoped to the V1 operational adapter, with no Apple/platform exception or change to household facts. A wire-codec regression covers nullable software credentials, grants, invitations, response targets/errors, and unchanged input. Production read-back confirmed new explicit null grant/invitation fields survive persistence. Existing credential/grant records were preserved without reinterpreting missing historical fields.

Reference: [SurrealDB NONE and NULL distinction](https://surrealdb.com/docs/reference/query-language/language-primitives/data-types/none-and-null). The actual deployed codec/storage behavior was verified directly, not inferred solely from documentation.

## Invitation workflow

Supported backend command: `python -m scripts.maintenance.client_interface invite-software --root OPERATOR_ROOT --output PRIVATE_FILE`. It calls existing mTLS `/client-interface/v1/pairings`, rejects redirects, refuses existing output files before minting a token, validates the complete response, and writes 0700/0600 private files. Exactly CALLER/null embodiment/null-body session authority is requested; no physical capabilities or credentials are embedded. Random one-use tokens expire in 600 seconds; same-CSR recovery is allowed by frozen V1 semantics.

Mac helper: `python3 scripts/create_software_invitation.py`. It uses passwordless SSH to the deployed operator CLI, copies the response to ignored `.local/provisioning/apple-invitation.json`, and prints only path/expiry/instructions. It refuses existing files to avoid overwriting active invitation state. CA transfer artifact: ignored `.local/provisioning/home-cortex-ca.txt`.

A real invitation was created and securely copied for the user's physical import; its structural authority and 0600 mode were checked without printing its token. The user was told the expiry and agreed to AirDrop/import it. The first invitation expired unconsumed; the registry confirmed no new client credential. Both expired temporary copies were removed, and the supported Mac helper successfully created/copied one fresh invitation. The user later requested another invitation after that copy expired. Verified the previous invitation was expired and unconsumed against the live registry, removed only its temporary Mac/server files, and generated one replacement using the supported helper. The current invitation expires at 22:27:05 PDT; its exact CALLER/null-body/session-only fields and 0600 mode were verified. No enrollment identity was created outside the phone. After consumption/expiry, delete temporary invitation copies from iPhone Files, the Mac, and the server. CA files and the device's long-term credential remain.

## Apple changes

Existing server-authenticated enrollment uses `https://home-cortex-0:8444/client-interface/v1/enroll` with only invitation ID, token, and PKCS#10 CSR. The previously imported CA authenticates the server, not the client. Native URLSession/Security TLS 1.3, pinned original CA/hostname/validity validation, no redirects, and no legacy fallback remain in force.

The phone generates P-256 locally in Secure Enclave, signs the standard PKCS#10 CSR with ECDSA/SHA-256, and keeps the key in permanent, unlocked/device-only Keychain storage. Only public-key bytes are exported. Simulator uses permanent Keychain storage. The returned certificate must match the key and chain to the original CA. Certificate/chain, client ID, key reference, expiry, and server association persist only in Keychain.

Added explicit provisioning phases: notProvisioned, invitationSelected, generatingKey, generatingCSR, enrolling, provisioned, failed. The connection view shows Provisioned separately from live session state, Software client role, and Embodiment Not enabled. It never equates provisioning/discovery with Connected. The prior V1 session implementation remains present and may show Connected only after real ACTIVE registration.

Malformed, expired, incompatible, missing-field, or privilege-expanded invitations fail before key preparation. Expiry has a specific local message; standardized invitation rejection/consumption errors have safe messages without remote secret-bearing prose. Enrollment reply validation requires the exact frozen fields, original origin, protocol 1.0, null embodiment, and session-only grant. The frozen response has no purpose field: CALLER is checked in the invitation and authoritative server registry; no new wire field was invented.

Relaunch now validates that the stored certificate matches the existing private key before showing Provisioned. A remembered ID cannot suffice. Interrupted/backgrounded enrollment fences late success, preserves the exact pending CSR/key for a still-valid invitation retry, and never stores its token. Selecting the invitation uses the native Files picker with no hardcoded app path.

## Validation

- Backend focused tests: 30 passed.
- Required full deterministic backend suite: 1,193 passed, 1 skipped.
- Final Apple simulator XCTest: 34 passed, 2 skipped, 0 failures; `.local/3B1aFinalSimTests.xcresult`. Skips are optional real discovery without supplied CA fixture and physical-device acceptance on simulator. xcodebuild exited successfully after its stalled post-test diagnostic collector was stopped; completed test results were retained.
- Six new Apple provisioning tests cover malformed/expired/expanded invitations, phases, enrollment denial/expanded response, late-response fencing/exact CSR reuse, missing-key relaunch rejection, and storage failure/retry. An additional native Keychain test proves metadata alone cannot show Provisioned when the corresponding private key is absent. Existing trust/CSR/Keychain tests remain in the suite.
- Final iPad simulator Release build passed (`.local/3b1a-ipad-release-build.log`).
- Backend regression covers null-body CALLER invitation/grant enforcement, identity issuance, exact restricted grants, metadata, single-use changed-CSR conflict, same-CSR retry, expiry, and rejected extra enrollment authority. Existing body assignment remains intact.
- Production image build, offline grant update, full read-back verification, restart, TLS bootstrap discovery, and real invitation creation passed.
- Signed updated iPhone app installation passed. Initial hosted device tests and process launch were blocked by the locked phone; that test run was cancelled before import so it cannot interfere with the document picker.
- A read-only physical acceptance test (`PhysicalProvisioningTests`) is prepared to validate the real installed credential, certificate/key matching, Secure Enclave token, and store recreation. It skips until the physical credential exists; no simulator/mock success is substituted for this check.

## Physical acceptance and remaining work

The user reports the public CA is imported. The target is the USB-connected iPhone 12 mini, iOS 26.7.1, Developer Mode enabled. The updated app is installed. A refreshed real invitation is ready, but consumption and persistent identity have not yet been observed. The last registry check confirmed zero issued software credentials and an unconsumed/expired first invitation. Keep the phone unlocked, import through Files, verify Provisioned/client ID/null embodiment, force quit/relaunch, and run the prepared read-only credential/security acceptance checks. Refresh an expired invitation rather than generating a key outside the phone.

Known limits: iOS may suspend provisioning; retry requires the same still-valid invitation/CSR. The app cannot delete the user's externally transferred Files copy. Certificate/Keychain setup remains synchronous on the main actor and the simulator reports a responsiveness warning; physical setup responsiveness must be observed. Full physical UI automation still needs its separate runner signing profile; unit-only hosted tests avoid it.

Network investigation after the phone reported unreachable: production services are running; trusted TLS 1.3 bootstrap discovery returned HTTP 200 through both the server's LAN and Tailscale addresses while preserving the configured TLS hostname. The Mac resolves the configured short hostname through Tailscale. The installed app has NSLocalNetworkUsageDescription; the phone's actual permission toggle and VPN/DNS state have not been observed. The generic transport message does not distinguish DNS failure, offline state, timeout, or local-network denial. The server certificate covers only the configured hostname, so switching the endpoint to an IP or a different hostname is not a valid workaround. Recommended next step is enabling Home Cortex local-network access if listed, connecting the phone to the same Tailscale network with MagicDNS, and checking discovery before importing a fresh invitation if the current one has expired. No server/network configuration was changed during this investigation.

3B.2 follow-up: the user confirmed Provisioned and Connected. The physical credential acceptance test passed on the actual phone (Secure Enclave, native certificate/key matching, and store recreation; no skip). Production read-back verified the single issued software CALLER retains only its null-body session grant and the invitation was consumed. Removed the consumed temporary invitation copies from Mac/server; the phone Files copy remains user-managed. Actual force-quit/relaunch/UI acceptance remains pending, so this report does not yet claim full ticket completion.

Current blocker: physical force-quit/relaunch acceptance; the phone subsequently locked during 3B.2 real chat validation.

APPLE V1 PROVISIONING: BLOCKED
