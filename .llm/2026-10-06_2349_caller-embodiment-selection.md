Date: 2026-10-06 23:49 PDT
Type: debugging
Status: completed

## Objective
Fix the physical iPhone's “Conversation access denied” when selecting This iPhone.

## Context
The vision UI uses independent CALLER authority for the existing canonical conversation selection endpoint. Applied the backend persistent work-log skill. Production is on fixed LAN 192.168.68.59.

## Findings
Production logs confirmed PATCH /conversations/{id}/active-embodiment returned 403 while owned history GET returned 200. The older software CALLER policy allowed only GET/POST transcript routes. It also rejected owned steward conversations with a selected body and removed them from listings. The native latest-conversation selection similarly excluded selected bodies. Previous vision conformance tests did not cover the real application authorization boundary.

## Decisions
Permit only the exact existing PATCH selection route in addition to current transcript routes. Retain mapped person, active owned CALLER session, steward restriction and canonical body-to-agent assignment validation. Selection does not grant DEVICE capabilities or change persistent body assignment.

## Changes
Backend: corrected route permission, owned-history and list filters; added end-to-end selection/history/stream/clear tests and negative owner, assignment, role, session and method checks. Native: allow latest steward conversation discovery with a selected body; added a physical selection/discovery/message/history test. Patched production sources narrowly, preserving prior login changes, with private source rollback copies; built and recreated only cortex-api. Signed native app built and installed. No credential, CA, provisioning, body identity or assignment changed.

## Validation
Backend full deterministic suite: 1,212 passed, 1 skipped. Focused caller/API tests: 85 passed. Native simulator ConversationTests: eight passed. Signed phone build-for-testing and installation passed. Production image build/recreation and startup succeeded. Both repository diff checks passed. Physical on-device result: one selection/discovery/stream/history test passed, one vision test explicitly skipped (.local/EmbodimentReadinessPhone.xcresult). The production host venv lacks pytest, so no server-host pytest result is claimed; full deterministic suite ran locally.

## Remaining Issues
Physical selection/discovery/message/history test passed on the real iPhone at 2026-10-07 00:00 PDT. Vision camera/scene/freshness acceptance remains separate and unverified; the physical vision test explicitly skipped because the DEVICE still has its original session-only credential.

## Recommended Next Step
Resume separate vision acceptance after explicit DEVICE vision invitation import and camera permission. Selection authorization is verified on hardware.
