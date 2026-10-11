# KeyStats for Linux

Rust + GTK4 native dashboard and an independent, unprivileged evdev collector.
The Swift/macOS implementation remains in the parent project. Linux stores data in
`$XDG_DATA_HOME/keystats/linux.db` (default `~/.local/share/keystats/linux.db`).
It never opens the original macOS database for writing.

## Build and run

Requires Rust, pkg-config, GTK4 development libraries; the collector requires
Hyprland, logind and read access to the active seat's keyboard event devices.

```sh
cargo test
cargo build --release
./target/release/keystats daemon
./target/release/keystats gui
```

Nix: `pkgs.callPackage ./package.nix { }`. Use a systemd user service for
`keystats daemon`, attached to `graphical-session.target`. Import
`XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE` into the user
service manager when the compositor starts. Do not run the collector as root or
add the user to the broad `input` group: use active-seat udev `uaccess` ACLs.
On this laptop these ACLs are already provided for xremap.

## Features

- Hourly key/shortcut counts, correction rate, average/peak KPM and typing duration.
- ANSI/JIS heatmap, daily/hourly/weekday charts, per-app and per-keyboard filters.
- Japanese/English GUI, native GTK light/dark appearance, pause and excluded apps.
- SQLite WAL aggregate storage; JSON export and key-count CSV export.
- CLI: `today`, `top`, `apps`, `keyboards`, `combos`, `weak`, `speed`, `export`,
  `status`, `where`, `pause`, `resume`, `prune DAYS`, `import-macos PATH`.
  Filters: `--period today|week|all`, `--app ID`, `--key EVDEV_CODE`, `--device ID`.
- Configuration: `~/.config/keystats/linux.json`; changes are reloaded automatically.
- Auto input source selects xremap's output if present, otherwise physical
  keyboards. xremap grabs physical input, so its output is required on this
  laptop. This counts remapped presses under one combined keyboard, not a
  hardware-by-hardware breakdown. Autorepeats are ignored.

## Collection boundaries

Only hourly aggregates are persisted, never typed text, event sequences, window
names or titles. Short in-memory state is needed to calculate speed and keys
preceding corrections. Correction attribution is an estimate, not spellchecking.
The collector is bound to the compositor's specific logind session. It pauses
when that session is inactive/locked, a hyprlock process is present, collection
is paused or the application is excluded. It fails closed if context checks fail.
Input is held for one 200ms interval; a focus/config/permission transition drops
that interval. Hyprland focus events also catch switches away and back.
Dropped evdev packets, newly opened devices and queued old input are discarded.
Conservative transition handling can undercount keys near an app switch.

Linux has no universal secure-input indicator: password fields inside an allowed
browser/terminal cannot be detected. Pause manually for sensitive input; known
password-manager apps are excluded by default. Context checks are not a security
boundary against arbitrary lockers/compositors. This collector currently supports
Hyprland; other Wayland compositors need their own foreground-app adapter.
App time measures foreground time within 60 seconds of a keyboard press, excluding
lock/idle time; it is not a mouse-based activity tracker. ISO/national-layout key
names are physical labels rather than decoded text.

## macOS import

`keystats import-macos /path/to/keystats.db` copies aggregate counts, shortcuts,
per-app typing, correction weights and app time with an explicit keycode mapping.
Source is read-only, import is transactional, and the same source path cannot be
imported twice. Imports from copied paths are not deduplicated. Imported data is
labelled `macOS import`; historical keyboard subtypes and shortcut-to-key
filtering are not carried over. Historical correction counts reconstruct delete
keys, not modifier-based corrections. Existing Linux data is retained.

## Tests

`cargo test` checks repeats, held modifiers, input gates, correction attribution,
speed boundaries, SQL filtering, read-only readers and source-safe macOS import.
`cargo test --no-default-features` also runs the portable core tests on macOS.
Nix builds run the same tests. GUI smoke checks should cover open/close, light/dark
rendering, filtering, settings, and pause/resume against a live daemon.
