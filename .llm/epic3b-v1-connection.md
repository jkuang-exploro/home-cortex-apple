# Epic 3B.1 — Apple Client Interface V1 connection

Date: 2026-10-05. Implementation is present; full physical acceptance is blocked. No authenticated Apple Connected state is claimed from discovery or mocks.

## Inspected contract and deployment

Read the accepted frozen V1 profile, implementation report, schemas, golden vectors, deployment guide, proxy configuration, provisioning/session implementation, and existing Mac client adapter in sibling repositories. Local backend reference: `734ca94ebaa073f7435738631c9c2e0ac1fa9496`; inspected deployed checkout: `845d125`. Golden fixture provenance is in `home-cortex-appleTests/Fixtures/PROVENANCE.md`.

Actual deployed paths/origins:

- `https://home-cortex-0:8444/client-interface/v1/discovery`: server-authenticated TLS bootstrap discovery.
- `https://home-cortex-0:8444/client-interface/v1/enroll`: invitation ID/token plus Apple-generated PKCS#10 CSR.
- `https://home-cortex-0:8443/client-interface/v1/discovery`: mTLS discovery.
- `https://home-cortex-0:8443/client-interface/v1/messages`: mTLS register, heartbeat, disconnect.
- `https://home-cortex-0:8443/client-interface/v1/pairings`: existing operator mTLS pairing API; the app does not call it.

Port 8443 rejects enrollment. Both services require TLS 1.3. Protocol is `1.0`, envelope schema `1`. The software principal has `embodiment_id: null`, CALLER purpose, and exactly the null-body `session` grant. No backend code, grants, credentials, or semantic behavior was changed. No physical capability was advertised or legacy authentication used.

Non-secret Debug configuration: `home-cortex-apple/Resources/Development.json`. Release requires imported configuration. Local signing override: ignored `Config/Signing.local.xcconfig`. The public server CA is obtained through an authenticated operator channel and imported by the user, not learned from an untrusted enrollment reply. Config/trust persist in device-only Keychain. No operator private key or existing Mac client identity is transferred to the app.

## Implementation

`Core/V1` contains closed configuration parsing, strict bounded JSON parsing (duplicate/escaped duplicate keys rejected), frozen request/response validation, standardized errors, server discovery, native transport, lease calculation, and the explicit connection state machine. `Core/Security` contains certificate trust evaluation, minimal standard PKCS#10 DER packing, and Keychain storage. `Features/Connection` contains the connection screen and bounded file import.

Networking uses ephemeral URLSession with native Security APIs, TLS 1.3, explicit trusted anchors, SSL hostname validation, certificate validity checks, disabled trust network fetch, no redirect following, cookies, credential cache, or insecure bypass. mTLS uses SecIdentityCreate with the issued certificate and the device-held key. URLCredential supplies the intermediate chain. There are no third-party runtime dependencies.

The physical-device key is P-256 in Secure Enclave, permanent in Keychain, with device-only/unlocked accessibility and private-key-use access control. Simulator uses permanent Keychain storage. Physical Secure Enclave creation has no exportable fallback. Only public-key bytes are exported for CSR packing; SecKeyCreateSignature signs ECDSA/SHA-256 locally. The server-issued certificate must match the key and validate against the original operator CA.

Keychain generic records retain client ID, key reference, certificate/chain, original CA, configuration, earliest certificate/registry expiry, and an authentication-rejection latch. A pending record retains the exact CSR/key reference for invitation-consumption retries; it never retains the token. Invitation data exists only during import/provisioning. Credential/key erasure occurs before disconnect I/O is awaited. No secret material is recorded in this document, README, configuration, fixtures, or logs.

The screen distinguishes unconfigured, provisioning, disconnected, discovering, authenticating, registering, connected, reconnecting, and failed; discovery has its own state. Compatible discovery does not grant authenticated status. Registration always sends null embodiment, revision 1, and an empty manifest. Responses must correlate request, operation, target, protocol/schema, principal, and session fence. Only ACTIVE with an unexpired conservative lease shows Connected.

Heartbeats use returned timing. Lease budget accounts for server expiry, local wall time, round-trip delay, monotonic elapsed time, and a safety margin; a watchdog removes stale ACTIVE status even if a request stalls. Retry uses bounded backoff; stale/expired sessions and backend restart re-register. REPLACED stops automatic retry. Authentication/permission rejection persists a re-provisioning requirement. Epoch cancellation prevents late responses restoring authority after disconnect, backgrounding, or forgetting.

Backgrounding cancels workers and clears local session authority. The server lease expires naturally while iOS suspends execution. Foreground re-registers when connection was requested. Force quit cannot guarantee delivery of disconnect; relaunch loads the key/credential and opens a fresh session. The app makes no attempt to run indefinite background heartbeats.

Logging uses OSLog with state/event labels for discovery, HTTPS/TLS, provisioning, registration, lease acceptance, heartbeat, and reconnect. Remote error prose is not displayed or logged because it could contain echoed secrets.

## Validation

Toolchain: Xcode 27.0 (27A266a), Swift 6.4, Swift language mode 6, iOS deployment target 17.0.

