# Camera LAN-First Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver reliable trip recording, LAN-first live video and recording downloads, confirmed internet fallback, two signed car APKs, and an EcoTrip TestFlight build.

**Architecture:** Haval Camera remains capture, encoder, file, and transfer authority. EcoTrip Android owns the authenticated LAN relay and same-device IPC; the Node bridge owns remote session coordination without video persistence; EcoTrip iOS selects LAN first and asks before internet. Existing HVC1 remote live code stays intact; HVT1 version 1 becomes canonical before remote recording transfer is implemented.

**Tech Stack:** Android 9, Java/Kotlin, NanoWSD, OkHttp, ContentProvider IPC, Node.js 24, WebSocket, Swift 5.10, Network.framework/Bonjour, AVFoundation, XcodeGen, GitHub Releases, TestFlight.

**Spec:** `docs/superpowers/specs/2026-11-02-camera-lan-routing-design.md`

## Global Constraints

- Before Task 1, finish the existing Camera OTA task review at or after `a311c20`; do not reopen or duplicate its implementation here.
- Never run Android, Gradle, Kotlin, or Xcode builds on the coordinator; use the authorized Mac Mini.
- Haval Camera and EcoTrip Android must use certificate SHA-256 `5efec0f94d84d90e769635a81d51e2f25953d5d5b3cea950a115705d3b5e83e0`.
- Keep Haval Camera usable without EcoTrip for preview, manual recording, gallery, playback, settings, and temporary paired LAN downloads.
- Existing HVC1 version 1 and remote live contracts are canonical and must remain backward compatible.
- Pin HVT1 version 1 byte layout before implementing any runtime; Java, Node, and Swift use identical fixtures.
- LAN uses HTTP/WS only for the exact Bonjour-resolved private endpoint; remote uses HTTPS/WSS only.
- Never send the long-lived bridge token to a Bonjour endpoint. LAN authentication uses a one-time HMAC challenge.
- Never switch LAN to internet without confirmation. Consent lasts only for the current open action.
- Live and transfer credentials are short-lived, scoped, bearer-header only, and never logged or persisted.
- The bridge never persists live frames or recording bytes.
- Only completed segments may be read or transferred; active trips and `.partial` files are always refused.
- Recorder delivery has priority. LAN, bridge, viewer, transfer, or settings failures must not stop EcoTrip telemetry or trip persistence.
- No new dependency unless an existing platform or project dependency cannot satisfy the requirement and review explicitly approves it.
- Do not patch `/opt/bridge` from an uncommitted tree. Deploy only audited files from an immutable commit with backup and rollback.
- Final car operations happen only while parked. Never start propulsion remotely.

## Review Focus

- Malicious Bonjour service: challenge-response must not disclose the bridge token or accept replay; Task 6 tests wrong car ID, reused nonce, expiry, and wrong HMAC.
- Slow or disconnected LAN viewer: recorder remains unblocked and relay recovers only after CONFIG/keyframe; Task 6 tests bounded pressure and sink isolation.
- Mixed versions during rollout: missing capability fields mean unavailable and remote behavior remains compatible; Tasks 6–8 test old/new combinations.
- Route change during an active action: LAN loss clears the frame and asks before internet; Task 7 tests refusal, consent, reconnect, and renewed LAN loss.
- Corrupt/resumed recording: offsets, chunk hashes, whole-segment hashes, and atomic promotion prevent mixed bytes; Tasks 2–4 and 8 test mismatch, restart, EOF, and insufficient storage.

---

### Task 1: Repair Recording Reserve and Preserve the Root Error

**Repository:** `/root/projects/haval-camera/.worktrees/continuous-trip-video`

**Files:**
- Modify: `app/src/main/java/br/com/redesurftank/havalcamera/VideoSettings.java`
- Modify: `app/src/main/java/br/com/redesurftank/havalcamera/VideoSettingsActivity.java`
- Modify: `app/src/main/java/br/com/redesurftank/havalcamera/ServiceStateReducer.java`
- Test: `app/src/test/java/br/com/redesurftank/havalcamera/VideoSettingsTest.java`
- Test: `app/src/test/java/br/com/redesurftank/havalcamera/RetentionPlannerTest.java`
- Test: `app/src/test/java/br/com/redesurftank/havalcamera/ServiceStateReducerTest.java`
- Modify: `README.md`
- Modify: `docs/VALIDATION.md`

