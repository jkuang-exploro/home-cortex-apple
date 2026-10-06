# Home Cortex for Apple

`home-cortex-apple` is the independent native Swift/SwiftUI iPhone and iPad client. The Xcode project and shared scheme are named `home-cortex-apple`; the installed app is **Home Cortex**.

This Epic 3B.0 bootstrap displays the device platform, local app status, version/build, and an explicit “Not configured yet” Client Interface V1 label. It has no backend connection, authentication, pairing, camera, microphone, telemetry, or embodiment functionality.

## Prerequisites

- Xcode 16.4 or newer with iOS platform support and an installed iOS simulator runtime.
- iOS/iPadOS 17.0 or newer on the destination device.
- For physical deployment: a connected/unlocked iPhone and an Apple account/team configured in Xcode. Simulator builds need no Apple account.

## Open and run

```sh
open home-cortex-apple.xcodeproj
```

Select the `home-cortex-apple` scheme, choose an iPhone simulator, and press Run (⌘R). Choose an iPad simulator to run the same application on iPad.

For command-line builds, list the available simulators and substitute a device name installed on your Mac:

```sh
xcrun simctl list devices available
xcodebuild -project home-cortex-apple.xcodeproj -scheme home-cortex-apple \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .local/DerivedData build
xcodebuild -project home-cortex-apple.xcodeproj -scheme home-cortex-apple \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' \
  -derivedDataPath .local/DerivedData build
```

## Physical iPhone and signing

1. Connect and unlock the iPhone. Approve **Trust This Computer** if prompted.
2. In **Xcode → Settings → Accounts**, add/select your Apple account locally.
3. In the app target's **Signing & Capabilities**, keep **Automatically manage signing** enabled and select your team. Use a bundle identifier your team controls. The initial identifier is `com.jiankuang.homecortex`; its namespace must be confirmed before device deployment.
4. To keep machine-specific signing out of Git, copy `Config/Signing.example.xcconfig` to `Config/Signing.local.xcconfig`, replace `YOUR_TEAM_ID`, and adjust the identifier as needed. The local file is ignored. Xcode can also select the team in project settings; avoid committing that local selection accidentally.
5. Select the physical iPhone as the run destination. If Xcode requests Developer Mode, enable **Settings → Privacy & Security → Developer Mode** on the iPhone, restart, then confirm enabling it. Approve any device-access prompts. If iOS explicitly asks to trust the developer, follow its **Settings → General → VPN & Device Management** prompt.
6. Run from Xcode. After installation, stop the debugger, return to the iPhone Home Screen, and tap **Home Cortex**. Confirm the bootstrap screen renders and stays open. This independent launch is required for physical acceptance.

Automatic signing lets Xcode manage the development provisioning assets. Do not put Apple passwords, certificates, private keys, or provisioning profiles in this repository. See Apple's [device run workflow](https://developer.apple.com/documentation/Xcode/running-your-app-on-simulated-or-physical-devices) and [Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## Tests

Use Product → Test (⌘U), or:

```sh
xcodebuild -project home-cortex-apple.xcodeproj -scheme home-cortex-apple \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .local/DerivedData -resultBundlePath .local/BootstrapTests.xcresult \
  -parallel-testing-enabled NO test
```

Use a fresh result bundle path on each run. Unit tests verify bundled application metadata and iPhone/iPad support. The UI test checks launch, required screen content, termination, and relaunch.

## Structure and configuration

- `home-cortex-apple/App/`: app entry point and root view.
- `home-cortex-apple/Features/Bootstrap/`: bootstrap screen.
- `home-cortex-apple/Core/`: bundled app metadata.
- `home-cortex-apple/Resources/`: native asset catalog and app icon.
- `home-cortex-appleTests/`, `home-cortex-appleUITests/`: test targets.
- `Config/`: shared base, Debug, and Release `.xcconfig` files; optional ignored local signing override.
- `.llm/epic3b-bootstrap.md`: actual validation results and physical deployment status.

Debug and Release provide a simple starting point for future Development/Production settings. There are no environment addresses or credentials yet. All required project files and the shared scheme are included; no project generator or third-party dependencies are required.

The next milestone is Home Cortex Client Interface V1 integration after physical iPhone bootstrap acceptance.