- iPhone 18 Pro / iOS 27 simulator: 26 unit tests and one fresh-client UI/relaunch test passed in `.local/V1VerifiedTests.xcresult` (zero failures).
- Optional live simulator test: trusted discovery against the deployed service passed in `.local/V1LiveDiscoveryTests.xcresult`; credential/session remained absent. This tests URLSession + actual server TLS, not mTLS enrollment.
- Final simulator verification, including optional live discovery and the extreme timing regression: 27 unit/integration tests plus one UI/relaunch test passed (28 total, zero failures) in `.local/V1FinalTests.xcresult`.
- Final xcodebuild exited successfully. Its optional post-test simulator diagnostic collector stalled and was stopped after all tests passed; test execution/results were retained. Temporary operator public CA fixture was removed afterward.
- xcresult includes one main-thread responsiveness warning during security validation. Keychain enrollment/identity setup currently runs synchronously on the main actor; measure setup responsiveness on the physical device during B/C. URLSession challenge handling and network I/O run asynchronously.
- Native Swift URLSession against the deployed bootstrap endpoint: valid original CA discovery passed; wrong-root rejection passed.
- Swift-generated PKCS#10 CSR: OpenSSL self-signature verification passed. Actual frozen backend validators accepted the Apple CSR and serialized null-body/empty-manifest session.register request.
- Final iPad Air 11-inch (M4) simulator Release build passed (`.local/v1-final-ipad-build.log`); Release has no implicit Debug server configuration.
- Final signed physical iPhone Debug build and installation passed (`.local/v1-final-device-build.log`, `.local/v1-final-install.json`). An earlier build launched successfully through devicectl; the final launch attempt was rejected because the phone had relocked. This establishes deployment/earlier launch only.
- Simulator screen visually inspected: Not Provisioned, Protocol 1.0, Session Not active, Embodiment Not enabled, and disabled provisioning before trusted CA import.

Protocol fixtures are byte copies of backend golden vectors; controller responses are explicit software-only derivatives of the frozen physical vector. Crypto fixtures contain public test certificates only. Test fixture signing keys remain in ignored local scratch storage. UI and optional discovery tests use isolated Keychain service names.

## Physical iPhone acceptance

Device: connected iPhone 12 mini, iOS 26.7.1, Developer Mode enabled. The actual signing identity/team was available; no signing keys or account passwords were collected.

| Step | Result |
| --- | --- |
| A: Fresh install/launch, Not Provisioned | Signed install and process launch succeeded. On-device visual state remains unverified: screenshot was black and the phone relocked. Simulator visual/UI assertions passed. |
| B: Local key, CSR, real enrollment, secure persistence | Blocked by unavailable authorized software-only invitation; physical Secure Enclave tests did not execute while the device was locked. |
| C: Real mTLS authentication | Blocked by B. Native transport is implemented; no real Apple credential was issued. |
| D: Software-only ACTIVE session/UI | Blocked by B/C. Golden request and backend validator conformance passed; no live Apple ACTIVE session is claimed. |
| E: Force quit/relaunch with credential | Blocked by B. Isolated Keychain retry tests and mock reconnect tests passed in simulator. |
| F: Real network interruption/recovery | Blocked by B/C. Mock interruption and stalled-heartbeat expiry tests passed. |
| G: Backend restart/fresh session | Blocked by B/C. Mock restart/fresh-fence test passed. Production service was not restarted. |
| H: Revoke Apple credential | Blocked by B/C. Mock rejection/persistence test passed. No production credential was revoked. |

## Explicit blockers and next actions

Update from Epic 3B.1a: the operator's null-body provision grant is now deployed and verified, and a real software-only invitation has been created. See [epic3b-provisioning.md](epic3b-provisioning.md) for current import/device results. The original rejection below is historical evidence; it is no longer the active operator blocker. Full physical session lifecycle acceptance remains outstanding.

1. The deployed existing operator is scoped to the MacBook embodiment. A real API attempt to create a CALLER/null-body invitation returned HTTP 403 PERMISSION_DENIED with `missing_grant`. An authorized operator must supply a software-only invitation, or independently configure an appropriately scoped provisioner through the existing operational workflow. Do not assign an iPhone embodiment or vision grant as a workaround. README gives the concrete existing API request and protected-file workflow. No token is requested in chat.
2. Keep the physical iPhone unlocked during hosted tests and app verification. Unit-only scheme `home-cortex-apple-unit` avoids the separate UI runner; physical test attempts remained at Xcode's “Unlock Test Iphone to Continue” preflight and were cancelled after waiting, so no physical test pass is claimed.
3. The full physical UI runner needs its own signing profile; Xcode account authentication was rejected when creating that profile. Refresh the account locally in Xcode. This does not prevent already successful signed app installation/launch, and the unit-only scheme avoids the UI profile dependency.
4. Once provisioned, run A–H on the physical phone, including a coordinated backend restart and revocation of only the newly issued Apple credential. Record actual server/session and UI behavior before changing this ticket to PASS.

APPLE V1 CONNECTION: BLOCKED
