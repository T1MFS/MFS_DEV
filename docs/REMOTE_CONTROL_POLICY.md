# Remote control policy (DRAFT, needs owner sign-off)

Priority order for MFS and its link to DigitalMe:

1. **Remote control into MFS is limited** and allowed only when a list of conditions is met.
2. **Data received by DigitalMe is not rejected outright**; it is held and validated (see DigitalMe `docs/BIOMETRICS_TRANSPORT.md`, quarantine).
3. **Data sent by MFS is encrypted**, and never leaves the device without an acceptable assurance of privacy.

## Today: there is no remote control

MFS only sends data out. Nothing in the app accepts commands from DigitalMe or any server:

- DigitalMe's responses are read only for counts (`inserted_count`); no field of a response changes app behavior.
- No inbound listener, URL scheme, push or silent-notification entry point exists, and `Sources/Info.plist` enables only `bluetooth-central`.
- `scripts/check_no_remote_control.sh` fails the `Test` workflow if any such entry point appears.
- `scripts/check_no_delivery_commands.sh` fails it if MFS code calls an insulin delivery command.

Adding any remote control must come with a change to this document and to the guard script.

## Proposed conditions for any future remote control (DRAFT)

These are a starting list for the owner to edit. Nothing here is implemented; **every** item would have to hold for a command to run.

1. Off by default; enabled on the device, per capability, by the user, and revocable at any time (kill switch).
2. Only commands from an explicit allowlist of capabilities. Insulin delivery and any dose or basal change are not on it.
3. Mutual TLS with the pinned CA, and a client identity on the device's allowlist.
4. Each command is signed by a key whose public half is stored on the device; unsigned or unknown-key commands are discarded.
5. Replay protection: a unique id and a short validity window; a repeated or expired command is discarded.
6. Parameter bounds checked on the device against the user's own limits, never against values supplied by the server.
7. Rate limits, and refusal while the connection's security is below its required level or has changed unreviewed.
8. Anything affecting therapy needs an on-device confirmation by the user at the time.
9. Every received, accepted and refused command is written to the on-device log the user can read.
10. Commands run only while the app is open and unlocked, never from a background wake.

Open for the owner: the real list and its thresholds ("a laundry list of metrics"), and which capabilities, if any, are ever allowed.

## Privacy of what is sent

- Biometrics are sent only when the connection verifiably provides encrypted transport with a verified server identity (at least TLS). This floor is set in code (`DigitalMeEndpoint.minimumSecurity`) and cannot be lowered by the connection's own minimum-security setting.
- Each send re-checks the connection first. If the security is below the floor, has weakened, or the server's certificate changed, the stream pauses and nothing leaves the device until the user reviews and resumes. No data is lost: the next successful send includes the backlog.
- Transport encryption only. The payload itself is not separately encrypted; DigitalMe reads and stores it in clear. Payload-level encryption is an open decision.