**Interfaces:**
- Consumes: existing `VideoSettings.Snapshot.reserveBytes`, `RetentionPlanner.selectDeletions`, and `ServiceStateReducer.Event.pipelineFailed`.
- Produces: accepted reserve presets `1`, `5`, `10`, `20` GiB; new-install default `1 GiB`; first pipeline failure remains authoritative until a new start clears it.

- [ ] **Step 1: Write failing reserve and error tests**

Add tests named `defaultsToOneGiBReserve`, `acceptsOneFiveTenAndTwentyGiBReserves`, `rejectsUnsupportedReserve`, and `firstPipelineFailureRemainsVisible`. Assert a second `pipelineFailed(..., "Muxer is closed")` cannot replace `"Reserva de armazenamento indisponível"`.

- [ ] **Step 2: Submit RED to the Camera queue**

Run from the Camera worktree:

```bash
git push origin HEAD:codex/continuous-trip-video-impl
/usr/local/bin/mac-mini-build submit-git /root/projects/haval-camera android-camera-verify RED_COMMIT
```

Expected: only the new reserve/default/first-error assertions fail; existing Camera tests pass.

- [ ] **Step 3: Implement the smallest settings and reducer change**

Use `1L << 30`; keep existing larger presets. Do not silently rewrite an existing explicit reserve. In `PIPELINE_FAILED`, retain `old.error` when non-null; normal start events keep clearing it as today.

- [ ] **Step 4: Submit GREEN**

Expected: full Camera unit suite, debug assembly, signed release, signer pin, ZIP alignment, and ZIP integrity pass.

- [ ] **Step 5: Commit**

```bash
git add app/src/main app/src/test README.md docs/VALIDATION.md
git commit -m "fix: allow recording on constrained storage"
```

### Task 2: Pin HVT1 Version 1 and Implement the Java Codec

**Repository:** `/root/projects/haval-camera/.worktrees/continuous-trip-video`

**Files:**
- Create: `app/src/main/java/br/com/redesurftank/havalcamera/TransferChunkCodec.java`
- Create: `app/src/test/java/br/com/redesurftank/havalcamera/TransferChunkCodecTest.java`
- Modify: `docs/VIDEO_PROTOCOL.md`

**Interfaces:**
- Consumes: transfer session identity from WebSocket credentials; completed segment metadata from `VideoCatalog`.
- Produces: `TransferChunkCodec.encodeData(int ordinal, long offset, byte[] payload)`, `encodeEof(int ordinal, long totalBytes, byte[] segmentSha256)`, `encodeAck(int ordinal, long nextOffset)`, `encodeError(int ordinal, String message)`, and `decode(ByteBuffer): Message`.

- [ ] **Step 1: Write failing Java fixture tests**

Pin a 56-byte big-endian header: magic `HVT1`, version `1`, type `DATA=1`, `EOF=2`, `ACK=3`, `ERROR=4`, zero flags, segment ordinal `u32`, offset `u64`, payload length `u32`, and 32-byte SHA-256. DATA is at most `262144` bytes. ERROR UTF-8 is at most `1024` bytes. ACK uses zero payload and zero digest. EOF uses zero payload and the whole-segment digest.

Test exact hexadecimal fixtures, unsigned bounds, wrong magic/version/type/flags, truncated header/payload, digest mismatch, offset overflow, oversized DATA/ERROR, and trailing bytes.

- [ ] **Step 2: Submit RED**

Expected: new codec symbols are missing; all prior Camera tests pass.

- [ ] **Step 3: Implement codec and canonical documentation**

Use only `ByteBuffer`, `MessageDigest`, and UTF-8. Document every byte offset, close/error behavior, ACK meaning (`nextOffset` is first unpersisted byte), and fixture hex in `docs/VIDEO_PROTOCOL.md`.

- [ ] **Step 4: Submit GREEN and commit**

