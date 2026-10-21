# Xcode Security Settings

Security build settings decisions for Swiftty (the XcodeGen app targets in `Apps/project.yml`: MobileClient, CatalystClient, VisionClient, TVClient, WatchCompanion).

Settings live in `Apps/project.yml` (the `.xcodeproj` is generated and gitignored) and in the per-target base entitlements `Apps/<Target>/<Target>.entitlements`, which `Scripts/configure-links.sh` merges into `Apps/Config/Generated/`. The plan approved for this record is `xcode-security-audit-plan.md`.

## Enabled settings

- `ENABLE_ENHANCED_SECURITY`: project level in `Apps/project.yml` (`settings.base`), inherited by all five targets. Cascades `ENABLE_POINTER_AUTHENTICATION` (arm64 + arm64e), `ENABLE_SECURITY_COMPILER_WARNINGS`, `GCC_WARN_SHADOW`, typed allocator support and libc++ hardening.
- `iOSPackagesShouldBuildARM64e`: written to the generated project's `WorkspaceSettings.xcsettings` by `Scripts/configure-arm64e-packages.sh` (XcodeGen `postGenCommand`). The app targets are thin wrappers, so the package code needs the arm64e slice for pointer authentication to cover it. Xcode 27 reads only this key: the `macOS…`/`visionOS…` variants do not exist in its frameworks. It produces arm64e package builds for iOS, visionOS and watchOS devices. Mac Catalyst and tvOS packages stay arm64.
- `EXCLUDED_ARCHS[sdk=*simulator*]` to `x86_64` (project level): with the package flag on, Xcode builds simulator package products for arm64 only, and an x86_64 app slice then fails with "Unable to resolve module dependency". macOS 27 runs only on Apple silicon, so the Intel simulator slice is unused.
- `com.apple.security.hardened-process`, `…enhanced-security-version-string` to `2`, `…hardened-heap`, `…dyld-ro`, `…platform-restrictions-string` to `2`: MobileClient, CatalystClient, VisionClient.
- `com.apple.security.hardened-process.checked-allocations` with `…checked-allocations.soft-mode`: MobileClient, CatalystClient, VisionClient. Soft mode produces simulated crash reports without terminating. Disable soft mode only after those reports are clean on A19 / M5 or later hardware.
- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`, `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`, `GCC_WARN_64_TO_32_BIT_CONVERSION`, `CLANG_WARN_EMPTY_BODY`: already set at project level by XcodeGen's default presets (not in `project.yml`). The Xcode targets compile only Swift, so these and the other C/Objective-C warning and static analyzer settings have little effect here.

## Disabled settings

- `ENABLE_POINTER_AUTHENTICATION` to `NO` (and `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` to `NO`) on CatalystClient and TVClient, at target level in `Apps/project.yml`:
  Xcode 27 does not build package products as arm64e for Mac Catalyst or tvOS, so an arm64e app slice cannot import `RoamingApp` (`Unable to resolve module dependency: 'RoamingApp'`, generic Mac Catalyst and tvOS device builds, 2026-10-21).
  The rest of Enhanced Security (security warnings, typed allocators, libc++ hardening and, on Catalyst, the hardened-process entitlements) still applies.
  Lift the override when Xcode builds packages as arm64e for these platforms.

## Deferred

Settings considered but not yet enabled. Revisit them later.

- `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` and `com.apple.security.hardened-process.checked-allocations.enforce-checked-pointer-arithmetic-overflow` (checked pointer arithmetic, MobileClient only):
  App code is almost entirely Swift, where integer overflow already traps.
  The C surface is small (swift-nio C shims, system zlib).
  It is only effective on A20 Pro or later, and it has no soft mode, so a latent bug terminates the app in production.
  Revisit after a release or two of memory-tagging soft-mode crash reports come back clean, enabling it first in a TestFlight build.
- Enhanced Security entitlements for TVClient and WatchCompanion:
  The capability covers iOS, macOS, visionOS and DriverKit only. They still inherit the project-level build setting.
- Enhanced Security for the SwiftPM-built native Mac app (Swiftty.app and its helpers, `swifttyd`):
  Built with `swift build` and signed by `Scripts/package-swiftmux.sh`, so Xcode's build setting and arm64e do not apply.
  Hardened-process entitlements at `codesign` time need separate validation with Developer ID.
- C warning flags for the SwiftPM C targets (`SwiftMuxLauncher`, `CAllocCounter`) via `cSettings` `unsafeFlags`:
  Not approved this round. `unsafeFlags` would make the package unusable as a remote dependency.
- `CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`, `CLANG_WARN_ASSIGN_ENUM`, `GCC_WARN_SIGN_COMPARE`, `CLANG_ANALYZER_SECURITY_BUFFER_OVERFLOW_EXPERIMENTAL`:
  No C/Objective-C in the Xcode targets. They would only matter through the SwiftPM C targets above.
- `ENABLE_C_BOUNDS_SAFETY`:
  Requires an annotation-based programming model. Candidate scope is `Sources/SwiftMuxLauncher/main.c`. Use the `adopt-c-bounds-safety` skill.
