# Éveil 2 — service foundation

Task 1 builds only a signed native bootstrap and authenticated privileged XPC ping. No power settings are changed and there is no shell/command execution API.

## Build and verify

`./scripts/build.sh` creates `dist/Eveil2.app`. It requires the configured Developer ID certificate in the signing keychain. Both binaries use hardened runtime and secure timestamp. SwiftPM needs its normal compiler cache and build permissions.

Install in `/Applications/Eveil2.app`, open it, choose **Autoriser le service**, and approve **Éveil 2** in System Settings → General → Login Items & Extensions. Choose **Vérifier maintenant**. This is the normal GUI flow; no Terminal is required by the user.

Developer-only checks:

- `swift test`
- `./scripts/verify-service.sh`
- `./scripts/verify-rejection.sh`

The installed app executable also accepts `--register`, `--unregister`, `--status` and `--probe`. These are developer diagnostics, not the user journey. Unregister before changing an installed daemon, then register the signed replacement; do not repeatedly overwrite a registered executable.

## Security and integration interfaces

- App ID `fr.eveil2.app`; daemon and Mach service `fr.eveil2.daemon`; launch plist `fr.eveil2.daemon.plist`.
- Daemon location `Contents/MacOS/Eveil2Daemon`; app location `/Applications/Eveil2.app`. The launch plist only uses relative `BundleProgram`, never a conflicting absolute executable argument.
- Both sides validate the remote code identity using an Apple Developer ID chain, exact team `4Y79TY2592`, and exact peer identifier before messages are delivered. Ad-hoc signatures cannot satisfy this requirement. Non-root clients only; daemon must run as root.
- `EveilIPC.EveilServiceProtocol.ping(_:reply:)` returns Codable `ServiceProof` with protocolVersion/build/PID/EUID and a fresh nonce. Client only declares readiness after validating a real reply.
- `EveilApp.ServiceClient` provides a bounded asynchronous probe with a five-second timeout. Its result is delivered on the main queue. Registration status alone never means the service works.

Task 2 should add a separate `EveilCore` session engine and typed IPC methods. Keep lifecycle ownership and serialized daemon-side coordination separate from GUI state. Restrict accepted durations server-side and add heartbeat/disconnect handling, persistent recovery, and fixed power operations; never add arbitrary command arguments.

Task 3 should replace the temporary bootstrap with the native menu UI, preserving the authenticated client and explicit registration state machine.

## Known scope limits

This stage has no session control, durable power recovery, launch-at-login preference, final icon, notarization submission, or uninstall flow. It is a foundation, not a distributable finished app.