```bash
git add app/src/main/java/br/com/redesurftank/havalcamera/TransferChunkCodec.java app/src/test/java/br/com/redesurftank/havalcamera/TransferChunkCodecTest.java docs/VIDEO_PROTOCOL.md
git commit -m "feat: define resumable video transfer protocol"
```

### Task 3: Add Remote Catalog, Settings, and Transfer Relay

**Repository:** `/root/projects/haval-ecotrip-git`

**Files:**
- Modify: `bridge/video-relay.js`
- Modify: `bridge/server.js`
- Modify: `bridge/test/video-relay.test.js`
- Modify: `bridge/docs/video.md`
- Modify: `bridge/package.json`

**Interfaces:**
- Consumes: exact HVT1 fixtures from Camera `docs/VIDEO_PROTOCOL.md`, `video_catalog` MQTT snapshots, and existing owner authentication/command broker.
- Produces: `GET /api/video/catalog`, `GET /api/video/settings`, `PATCH /api/video/settings`, `DELETE /api/video/recordings`, `POST /api/video/transfer/session`, `DELETE /api/video/transfer/session/:id`, `/ws/video/transfer/car`, and `/ws/video/transfer/viewer`.

- [ ] **Step 1: Add failing Node tests**

Cover owner auth, completed trips only, atomic catalog revision replacement, stale `updatedAt`, invalid metadata, no byte persistence, exact HVT1 fixtures, `262144`-byte chunk cap, ordinal/offset checks, ACK only after viewer send, reconnect with a new scoped token, token expiry, one transfer, live pausing transfer, cancellation, settings revision conflicts, confirmed deletion, and cleanup.

- [ ] **Step 2: Run RED on Node 24**

Run:

```bash
/root/.local/share/node24/bin/node --test bridge/test/video-relay.test.js
```

Expected: new catalog/transfer/settings tests fail; existing live relay tests pass.

- [ ] **Step 3: Implement bounded in-memory relay**

Extend existing `VideoRelay`; do not create a second server. Parse only HVT1 header and bounds. Keep metadata in existing mutable runtime data using atomic replacement; keep video bytes only in socket calls.

- [ ] **Step 4: Run GREEN and static checks**

```bash
/root/.local/share/node24/bin/node --test bridge/test/video-relay.test.js
node --check bridge/video-relay.js
node --check bridge/server.js
```

Expected: all video tests pass; no video files are created.

- [ ] **Step 5: Commit**

```bash
git add bridge/video-relay.js bridge/server.js bridge/test/video-relay.test.js bridge/docs/video.md bridge/package.json
git commit -m "feat: relay camera recordings and settings"
```

### Task 4: Add Haval Camera Transfer Producer

**Repository:** `/root/projects/haval-camera/.worktrees/continuous-trip-video`

**Files:**
- Create: `app/src/main/java/br/com/redesurftank/havalcamera/RecordingTransfer.java`
- Create: `app/src/test/java/br/com/redesurftank/havalcamera/RecordingTransferTest.java`
- Modify: `app/src/main/java/br/com/redesurftank/havalcamera/VideoRelayClient.java`
- Modify: `app/src/main/java/br/com/redesurftank/havalcamera/TripVideoService.java`
- Modify: `app/src/main/java/br/com/redesurftank/havalcamera/VideoCatalog.java`
- Modify: `app/src/test/java/br/com/redesurftank/havalcamera/VideoRelayClientTest.java`
- Modify: `docs/VIDEO_PROTOCOL.md`

**Interfaces:**
- Consumes: `TransferChunkCodec`, completed segment files, transfer URL/token/session, requested segment IDs, and ACK offsets.
- Produces: HVT1 DATA/EOF, resumable offset state, catalog-change notification, and retention lease ownership.

- [ ] **Step 1: Write failing transfer-state tests**

Cover start at offset zero, resume at exact ACK, wrong ACK refusal, one `262144`-byte buffer, per-chunk and whole-file SHA-256, EOF, active/partial/traversal refusal, live pause/resume, network loss, new-token resume, cancellation, lease release, deletion during idle, and no camera/encoder startup.

- [ ] **Step 2: Submit RED**

Expected: transfer classes and service effects are missing; all prior Camera tests pass.

