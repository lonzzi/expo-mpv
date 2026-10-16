# iOS command responsiveness regression

Run from the module root with Xcode, ffmpeg, downloaded `ios/Frameworks`, and an
already booted iOS Simulator on an Apple Silicon Mac:

```sh
bun run test:ios-commands
# Keep the build log and per-scenario JSON:
bun run test:ios-commands --simulator <UDID> --output /tmp/mpv-command-results
```

This compiles the production `ExpoMpvView.swift` into a small UIKit application
and links the real MPVKit frameworks. Only Expo's base UIView and event forwarding
are replaced by minimal test adapters; network requests, rendering, commands,
properties, track selection, cancellation, and shutdown use the real code.
It does not replace a full Expo bridge build or physical-device validation.

The runner generates a local H.264/AAC fixture and hosts subtitles/audio on an
ephemeral loopback HTTP port. Responses deliberately wait four seconds. UIKit
buttons schedule pause, resume, seek, source replacement, and return actions while
a 50 ms main-run-loop timer measures stalls. The runner asserts:

- Subtitle/audio additions and subtitle reload return without stalling the UI.
- Completion fires exactly once after actual loading, or promptly on cancellation.
- Pause/resume/seek still operate during the outstanding request.
- The loaded external track can be selected, disabled, and removed.
- Replacing the source does not receive the old track after its request finishes.
- Stop-and-return and direct destruction return promptly with no stale error.
- A failed HTTP request emits exactly one `onError` with the existing command format.

The test app is stopped and uninstalled, and the temporary HTTP server is closed
when the runner exits. All requests use generated local data; no media-server
account or network configuration is needed.
