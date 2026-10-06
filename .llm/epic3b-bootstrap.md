# Epic 3B.0 bootstrap development log

Validation date: 2026-10-05 (America/Los_Angeles).

## Identity and implementation

- Repository: `home-cortex-apple`, an existing independent Git repository in the workspace.
- Xcode project and shared scheme: `home-cortex-apple`.
- One native Swift/SwiftUI application target; product/display name: **Home Cortex**.
- Deployment target: iOS/iPadOS **17.0**; device families: iPhone and iPad (`1,2`).
- Initial bundle identifier: `com.jiankuang.homecortex`. Developer namespace ownership is pending confirmation before physical deployment. Override it through `HOME_CORTEX_BUNDLE_IDENTIFIER` in the ignored local signing configuration.
- Version/build: **0.1.0 (1)**.
- `App/` contains the app entry point and root view. `Features/Bootstrap/` contains the screen. `Core/` contains bundle metadata. `Resources/` contains the native asset catalog and app icon. Separate unit and UI test targets are included.
- Shared `Config/Base.xcconfig`, `Debug.xcconfig`, and `Release.xcconfig` provide a simple foundation for later Development/Production configuration. No backend environment configuration exists yet.
- No third-party packages, runtime dependencies, network calls, endpoint addresses, device permissions, credentials, pairing, or Client Interface V1 implementation.

## Toolchain

- Xcode **16.4**, build **16F6**.
- Apple Swift compiler **6.1.2** (`swiftlang-6.1.2.1.2`, `clang-1700.0.13.5`); Swift language mode **6.0**.
- iOS/iPhone Simulator SDK **18.5**; installed simulator runtime **iOS 18.6 (22G86)**.
- Project opens through the command-line toolchain: `plutil -lint` passes and `xcodebuild -list` discovers the app, unit test, and UI test targets plus the shared scheme.

## Simulator acceptance

- **iPhone 16 Pro, iOS 18.6**: Debug `xcodebuild build` returned `BUILD SUCCEEDED`.
- Installed with `simctl install`, launched with `simctl launch` without a debugger, and visually inspected the screenshot. The bootstrap title, local running label, iPhone platform, unconfigured integration label, and version/build all render correctly.
- Unit tests: **2 passed, 0 failures**. Verify the application bundle's version, build, display name, and both device families.
- UI tests: **1 passed, 0 failures**. Verify required screen content on initial launch and after terminate/relaunch.
- Full iPhone test action returned `TEST SUCCEEDED`.
- **iPad Pro 11-inch (M4), iOS 18.6**: Release `xcodebuild build` returned `BUILD SUCCEEDED`. Installed, launched without a debugger, and visually inspected the same screen with the iPad platform label and a centered, bounded layout.
- Full iPad Debug test action also returned `TEST SUCCEEDED`: **2 unit tests and 1 UI launch/relaunch test passed, 0 failures**.
- Build logs, result bundles, and simulator screenshots are retained locally under ignored `.local/`; these are not source artifacts.

## Signing and physical iPhone acceptance

- Configuration type: **automatic signing**, with an optional ignored `Config/Signing.local.xcconfig` for team and bundle identifier overrides. No signing secrets or local credentials are included in Git.
- Physical device known to CoreDevice: **Jian’s iPhone (iPhone 14)**. Cached device information reports iOS **18.6.2** and Developer Mode enabled; this is not a live verification while the device is unavailable.
- The user reported connecting the iPhone. Subsequent `devicectl list devices` still reports **unavailable**. `xcdevice list` reports it unavailable with “Browsing on the local area network for Jian’s iPhone” and advises unlocking/connecting the device. A live device connection has not been established by this toolchain.
- `security find-identity -v -p codesigning` reports **0 valid identities**.
- A Debug build for `generic/platform=iOS` was attempted and returned `BUILD FAILED`: **Signing for "home-cortex-apple" requires a development team. Select a development team in the Signing & Capabilities editor.**
- No signed device build, physical installation, Home Screen icon verification, or independent physical launch has been completed.
- Opening Xcode through the computer-use tool also failed with `kLSIncompatibleApplicationVersionErr`. The command-line Xcode toolchain does work. Local Xcode UI availability needs checking by the developer.

## Manual device steps and remaining work

Confirmed user action: iPhone cable connection was reported. No new trust, signing, or Developer Mode action has been confirmed during this run.

1. Unlock the iPhone and approve Trust This Computer if requested. Check Xcode's Devices and Simulators window for connection/preparation errors until the phone is available.
2. Open Xcode locally and select/add the developer's Apple account in Settings → Accounts. Resolve any local Xcode launch error if present.
3. Supply the development team ID and confirm a bundle identifier in that team's namespace using `Config/Signing.local.xcconfig` or target Signing & Capabilities. Keep automatic signing enabled.
4. If required by the live device, enable Settings → Privacy & Security → Developer Mode, restart, and confirm. Approve device access/developer trust only if iOS requests it. The cached device record already says Developer Mode is enabled.
5. Build and install to the connected iPhone. Stop debugging, return to the Home Screen, and tap Home Cortex. Confirm the screen renders and remains open independently; record the observed result here before declaring physical acceptance.

See `README.md` for the full reproducible workflow and Apple documentation references. Never send or record Apple passwords or signing key material.

## Known issues

- Physical acceptance is blocked by an unavailable device connection and missing development team/signing identity. The developer-controlled bundle namespace is not yet confirmed.
- Xcode emits a non-failing “Metadata extraction skipped. No AppIntents.framework dependency found” warning. This app intentionally has no App Intents. No Swift compile errors were observed.
- The Xcode UI launch failure from computer-use is separate from the working command-line build/test pipeline.

PHYSICAL IPHONE BOOTSTRAP: BLOCKED
