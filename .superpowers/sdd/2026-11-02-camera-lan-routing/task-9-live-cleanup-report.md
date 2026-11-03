# Task 9 pre-release gate: idempotent LAN live cleanup

Date: 2026-11-03

## Status and heads

- Status: PASS. The narrow pre-release gate is implemented and all required immutable Mac Mini jobs passed.
- Source base: `09d86cf06385d57f53e18ed81c62de4fe4c54c92`.
- Tests-only RED commits: `73bd30bdb733682f96a5e8c7f9a814447718d822` and test-compilation correction `18e1c70614d217595d1e4cdaea1b19ebbfae9477`.
- Final immutable source head: `0d7b9ac286c74d439d3eaee3d507131015f3b637`.
- Branch: `codex/camera-lan-routing`, pushed to `origin` at the source head before final verification.
- No bridge source changed, so the bridge Node suite was not run, as directed by the binding brief.
- No versioning, deployment, tag, release, TestFlight, signing, installation, hardware operation, or publication occurred. No Android, Gradle, Kotlin, or Xcode build ran on the coordinator.

## Observations, assumptions, and decisions

### Observations

- iOS `CameraLanClient.stopLiveSession` accepted compatibility statuses `200/404` but rejected the final server status `204`.
- Android explicit authenticated DELETE already created a bounded, expiring tombstone containing only a control-token SHA-256 digest, but internal `CameraLanAuth.revoke` zeroed every digest without retaining that cleanup authority.
- `LocalApiServer.endLanLive` is the shared teardown boundary for producer/viewer close, socket exception, relay rejection, write timeout, expiry, and server stop. It already invokes `CameraLanAuth.revoke` before aborting sockets and dispatching `STOP_LIVE`.

### Assumptions

- The existing authenticated tombstone design is the binding security and compatibility design; no new persistence, plaintext token retention, or server route is needed.
- The report documents evidence but does not change runtime behavior, so the immutable source head remains the commit verified by all final jobs.

### Decisions

- Reuse one `retainControlTombstone` path for explicit DELETE and internal revocation. It copies only the already-hashed control digest, zeros all live credential arrays, preserves the original expiry, enforces the existing 128-entry bound, and zeros expired/evicted/cleared digests through existing paths.
- Keep `LocalApiServer.kt` unchanged because all relevant live teardown paths already call the corrected responsible-layer method.
- Accept exactly `200`, `204`, and `404` as terminal iOS cleanup responses; all other statuses and transport errors still throw.
- No documentation contract update was needed: `docs/architecture.md` already specifies idempotent `204` DELETE, original-expiry tombstones, and iOS `200/204/404` compatibility.

## TDD mutations and commits

Before each new test body, the test names its production mutation:

- Android: internal live revocation discards control authority instead of retaining its digest until expiry.
- iOS: `stopLiveSession` omits final `204` while accepting only legacy terminal statuses.

Commits:

```text
73bd30bdb733682f96a5e8c7f9a814447718d822 test(camera): cover live cleanup ordering
18e1c70614d217595d1e4cdaea1b19ebbfae9477 test(camera): compile live cleanup regression
0d7b9ac286c74d439d3eaee3d507131015f3b637 fix(camera): preserve live cleanup authority
```

The first Android RED submission exposed a test-only type error (`Any` versus `CameraLanAuth`) before reaching behavior. It is retained as immutable evidence but is not counted as the qualifying Android RED. Commit `18e1c70` corrected only that test type and produced the required behavioral RED before production changed.

## RED evidence

