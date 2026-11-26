# Technical debt

Accepted shortcuts, with why and what would retire them.

## Biometric payloads are protected by transport encryption only

- **State:** Biometrics are sent over TLS with a verified server (never lower; see `DigitalMeEndpoint.minimumSecurity`). The JSON body is not separately encrypted, so DigitalMe stores and reads it in clear.
- **Accepted:** by the owner, for now.
- **Retire by:** payload-level (end-to-end) encryption to a key held by DigitalMe, plus the matching decrypt step before validation, quarantine and analysis.

## Security-change audit log is local and capped

- **State:** Changes to a connection's certificate, level or mode seen during streaming are logged with time in the on-device security history, capped at 200 entries. They are not sent anywhere.
- **Retire by:** a durable, exportable audit trail if one is needed.
