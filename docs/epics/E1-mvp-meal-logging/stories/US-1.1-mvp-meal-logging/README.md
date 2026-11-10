# US-1.1 Log meals with minimal effort and build the basis for long-term analysis

[← E1 MVP: low-effort meal logging](../../README.md)

**MVP:** this story is the MVP for E1. All other stories and tasks support it; it is not yet delivered.

**Status:** Planned

**As a** user, **I want** to log what I eat to DigitalMe with as little manual interaction as possible, and see self-regulated dose recommendations **so that** I can manage my own dosing while building the data needed for long-term analysis.

## Acceptance
- **Easy input:** food can be entered by barcode or manually, with a minimum threshold of manual interaction.
- **Photo matching:** a photo of a meal is matched against past meals and image matches are suggested for the user to accept or reject.
- **Common reference:** the same food eaten more than once is cataloged in a shared reference, so repeats point to one entry.
- **Logging:** accepted food instances are logged to DigitalMe (see [US-1.4](../US-1.4-digitalme-upload/README.md)).
- **Self-regulated recommendations:** dose recommendations are advisory and the user decides. No active dosing: the app never delivers or commands insulin.
- **Analysis basis:** food instances (especially repeated consumption of the same food) are time-matched to basal insulin dose and to pre- and post-prandial glucose response, so long-term analysis can be developed later.

## Out of scope
- Active or automated insulin delivery.
- The long-term analysis itself; this story only creates the data basis.

## Tasks
To be defined.
