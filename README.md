# OPD-Slot-Guard

OPD Slot Guard is a single-device appointment coordination board prototype designed to enforce strict appointment invariants, partial unique constraints, and idempotent command replay within a local-first SQLite authority.

## Architecture Documentation

The frozen architecture and design specifications are documented in the `docs/` folder:

1. [01-SOLUTION-BRIEF.md](docs/01-SOLUTION-BRIEF.md) — Product boundary, identities, core journey, state machine.
2. [02-HLD.md](docs/02-HLD.md) — System architecture, container diagrams, ports and adapters.
3. [03-LLD.md](docs/03-LLD.md) — SQLite schema, triggers, pipeline steps, command specs.
4. [ADR-01-AUTHORITY-LOCAL-FIRST.md](docs/ADR-01-AUTHORITY-LOCAL-FIRST.md) — Local SQLite as single authority.
5. [ADR-02-COMMAND-IDEMPOTENCY.md](docs/ADR-02-COMMAND-IDEMPOTENCY.md) — Command fingerprints & idempotency table.
6. [ADR-03-POLICY-PROVIDER-BOUNDARIES.md](docs/ADR-03-POLICY-PROVIDER-BOUNDARIES.md) — Policy and boundary isolation.
7. [DEMO-RUNBOOK.md](docs/DEMO-RUNBOOK.md) — Step-by-step instructions for DEMO1, DEMO2, DEMO3, and chaos scenarios.
8. [FAILURE-MATRIX.md](docs/FAILURE-MATRIX.md) — Failure cases, error codes, and recovery behaviors.
9. [JUDGE-DEFENSE.md](docs/JUDGE-DEFENSE.md) — Top technical questions, trade-offs, and design defenses.
10. [TEST-PLAN.md](docs/TEST-PLAN.md) — Unit, integration, and scenario testing strategy.

