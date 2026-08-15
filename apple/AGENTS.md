# The macOS and iOS shell

SwiftUI, and THE REFERENCE SHELL: when the platforms disagree about what the
chrome should do, this one is right. `apple/project.yml` generates the Xcode
project; `apple/screenshots.sh` captures the documentation frames.

Build: `xcodebuild -project apple/LookoutMarine.xcodeproj -scheme LookoutMarine
-configuration Debug -derivedDataPath apple/build`.

## What must stay true

- **A screenshot must capture an app window by id**, never the screen. The
  Dock and file dialogs carry personal data. See `apple/screenshots.sh`.
- **macOS preferences ignore a redirected HOME.** CFPreferences resolves the
  domain from the login session; use the NSUserDefaults argument domain.
- **A screenshot instance loads this machine's saved plugin settings**, so it
  dials the developer's own instruments and publishes other people's vessel
  names and positions. `LOOKOUT_CLEAN=1` leaves every plugin on its manifest
  defaults; `apple/screenshots.sh` sets it and serves the recorded fixture on
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
