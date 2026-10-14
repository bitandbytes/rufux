# CLAUDE.md — Sources

Two SPM targets live here:

```text
PhoneBTConsole executable ── PhoneBTCore library
```

`PhoneBTCore` is one importable module with responsibility-based subfolders:

- `HFP/` owns IOBluetooth discovery, commands, callbacks, the event stream, and authoritative HFP state.
- `Audio/` owns CoreAudio device selection/routing, the shared audio engine, and PCM conversion.
- `Agent/` owns GPT-Live protocol, Responses delegation, input configuration, and result persistence.
- `Shared/` owns value models and logging used throughout the library.

`PhoneBTConsole` contains stdin/stdout and coordinates lifecycle through the public `PhoneBTCore` API. Keep terminal-specific code out of the library.

Every new Swift source file must retain the Apache 2.0 / ICOA Inc. license header.
