# Task 8 report — iOS camera gallery, verified downloads, and settings

Date: 2026-11-03  
Base: `6a93524b0b3adabea0b679ee8f8cf4e2e50dd43a`  
Final source head: `91bcd8b70be599511162a69afc1d6a7c40d60613`  
Branch: `codex/camera-lan-routing` (pushed; remote head matches)

## Observations

- The Camera canonical `TransferChunkCodec.java` defines HVT1 v1 as a fixed 56-byte big-endian header with unsigned 32-bit ordinal and unsigned 64-bit offset semantics. Swift fixtures were copied from the canonical Java fixture bytes, not regenerated from the Swift encoder.
- Task 6 exposes the documented LAN capability, challenge/session, catalog, and exact-Range segment endpoints. Its current catalog response may expose only a segment count, without each segment's size and SHA-256. Since Task 8 requires whole-segment verification before promotion, those LAN trips are displayed without downloadable segment rows rather than accepting unverifiable bytes.
- Task 7's `CameraRoutePolicy` resets internet authorization at every `beginAction`, when LAN becomes active, and when the action closes. Task 8 now uses separate policy instances for catalog and individual downloads.
- The existing cabin-audio screen remains in place. `GravacoesV2View` only gains the vehicle-camera entry and sheet.
- No connected car, Camera Android process, bridge deployment, or physical iPhone was available in this task.

## Assumptions

- The bridge remote endpoints and payloads consumed here are the Task 3 contracts; bridge behavior beyond those APIs was not invented or deployed.
- A completed trip is eligible only when `completed == true` and `end != nil`.
- A segment-count-only LAN catalog is insufficient evidence for a verified download. Failing closed is safer than deriving or trusting a missing digest.
- A download action ends after success, cancellation, or failure. A new download tap starts a fresh action and therefore requires fresh remote consent.

## Decisions

- Store final and route-specific `.partial` files under `Application Support/HavalCamera/<trip>/`; LAN and internet partial bytes have different names and never mix.
- Use LAN first. LAN unavailability may present an internet confirmation, but never initiates remote transport automatically. Each video/download has its own Task 7 policy and explicit confirmation.
- Send only the short LAN download credential to catalog/Range endpoints. The long bridge secret is used locally to verify the server proof and derive the challenge HMAC; it is not placed in the discovered LAN endpoint's headers, query, or body.
- Require exact Range offsets and `Content-Range`, capacity before transfer, durable file synchronization before every HVT1 DATA ACK, chunk SHA-256, EOF/whole-file SHA-256, and atomic `.partial` promotion.
- Reject malformed HVT1 magic/version/type/flags/length/digest/trailing bytes, offset overflow, and payloads above 262144 bytes.
- Keep deletion confirmation independent of internet/download consent. Keep Camera settings optimistic in the UI but replace them with authoritative revisioned responses, expose stale conflicts, and roll back command failures.
- Add no dependency and make no changes outside the user-authorized Task 8 files.

## Evidence

### TDD and queue commands

