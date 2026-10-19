# Android builds on the Mac Mini

The authorized Mac Mini queue is the default destination for Android builds. Do not run Gradle on the coordinator host and do not fall back automatically when the Mini is unavailable. Report the outage and wait.

## Submit an audited Debug build

Only an immutable Git commit whose build-control digest has been reviewed and locally allowlisted can be submitted:

```sh
scripts/build-on-mac-mini.sh "$COMMIT"
```

The coordinator resolves the full commit SHA, checks tracked filenames and file contents for high-confidence credential patterns, verifies the reviewed build-control digest, creates a source archive, computes its SHA-256, and sends it to a unique queue directory. A finding blocks the job before transfer and never prints the matched value.

Use the returned job identifier:

```sh
mac-mini-build status "$JOB_ID"
mac-mini-build fetch "$JOB_ID" "$NEW_EMPTY_DESTINATION"
```

`fetch` refuses an existing destination and verifies `SHA256SUMS`. A successful Android Debug job returns the APK, `build.log`, and `SHA256SUMS`.

Projects without Git are never submitted implicitly. First migrate the intended source to an authorized commit or obtain approval for an explicit sanitized manifest. Never copy an entire working directory.

## Isolation and queue behavior

Each job has separate `incoming`, `work`, `out`, `logs`, and `state` locations. Existing project copies are never destinations. The runner processes one job at a time, survives the submitting SSH session, verifies the input hash, and rejects absolute paths, parent traversal, archive links, credential filenames, archives above 5 GiB, or a build host with less than 15 GiB free.

Android and Xcode commands have a 45-minute timeout. Failed work directories and logs remain available for diagnosis; cleanup is explicit so failure evidence is not silently destroyed.

Filename and content scanning reduce risk but cannot prove arbitrary source text contains no secret. Review each new commit and its build scripts before adding its exact SHA and build-control digest to the private allowlist.

## Toolchain and signing

Android Debug uses the project Gradle wrapper with `--no-daemon`, one worker, in-process Kotlin compilation, JDK 17, and the installed Android SDK. The runner refuses to create a missing Debug keystore. Debug signing material remains on the authorized build host and must not be tracked by Git or included in the source archive.

Release builds are disabled. Enabling release requires separate review of artifact type, signing identity, credential location, and publication destination. Signing keys must never enter the source archive or repository.

For Xcode simulator validation, the queue accepts an audited Git commit plus an explicit project and scheme. It builds Debug for `iphonesimulator` with `CODE_SIGNING_ALLOWED=NO` and returns a zipped `.app`, log, and checksums. Device archives, notarization, distribution, and App Store publication are outside this flow.

## Validation status

The queue's `probe`, `status`, and `fetch` commands passed end-to-end tests with synthetic archives and verified output hashes. The first reviewed Android candidate was blocked before transfer because signing material was tracked by Git. No real APK was produced from that unsafe commit.
