Date: 2026-10-06 22:47 PDT
Type: debugging
Status: partial

## Objective
Finish Epic 3B.3a and fix the reported Enable as Embodiment invitation picker failing to appear.

## Context
Full implementation/evidence is recorded in epic3b-iphone-embodiment-identity.md. The user explicitly attempted DEVICE enablement and import. Applied the backend persistent work-log skill for the cross-repository work.

## Findings
Presenting fileImporter while the Enable alert dismissed caused an unreliable presentation. Files uses a FullDocumentManagerViewControllerNavigationBar identifier; Browse/Recents are not navigation identifiers in the observed simulator hierarchy.

## Decisions
Use a dedicated explicit setup sheet and attach its fileImporter to that sheet. Preserve independent CALLER/DEVICE storage and state, and keep the persistent body/profile unchanged during invitation regeneration.

## Changes
Added the separate canonical DEVICE identity/session and opt-in runtime model, role/body/namespace validation, independent runtime controls, lifecycle/security tests, operator invitation helper, and documentation. Replaced the racing alert with an Enable Embodiment setup sheet, bounded security-scoped import, and focused Files/cancel/relaunch regression. Updated signed app installed on the iPhone. Regenerated the expired invitation; server readback then confirmed real DEVICE enrollment. Consumed operator/Mac invitation copies removed, retained profile preserved. Restored project dictionary order; user AppIcon edit left unchanged.

## Validation
Apple full simulator suite: 50 passed, 6 expected skips, zero failures; final Security/Embodiment 11 passed; final Files UI regression 1 passed. Signed phone build/install, physical-test compilation, iPad Release build, plist lint and diff checks passed. Backend full suite: 1,209 passed, 1 skipped; final operator suite 21 passed. Production image build and canonical body/association/DEVICE session-only grant readback passed.

## Remaining Issues
Phone relocked before hosted physical tests launched. Cancelled the waiting run. Secure Enclave/active dual sessions and physical network/relaunch/revocation/caller-chat acceptance remain unverified; no production DEVICE revocation was done. Native credential replacement UI is not implemented.

## Recommended Next Step
Keep the phone unlocked/open and confirm Embodiment Enabled / Runtime Online, then run PhysicalEmbodimentTests and remaining physical acceptance. Update the detailed report's BLOCKED marker only after actual acceptance.
