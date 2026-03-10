# ``LoomShell``

Build terminal-class apps on top of Loom-native direct transport, relay introduction, and optional OpenSSH fallback.

## Overview

`LoomShell` is the app-facing product for building shell and terminal apps with Loom.

Use it when you want:

- nearby shell sessions over Bonjour and AWDL
- remote shell sessions that still stay direct, with relay used only as an introducer
- CloudKit-aware trust at the Loom session layer
- a Loom-native PTY protocol for your own host app
- OpenSSH fallback for peers that do not run the Loom host runtime

`LoomShell` sits above `Loom`:

- `Loom` owns discovery, authenticated transport, trust, relay rendezvous, and bootstrap primitives
- `LoomShell` owns shell session protocol, host runtime wiring, connection policy, and SSH fallback

On macOS, `LoomLocalShellHost` gives you a PTY-backed host runtime out of the box. On every client platform supported by Loom, `LoomShellConnector` gives you one connection API that prefers Loom-native transport first and OpenSSH second.

## Topics

### Essentials

- <doc:BuildAShellAppOnLoom>
