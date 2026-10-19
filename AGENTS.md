<!-- MAC_MINI_ANDROID_BUILD_BEGIN -->
## Android build destination

Use `docs/BUILD_ANDROID_ON_MAC_MINI.md` and `scripts/build-on-mac-mini.sh` for every Android, Gradle, or Kotlin build. The authorized Mac Mini queue is the only default build destination. Do not build on the coordinator host or fall back when the Mini is unavailable. Submit only an audited immutable commit whose exact build-control digest is allowlisted; keep signing material on its authorized host.
<!-- MAC_MINI_ANDROID_BUILD_END -->
