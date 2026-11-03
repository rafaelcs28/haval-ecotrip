# iOS CarCam Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the fixed CarCam dashcam as a second live source in the existing iOS camera sheet.

**Architecture:** A pinned WHEP client owns HTTPS and teardown, a WebRTC adapter owns the peer connection and media tracks, and one main-actor session owns UI state. The current Haval live session stays unchanged and `CameraVideoView` selects exactly one source.

**Tech Stack:** Swift 5.10, SwiftUI, Security, CryptoKit, AVFoundation, WebRTC XCFramework M155, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-03-ios-carcam-viewer-design.md`

## Global Constraints

- iOS 17.0; builds and tests run only on the authorized Mac Mini.
- Fixed endpoint `https://100.105.51.56:8443`; no public network fallback.
- Never persist or log SDP/Location; token is read from existing settings and copied to Keychain.
- No STUN/TURN, trickle ICE, automatic retry, local capture or simultaneous camera sessions.
- Pin only EC P-256 SPKI and reject every unexpected TLS challenge or redirect.

## Review Focus

- Start/Stop races must produce at most one peer and one DELETE.
- Cancellation before `201` must close the local peer without inventing a remote session.
- Invalid redirect, Location, MIME, SDP, host or pin must fail closed.
- Screen dismissal and source switching must stop both session types.
- `401`, `409`, `502`, `503`, and `504` must remain distinguishable and manually retryable.

---

### Task 1: Fixed credentials and pinned WHEP transport

**Files:**
- Create: `ios-app/HavalEcoTrip/CarCamConfiguration.swift`
- Create: `ios-app/HavalEcoTrip/CarCamWHEPClient.swift`
- Create: `ios-app/CameraVideoTests/CarCamWHEPClientTests.swift`
- Modify: `ios-app/project.yml`

**Interfaces:**
- Produces: `CarCamBridgeConfiguration.fixed(token:)`, `CarCamCredentialStore`, `CarCamWHEPClient.createSession(offer:)`, and `stop(location:)`.

- [ ] Write failing tests for fixed endpoint/pin, P-256 SPKI fixture, response validation, no redirects and status mapping.
- [ ] Submit the RED commit to `xcode-native-test`; expect missing CarCam symbols.
- [ ] Implement the smallest fixed configuration, Keychain store, pinned URLSession delegate and WHEP POST/DELETE client.
- [ ] Submit the GREEN commit; expect all `CameraVideoTests` passing.
- [ ] Commit `feat(ios): add pinned CarCam WHEP transport`.

### Task 2: Receive-only WebRTC session

**Files:**
- Create: `ios-app/HavalEcoTrip/CarCamPeerConnection.swift`
- Create: `ios-app/HavalEcoTrip/CarCamViewerSession.swift`
- Create: `ios-app/CameraVideoTests/CarCamViewerSessionTests.swift`
- Modify: `ios-app/project.yml`

**Interfaces:**
- Consumes: Task 1 WHEP client and fixed configuration.
- Produces: `CarCamViewerSession.State`, `start()`, `stop()`, and `videoTrack` for the UI.

- [ ] Write failing state-machine tests for one Start, one DELETE, cancellation, errors and idempotent Stop.
- [ ] Submit the RED commit; expect missing viewer symbols.
- [ ] Add exact WebRTC `155.0.0`, implement one audio/video `recvonly` peer, ICE-complete wait and main-actor session.
- [ ] Submit the GREEN commit; expect all camera tests and dependency resolution passing.
- [ ] Commit `feat(ios): add receive-only CarCam session`.

### Task 3: Existing camera screen integration

**Files:**
- Create: `ios-app/HavalEcoTrip/CarCamVideoSurface.swift`
- Modify: `ios-app/HavalEcoTrip/CameraVideoView.swift`
- Create: `ios-app/CameraVideoTests/CameraSourceSelectionTests.swift`
- Modify: `PRODUCT.md`
- Modify: `docs/architecture.md`
- Modify: `docs/quality.md`

**Interfaces:**
- Consumes: Task 2 session/video track and existing `CameraLiveSession`.
- Produces: one segmented `Haval`/`Dashcam` camera sheet with serialized source switching and teardown.

- [ ] Write failing selection/lifecycle tests using a pure source-selection policy.
- [ ] Submit the RED commit; expect missing selection policy.
- [ ] Implement selector, CarCam renderer, status/control copy and teardown on switch/dismiss.
- [ ] Submit `xcode-native-test` and `xcode-native-simulator`; expect all tests and app compilation passing.
- [ ] Update product, architecture and quality boundaries; commit `feat(ios): show dashcam beside Haval live camera`.

### Task 4: Review and device handoff

**Files:**
- Modify only files required by Critical/Important review findings.

- [ ] Run whole-branch review against this plan/spec and fix relevant findings through RED/GREEN.
- [ ] Re-run Mac Mini test and simulator gates on the final commit.
- [ ] Archive/upload TestFlight only after the user authorizes publication of the verified commit.
- [ ] Record pending physical checks: real SDP, one-minute A/V sync, Stop cleanup, camera Wi-Fi loss and Tailscale loss.
