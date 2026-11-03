# Final whole-branch review fix report

Date: 2026-11-03

## Outcome and source heads

- EcoTrip source head: `ab536f0e0239ebfb3accf391f592a07d6adde1f6` on `codex/camera-lan-routing`, pushed to `origin`.
- Camera source head: `5db56589866f40d16e9a861728fbc137a1df9029` on `codex/continuous-trip-video-impl`, pushed to `origin`.
- EcoTrip source base supplied for this wave: `902f3121bd9984543c1c3be66971f0fe2d04dde7`; prior report head: `ccd3b7be3fc0928f22e38d4da048466405334af0`.
- Camera base supplied for this wave: `425b31e5ded9d6394126ecd6db97b7997305e4b1`.
- No controller-ledger edit, release/version/tag, TestFlight, deployment, installation, hardware operation, or publication occurred. No mobile build ran on the coordinator.

## Corrections

1. iOS validates each LAN session expiry against `receivedAt = now()` sampled after response decode. Both the 30-second challenge and 300-second session upper bounds saturate safely at `Int64.max`.
2. Android `CameraLanAuth` atomically authenticates and revokes a live session or authenticates its tombstone. A first valid DELETE zeros all live digests, retains only the control digest plus original expiry, and returns `204`; repeated authenticated DELETE returns `204` through that expiry. Tombstones are capped at 128 and their digests are zeroed on eviction, expiry, and clear.
3. `LocalApiServer` invokes atomic revoke before live teardown and emits an empty `204` with `Cache-Control: no-store`. Wrong session/token remains `401`.
4. iOS LAN cleanup retains retry identity on transport/nonterminal failures and treats legacy `200` plus final `204/404` as terminal during compatibility. A lost response after server-side deletion retries the same identity.
5. Before network I/O, a full partial is digest-verified: valid bytes are promoted immediately; corrupt bytes are deleted and restarted from offset zero. A terminal whole-file digest mismatch deletes the corrupt full partial. Short useful partials retain existing resume/cancel behavior.
6. Camera validation now states that reserve fallback applies when `reserveGb` is absent or invalid. `RetentionPlannerTest` uses binary GiB units and an accurate test name.
7. EcoTrip product, architecture, and quality docs now describe current bridge/Android/iOS/Camera automation and explicitly separate all physical-hardware gates.

## TDD commits

EcoTrip immutable tests-only commits:

```text
73814023cfa6adb7f856cb43ada373d162de46ff test(camera): cover final review regressions
584a7619c1e1186d7c2f6de214ee0160fb67019a test(camera): tighten tombstone and partial proof
ac77993810a9ff612c0299345b9388478935c0c1 test(camera): prove legacy cleanup is terminal
```

EcoTrip implementation and docs:

```text
e540e0cf9bd545a7e48b0c36d42eb21615aa3191 fix(camera): make LAN cleanup retry safe
ab536f0e0239ebfb3accf391f592a07d6adde1f6 docs(camera): record automated and hardware gates
```

Camera commits:

```text
f87b8894e40b4a27fbd103853df43584e7f8ca59 test(retention): use binary reserve units
5db56589866f40d16e9a861728fbc137a1df9029 docs(retention): clarify reserve fallback
```

The Camera change is test semantics plus prose; it has no missing production behavior that can honestly produce RED. Its tests-only commit was therefore verified green rather than manufacturing an artificial failure.

## RED evidence

