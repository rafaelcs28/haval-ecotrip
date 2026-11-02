# Android builds on the Mac Mini

The authorized Mac Mini queue is the default destination for Android builds. Do not run Gradle on the coordinator host and do not fall back automatically when the Mini is unavailable. Report the outage and wait.

## Submit an audited Debug build

Only an immutable Git commit whose build-control digest has been reviewed and locally allowlisted can be submitted:

```sh
scripts/build-on-mac-mini.sh COMMIT
```

The coordinator resolves the full commit SHA, checks tracked filenames and contents for high-confidence credential patterns, verifies the reviewed build-control digest, creates a source archive, computes its SHA-256, and sends it to a unique queue directory. A finding blocks the job before transfer and never prints the matched value.

Use the returned job identifier:

```sh
mac-mini-build status JOB_ID
mac-mini-build fetch JOB_ID NEW_EMPTY_DESTINATION
```

`fetch` refuses an existing destination and verifies `SHA256SUMS`. A successful Android Debug job returns the APK, `build.log`, and checksums.

Projects without Git are never submitted implicitly. First migrate the intended source to an authorized commit or obtain approval for an explicit sanitized manifest. Never copy an entire working directory.

## Isolation and signing

Each job has separate incoming, work, output, log, and state locations. The runner verifies the archive and rejects unsafe paths, credential filenames, excessive size, or insufficient disk space.

Android Debug uses the project Gradle wrapper with constrained resources, JDK 17, and the installed Android SDK. The runner refuses to create a missing Debug keystore. Signing material remains on the authorized build host and must not enter the repository or source archive.

Release builds are disabled. Enabling release requires separate review of artifact, signing identity, credential location, and publication destination.

Xcode simulator validation is a separate queue job with an audited commit, explicit project/scheme, and `CODE_SIGNING_ALLOWED=NO`. Device archives, distribution, and App Store publication remain outside this flow.
