Date: 2026-10-06 23:38 PDT
Type: coding
Status: partial

## Objective
Add native iPhone DEVICE vision.observe with frozen V1 evidence and active conversation context, retaining independent CALLER chat.

## Context
User supplied Epic 3B.3b and confirmed initial Embodiment Enabled/Runtime Online. Applied the backend persistent work-log skill. Detailed evidence is in epic3b-iphone-vision-observe.md. Prior identity physical prerequisite remained pending because the phone relocked before test launch.

## Findings
Frozen backend polling/response, pairing, evidence verification, and active-embodiment routes already support the requested feature. Canonical image identity uses exact sorted compact UTF-8 hashing. Session registration revision must restart at 1; each update increments exactly once.

## Decisions
Use rear-primary AVFoundation still capture after accepted requests, a narrow camera port, independently scoped DEVICE replacement rather than grant broadening, durable duplicate receipts, and canonical CALLER conversation selection. Make no new backend semantic/runtime change.

## Changes
Added native one-photo capture/cancel/permission handling, canonical evidence encoding and shared vectors, DEVICE command polling and acknowledgment, manifest updates/availability/media limits, protected receipt replay/crash suppression, retained body storage across upgrade failures, explicit vision upgrade/Camera UI, and server-backed chat embodiment selector. Added operator helper and documented workflow, Swift/security/fake-camera/physical tests, and actual Swift-output backend conformance fixture. Production canonical profile now contains only vision.observe and retains the existing ID/frame/association; original DEVICE/CALLER authority is unchanged. Signed vision app installed; expired invitation replaced with a fresh private file.

## Validation
Final full Swift simulator suite: 60 passed, 7 expected skips, zero failures. Focused vision/provisioning/login security: 19 passed. Files/setup/relaunch UI: 1 passed. Signed physical test build/install and iPad Release build passed. Backend full suite: 1,211 passed, 1 skipped; V1/perception/evidence conformance: 37 passed; MacBook V1/evidence: 22 passed. Both shared evidence ID vectors and actual Swift-produced backend intake/replay passed. Plist lint and both diff checks passed; existing user AppIcon edit preserved.

## Remaining Issues
Vision replacement invitation and explicit camera consent are still pending. Production readback has only the original session-only DEVICE. Real capture/AcceptedEvidence/scene answer/freshness/denied-restored permission/Wi-Fi/duplicate physical capture and hardware timings remain unverified. Prepared PhysicalVisionTests cannot establish acceptance until upgrade and permission are complete. No old DEVICE revocation performed; previous physical identity prerequisite remains pending.

## Recommended Next Step
Import the fresh invitation through Upgrade Vision Access, allow Camera, keep the phone awake, select This iPhone, and run physical scene/duplicate/freshness/permission/network checks. Record actual results/timings and update the detailed BLOCKED marker only after acceptance.