All Xcode work ran on the Mac Mini queue; no Android, Gradle, Kotlin, or Xcode command ran on the coordinator.

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-test <COMMIT> ios-app/HavalEcoTrip.xcodeproj CameraVideoTests
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-simulator <COMMIT> ios-app/HavalEcoTrip.xcodeproj HavalEcoTrip
/usr/local/bin/mac-mini-build status <JOB>
/usr/local/bin/mac-mini-build fetch <JOB> <NEW_DESTINATION>
(cd <DESTINATION> && sha256sum -c SHA256SUMS)
```

Initial immutable tests-only RED:

- Commit `b0aa4de1457a259a42fa6cdd27392f31d9d39312`.
- Job `haval-ecotrip-git-b0aa4de1457a259a-20261103T040302Z-12889`, archive SHA-256 `179f78e593b71fd610a2679823c60d7bb190cb58f8516a77aa07322b464b3083`.
- Result: expected failure, rc 65; terminal suite output recorded 26 executed tests and 2 intended Task 8 sentinel failures, with no unrelated failure in that output.
- Fetched manifest passed. `SHA256SUMS` `119a9b8e8f521703cb8fb410332363478e8160a6e3aab3e01526f585f2b0a881`; `build.log` `15736b2587624631de531e6aaa8fa5e6d6e46bfe0298acca06c4a8dcd9d52694`.

Implementation feedback jobs:

- `haval-ecotrip-git-3bf9468235f7d974-20261103T040628Z-4910`, archive `39e3e6143aeb8e8de1fd8dc7acf4213fe041ec0288367428aab5aa928d1d3729`: expected implementation iteration failed compile on a main-actor test default argument.
- `haval-ecotrip-git-e78d6d24dfe31575-20261103T040652Z-22759`, archive `c0993f9cb140f9f424f3821e7b21167606ffab1b9560a17489a4cde2560b33e2`: failed compile on expression precedence.
- `haval-ecotrip-git-b9aa25b679638e61-20261103T040717Z-302`, archive `8bf141304c3578ea9d86cc53fecfac48b835bef9482beeb992529c54df27ad62`: 64 tests executed, 2 failures (cap boundary fixture and cached file-size observation); both received narrow fixes.
- `haval-ecotrip-git-339e83bc4a053239-20261103T040801Z-21335`, archive `3efb4796680fd43964ce3da18502053cc41483cb6849591a6ff175c0e1c95a2a`: 64/64 tests passed.
- `haval-ecotrip-git-339e83bc4a053239-20261103T040859Z-5776`, archive `c726661097e1db672f10e0ccee068f0f8f2f1229336660ea4b839107a8ad2f10`: intermediate full simulator build passed.

Incremental consent RED:

- Commit `2f16e13f00314836` contains only the new consent regression test.
- Job `haval-ecotrip-git-2f16e13f00314836-20261103T040942Z-19639`, archive `0791a4da256059ee1a580988678d30ef9bc75221546a4d7db6575a6c37da01dd`.
- Result: expected compile RED, rc 65, because `beginDownloadAction` and `confirmDownloadInternet` did not yet exist; 3 failed build commands, no test execution.
- Fetched manifest passed. `SHA256SUMS` `c55bf18cbadbc72aef3e02c68905054e07a0ec99abba926861c60c69be01fb9a`; `build.log` `c7da02291aa9a5894356bb3d6f4f34cb932b0724fb65a648dbe84cb245ed36da`.

Final focused GREEN:

- Job `haval-ecotrip-git-91bcd8b70be59951-20261103T041123Z-626`, archive `3a250911ff6cb8f52e89bca7f4c5b2f7744f469d440a08d41a84943650933dfe`.
- Result: 65/65 tests passed, including 9/9 `CameraVideoStoreTests`; rc 0.
- Fetched manifest passed. `CameraVideoTests.xcresult.zip` `68603e2ef3824fd8fa0535b4d2d54cf166f78dd19a31eaaa6d2b289e77adcf68`; `build.log` `2c15bc3c55361cbef98c9d757b3ec93a2170cd5d9e87d0505eca67603a0c1531`; `SHA256SUMS` `3af1f072ca77fcbb2ab957e2b1b43a6a8fc20d6f63c08ee2f26aeddfb7827c83`.

Final full build:

- Job `haval-ecotrip-git-91bcd8b70be59951-20261103T041153Z-20077`, archive `c0e95ef9c9af24e7143f65b1cd39e5ee470542d791bc9629eb7b945d3f7ff2ff`.
- Result: `HavalEcoTrip` iOS simulator build succeeded with `CODE_SIGNING_ALLOWED=NO`; rc 0.
- Fetched manifest passed. `HavalEcoTrip-iphonesimulator-Debug.zip` `d3ba88747e568165f913680d52097f0599f1d1d3ea132f1d4dbbc60f422fdbfd`; `build.log` `6e364ae00cf85ea11a27dce69f857494b65ed6a1f8f91defd53b5558d47a7165`; `SHA256SUMS` `866c6c7af9be4e7c4e98359b03b96181ab6ab0b862c8b6b238c6f29732d412d1`.

### Commits

```text
b0aa4de test: define camera recordings contract
3bf9468 feat: add vehicle camera recordings and settings
e78d6d2 test: isolate camera store fixtures
b9aa25b fix: compile camera catalog store
339e83b fix: verify resumed camera segments
2f16e13 test: require scoped camera download consent
91bcd8b fix: scope remote camera download consent
```

### Changed source files

- `ios-app/HavalEcoTrip/CameraVideoStore.swift` (new)
- `ios-app/HavalEcoTrip/CameraRecordingsView.swift` (new)
- `ios-app/HavalEcoTrip/CameraSettingsView.swift` (new)
- `ios-app/CameraVideoTests/CameraVideoStoreTests.swift` (new)
- `ios-app/HavalEcoTrip/CameraVideoProtocol.swift`
- `ios-app/HavalEcoTrip/GravacoesV2View.swift`
- `ios-app/CameraVideoTests/CameraVideoProtocolTests.swift`
- `ios-app/project.yml`

### Security checks

- Exact HVT1 framing, flags/types/lengths/trailing bytes/digests/cap and unsigned numeric boundaries are regression-tested.
- LAN capability is required before credentials; challenge expiry/server proof are validated; nonce/session scope are checked; only short session/download credentials reach LAN catalog/Range calls.
- Remote owners use HTTPS and transfers require WSS without URL user info or fragments.
- Remote download is impossible until a fresh action is opened and explicitly confirmed; a new download or LAN action invalidates prior consent. LAN failure only presents confirmation and does not silently open remote transport.
- Route-specific partial identities, exact offsets, durable-before-ACK behavior, SHA-256 verification, capacity checks, atomic promotion, safe playback/share paths, and independent deletion confirmation have tests.

## Residual risks and limits

- Task 6's current count-only LAN catalog cannot support verified per-segment downloads. This implementation visibly fails closed for those entries. End-to-end LAN download remains blocked until the producer supplies per-segment ordinal, exact byte size, and SHA-256 in the catalog (or an equivalent authenticated metadata API).
- Bonjour discovery, challenge/session exchange, Range resume, bridge HVT1 streaming, Camera settings reconciliation, real storage pressure, cancellation timing, and playback/share were not exercised against physical iPhone/car/Camera hardware.
- Simulator/file-system tests prove the ordering calls and digest boundaries but cannot prove behavior during real device power loss.
- No archive, release signing, TestFlight, production deployment, publication, hardware access, or car access occurred.

## Fix round 1 — reviewer Critical/Important findings

Date: 2026-11-03  
EcoTrip starting head: `91bcd8b70be599511162a69afc1d6a7c40d60613`  
EcoTrip final head: `72f6d6e884022be0d2dc473f9785bcb29ec9405c`  
Camera starting head: `6f634432a48eae6e3b6ca3b27604bc5b2f9cc7d8`  
Camera final head: `3175dc041cf1da34514031d9ac81374b8bd721d3`  
Branches: `codex/camera-lan-routing` and `codex/continuous-trip-video-impl` (both pushed; worktrees clean).

### Observations

- The ledger explicitly authorized the cross-task additive catalog metadata change while retaining the legacy `segments` count. Before this round, neither the Camera provider nor LAN/MQTT catalogs carried the per-segment size and digest required for verified downloads.
- Task 6's actual fresh segment response is `200` with exact `Content-Length` and no `Content-Range`; resumed responses are `206` with exact `Content-Range: bytes <offset>-<last>/<total>` and exact remaining `Content-Length`.
- `URLSession.download(for:)` writes the HTTP body to a temporary file instead of materializing the MP4 as `Data`. The client then reads that file in chunks capped at 64 KiB into the route-specific partial.
- One focused iOS run recorded an unexpected runner exit in the pre-existing `CameraLiveSessionTests.testStaleFrameIsBlanked`. Xcode relaunched and all remaining tests passed, but returned rc 65. The unchanged immutable commit was rerun and passed all 80 tests; this was recorded as simulator-runner feedback rather than hidden.
- The existing cabin-audio entry and views remain unchanged.

### Assumptions

- Camera trip segment files and their stored SHA-256 values are authoritative only after the provider's existing completed-trip model reports them. Invalid/missing metadata is omitted rather than repaired or inferred.
- A remote transfer session DELETE is required for cancellation and terminal failure. Successful EOF removes the cached session identifier without an extra DELETE because the Task 3 transfer has completed.
- The final hardware residuals remain appropriate because this round had no physical Camera, car LAN, bridge deployment, or iPhone access.

### Decisions

- Canonical provider metadata is exactly:

```json
[{"segmentId":1,"byteSize":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]
```

- LAN and MQTT publish the same sanitized trip object (ordering shown for evidence):

```json
{"tripId":"42","source":"automatic","startMs":1,"endMs":2,"byteSize":3,"segmentCount":1,"completed":true,"segments":[{"segmentId":1,"byteSize":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]}
```

- Trip IDs must be canonical positive decimal `UInt64` strings. Segments must be 1-based, positive, unique and consecutive; each size is positive; aggregate size must add without overflow and equal the trip size; each digest is exactly 32 lowercase-hex bytes. Segment metadata objects with missing or additional keys fail closed.
- Final and partial destinations are standardized and must remain descendants of the configured camera root. LAN and internet partial names remain distinct.
- LAN credentials are cached per resolved endpoint for one gallery action, reused across catalog/reload/download, and revoked with the control token on close, expiry, or terminal failure. Remote cached IDs are removed after success and DELETE is sent on cancellation/failure/deletion cleanup.
- File writes are synchronized before DATA ACK. Cancellation is checked around stream reads and file writes. Promotion occurs only after exact length and whole-file SHA-256 verification.
- Settings responses are generation/revision-gated. Older delayed responses cannot replace newer authoritative state or roll back unrelated edits; controls are disabled while saving and conflicts trigger an authoritative refetch.

### Evidence

No Android, Gradle, Kotlin, or Xcode build ran on the coordinator. The exact queue command forms used were:

```text
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-camera android-camera-verify <COMMIT>
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git android-test-debug <COMMIT>
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-test <COMMIT> ios-app/HavalEcoTrip.xcodeproj CameraVideoTests
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-simulator <COMMIT> ios-app/HavalEcoTrip.xcodeproj HavalEcoTrip
/usr/local/bin/mac-mini-build status <JOB>
/usr/local/bin/mac-mini-build fetch <JOB> <NEW_DESTINATION>
```

All fetched manifests validated. Artifacts are outside the Git worktree at `/root/projects/haval-ecotrip-task8-artifacts/fix-round-1/`.

#### Immutable tests-only RED

- Camera commit `d80789c8f65b4cb6`; job `haval-camera-d80789c8f65b4cb6-20261103T042130Z-28103`; archive `245c56618a7c30278ef88d5857bd80ec4252d350b9371b68436a239fb44cabb7`; expected compile RED because `VideoCatalogProvider.segmentMetadataJson(Trip)` did not exist. Fetched `SHA256SUMS` hash `6cbe5360aa67d6ee700a1e52a45490d82eb2443920d50ab7414239e7afe8e521`.
- EcoTrip commit `4a9fc85f9d69e981`; Android job `haval-ecotrip-git-4a9fc85f9d69e981-20261103T042131Z-17820`; archive `21b4ec09b212b7aa0f1da15fa4cf59371d8ce9a1af9222085a19f86c0d5fef55`; 66 tests, exactly 3 intended failures (LAN metadata, invalid metadata fail-closed, MQTT parity). Fetched `SHA256SUMS` hash `abcc7cdf0dc0c4640451cfb77e3e9a299efa3bfd23572ad653255559e7eeda9d`.
- Same EcoTrip RED commit; iOS job `haval-ecotrip-git-4a9fc85f9d69e981-20261103T042131Z-19806`; same archive hash; expected compile RED for missing `CameraLANStream` and `CameraVideoFileSink` contracts. Fetched `SHA256SUMS` hash `7ecfc3afcf265280bcbdbcbc56043f4be21487dbc81b9cf8b17dcee544108869`.

#### Implementation feedback

- Camera `9b6b9b4`: job `haval-camera-9b6b9b490f5eee30-20261103T042313Z-23503`, archive `6750ead46bc3167ecaa487752bf248e27a58cf56c8c3fc31cf63c6f4a785b78e`; 279 tests, one Android-stub static-initializer failure. The matcher was made lazy. Manifest hash `b6657f76fd30a39bf1517314545df9e0702e368c9f788491a0cf334a188874b0`.
- iOS `6eb85d1`: job `haval-ecotrip-git-6eb85d1f5db7b760-20261103T043041Z-16155`, archive `559423c69888c53962ffb0e37c1618f05773bdc6ea2e46e722fe6cf05655560a`; main-actor default-argument compile failure. Manifest hash `432a76660a6e06089422d3011b6a4cd6234455a4db72c84ecff44a838948c90b`.
- iOS `78681c5`: job `haval-ecotrip-git-78681c56be2b1830-20261103T043108Z-1138`, archive `8285f35668c800308ac3206c9089d861f7ae9b1476633ba0d0b2205122c2bd9e`; test `await` inside XCTest autoclosure compile failure. Manifest hash `38b0d92304818495476f366c22f4dc27859dab673b7c6859f8e3acf16930efb0`.
- iOS `77e10a6`: job `haval-ecotrip-git-77e10a643325cfdf-20261103T043131Z-32565`, archive `044d139746f18111a76e39913446cd0802020606db0419ea7300628f742828b9`; 50 tests ran after compilation, with two focused behavior failures (pending-consent lifetime and cancellation-test observation). Manifest hash `6af34ff98a0c8a1276923aea58b13eef068c4bb929d2dff10e3bd2ce9e8aca5a`.
- iOS final commit first run: job `haval-ecotrip-git-72f6d6e884022be0-20261103T043224Z-32740`, archive `6c42001400277a0903067e1ee5938623034f51d3cb93789600e7a7077fd7635a`; runner unexpectedly exited in the pre-existing live-session test, then 50 relaunched tests passed; rc 65. Manifest hash `63e3926eeec27dbef0069997ea4db5480ddc8ea70f6bdafe5400bb20a272ade4`.

An accidental Camera submission used literal `HEAD`, resolved to unrelated canonical commit `2a4e1ac`, and was rejected before upload with `build_controls_not_approved`; no job or artifact was created.

#### GREEN and full builds

- Camera final `3175dc041cf1da34514031d9ac81374b8bd721d3`: job `haval-camera-3175dc041cf1da34-20261103T042348Z-23806`; archive `9727252c9e98b80a3a89c0507890e20fb27b525ac4acb431c4fe9551ca4cc903`; 279/279 debug unit tests passed, authorized debug/release verification and APK checks passed, rc 0. Artifact hashes: `haval-camera.apk` `8d80d1d1d226fc333cf4222d9aa8110fdc737a050c98762ce024c32ec3024f3c`, `build.log` `4377706d0c64432125f57ce6c61d8ae5d20c973db7913ad923d7c8c3c433962b`, manifest `68ed364ebc3d7e4feb457e4aeee90bb8ee75157e833b14099c3d3000a6fb7db4`.
- EcoTrip metadata implementation `fefbe026f27e2d89`: job `haval-ecotrip-git-fefbe026f27e2d89-20261103T042508Z-21303`; archive `dd10e5e0f9c72cd66e034cff609bdfedc213ebd71f2e0621e8118334d22cc21f`; 66-test app unit suite and all three debug assemblies passed, rc 0. Manifest hash `e760d539a08c9708d8db1b14ba13d86de939b62ca91766f6cca6933d66ed22c7`.
- Final iOS focused GREEN, unchanged commit rerun: job `haval-ecotrip-git-72f6d6e884022be0-20261103T043345Z-518`; archive `50341b1c15e8be51233e5daaf532edb7b64fd4efb4da02a9bb8e4757c2424757`; 80/80 tests passed, including 23/23 `CameraVideoStoreTests`, rc 0. Artifact hashes: `CameraVideoTests.xcresult.zip` `3b331054ecbb3b8328c8521d165f65514009adaa9cf90533abafbf87cce2a5a2`, `build.log` `bbb02ed9f7526dc77bb8556db90578c1de9d7eb4f5366aab1cc6b8dece370dbf`, manifest `91f10b215d12f5908312256bba67c490d636b40eb6d4d13c5416daa0642a0fba`.
- Final full iOS simulator build: job `haval-ecotrip-git-72f6d6e884022be0-20261103T043419Z-20375`; archive `78487976a2bfb7a8561653d8a05a5edc834d4c0315aa02f200b28bd604641ac9`; `HavalEcoTrip` build passed with `CODE_SIGNING_ALLOWED=NO`, rc 0. Artifact hashes: simulator zip `46d6244ac1bd863142473cdb3efad70561a5af4c6cc0d749275b4f8728475175`, `build.log` `e0fa491f55f13e43d70c94fea94c02fd29aebc58ad71781db3bdca63b586e11e`, manifest `bc0d2121100ab4a6cf0bce68479131a0425b12caba7017ce9d5494f436fb4f4c`.
- Final-head EcoTrip Android: job `haval-ecotrip-git-72f6d6e884022be0-20261103T043425Z-26680`; archive `5aa6711ccb3539777a210b2902758340538a3e3a62228b35d0dfc73849e755de`; 66-test app unit suite and app/cluster/companion debug assemblies passed, `BUILD SUCCESSFUL`, 115 tasks, rc 0. Artifact hashes: app APK `e8d6b31312483f1192dce67e7e6103d0fbfd4f12aacf6f9bea59cd076e282bb9`, cluster APK `50ddf06134beef0b2e5af36cd0ac7198133d6f737aaf16ed3ada2de88fa93432`, companion APK `315cede549718aad9bb221f58556ca1e298e4fd54ce94be17a708730c52f6a0c`, `build.log` `2ec2e17454fc16fc603ca6eca8bc7164f496b158f122a0abe5d8324037d23871`, manifest `f0cb93a4b31f81b58192c62a03213894c3123154e902d9e6560e4f4738410bd1`.

#### Commits and changed files

Camera commits:

```text
d80789c test: require canonical segment catalog metadata
9b6b9b4 feat: publish canonical segment catalog metadata
3175dc0 fix: lazily initialize provider URI matcher
```

Camera files:

- `app/src/main/java/br/com/redesurftank/havalcamera/VideoCatalogProvider.java`
- `app/src/test/java/br/com/redesurftank/havalcamera/VideoCatalogProviderTest.java`

EcoTrip commits:

```text
4a9fc85 test: cover camera gallery review findings
fefbe02 feat: publish verified camera segment metadata
6eb85d1 fix: harden camera recording transfers
78681c5 fix: initialize camera transport on main actor
77e10a6 test: await LAN chunk before assertion
72f6d6e fix: preserve pending camera download consent
```

EcoTrip files:

- `app/src/main/java/br/com/redesurftank/ecotrip/managers/CameraLanDownloads.kt`
- `app/src/main/java/br/com/redesurftank/ecotrip/managers/TripVideoBridge.kt`
- `app/src/test/java/br/com/redesurftank/ecotrip/managers/CameraLanDownloadsTest.kt`
- `app/src/test/java/br/com/redesurftank/ecotrip/managers/TripVideoBridgeTest.kt`
- `ios-app/CameraVideoTests/CameraVideoProtocolTests.swift`
- `ios-app/CameraVideoTests/CameraVideoStoreTests.swift`
- `ios-app/HavalEcoTrip/CameraRecordingsView.swift`
- `ios-app/HavalEcoTrip/CameraSettingsView.swift`
- `ios-app/HavalEcoTrip/CameraVideoStore.swift`

#### Security and lifecycle proof

- Provider/LAN/MQTT parity and invalid-metadata fail-closed behavior are covered by Camera and EcoTrip contract tests. A store integration test decodes the real catalog shape and completes a digest-verified LAN download.
- HVT1 tests retain the exact canonical 56-byte Java fixtures and add wrong magic/version, truncation, invalid ACK digest, malformed UTF-8 ERROR, and oversized ERROR rejection.
- Adapter tests prove short LAN credentials, one reused session, control-token DELETE, bounded file-backed reads, exact Range behavior, WSS bearer setup, terminal remote DELETE, and cached-ID removal.
- Store tests prove route-specific resume, exact offset/status/header validation, capacity rechecks, duplicate-task rejection, cancellation and join during stream/file write, no corrupt promotion, write -> synchronize -> ACK ordering, whole-segment verification, safe descendant paths, all-files playback/share gating, independent delete confirmation, and settings response ordering/conflict refetch.
- No silent LAN-to-internet fallback was introduced. Internet remains explicit and action-scoped; the expected pre-confirmation rejection no longer destroys the pending action needed for the user's confirmation.

### Residual hardware risks and limits

- Real Bonjour resolution, Camera challenge/session expiry timing, HTTP socket interruption during a large Range response, HVT1 bridge reconnection, filesystem durability across device power loss, low-storage races, AV playback/share UI, and Camera settings conflicts remain unverified on physical hardware.
- `URLSession.download(for:)` bounds app memory by using a temporary file, but real-device throughput, temporary-volume pressure, and cancellation latency need hardware observation.
- Existing unrelated build warnings remain (deprecated Android APIs/Gradle features and a retroactive `URL: Identifiable` warning). No warning was weakened or suppressed.
- No archive, TestFlight, deploy, release, install, production signing, hardware, or car operation occurred.

## Fix round 2 — remote schema, bounds, retryable cleanup, and real cancellation

### Observations

- The Task 3 bridge exact-key validator rejected the additive Android `segmentCount` field and normalized full catalogs without it, while Swift required it. Legacy count-only catalogs used numeric `segments` and had no per-segment metadata.
- The provider, LAN parser, and Swift decoder still treated the transfer-selection cap of 256 as the catalog cap. Task 3 permits 4,096 segment metadata entries and limits each metadata message to 1 MiB.
- LAN and remote cleanup removed the only local copy of the control authority before the server confirmed DELETE. A network failure therefore made cleanup non-retryable and could consume the 16 LAN sessions or sole remote transfer slot.
- Cooperative task cancellation alone could leave an adapter suspended in `URLSession` download or WebSocket receive. A 409 settings response was applied, but a failed optional GET then restored the stale pre-edit snapshot.

### Assumptions

- The ledger ruling authorizes the additive Camera provider bound and the approved bridge files; no other cross-task production file was needed.
- Bridge-normalized full catalog trips use `segmentCount` plus canonical `segments`; normalized legacy summaries use `segmentCount` and omit `segments`, so they remain visible but cannot become download selections.
- Provider metadata is ASCII-only canonical JSON, so its explicit 1,048,576-character bound is also its UTF-8 byte bound.
- DELETE 204 and 404 are the only terminal cleanup acknowledgements. Transport errors and every other status retain the in-memory cleanup record and prevent allocation of another slot.

### Decisions

- `normalizeCatalog` accepts exact Android full metadata, compatible older full arrays without an explicit count, and legacy numeric/count-only summaries. It always emits `segmentCount`; it emits `segments` only when verified metadata exists. Full arrays require an exact count, consecutive IDs, positive sizes, exact aggregate, lowercase SHA-256, and at most 4,096 entries.
- Camera rejects provider metadata outside 1...4,096 or beyond 1 MiB before publishing a Binder row; an invalid completed trip is omitted rather than aborting the whole query. EcoTrip LAN and Swift use the same 4,096 catalog boundary. The 256 cap remains only on transfer/deletion selection.
- LAN and remote DELETE authority moves into retry records before network I/O and is cleared only after 204/404. A pending failed cleanup is retried before a new session/transfer is created; failure blocks new allocation. Successful transfer completion still removes the cached remote ID without an unnecessary DELETE.
- LAN uses an explicit cancellable `URLSessionDownloadTask` handle and file-backed temporary download. Cancellation invokes the underlying task immediately. Remote cancellation closes the WebSocket from a task cancellation handler, unblocking receive before bounded join.
- A 409 body immediately replaces local settings and enters conflict state. The optional refetch may improve that snapshot, but failure leaves the 409 authority and revision intact.

Canonical bridge output used by the Node and Swift cross-runtime tests:

```json
{"ok":true,"catalogRevision":7,"updatedAt":1700000000007,"trips":[{"tripId":"42","source":"automatic","startMs":1000,"endMs":2000,"byteSize":3,"completed":true,"segmentCount":1,"segments":[{"segmentId":1,"byteSize":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]}]}
```

Legacy normalized trips retain the same trip fields and `segmentCount`, with `segments` absent.

### Evidence

No Android, Gradle, Kotlin, or Xcode build ran on the coordinator. Node 24.22.2 ran only the bridge suite. Queue commands were:

```text
node --test --test-name-pattern='catalog' test/video-relay.test.js
npm test
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-camera android-camera-verify <COMMIT>
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git android-test-debug <COMMIT>
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-test <COMMIT> ios-app/HavalEcoTrip.xcodeproj CameraVideoTests
env -u LC_ALL LC_COLLATE=C /usr/local/bin/mac-mini-build submit-git /root/projects/haval-ecotrip-git xcode-native-simulator <COMMIT> ios-app/HavalEcoTrip.xcodeproj HavalEcoTrip
/usr/local/bin/mac-mini-build status <JOB>
/usr/local/bin/mac-mini-build fetch <JOB> <NEW_DESTINATION>
(cd <DESTINATION> && sha256sum -c SHA256SUMS)
```

Artifacts are outside the worktrees under `/root/projects/haval-ecotrip-task8-artifacts/fix-round-2/`; every fetched `SHA256SUMS` manifest passed.

#### Immutable tests-only RED

- Camera `dd1b9b2c83e081f3`: job `haval-camera-dd1b9b2c83e081f3-20261103T044416Z-29438`, archive `3acf768d86710d8f5b2bd22a28c4f87cded2746fb368d1b3c4582a01c439e089`; 280 tests ran with the one intended provider-bound failure. Manifest `2d8f592223e569cfe1a76ce965fe1ef250eadf5dd5d7df8aea58d48430d7965d`; log `3d7fd008276a53a358ee5240079a8a86460f8e4f45b31deebe9a36c849e95702`.
- EcoTrip `a4a070eb77e24a39`: Android job `haval-ecotrip-git-a4a070eb77e24a39-20261103T044416Z-21890`, archive `2ecebc025aa77db881ad16d1e5ece1e2866aa86b1243fcf299ee393e5ab44899`; 67 tests ran with the one intended 4,096-bound failure. Manifest `d9d2993cb9f88d8e68b495799397f01db9e6c9519758f275aaedf0bda95dfc84`; log `57cc5737839807a8a6b6c10dffeea69aacc0de7b754525300d4481f81ff7b63f`.
- The same EcoTrip RED commit used iOS job `haval-ecotrip-git-a4a070eb77e24a39-20261103T044416Z-22682`, same archive; expected compile RED because the cancellable `CameraHTTPDownload` contract did not exist. Manifest `ee62ac246744c958c4aeb9d34be58e106937b10c1c597670989fab6f519e6c59`; log `28396b25ad7a5c2b636de296a888df0ecb98acd57dbfc46614d4dac05107cc1f`.
- Coordinator Node catalog RED at `a4a070e`: 7 focused tests, 1 pass and 6 expected schema/bound failures; no production code was edited before this run.

#### Implementation feedback

- iOS `5ff074888f730a48` compiled and all 55 relaunched tests passed, including 28/28 `CameraVideoStoreTests`, but the pre-existing live-session simulator process unexpectedly exited before relaunch, so xcodebuild returned 65. Job `haval-ecotrip-git-5ff074888f730a48-20261103T044535Z-21269`, archive `8a046b6c34977a3dc93dee61640a4461712f44d6d8a8ae57b54368a63e0e4020`; manifest `cd95094375410b9432209140e15342759bece04f9100686109d8feb9eeb51e48`; log `fb4d7bb927c1074ea25e7504a267f17c3a545594a1c80e8834963d80e0957719`.
- Android `5ff074888f730a48` passed the 67-test app suite and all three debug assemblies, 115 tasks, rc 0. Job `haval-ecotrip-git-5ff074888f730a48-20261103T044535Z-23142`, same archive; fetched manifest `6af1997ac6f8257ed2988c90a78be72f50a2d548545eaac36c036c059f74bb79`.
- The first full Node run found one pre-existing multi-segment fixture that appended metadata without incrementing the newly canonical count. Commits `39ba907` and `443adc3` made that fixture and the duplicate-ordinal negative fixture otherwise fully valid. The final suite passed.

#### GREEN and full builds

- Bridge final `5dd74a42671f12f5`: full Node suite 66/66 passed, including exact Android JSON -> normalized GET -> Swift-compatible schema, legacy summary, 4,096/4,097, malformed metadata, HVT1, transfer, settings, and deletion contracts.
- Camera final `425b31e5ded9d639`: job `haval-camera-425b31e5ded9d639-20261103T044535Z-21818`, archive `ea6fd24f98d69a54226053b755bcd350aef24998cfe5220c4c3eddd14c731528`; 280/280 debug tests and the approved Camera verification profile passed, rc 0. APK `ca922d634bee9a3e58d074fe2710e896ff868f06987d13dbd64dd74277996462`; log `e69a2e970b0f0b86102516ee5e5a0466a5e61d535ccdc7ef3a23396a155107b4`; manifest `64f314be4ee3d177a7285dbb1fe50fd6cf8a9c6cb5c4f9337cfe305f5cbbf2a5`.
- EcoTrip Android final `5dd74a42671f12f5`: job `haval-ecotrip-git-5dd74a42671f12f5-20261103T044706Z-3386`, archive `b372df458109c042842609f48b18fb41d7b974772afd771da9719d0df6317017`; 67-test app suite and app/cluster/companion debug assemblies passed, 115 tasks, rc 0. App APK `f383643644aa6dadb48fba807d03347625a257d66e56355bd98062427b071584`; cluster APK `50ddf06134beef0b2e5af36cd0ac7198133d6f737aaf16ed3ada2de88fa93432`; companion APK `315cede549718aad9bb221f58556ca1e298e4fd54ce94be17a708730c52f6a0c`; log `0941f48b8d76a84625efc1bad33d247ad1d89234998dff31a086e33cc997036f`; manifest `b3304aaea8748daa50f1842009fa6c850bf6366aafb5854e518ca12ff818148d`.
- iOS focused final `5dd74a42671f12f5`: job `haval-ecotrip-git-5dd74a42671f12f5-20261103T044706Z-22805`, same archive; 85/85 tests passed, including 28/28 `CameraVideoStoreTests`, rc 0. Result zip `1f96c4433ae419157e99133c72879030a739883832bbe7c743f294aae7793c5a`; log `764537bffe75b09e5ce1b20c53f3bff9d93f773d100416174d84125f235af4b6`; manifest `4a41e2fa1fd3fcafa24feb3094a4f06cffe41b98dcc1515b6e15e964e036e421`.
- Full unsigned iOS simulator build at `5dd74a42671f12f5`: job `haval-ecotrip-git-5dd74a42671f12f5-20261103T044706Z-16996`, same archive; `HavalEcoTrip` passed with `CODE_SIGNING_ALLOWED=NO`, rc 0. Simulator zip `580d02cef1b4632003bd0b2c34f24e1349908beb111378597d0c029886c7b4c4`; log `2d509bdbd35cc4bc9027a8861eae79f07a6c3f3e542a05a13779822aa505134d`; manifest `3a165066af84333a6e37f77757025a4a9c38eba1c62ffa1400dbaef12c8ee0f1`.

#### Commits and changed files

Camera commits:

```text
dd1b9b2 test(camera): cover catalog metadata bounds
425b31e fix(camera): bound catalog metadata publication
```

Camera files:

- `app/src/main/java/br/com/redesurftank/havalcamera/VideoCatalogProvider.java`
- `app/src/test/java/br/com/redesurftank/havalcamera/VideoCatalogProviderTest.java`

EcoTrip commits before this report-only commit:

```text
a4a070e test(camera): cover task 8 round 2 regressions
5ff0748 fix(camera): align catalog and retry cleanup lifecycle
39ba907 test(bridge): keep multi-segment fixture canonical
443adc3 test(bridge): isolate duplicate ordinal validation
5dd74a4 test(camera): prove cleanup survives session cap cycles
```

EcoTrip files:

- `app/src/main/java/br/com/redesurftank/ecotrip/managers/CameraLanDownloads.kt`
- `app/src/test/java/br/com/redesurftank/ecotrip/managers/CameraLanDownloadsTest.kt`
- `bridge/video-relay.js`
- `bridge/test/video-relay.test.js`
- `ios-app/HavalEcoTrip/CameraVideoStore.swift`
- `ios-app/CameraVideoTests/CameraVideoStoreTests.swift`
- `.superpowers/sdd/2026-11-02-camera-lan-routing/task-8-report.md`

#### Security and session proof

- Exact-key bridge validation preserves no Camera-local path/codec extras. Full metadata must match count, order, size aggregate, and digest; legacy summaries have no downloadable segment objects. Provider and LAN bounds reject 4,097 before exposure, while 4,096 remains visible.
- Failed cleanup tests retain the original LAN control token/session ID and remote session ID across a failed DELETE, retry before allocation, clear only on 204, and complete 20 LAN gallery cycles without exceeding one active fake server session. The remote fake refuses POST while its sole slot remains occupied, proving retry precedes reallocation.
- Adapter cancellation fakes deliberately ignore cooperative task cancellation. Tests prove the explicit LAN download cancel closure and remote socket close are called within the bounded observation window and unblock join without promotion.
- Existing tests continue to prove action-scoped internet consent, no silent fallback, route-specific partial identity, exact Range/status/length, bounded file chunks, capacity checks, write -> synchronize -> ACK ordering, whole-file SHA-256, safe descendant paths, deletion confirmation, and authoritative settings ordering.
- No dependency, credential logging, controller-ledger edit, archive, TestFlight, deploy, install, release publication, production signing, hardware, or car access was introduced.

### Residual hardware risks and limits

- Physical Camera/bridge behavior remains unverified for Binder pressure at the 4,096 boundary, real Wi-Fi interruption during Range download, server expiry during pending DELETE retry, WebSocket close latency, filesystem durability through power loss, low-storage races, and settings conflicts against real Camera timing.
- The simulator proves the explicit cancellation ownership contract and the production adapter uses a real `URLSessionDownloadTask`, but real-device network-stack cancellation latency still requires hardware observation.
- Existing unrelated Android deprecation/Gradle warnings and the known intermittent simulator exit in the pre-existing live-session tests remain. The unchanged final-head rerun passed 85/85.
