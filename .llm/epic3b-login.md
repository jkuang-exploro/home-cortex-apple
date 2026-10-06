Date: 2026-10-05 23:39 PDT
Type: coding
Status: partial

## Objective
Replace routine manual CA/invitation setup with GUI-credential sign-in, automatic native enrollment, and direct fixed-LAN connectivity.

## Context
The user authorized the same credentials as home_gui and specified the fixed server IP 192.168.68.59 with no Tailscale client dependency. Inspected canonical GUI identity/authentication, software V1 enrollment/journal, native certificate/Keychain/TLS/session lifecycle, and production configuration. Applied the backend repository persistent work-log skill.

## Findings
Web sign-in uses mapped email/user ID plus a household API key, not a distinct account password. The original server leaf lacked an IP SAN. A bundled original public CA and fixed installation profile permit authenticated first contact without manual/system CA import. The CA signing key stays on the server; native device keys remain on the phone.

## Decisions
Use pinned TLS 1.3 on LAN bootstrap port 8444 for POST /session/device-invitation. Reuse canonical GUI authentication/identity mapping and issue fixed CALLER/null-body/session-only invitations lasting ten minutes. Preserve frozen V1 wire fields; durable GUI-person binding is server-only metadata. Conversation access still requires an owned ACTIVE mTLS session and unchanged GUI key-to-person mapping. No bearer/cookie session/chat fallback or new embodiment/capability. Existing matching-CA phone credentials migrate endpoints while preserving identity and rejection status.

## Changes
Added native LoginView and bounded pinned login transport, bootstrap validation, automatic configuration/trust/enrollment, memory-only API key handling, and LAN migration. Bundled public CA/Household.json for Debug/Release and changed Development.json to the fixed LAN IP. Manual setup remains under Advanced; local forgetting is Sign out. Added login, migration, negative authority/trust, lifecycle, UI, optional live LAN, and physical reconnection checks. Updated README and historical provisioning note. Backend added the restricted trusted-proxy login policy and durable person binding plus supported certificate-refresh CLI and deployment documentation. Production uses the LAN endpoint and a replacement server leaf signed by the unchanged CA/server key, retaining the original DNS SAN. Protected rollback files remain server-side; temporary deployment helper removed. Signed app installed on the connected iPhone.

## Validation
- Backend full suite: 1,200 passed, 1 skipped. Focused setup/login suite: 15 passed.
- Final Apple unit suite: 44 passed, 4 expected skips, zero failures (.local/LoginFinalTests.xcresult). Initial suite 44 passed/3 skips before the added physical LAN check; optional diagnostics collector stopped only after completion.
- Simulator native sign-in/advanced/relaunch UI: one passed (.local/LoginUITests.xcresult).
- Real LAN native iOS URLSession test: pinned CA/IP SAN discovery compatible and invalid GUI credentials rejected, one passed without skips (.local/LoginLANLive.xcresult). Temporary public-CA fixture removed afterward.
- Real production TLS 1.3 login: existing GUI key/email accepted, wrong key rejected; exact original CA, LAN profile, no-store and least-privilege invitation verified. No key/token printed or copied to this Mac; validation invitation discarded and left to expire.
- Production API image build/recreation and nginx test/reload passed. OpenSSL verifies both LAN IP and original hostname. CA certificate/private key and server private key hashes unchanged.
- Signed physical build/install passed; updated app launched once before relocking. iPad Release build passed. Final project plist lint and both repositories' diff checks passed.

## Remaining Issues
Phone relocked before physical hosted LAN/mTLS/Secure Enclave acceptance could start. Cancelled waiting Xcode run so it will not later take over the phone. No complete fresh web-credential sign-in/enrollment on the physical phone is claimed; do not delete the existing credential just to test. Earlier physical chat/network/relaunch acceptance remains separate. Local sign-out does not revoke a server credential. API key must be entered on the phone, never supplied in chat/logs.

## Recommended Next Step
On household Wi-Fi, unlock/open Home Cortex and allow local-network access. Existing identity should reconnect directly; run prepared PhysicalProvisioningTests when unlocked. For a fresh installation (or deliberate Sign out), enter the same web email/API key and verify automatic enrollment/Connected. Retain actual physical results in this report.