- [ ] **Step 3: Implement one-worker transfer**

Use `RandomAccessFile.seek`; acquire one `VideoCatalog.ReadLease` per transferred trip/segment and release on every terminal path. Keep live and transfer WebSockets/queues separate. Transfer failure never invokes recording pipeline failure.

- [ ] **Step 4: Submit GREEN and commit**

```bash
git add app/src/main app/src/test docs/VIDEO_PROTOCOL.md
git commit -m "feat: publish and transfer trip recordings"
```

### Task 5: Permit Only Signed Loopback Live Production

**Repository:** `/root/projects/haval-camera/.worktrees/continuous-trip-video`

**Files:**
- Create: `app/src/main/java/br/com/redesurftank/havalcamera/LiveSessionPolicy.java`
- Create: `app/src/test/java/br/com/redesurftank/havalcamera/LiveSessionPolicyTest.java`
- Modify: `app/src/main/java/br/com/redesurftank/havalcamera/VideoRelayClient.java`
- Modify: `app/src/main/java/br/com/redesurftank/havalcamera/TripVideoService.java`
- Modify: `app/src/test/java/br/com/redesurftank/havalcamera/VideoRelayClientTest.java`

**Interfaces:**
- Consumes: signature-protected `START_LIVE` IPC, URL, bearer token, session ID, and expiry.
- Produces: `LiveSessionPolicy.validate(String url, long expiresAtMs, long nowMs): Scope`, where `Scope` is `REMOTE_WSS` or `LOOPBACK_WS`.

- [ ] **Step 1: Write failing policy tests**

Accept WSS with existing constraints. Accept WS only for literal `127.0.0.1` or `[::1]`, explicit nonzero port, sole `session` query, no user info/fragment, token length `32...512`, and expiry within 30 minutes. Reject localhost names, private/LAN/public WS hosts, redirects, changed session IDs, token in URL, and unprotected callers.

- [ ] **Step 2: Submit RED, implement, and submit GREEN**

Keep `VideoRelayClient` transport behavior unchanged after policy acceptance. The exported service remains guarded by `CONTROL_PERMISSION`; no broad cleartext network allowance is added.

- [ ] **Step 3: Commit**

```bash
git add app/src/main app/src/test
git commit -m "feat: allow signed loopback camera relay"
```

### Task 6: Add Authenticated EcoTrip LAN Video Relay and Downloads

**Repository:** `/root/projects/haval-ecotrip-git`

**Files:**
- Create: `app/src/main/java/br/com/redesurftank/ecotrip/managers/CameraLanAuth.kt`
- Create: `app/src/main/java/br/com/redesurftank/ecotrip/managers/CameraLanRelay.kt`
- Create: `app/src/main/java/br/com/redesurftank/ecotrip/managers/CameraLanDownloads.kt`
- Create: `app/src/test/java/br/com/redesurftank/ecotrip/managers/CameraLanAuthTest.kt`
- Create: `app/src/test/java/br/com/redesurftank/ecotrip/managers/CameraLanRelayTest.kt`
- Create: `app/src/test/java/br/com/redesurftank/ecotrip/managers/CameraLanDownloadsTest.kt`
- Modify: `app/src/main/java/br/com/redesurftank/ecotrip/managers/LocalApiServer.kt`
- Modify: `app/src/main/java/br/com/redesurftank/ecotrip/managers/TripVideoBridge.kt`
- Modify: `app/src/main/java/br/com/redesurftank/ecotrip/managers/LocalServiceAdvertiser.kt`
- Modify: `app/src/test/java/br/com/redesurftank/ecotrip/managers/TripVideoBridgeTest.kt`
- Modify: `docs/architecture.md`

**Interfaces:**
- Consumes: current bridge token from `MqttManager`, Haval Camera signature IPC/provider, HVC1 messages, and completed segment metadata.
- Produces: `GET /api/capabilities`, `POST /api/video/lan/challenge`, `POST /api/video/lan/session`, `DELETE /api/video/lan/session/:id`, `/ws/video/lan/car`, `/ws/video/lan/viewer`, `GET /api/video/lan/catalog`, and ranged `GET /api/video/lan/trips/:tripId/segments/:segmentId`.

