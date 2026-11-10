# US-4.2 Read Omnipod DASH history

[← E4 Device data](../../README.md)

**As a** user, **I want** MFS to read pod reservoir, status and dose history **so that** it can show them with meals.

**Acceptance:** Read-only. No bolus, temp basal, suspend or resume command is ever called. Contracts are described in the task below.

## Tasks
- [T-4.2.1 Implement a read-only PumpManagerDelegate](tasks/T-4.2.1-pump-delegate.md)
- [T-4.2.2 Safety review: no delivery commands](tasks/T-4.2.2-safety-review.md)
