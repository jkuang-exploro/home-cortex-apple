Date: 2026-10-07 00:01 PDT
Type: investigation
Status: partial

## Objective
Determine why selecting This iPhone does not yet permit physical observations.

## Context
Following the deployed CALLER selection fix, user reports that the embodiment still cannot do anything. Keep independent CALLER/DEVICE authority and explicit camera consent.

## Findings
Production selection PATCH now returns 200. Sanitized canonical journal readback shows only the original session-only DEVICE credential for the retained phone body; no receive vision.observe grant. Physical test confirms selection, fresh conversation discovery, message streaming and selected-body history work. Physical vision test explicitly skips because upgrade has not been imported.

## Decisions
Do not silently broaden an existing credential. Refresh the expired invitation through the canonical operator pairing API and guide the explicit same-body replacement and camera consent. Current supported physical capability is fresh single-frame vision.observe; selection alone has no capture effect.

## Changes
No runtime code changed. Updated the selection work log with actual hardware results and the vision report with the credential blocker. Removed expired invitation files only, retained the canonical profile and original credentials, issued a fresh private vision invitation, revealed it in Finder and relaunched the installed app. No token, key or real camera media was logged.

## Validation
Real iPhone: one selection/discovery/stream/history test passed; one vision test explicitly skipped; zero failures (.local/EmbodimentReadinessPhone.xcresult). Canonical credential grants read back as session only. Fresh invitation has exact same-body DEVICE session plus receive vision.observe scope; expires 2026-10-07 00:10:26 PDT. Canonical body/agent association preserved by helper readback.

## Remaining Issues
User must import the new invitation and allow Camera. Real observation/accepted evidence, scene correctness, freshness, permission and network recovery remain unverified.

## Recommended Next Step
Once Runtime Online / Vision Available, run the prepared physical vision test and verify a recognizable scene, then complete remaining physical acceptance.