- [ ] **Step 1: Write failing authentication and capability tests**

Test 128-bit nonce uniqueness, 30-second challenge expiry, one-time use, HMAC-SHA256 input exactly `haval-camera-lan-v1|deviceId|nonce|expiresAt`, constant-time equality path, wrong HMAC/device ID, absent token, no secret logging, and capability fields `cameraLiveLan=1`, `cameraDownloadLan=1`, `hvcVersion=1`, `hvtVersion=1`. Missing Camera package returns both camera capabilities as `0`.

- [ ] **Step 2: Write failing relay tests**

Test one producer/viewer, short media credentials distinct from HMAC, session expiry, binary HVC1 only, exact 4 MiB payload limit, CONFIG before deltas, viewer join keyframe request, 1 MiB/30-message queue bound, slow viewer drop/recovery, disconnect cleanup, and recorder-isolation command behavior.

- [ ] **Step 3: Write failing download tests**

Test completed catalog only, authenticated requests, strict numeric IDs, provider-derived paths, active/partial refusal, `Range` parsing, `206/416`, lease lifetime, disconnect cleanup, and no traversal.

- [ ] **Step 4: Submit Android RED**

```bash
git push origin HEAD:codex/camera-video-bridge
scripts/build-on-mac-mini.sh RED_COMMIT
```

Expected: only new LAN video assertions fail; existing EcoTrip camera bridge tests pass.

- [ ] **Step 5: Implement the LAN components**

Keep `LocalApiServer` as route/WebSocket adapter; put auth, relay state, and file decisions in their focused classes. Use existing NanoWSD and JCA; add no dependency. `TripVideoBridge` sends loopback `START_LIVE` and never handles frame bytes.

- [ ] **Step 6: Submit GREEN and commit**

Expected: full Android unit suite and debug assembly pass on Mac Mini.

```bash
git add app/src/main app/src/test docs/architecture.md
git commit -m "feat: relay camera video over authenticated LAN"
```

### Task 7: Add LAN-First iOS Live Routing With Confirmed Internet

**Repository:** `/root/projects/haval-ecotrip-git`

**Files:**
- Create: `ios-app/HavalEcoTrip/CameraRoutePolicy.swift`
- Create: `ios-app/HavalEcoTrip/CameraLanClient.swift`
- Create: `ios-app/CameraVideoTests/CameraRoutePolicyTests.swift`
- Create: `ios-app/CameraVideoTests/CameraLanClientTests.swift`
- Modify: `ios-app/HavalEcoTrip/CameraLiveSession.swift`
- Modify: `ios-app/HavalEcoTrip/CameraVideoView.swift`
- Modify: `ios-app/HavalEcoTrip/LANDiscovery.swift`
- Modify: `ios-app/CameraVideoTests/CameraLiveSessionTests.swift`
- Modify: `ios-app/project.yml`

**Interfaces:**
- Consumes: exact Bonjour endpoint, capability response, HMAC challenge, local session credentials, existing remote session transport, and user consent callback.
- Produces: `CameraRoutePolicy.Decision` values `.useLAN`, `.askInternet`, `.offline`; `CameraLiveSession.Route` values `.lan` and `.internet`; visible route/latency state.

- [ ] **Step 1: Write failing route tests**

Cover LAN available, capability absent, local auth failure, initial no-LAN confirmation, refusal, consent scoped to one action, remote reconnect within that action, LAN loss clearing frame, a second confirmation before internet, cancel, stop invalidating consent, and returning LAN invalidating old internet consent.

- [ ] **Step 2: Write failing client security tests**

Assert the bridge token appears only as HMAC key, never in local headers/URL/body/logs; URL must match exact resolved host/port and use HTTP/WS; no redirect, user info, fragment, alternate port, or different host; media token uses bearer header.

- [ ] **Step 3: Submit focused RED simulator job**

Use the established `CameraVideoTests` queue profile against the immutable commit. Expected: only new route/LAN tests fail; existing 13 camera video tests pass.

- [ ] **Step 4: Implement route state and UI confirmation**