Commands:

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git android-test-debug <COMMIT>
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-test <COMMIT> ios-app/HavalEcoTrip.xcodeproj CameraVideoTests
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-camera android-camera-verify <COMMIT>
/usr/local/bin/mac-mini-build status <JOB>
/usr/local/bin/mac-mini-build fetch <JOB> <NEW_DESTINATION>
(cd <DESTINATION> && sha256sum -c SHA256SUMS)
```

- EcoTrip iOS `7381402`: job `haval-ecotrip-git-73814023cfa6adb7-20261103T050837Z-28899`, archive `f23c01a9b3b12fd5174cf10b7c82e6783be9c7373003acdf278d8cb431e5a93f`. 91 tests ran; the three intended failures were response-time/overflow expiry, corrupt full-partial restart, and terminal digest cleanup. Build log `fcb9ff2a417bfffda27c76b9a41999c8a08ae3ca3593956ab7e674f748b2c432`; manifest `120de80cbe69fde389a6d394500d2422b6026a6e10765b0e049cd342bb5885bb`.
- EcoTrip Android `7381402`: job `haval-ecotrip-git-73814023cfa6adb7-20261103T050837Z-30969`, same archive. Expected test-compilation RED on missing `deleteSessionStatus`. Build log `2d67cf57f4cd7326ab86dbae38a4976d75f9b2c99898a60d4ab6cf34d6cdae9c`; manifest `61689d3cb35b7843c67c96ef69f97fdd95cbedc45f66efe07dccd4449acbacf0`.
- EcoTrip Android `584a761`: job `haval-ecotrip-git-584a7619c1e1186d-20261103T050942Z-14870`, archive `7b13da198e939b1c19444300bb2c7e5d0b7bb5304a687f5dd00e068c38d98678`. Expected test-compilation RED on the same missing DELETE contract. Build log `3f3083c4ba207f066468c520c32da7c0425b09300a5af29c736b7466595fb0ff`; manifest `23c1d9d514bb1c27565482d6b1ba53db26cd9e15008d323febf42f9137e029e9`.
- EcoTrip iOS `584a761`: job `haval-ecotrip-git-584a7619c1e1186d-20261103T050947Z-19411`, archive `5617b0a8d8f607283057a0b8f590fa772b827a2b4adc1514c628acf114a612c5`. 92 tests ran with five failures covering the missing expiry, partial, digest, legacy cleanup, and valid-full-promotion behavior. Build log `8c9bcc076504cd5cf2788019de28cc11547d2b5e91d4fcc44761771be35bd25a`; manifest `05a1036c56d88dad4037a6d96581c1f458cfcd5f7c61d490733d20c9bb719168`.
- EcoTrip iOS `ac77993`: job `haval-ecotrip-git-ac77993810a9ff61-20261103T051029Z-14592`, archive `7bfb913c9eb97ed45ff541136898d555e94d92c6e3873f205ce0298219d7a751`. 92 tests ran with six assertions/errors after tightening proof that legacy `200` actually clears pending cleanup. Build log `a076c96a1aa1c6a4d64ad64dbecf01f924ba8629f2261bbd3af2afe95e1469d2`; manifest `676e3040c36193a164f3eaf9fa93217aac855c45652a58c5ab5253337d979f3c`.
- Camera tests-only `f87b889`: job `haval-camera-f87b8894e40b4a27-20261103T050837Z-30716`, archive `073a5894b8052cf4a309a60311d4231c7caa5a1529ad131d51efc6ca32b763ae`, passed as expected for a unit/name correction. APK `16e2c52f5da056e875aebf76c8d49a6d9eff786846b10ebd2c699a4438cfdfe0`; log `dc1fb4750f0fded9a02d92ff916c4dbc905008dd2cf569f9b3574e`; manifest `7a4351b9e4133892f6ead8415b671820fb64c8fdfdbf27adaa492d06d83f3295`.

## Final verification from immutable source heads

### EcoTrip `ab536f0e0239ebfb3accf391f592a07d6adde1f6`

```text
cd bridge && npm test
```

Result: 66/66 Node tests passed, 0 failed.

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git android-test-debug ab536f0e0239ebfb3accf391f592a07d6adde1f6
```

- Job `haval-ecotrip-git-ab536f0e0239ebfb-20261103T051215Z-14244`, archive `acfd6c1dfe5b411ae0d38ca78854cb415b8a1f5555a47251a265ea0683bc6d38`.
- All 70 source unit tests passed; app, cluster, and companion Debug APK assemblies passed; 115 Gradle tasks, rc 0.
- App APK `28422232fe4c590c99cd84dda074982554852f4c5d553a468511bd0d0ed7db49`.
- Cluster APK `50ddf06134beef0b2e5af36cd0ac7198133d6f737aaf16ed3ada2de88fa93432`.
- Companion APK `315cede549718aad9bb221f58556ca1e298e4fd54ce94be17a708730c52f6a0c`.
- Build log `dd405f806d7811fe41c96c68e584b6752656119cd87c3e37e9946f6e9c43ef7d`; manifest `5e7863d93c36f3aa5e24b5448ff6669bce41cc31e7e17bc0b4b77f81e19a297f`.

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-test ab536f0e0239ebfb3accf391f592a07d6adde1f6 ios-app/HavalEcoTrip.xcodeproj CameraVideoTests
```

- Job `haval-ecotrip-git-ab536f0e0239ebfb-20261103T051215Z-22483`, archive `acfd6c1dfe5b411ae0d38ca78854cb415b8a1f5555a47251a265ea0683bc6d38`.
- 92/92 tests passed; `CameraVideoStoreTests` 35/35; rc 0.
- Result bundle `3a656cd609dbc075fbf45d06c8ce4c99d4ef5936d80d859e901d140ca0030940`.
- Build log `dfe6e17189ae9540918bc1c662933c5bdd10f77d15e75136829e30505f449441`; manifest `0464b67e0e1e561e3fb5a09110cc6297a38e7270e9e5b3bb57a73c1b9fec8ddc`.

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-simulator ab536f0e0239ebfb3accf391f592a07d6adde1f6 ios-app/HavalEcoTrip.xcodeproj HavalEcoTrip
```