Submission commands:

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git android-test-debug COMMIT
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-test COMMIT ios-app/HavalEcoTrip.xcodeproj CameraVideoTests
/usr/local/bin/mac-mini-build status JOB
/usr/local/bin/mac-mini-build fetch JOB NEW_DESTINATION
(cd DESTINATION && sha256sum -c SHA256SUMS)
```

### iOS RED at `73bd30bdb733682f96a5e8c7f9a814447718d822`

- Job: `haval-ecotrip-git-73bd30bdb733682f-20261103T084540Z-4109`.
- Source archive SHA-256: `8ab0a9ae63c2715bf9c52ac80e9d0718f260b3c31806b88d7119e98f53f3f5dc`.
- Result: expected failure, rc 65. `CameraVideoTests` executed 93 tests with exactly 1 failure.
- Expected failure: `testStopLiveSessionAcceptsFinalAndLegacyTerminalStatuses` caught `rejected(204)` at `CameraLanClient.swift:110`; the other 92 tests passed.
- Fetched build log SHA-256: `2b920fe739cf5dbc299ec7a23156e6d4dc0c79a1fcc54978b612090633959a43`.
- `SHA256SUMS` SHA-256: `07fcf4199e6af1505844e1b3ec7cea576ceb23051dd38ce03dee51283cd84582`.
- Fetch destination: `/root/projects/haval-task9-artifacts/red-ios`.

### Android nonqualifying compile RED at `73bd30bdb733682f96a5e8c7f9a814447718d822`

- Job: `haval-ecotrip-git-73bd30bdb733682f-20261103T084540Z-25065`.
- Source archive SHA-256: `8ab0a9ae63c2715bf9c52ac80e9d0718f260b3c31806b88d7119e98f53f3f5dc`.
- Result: test compilation failed because the test helper result needed a local cast. Production was not changed.
- Fetched build log SHA-256: `de1734c3049b429493d7b733679999508691bd230969eabc2f184df69dfcc62d`.
- `SHA256SUMS` SHA-256: `af805dc4b5af1bfb85b29fe29245bca45056f2f163f3e3aa6ab1eda29675be0a`.
- Fetch destination: `/root/projects/haval-task9-artifacts/red-android-compile`.

### Android qualifying RED at `18e1c70614d217595d1e4cdaea1b19ebbfae9477`

- Job: `haval-ecotrip-git-18e1c70614d21759-20261103T084808Z-6932`.
- Source archive SHA-256: `ba6a48b0d0b57a5dfcb3e0a0a05a3c6dc90707464b4e838e9daa4221f449529d`.
- Result: expected behavioral failure, rc 1. Android executed 71 tests with exactly 1 failure.
- Expected failure: `internalLiveRevocationKeepsAuthenticatedDeleteIdempotentThroughOriginalExpiry` failed at the first authenticated DELETE assertion after internal revoke (`CameraLanAuthTest.kt:250`); the other 70 tests passed.
- Fetched build log SHA-256: `016f33620d5c1a245603e988236d5a03deb2a89247a4e79a6990c68089354246`.
- `SHA256SUMS` SHA-256: `f700b056977179c12e308726b311f4f4de25504c7ce087224473e075d8c43798`.
- Fetch destination: `/root/projects/haval-task9-artifacts/red-android-behavior`.

All fetched RED manifests passed `sha256sum -c SHA256SUMS`.

## Implementation

Production files:

- `app/src/main/java/br/com/redesurftank/ecotrip/managers/CameraLanAuth.kt`
- `ios-app/HavalEcoTrip/CameraLanClient.swift`

Test files:

- `app/src/test/java/br/com/redesurftank/ecotrip/managers/CameraLanAuthTest.kt`
- `ios-app/CameraVideoTests/CameraLanClientTests.swift`

No other source, bridge, build-control, dependency, configuration, or documentation file changed.

## Final GREEN verification at `0d7b9ac286c74d439d3eaee3d507131015f3b637`

All jobs used source archive SHA-256 `081b27b32aa8db458f822d6ecf413e02e2686bdc32d9a3f12ee9340591b67391`.

### Android full tests and Debug assemblies

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git android-test-debug 0d7b9ac286c74d439d3eaee3d507131015f3b637
```

- Job: `haval-ecotrip-git-0d7b9ac286c74d43-20261103T084948Z-3530`.
- Result: success, rc 0. All 71 source unit tests passed; app, cluster, and companion Debug assemblies passed; 115 Gradle tasks executed.
- App Debug APK SHA-256: `3e864004ada7f5ddb0eb5d4a6b2d5470ac5f82c55fdb97a10e1057e3a458727d`.
- Cluster Debug APK SHA-256: `50ddf06134beef0b2e5af36cd0ac7198133d6f737aaf16ed3ada2de88fa93432`.
- Companion Debug APK SHA-256: `315cede549718aad9bb221f58556ca1e298e4fd54ce94be17a708730c52f6a0c`.
- Build log SHA-256: `19c54ee836a421e30dfcc636a4a66c8043c21e59a3eafd67309766cb4ee5ee73`.
- `SHA256SUMS` SHA-256: `5720836f0d090c4bea0da81141a1be5de1eee25ba7759256819a6b4e9cc0ada9`.
- Fetch destination: `/root/projects/haval-task9-artifacts/green-android`.