Keep parsing/decoding unchanged. On LAN loss call `renderer.clear()` before publishing the prompt. Show `LAN` or `Internet`; use existing quality estimate in confirmation copy.

- [ ] **Step 5: Run focused GREEN and full simulator build**

Expected: `CameraVideoTests` passes with zero failures, then scheme `HavalEcoTrip` builds with `CODE_SIGNING_ALLOWED=NO`.

- [ ] **Step 6: Commit**

```bash
git add ios-app/HavalEcoTrip ios-app/CameraVideoTests ios-app/project.yml
git commit -m "feat: prefer LAN for live vehicle cameras"
```

### Task 8: Add iOS Video Gallery, Verified Downloads, and Camera Settings

**Repository:** `/root/projects/haval-ecotrip-git`

**Files:**
- Create: `ios-app/HavalEcoTrip/CameraVideoStore.swift`
- Create: `ios-app/HavalEcoTrip/CameraRecordingsView.swift`
- Create: `ios-app/HavalEcoTrip/CameraSettingsView.swift`
- Create: `ios-app/CameraVideoTests/CameraVideoStoreTests.swift`
- Modify: `ios-app/HavalEcoTrip/CameraVideoProtocol.swift`
- Modify: `ios-app/HavalEcoTrip/GravacoesV2View.swift`
- Modify: `ios-app/CameraVideoTests/CameraVideoProtocolTests.swift`
- Modify: `ios-app/project.yml`

**Interfaces:**
- Consumes: LAN catalog/Range endpoints, remote catalog/settings/HVT1 endpoints, route consent, and canonical HVT1 fixtures.
- Produces: catalog states, resumable verified local files, ordered segment playback/share, deletion confirmation, and reconciled Camera settings.

- [ ] **Step 1: Write failing HVT1 Swift tests**

Use the exact Java fixture hex. Cover DATA/EOF/ACK/ERROR, malformed lengths, digest mismatch, offset overflow, unknown flags/types, and `262144`-byte cap.

- [ ] **Step 2: Write failing store tests**

Cover LAN-first catalog, remote confirmation, stale/offline labels, active trip absent, route-specific partial state, exact offset resume, wrong chunk/whole-file SHA-256, insufficient iPhone storage, cancellation, duplicate segment, atomic `.partial` promotion, ordered playback, safe share, optimistic settings, authoritative revision replacement, stale conflict, and rollback on command failure.

- [ ] **Step 3: Submit RED**

Expected: new store/protocol symbols are missing; Task 7 tests stay green.

- [ ] **Step 4: Implement store and views**

Store verified files under Application Support. Acknowledge HVT1 only after durable write. Use the same safe presets/toggles as Haval Camera, including reserve `1/5/10/20`. Require separate deletion confirmation.

- [ ] **Step 5: Submit focused GREEN and full simulator build**

Expected: all CameraVideoTests pass; `HavalEcoTrip` simulator build passes; existing cabin audio views compile unchanged.

- [ ] **Step 6: Commit**

```bash
git add ios-app/HavalEcoTrip ios-app/CameraVideoTests ios-app/project.yml
git commit -m "feat: add vehicle camera recordings and settings"
```

### Task 9: Version, Deploy, Install, Validate, and Publish

**Repositories:** Camera and EcoTrip immutable reviewed heads.

**Files:**
- Modify: Camera `app/build.gradle.kts` to `versionCode=3`, `versionName="0.3"`
- Modify: EcoTrip `README.md`, `docs/architecture.md`, `docs/quality.md`
- Generated outside Git: signed APKs, Camera `update-manifest.json`, TestFlight archive/logs, validation receipt.

**Interfaces:**
- Consumes: all reviewed task heads and Mac Mini build artifacts.
- Produces: Camera `0.3`, EcoTrip Android `v6.237` (`versionCode 6237` from workflow), one valid HavalEcoTrip TestFlight build, and rollback receipts.

- [ ] **Step 1: Run final whole-branch reviews**

Review Camera from the pre-plan base through final Camera head; review EcoTrip/bridge/iOS from `1226cea` through final head. Resolve every Critical/Important finding before release.

- [ ] **Step 2: Run final authorized builds**

