# ADR-01 — SQLite is the prototype AppointmentAuthority

Status: accepted for the hackathon.
Date: 2026-11-01.

## Context

OPD Slot Guard's correctness depends on a single decision point for confirm, waitlist, decline, cancel, and reopen. The demo runs three identities on one device and injects `OFFLINE`, `TRANSACTION_ABORT`, and `ACK_LOST` without a network. The brief also asks for a production shape where a remote coordination service can own the same decisions.

If we blur those two, the demo will either pretend to be distributed or paint the team into a local-only API that a service cannot implement.

## Decision

Define one port:

```text
abstract class AppointmentAuthority {
  Future<CommandResult> submit(AppointmentCommand command);
}
```

For this prototype, `SqliteAppointmentAuthority` is the only implementation. It runs the pipeline in `03-LLD.md` inside `BEGIN IMMEDIATE` on `opd_slot_guard.db`. Ramesh, Priya, and Clinic Desk are actors on commands against that file. They are not peers with their own stores.

**Prototype guarantee**

- Invariants hold inside one SQLite file on one device.
- Shared identity state means the switcher changes `actor_id`, not the database.
- Idempotency and audit are durable after commit of that file.
- Chaos failures are in-process injections at the points in the LLD.
- No replication, no multi-device session, no conflict-free replicated data type.

**Production intent**

- A coordination service becomes the implementation of `AppointmentAuthority`.
- The service is the single writer. Phones submit the same command documents and idempotency keys.
- Device storage, if kept, is a cache of the read model and an outbox of unacknowledged commands. It is not allowed to confirm a slot locally and reconcile later.
- HTTP codes in `FAILURE-MATRIX.md` describe that service. They are not handled by a real client stack in this hackathon.

Speech and README language must keep those two labels. The demo script says "one local authority." It does not say "works offline across devices."

## Alternatives

### A. Each widget writes the tables it needs

Rejected. Confirm must update the winner, the slot version, and the sibling requests, then audit, or roll all of that back. A widget that updates two tables in two calls breaks invariant 4 and invariant 6 as soon as the second call fails. Cost of the port: every feature pays `submit`. That cost is the product.

### B. Firestore or Firebase Realtime Database as the shared board

Rejected for the core path. A cloud document per slot gives multi-device illusion and loses the transaction we need: partial unique confirm, command insert, and audit must commit together. Firebase security rules are not a substitute for `BEGIN IMMEDIATE` plus a version check. Offline persistence would create a second writer, which is the failure this ADR exists to prevent. Firebase may later notify a device that a command already committed. It may not accept the command.

### C. Event-sourced log as the authority

Rejected. We need four tables and three demos. Rebuilding a slot by folding events adds a fold bug on the highest-risk rule (reopen must not confirm). The audit table already explains what happened. State is the rows.

### D. Claim the local database is a replica of a server we do not have

Rejected. That claim is false and a judge can break it with one question about two phones. We document the seam instead of role-playing the server.

## Cost

- The prototype cannot show two devices converging.
- A remote implementation is not started, so production HTTP behavior is specified and unproven.
- All mutation UX waits for the local transaction. There is no optimistic confirm.

## Failure this protects

- Two confirmed patients because two identities wrote two stores.
- A lost ack that retries against a different store than the one that committed.
- A future Firebase integration becoming the source of truth by accident.
- Demo narration that over-claims consistency.

## Revisit when

- The hackathon scope adds a second device as a judged demo. Then implement a real coordination service behind the same port, or explicitly drop the claim. Do not turn on Firebase sync as a shortcut.
- Transaction time on the local file becomes visible to a human. It will not, at six slots.

## Evidence expected in the build

- Domain and application tests depend on the port, not on `Database`.
- Only `lib/infrastructure` imports sqflite.
- Demo 3 runs against the SQLite implementation and shows one `commands` row after retry.
- README or judge defense uses the two labels above and no third label such as "eventually consistent."