### CameraVideoTests

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-test 0d7b9ac286c74d439d3eaee3d507131015f3b637 ios-app/HavalEcoTrip.xcodeproj CameraVideoTests
```

- Job: `haval-ecotrip-git-0d7b9ac286c74d43-20261103T084948Z-2154`.
- Result: success, rc 0. `CameraVideoTests` passed 93/93; `CameraVideoStoreTests` passed 35/35.
- Result bundle SHA-256: `c28a1190e6e811b32f957e5a2fe3fdf4de1201b4a4ec5e398fa000cfa34d2a2b`.
- Build log SHA-256: `a61c97390e946f02191c7a94fdd999a40abe7838852059aea459f89c58452dec`.
- `SHA256SUMS` SHA-256: `b0deb2c1b799d6764e9997bef745a1a7c93be68786ff326ae56850db6cec2180`.
- Fetch destination: `/root/projects/haval-task9-artifacts/green-ios-tests`.

### Full unsigned iOS simulator build

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-simulator 0d7b9ac286c74d439d3eaee3d507131015f3b637 ios-app/HavalEcoTrip.xcodeproj HavalEcoTrip
```

- Job: `haval-ecotrip-git-0d7b9ac286c74d43-20261103T084949Z-5511`.
- Result: success, rc 0, with `CODE_SIGNING_ALLOWED=NO` and `BUILD SUCCEEDED`.
- App bundle ZIP SHA-256: `36085e63a94a0b54436d8abaa282bff23b57e229206934a77ee316868e2da552`.
- Build log SHA-256: `477b1e73f30c1afc0d30680780fbc0ed733e5b5f5359cfe41a82ddef881a54e1`.
- `SHA256SUMS` SHA-256: `0d35e306e75996af235fd742bf3c203cb68f7a2d3b51c9c7e435aa6d5c13ab10`.
- Fetch destination: `/root/projects/haval-task9-artifacts/green-ios-simulator`.

Every fetched GREEN manifest passed a separate `sha256sum -c SHA256SUMS` run.

Coordinator-safe checks also passed:

```text
bash -n scripts/build-on-mac-mini.sh
git diff --check 09d86cf06385d57f53e18ed81c62de4fe4c54c92..0d7b9ac286c74d439d3eaee3d507131015f3b637
```

## Compatibility and security proof

- iOS live cleanup accepts final `204` and legacy `200/404`; it preserves the same session ID and bearer request contract. Any other HTTP status remains a rejection.
- Internal Android live teardown now retains only a copy of the SHA-256 control digest plus original expiry. It retains no plaintext token, producer token, viewer token, media token, proof, or video byte.
- All live credential arrays are zeroed before the tombstone is published. Existing `MessageDigest.isEqual` constant-time comparison is unchanged.
- Wrong tokens return `401`; the original control token returns `204` after internal revoke and on repeat; the same token returns `401` at original expiry.
- Existing focused tests remain green for explicit DELETE, 128-entry bound, eviction zeroing, expiry pruning/zeroing, process clear/zeroing, wrong-session rejection, one-time producer/viewer credentials, and replacement-safe handshake admission.
- Producer/viewer close, explicit DELETE, repeated DELETE, timeout/expiry, failed start, and process clear all converge on the existing synchronized auth/server boundaries. No validation or security control was weakened.
- No credentials, runtime data, logs, caches, generated build output, signing material, or service configuration entered source control.

## Review

- Final task-range review: no Critical, Important, or Minor findings.
- Review focus covered every `CameraLanAuth.revoke` caller, `LocalApiServer.endLanLive`, explicit DELETE ordering, tombstone retention/zeroing/bounds/expiry, iOS status compatibility, and the complete task diff.
- Limitation: the user prohibited subagents, so this was an author self-review rather than an independent fresh-context review.

## Residual concerns and hardware-only gaps

- Real producer/viewer socket-close ordering and DELETE retry timing still require physical EcoTrip/Camera APKs on the authorized vehicle hardware.
- Production-signed Binder/provider permissions, Bonjour discovery, real Wi-Fi interruption, socket close latency, and expiry during in-flight DELETE remain hardware/network gates.
- OEM camera capture/mux, H.264 playback on iPhone, simultaneous recording/live/download pressure, CPU/memory use, thermal behavior, 4G behavior, and power-loss durability remain outside this synthetic pre-release gate.
- Existing Android deprecation/language warnings were present in successful queue output and were not widened into this narrow task.

No release or hardware-validation claim is made.