Camera: submit `android-camera-verify`, fetch into a new artifact directory, verify checksums, signer pin, package/version, alignment, ZIP, and generated update manifest.

EcoTrip Android: run `scripts/build-on-mac-mini.sh FINAL_COMMIT`; verify tests/debug APK. Create signed release only through the existing GitHub tag workflow by pushing reviewed tag `v6.237`; fetch the release APK and verify package, `versionCode=6237`, versionName `6.237`, and approved certificate.

iOS: run focused `CameraVideoTests` and full `HavalEcoTrip` simulator build from the same final commit before archive.

- [ ] **Step 3: Deploy bridge compatibly**

Back up exact current `/opt/bridge/server.js`, `video-relay.js`, `package.json`, lockfile, and docs with SHA-256 receipt. Copy only audited changed files from the immutable EcoTrip commit, install no unreviewed dependency, run Node 24 tests/static checks, restart the existing PM2 service, and verify health plus old live APIs. Restore backup immediately on failure.

- [ ] **Step 4: Stage Camera release metadata without publishing**

Prepare release `v0.3.0` notes and verify the exact signed `haval-camera.apk` plus generated `update-manifest.json` locally. Do not create the GitHub release before hardware gates.

- [ ] **Step 5: Install Camera and update EcoTrip through its OTA**

While parked and explicitly online, push only the exact verified Camera APK to a unique `/data/local/tmp` path. Re-check SHA-256 on the car, install Camera with `pm install -r`, verify `Success`, signer continuity, startup, and no new package `FATAL EXCEPTION`, then delete only that temporary APK.

For EcoTrip, publish verified tag/release `v6.237`, launch the already-installed EcoTrip app, and use its existing `UpdateManager` OTA path exactly as a normal startup update. Do not sideload the EcoTrip APK. Observe download/install completion, then verify package `versionCode=6237`, versionName `6.237`, signer continuity, process startup, and no new package `FATAL EXCEPTION`.

- [ ] **Step 6: Apply and verify 1 GiB reserve**

Use the signed EcoTrip settings IPC/UI to update `reserveGb=1` with revision/request ID. Read back the authoritative Haval Camera snapshot. Do not edit SharedPreferences XML directly.

- [ ] **Step 7: Run parked hardware gates**

Record approximately 10 seconds; verify completed MP4 exists, size > 0, duration readable, catalog complete, SHA-256 present, and no `Muxer is closed`. Test live LAN on Starlink with route label `LAN`; disable phone Wi-Fi and verify frame clears plus internet confirmation; accept once and verify remote WSS; reject a second transition. Test one LAN recording download and one confirmed remote download with matching hashes. Confirm OEM camera composition still works and no separate-camera claim appears.

- [ ] **Step 8: Publish Camera GitHub release**

Attach the exact hardware-tested signed `haval-camera.apk` and generated `update-manifest.json` to stable release `v0.3.0`. Verify GitHub asset hashes against fetched build artifacts and confirm the in-app updater sees versionCode `3` only after publication.

- [ ] **Step 9: Archive and upload HavalEcoTrip to TestFlight**

Sync the immutable final commit to `/Users/consorciolimpagyn/driverapp` on `mac-mini`. Unlock the login keychain in the logged-in graphical session, then invoke `ios-app/build-testflight.sh BUILD_NUMBER` through Terminal.app via AppleScript with `DEVELOPMENT_TEAM=7Y6MPKR5CD` and `CODE_SIGN_STYLE=Automatic`. Use a build number greater than `2610192020`. Confirm App Store Connect reports the exact build `VALID`; retain logs/artifacts under `build/TestFlight-BUILD_NUMBER/`.

- [ ] **Step 10: Record rollback and completion evidence**

Record source commits, tags, APK/manifest hashes, certificate hash, bridge backup hashes, installed package versions, TestFlight build, hardware observations, and unverified scenarios. Rollback order: disable camera live/download flags, restore bridge backup, reinstall previous signed APKs, then select prior TestFlight build. Never delete recordings during rollback.

- [ ] **Step 11: Commit release documentation**

```bash
git add README.md docs/architecture.md docs/quality.md
git commit -m "docs: record camera rollout evidence"
```
