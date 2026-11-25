# PS Remote

Native macOS (Apple Silicon) PS5 Remote Play client built on [chiaki-ng](https://github.com/streetpea/chiaki-ng)'s libchiaki.
Command-line only for now: discovery, registration, wake, and a stream with video, audio and controller input.

This is an unofficial project. It is not affiliated with or endorsed by Sony Interactive Entertainment;
"PlayStation", "PS5" and "DualSense" are trademarks of their owner. You need your own console and account.

## Requirements

macOS on Apple Silicon, Xcode (Swift 6 toolchain), Homebrew with `cmake ninja pkg-config opus json-c miniupnpc libevent openssl@3`, and `uv`.
`Scripts/build-libchiaki.sh` checks for these and installs nothing.

## Build

    ./Scripts/build-libchiaki.sh   # once, and after a chiaki-ng submodule bump
    swift build
    swift test                     # offline unit tests
    PSREMOTE_LIVE=1 swift test     # also runs LAN tests against a real PS5

## CLI

    swift run psremote-cli discover
    swift run psremote-cli set-account <PSN Account-ID, base64>
    swift run psremote-cli import-chiaki     # reuse chiaki-ng's existing registration
    swift run psremote-cli register "<console name|host id|ip>" <8-digit PIN>
    swift run psremote-cli list
    swift run psremote-cli wake "<console name|host id>"
    swift run psremote-cli forget <host id>
    swift run psremote-cli stream "<console name|host id>" [seconds]

`stream` plays the console's audio and forwards a connected DualSense (or DualShock 4). Keyboard
fallback: WASD left stick, arrow keys D-pad, Return cross, Escape circle, Tab Options.

    PSREMOTE_LIVE_STREAM=1 swift test --filter LiveStreamTests   # opens a real Remote Play session

## License

[AGPL-3.0](LICENSE), inherited from chiaki-ng, which is included as a git submodule under `third_party/`.
