# The macOS and iOS shell

SwiftUI, and THE REFERENCE SHELL: when the platforms disagree about what the
chrome should do, this one is right. `macos/project.yml` generates the Xcode
project; `macos/screenshots.sh` captures the documentation frames.

Build: `xcodebuild -project macos/LookoutMarine.xcodeproj -scheme LookoutMarine
-configuration Debug -derivedDataPath macos/build-mac`.

## What must stay true

- **A screenshot must capture an app window by id**, never the screen. The
  Dock and file dialogs carry personal data. See `macos/screenshots.sh`.
- **macOS preferences ignore a redirected HOME.** CFPreferences resolves the
  domain from the login session; use the NSUserDefaults argument domain.
- **A screenshot instance loads this machine's saved plugin settings**, so it
  dials the developer's own instruments and publishes other people's vessel
  names and positions. `LOOKOUT_CLEAN=1` leaves every plugin on its manifest
  defaults; `macos/screenshots.sh` sets it and serves the recorded fixture on
  a port of its own. Never point a capture at whatever is on 10110.
- **Only one copy of the app runs per machine.** A second hands over to the
  first and exits, because two copies share one preferences domain and one
  plugin storage directory. `LOOKOUT_MULTI=1` lifts it, which the screenshot
  protocol needs since every frame is its own instance.
- **Xcode here is a partial install**: no `Contents/Developer/Applications`, so
  no Simulator.app and no window for a booted device. Drive simulators
  headless with `simctl boot`, `simctl launch` (env via `SIMCTL_CHILD_*`) and
  `simctl io <id> screenshot`. Shut them down after; a booted device burns CPU.

- **SwiftUI owns the menu bar.** An `NSMenuItem` poked into `NSApp.mainMenu`
  survives until the next time SwiftUI rebuilds its `Commands`, which any
  `@Published` change triggers. Declare menus in `AppCommands` and fill them
  from observable state. The AIS Targets item was invisible for weeks this way.
- **`xcodebuild` rewrites `xcshareddata/xcschemes/LookoutMarine-iOS.xcscheme`**
  on most runs, downgrading its format. Revert it rather than committing it.

- **A stale app on the simulator survives `xcodebuild test`** and runs instead
  of the one just built. It reads as a missing test resource: a fixture that is
  plainly in the bundle comes back "no fixture named plugins.json in the test
  bundle". `simctl uninstall` before believing an iOS test failure of that
  shape.

- **`build-dev.sh` needs Xcode's own swiftc**, not the Command Line Tools alone,
  whatever its header says. SwiftUI's `@State` is a macro now and its plugin
  ships inside Xcode: without `DEVELOPER_DIR` it fails with eighteen errors
  about `SwiftUIMacros.StateMacro`.

- **The shipped plugins go in `LookoutPlugins`, never `Plugins`.** On iOS an app
  bundle is flat, so `$UNLOCALIZED_RESOURCES_FOLDER_PATH/Plugins` lands on the
  system's own `PlugIns` directory for app extensions and the installer takes it
  over. The app then runs with no own ship, no AIS and no laylines, and says so
  in one log line nobody reads. `ChartController.bundledPluginCandidates` checks
  both names.

## Testing

`macos/Tests/` is one source directory compiled into `LookoutMarineTests`
(macOS) and `LookoutMarine-iOSTests` (iOS). Both app targets produce a module
named `LookoutMarine`, so a test is written once and runs on either platform.

```sh
xcodebuild test -project macos/LookoutMarine.xcodeproj -scheme LookoutMarine \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath macos/build-mac
xcodebuild test -project macos/LookoutMarine.xcodeproj -scheme LookoutMarine-iOS \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath macos/build-mac CODE_SIGNING_ALLOWED=NO
```

A test that persists anything subclasses `ShellTestCase`, which puts a defaults
suite of its own in `Store.shared`. Nothing in the shell reads
`UserDefaults.standard` directly.

The fixtures under `macos/Tests/Fixtures/` are the core's own output, captured
with `LOOKOUT_DUMP_JSON=<dir>`; see the README beside them. Capture them again
when the core changes what it sends.

The UI tests open the baked cell this repository carries for the Android build,
through `ChartFixture`. `$LOOKOUT_TEST_CHART` overrides it. They are slow and
one at a time, so run a class with `-only-testing:` while working.
