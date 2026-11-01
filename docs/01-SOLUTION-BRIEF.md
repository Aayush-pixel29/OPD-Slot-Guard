# OPD Slot Guard — Solution Brief

Status: architecture gate. No application code is authorized by this document.
Build window: 4-hour solo hackathon.
Product: OPD Slot Guard.
Domain: healthtech appointment coordination.

This brief freezes the product boundary. `02-HLD.md` freezes structure. `03-LLD.md` freezes schema, commands, and the pipeline. ADRs freeze the three decisions most likely to drift during the build. The failure matrix, test plan, demo runbook, and judge defense are the acceptance pack.

## Problem

A clinic slot can be requested by more than one patient. The desk must confirm one patient, park the others, and reopen the slot cleanly if the confirmed patient cancels. The prototype has to show that those rules hold on one shared state, including when the UI loses the acknowledgement of a command that already committed.

## Users and identities

Authentication is intentionally absent. A role switcher is a demo control. It changes the actor id stamped on the next command. It does not open a second database.

| Display name | Actor id | Role | May do |
| --- | --- | --- | --- |
| Ramesh | `patient-ramesh` | patient | Request a slot. Cancel his own request in `REQUESTED`, `WAITLISTED`, or `CONFIRMED`. |
| Priya | `patient-priya` | patient | Same, for her own rows only. |
| Clinic Desk | `clinic-desk` | clinic | Confirm, decline, waitlist, or cancel any request. Cannot file a patient request. |

All three read and write the same SQLite file.

Synthetic display names are presentation constants. They are not clinical records.

## Core journey

1. Patient browses slots.
2. Patient requests one slot.
3. Clinic confirms or declines.
4. Patient sees the resulting status.
5. A confirmed patient can cancel.
6. Cancel of a confirmed request reopens that slot and returns waitlisted patients to `REQUESTED` in `queue_ms` order.
7. The desk must confirm the next patient explicitly.

## State machine

`REQUESTED` `CONFIRMED` `WAITLISTED` `DECLINED` `CANCELLED`

Legal:

- `REQUESTED` → `CONFIRMED` | `WAITLISTED` | `DECLINED` | `CANCELLED`
- `WAITLISTED` → `REQUESTED` | `DECLINED` | `CANCELLED`
- `CONFIRMED` → `CANCELLED`

Every other transition is rejected, including self-transitions. `DECLINED` and `CANCELLED` are terminal.

Creation is not a transition. The authority inserts the first status:

- slot has room under the capacity policy → `REQUESTED`
- slot is already at capacity → `WAITLISTED`

`WAITLISTED` → `CONFIRMED` is illegal. A waitlisted patient becomes confirmable only after a reopen moves them to `REQUESTED`.

`WAITLISTED` → `REQUESTED` is legal only inside the same transaction that cancelled a `CONFIRMED` request and observed remaining capacity. There is no standalone promote command in the prototype.

## Business invariants

1. A slot cannot have two `CONFIRMED` patients while capacity is 1. The database enforces this with a partial unique index. The domain enforces it with `SlotCapacityPolicy` before the write.
2. Cancelling `REQUESTED` does not change slot availability and does not rewrite other requests.
3. Cancelling `WAITLISTED` does not change slot availability and does not rewrite other requests.
4. Cancelling `CONFIRMED` sets that request to `CANCELLED` and reopens the slot in the same transaction.
5. Reopen sets every `WAITLISTED` request on that slot back to `REQUESTED`, retaining each row's original `queue_ms`. Audit rows for that restore are written in `queue_ms` order. `queue_ms` is an authority clock value assigned on insert. The client cannot supply it.
6. Reopen never confirms another patient.
7. The same idempotency key returns the stored result and does not apply a second mutation. The same key with a different logical payload is rejected.
8. A command whose expected slot version or expected request version does not match current rows is rejected. The client reconciles by reading current state. A later user gesture uses a new idempotency key.

Derived slot availability, not a stored slot status:

- `BOOKED` when confirmed count >= capacity
- `AVAILABLE` otherwise

Demo copy uses those two words. The primary demonstration slot is **6:30 PM**, id `slot-1830`.

## What the three demos prove

Demo 1 proves confirm fills capacity and parks the other requester as `WAITLISTED`.

Demo 2 proves cancel of `CONFIRMED` reopens availability and restores the waitlisted patient to `REQUESTED` without auto-confirm.

Demo 3 proves a lost acknowledgement retries the same key and returns the original success without a second mutation.

Exact steps live in `DEMO-RUNBOOK.md`.

## Prototype guarantee

On this build, SQLite is the `AppointmentAuthority`.

- One device, one database file, one writer.
- `BEGIN IMMEDIATE` transactions.
- Identities share that file, so the desk and both patients cannot diverge inside the demo.
- Idempotency, versions, and capacity hold inside that file.
- `OFFLINE`, `TRANSACTION_ABORT`, and `ACK_LOST` are injected in-process at defined pipeline points.

This prototype does not provide distributed multi-device consistency. A second phone, a second process, or a Firebase replica is outside the guarantee.

## Production intent

A remote coordination service can implement the same `AppointmentAuthority` contract and become the single writer. Device SQLite would then be a cache and outbox, not the authority. The command shape, status machine, idempotency key, and version fields stay. HTTP status handling in `FAILURE-MATRIX.md` is that future service's contract. It is not implemented in the hackathon.

## Architecture in one paragraph

Presentation holds a `ChangeNotifier` shell and sends intent. Application builds a command, applies chaos for the demo, and maps failures to safe copy. Domain is pure: transitions, actor rules, capacity policy, and the guard decision. Ports are `AppointmentAuthority`, read model, clock, and id generator. Infrastructure is raw `sqflite` executing the guard inside one transaction, plus append-only audit. Domain imports none of Flutter, sqflite, Firebase, HTTP, Gemini, or notification SDKs.

## Quality priority

1. Data consistency and correctness.
2. Resilience and recovery.
3. Maintainability and adaptability.

Targets, decisions, evidence, and trade-offs are in `02-HLD.md`. Security and privacy sit with them.

## Explicitly out of this build

- Login, accounts, passwords, OTP, sessions.
- Real patient data, clinical notes, phone numbers, addresses.
- More than one screen route. Details and diagnostics are bottom sheets on the board.
- A patient view of another patient's name.
- Auto-confirm on reopen.
- Firebase, Gemini, and Measure on the core path.
- Riverpod, Bloc, Drift, `build_runner`, event sourcing, microservices, GraphQL, Supabase.
- Any claim that the demo survives a network partition across devices.

## Capacity later

Moving capacity from 1 to N is specified in `ADR-03-POLICY-PROVIDER-BOUNDARIES.md`. The command contract, status machine, idempotency, reopen rule, and UI availability words stay. The edit surface is `SlotCapacityPolicy`, `slots.capacity`, and the database capacity constraint.

## Implementation gate

Application code starts only after this pack is accepted. Phases, the file list, and the do-not-create list are the closing section of the architecture review, not a license to skip the tests in `TEST-PLAN.md`.