- Job `haval-ecotrip-git-ab536f0e0239ebfb-20261103T051215Z-29724`, archive `21d1ae697beea39d4c1ad2c58a22650962cab0a9a81fdcfc302d29afcb1aa5ee`.
- Full unsigned simulator build passed with `CODE_SIGNING_ALLOWED=NO`, rc 0.
- App bundle `ccad5699dac1e259688fd988a39c63460a7067364db255dd6d4df265c84241eb`.
- Build log `be10b33bfc9152f3d23e08b550d57d04e93b629a5137c06c38ebd49042b5fe5a`; manifest `cb0eb5f059ab5a49bc57144765f122b6d57092998dd48fb980c261b5718ea3c9`.

Static checks also passed:

```text
bash -n scripts/build-on-mac-mini.sh
node --check bridge/server.js
node --check bridge/gateway.js
git diff --check 902f3121bd9984543c1c3be66971f0fe2d04dde7..ab536f0e0239ebfb3accf391f592a07d6adde1f6
```

### Camera `5db56589866f40d16e9a861728fbc137a1df9029`

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-camera android-camera-verify 5db56589866f40d16e9a861728fbc137a1df9029
```

- Job `haval-camera-5db56589866f40d1-20261103T051009Z-28062`, archive `adcc142719b0c893a6c4480dbc716bed9024eb35a42a13368fe5ad9101dfe68a`.
- JVM tests, Debug/native assembly, existing package verification, lint vital, alignment, and ZIP integrity passed; rc 0. No package was installed or published and no signing material/source changed.
- APK `760d8c372c6499939fb87e00d3906040a26db7d5f1b6fb7c4f17fb81eeb1db4e`.
- Build log `cd7adcda1b5f6fa32753debabc866c3ae6ef16b0c71d67a875ebace5d60cc975`; manifest `a4c9de1e45ec2701008b61d13410a1391e96ad09bf26ba73f4229c31a851ad10`.

All fetched manifests passed under `/root/projects/haval-final-review-artifacts/`.

## Files changed in this wave

EcoTrip:

- `app/src/main/java/br/com/redesurftank/ecotrip/managers/CameraLanAuth.kt`
- `app/src/main/java/br/com/redesurftank/ecotrip/managers/LocalApiServer.kt`
- `app/src/test/java/br/com/redesurftank/ecotrip/managers/CameraLanAuthTest.kt`
- `ios-app/HavalEcoTrip/CameraVideoStore.swift`
- `ios-app/CameraVideoTests/CameraVideoStoreTests.swift`
- `PRODUCT.md`
- `docs/architecture.md`
- `docs/quality.md`
- this report only above the source head

Camera:

- `app/src/test/java/br/com/redesurftank/havalcamera/RetentionPlannerTest.java`
- `docs/VALIDATION.md`

## Compatibility and security proof

- Tombstones contain no media/download/viewer/producer token and no plaintext control token: only SHA-256 control digest plus original expiry. Live credential byte arrays are zeroed before the tombstone becomes visible.
- Wrong control token and wrong session are rejected; repeated matching DELETE is accepted only until original expiry. Bound eviction, expiry pruning, and clear zero the retained digest under focused tests.
- Android emits final `204`; iOS accepts legacy `200` only as a temporary compatibility terminal and final `204/404`. Network and all other statuses preserve retry authority.
- Lost-response testing deletes server state on the first call, throws before the client receives a response, then proves retry with the same identity reaches terminal `204` before a replacement session is allocated.
- Session expiry tests advance the fake clock between POST and response and exercise saturation near `Int64.max`.
- Full partial handling is shared before LAN/remote branching and covered for both routes. Existing short-partial resume, cancellation, capacity, durable-write-before-ACK, safe-path, and no-silent-fallback tests remain green.
- No credential, digest, proof, video byte, runtime data, build output, cache, log, signing material, or service configuration was added to source control.

## Remaining hardware-only gates

- OEM camera capture and MP4 mux/finalization on the vehicle's Android 9 hardware.
- Installed, production-signed EcoTrip/Camera Binder/provider permission behavior and real teardown timing.
- Bonjour discovery, physical Wi-Fi interruption, Range resume, socket close latency, and expiry during real pending DELETE traffic.
- H.264 playback/share UI on an iPhone, real temporary-volume pressure, cancellation latency, and filesystem durability through power loss.
- Deployed bridge/WSS behavior, 4G latency/data use, simultaneous recording/live/download pressure, AVM coexistence, CPU/memory use, and thermal behavior.

No release or hardware-validation claim is made.
