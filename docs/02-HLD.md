# OPD Slot Guard — High-Level Design

Status: frozen for the hackathon implementation that follows this gate.

## 1. System context

```text
+----------------------- one Flutter process -----------------------+
|  Board shell (ChangeNotifier)                                     |
|    identity switcher | 6 slot cards | detail sheet | chaos sheet  |
|           |                                                       |
|  Application                                                      |
|    build command, one-shot chaos, patient-safe messages           |
|           |                                                       |
|  Ports                                                            |
|    AppointmentAuthority.submit(command)                           |
|    AppointmentReadModel.load(actor)                               |
|    Clock.nowMs()    IdGenerator.newId()                           |
|           |                                                       |
|  SqliteAppointmentAuthority                                       |
|    pipeline inside BEGIN IMMEDIATE                                |
|    calls domain guards, writes slots/requests/commands/audit      |
+-------------------------------------------------------------------+
                              |
                    opd_slot_guard.db
```

There is one software component. There is no second service in the prototype.

Production intent adds a second implementation of `AppointmentAuthority` in front of a coordination service. That implementation is a different composition root. The shell still submits commands. It does not gain a second writer.

## 2. Why these layers

| Layer | Owns | Why it exists | Alternative rejected | Cost | Protects against | Revisit when |
| --- | --- | --- | --- | --- | --- | --- |
| Presentation | Widgets, `ClinicBoardController extends ChangeNotifier`, sheets | The demo is one screen. Flutter notifications are enough to refresh six cards. | Riverpod or Bloc. They add indirection and codegen risk in a 4-hour window without a second route or a team sharing state. | The shell file will be longer. Business rules must not leak into `onPressed`. | UI frameworks becoming the place where confirm side effects are coded. | A second independent screen needs the same board state and prop passing becomes noisy. Still no new framework until a concrete bug appears. |
| Application | Command assembly, actor resolution from the switcher, chaos arming, message map | Keeps widgets free of version fields and keeps SQLite free of English copy. | Calling sqflite from widgets. Fast for a demo, and it makes the three demos untestable without pumping frames. | One extra type per command. | Patient UI showing SQLite or HTTP text. Idempotency keys generated in two different widgets. | Never merge this into presentation. |
| Domain | Status machine, `SlotCapacityPolicy`, `ActorPolicy`, `CommandGuard` pure decision | Rules must be executable in unit tests with no database. | SQL-only rules. The partial unique index is necessary but it cannot express "reopen does not auto-confirm" or actor ownership. | Policies can drift from SQL if tests skip one side. Both are tested. | A UI-only check that a second client (or a later HTTP adapter) can bypass. | Domain starts needing I/O. That is a design failure, not a reason to add imports. |
| Ports | Authority, read model, clock, ids | The prototype SQLite adapter and a future remote adapter must be swappable at one interface. | A repository per table exposed to the UI. Callers would assemble multi-table writes and break atomicity. | All mutations funnel through `submit`. Reads are a separate port so refresh is not a fake command. | Split writes. Client-supplied `queue_ms`. | A query needs a transaction with a command. Keep it inside the authority, do not let the UI open a transaction. |
| Infrastructure | Schema, transactions, chaos injection points, demo file reset | sqflite stays at the edge. `sqflite_common_ffi` runs the same schema in tests. | Drift. Codegen and a query layer we would not finish. Raw SQL makes the partial index and append-only triggers visible. | SQL strings are manual. | Hidden migrations that drop the unique index. | The SQL file becomes unreadable. Split by table, do not adopt an ORM. |

Dependency direction:

```text
presentation → application → ports
application → domain
infrastructure → ports
infrastructure → domain
```

Domain does not import presentation, application, infrastructure, Flutter, sqflite, Firebase, HTTP clients, Gemini, or notification SDKs.

## 3. Authority boundary

`AppointmentAuthority` is the only mutation port:

```text
Future<CommandResult> submit(AppointmentCommand command);
```

`SqliteAppointmentAuthority` implements it for the prototype.

The production coordination service would implement the same method. The service, not the phone, would run the pipeline in its own transaction. Until that service exists, documentation must not describe the app as multi-device consistent.

Firebase is not an authority. Using Firestore as a second writer would let a device commit a confirm that SQLite has already rejected. Optional Firebase work, if any, is a notifier after a local commit and is off the core journey. See ADR-03.

## 4. Command pipeline

Every mutation follows this order. Steps 2–6 are a pure `CommandGuard` result. Steps 1 and 7 need the database.

1. **Idempotency replay.** Look up `idempotency_key`. Matching fingerprint returns `result_json` and writes nothing to `slots` or `requests`. Mismatched fingerprint rejects. See ADR-02.
2. **Entity existence.** Missing slot or request becomes `NOT_FOUND`. No partial write.
3. **Actor authorization.** `ActorPolicy` uses the actor on the command, not a global from the widget. Patients act only on their rows. Clinic acts on desk commands. Unknown actors are `FORBIDDEN`.
4. **Legal transition.** The table in the solution brief. Side effects (park others, restore waitlist) are part of the command's apply plan, not extra client calls.
5. **Version validation.** `expectedSlotVersion` and, when a request row is the target, `expectedRequestVersion`. Mismatch is `STALE_VERSION`. The handler re-reads versions inside the transaction. It does not trust the widget's memory.
6. **Policy and capacity.** `SlotCapacityPolicy` for confirm. Direct insert chooses `REQUESTED` versus `WAITLISTED` with the same policy. Cancel of `CONFIRMED` checks that restore does not confirm anyone.
7. **Atomic apply and audit.** One `BEGIN IMMEDIATE` transaction inserts the `commands` row, updates domain rows, and appends `audit_events`. Commit is the only success. Rollback leaves no command row and no domain change.

`CommandGuard` returns an apply plan or a rejection. The adapter does not invent a second plan.

## 5. Apply plans that cross rows

These are the only multi-row mutations. Each is one command and one transaction.

**Confirm** (`REQUESTED` → `CONFIRMED`) when policy admits the row:

- target request becomes `CONFIRMED`, request version increments
- slot version increments
- every other `REQUESTED` on that slot becomes `WAITLISTED`, each request version increments, `queue_ms` unchanged
- if capacity is then full, zero `REQUESTED` rows remain on that slot

**Cancel confirmed**:

- target becomes `CANCELLED`, request version increments
- slot version increments
- every `WAITLISTED` on that slot becomes `REQUESTED` in `queue_ms` ascending order, versions increment, `queue_ms` unchanged
- confirmed count after the transaction is 0 for capacity 1
- no row is written as `CONFIRMED`

**Cancel requested or cancel waitlisted**:

- only that request becomes `CANCELLED`
- slot version does not change
- other requests do not change

**Decline** (`REQUESTED` or `WAITLISTED` → `DECLINED`):

- only that request changes
- slot version does not change
- decline of `CONFIRMED` is an illegal transition

**Explicit waitlist** (`REQUESTED` → `WAITLISTED`):

- clinic-only
- occupancy does not change
- the demo UI does not need a waitlist button; confirm's side effect is the judged path
- the command exists so the transition is real and tested

**Request slot**:

- insert one row
- `queue_ms` from `Clock` inside the transaction
- initial status from capacity
- slot version does not change, because occupancy does not change until confirm

## 6. Read model

`AppointmentReadModel.load(actor)` is not a command and has no idempotency key.

Patient projection:

- six slots
- availability `AVAILABLE` or `BOOKED`
- that patient's own request status, if any
- no other patient's id or display name

Clinic projection:

- six slots
- each non-terminal request: patient display name, status, `queue_ms`
- terminal rows may appear on the detail sheet so a judge can see `CANCELLED`

The controller refreshes after every command result and when the identity switcher changes. Switching identity does not issue a command.

## 7. UI composition

One `MaterialApp` home: the board shell.

- Identity switcher in the app bar: Ramesh, Priya, Clinic Desk.
- Six cards. `slot-1830` / 6:30 PM is visually primary and is the runbook slot. The other five exist so browsing is real: 4:00, 4:30, 5:00, 5:30, 6:00 PM.
- Slot or request actions open a modal bottom sheet. Confirm, decline, request, and cancel happen there.
- Diagnostics / chaos is a separate bottom sheet: one-shot `OFFLINE`, `TRANSACTION_ABORT`, `ACK_LOST`, last command summary, short audit tail, reset demo.
- Reset deletes the database file and reopens the seeded schema. It is not a domain command. Append-only triggers stay in force during normal writes because reset does not `DELETE` audited rows in place.

No named routes. No login page. No settings page.

## 8. Concurrency model inside the prototype

sqflite serializes transactions on one database instance. `BEGIN IMMEDIATE` takes the write lock at the start so two confirms cannot both pass the capacity read. The version check is still required: it defines the conflict result the future HTTP API will return, and it catches a command built from a stale screen.

The prototype has no cross-process lock. Two isolates with two connections are outside the guarantee.

## 9. Failure placement

Chaos is a one-shot flag read by `SqliteAppointmentAuthority`, not a boolean scattered across buttons.

| Injection | Where | Database after the call |
| --- | --- | --- |
| `OFFLINE` | Before `BEGIN` | Unchanged. No command row. |
| `TRANSACTION_ABORT` | After writes are staged, before commit. Throw inside the transaction callback. | Unchanged. sqflite rolls back. |
| `ACK_LOST` | After commit returns, before `submit` returns to the application. | Command and domain rows are durable. The UI sees a transport failure. |

Retry after `OFFLINE` or `TRANSACTION_ABORT` uses the same idempotency key and will apply once, because no command row exists.

Retry after `ACK_LOST` uses the same key and receives the stored success.

Patient copy never includes exception text, SQL, or HTTP numbers. The chaos sheet, available in every identity for the judge, shows the technical code. That sheet is demo instrumentation.

Production HTTP mapping is specified in `FAILURE-MATRIX.md` and is not built.

## 10. Quality attributes

### Priority 1 — Data consistency / correctness

- **Target.** Invariants 1–8 hold under the three demos, under illegal transitions, and under the two in-transaction races we can actually run: double confirm and lost ack.
- **Decision.** Single authority, one transaction per command, partial unique index for one confirmed row, optimistic versions, idempotency stored in the same transaction as the mutation.
- **Evidence.** `sqflite_common_ffi` tests named in `TEST-PLAN.md`, especially `demo1`, `demo2`, `demo3`, `rejectsSecondConfirm`, `reopenDoesNotConfirm`, `staleVersionRejected`.
- **Trade-off.** The UI cannot optimistic-update a confirm. The card changes only after commit or after a refresh of authoritative rows. The demo will feel a beat slower and will not lie.

### Priority 2 — Resilience / recovery

- **Target.** A failed attempt before commit is retryable with the same key. A lost ack does not double-apply. The patient is told to look at status when the outcome is ambiguous. Automatic retry is bounded and only for codes marked retryable.
- **Decision.** Insert-only `commands` row committed with the mutation. Client keeps the idempotency key across the three prototype failures. A new tap after a terminal rejection mints a new key. See ADR-02 and the failure matrix.
- **Evidence.** Chaos tests for the three injections. Message-map unit test asserting patient strings do not contain `SQLite`, `HTTP`, `500`, or stack-trace markers.
- **Trade-off.** Persisting a rejection under the key means a blind retry will not "heal" after the user refreshes. The UI must refresh and require a new gesture. That is the cost of stable replay.

### Priority 3 — Maintainability / adaptability

- **Target.** A remote authority or capacity N can be introduced by replacing named seams, not by rewriting the status machine.
- **Decision.** `AppointmentAuthority`, `CommandGuard`, `SlotCapacityPolicy`, and a capacity check constrained to `capacity = 1` in SQL. ADR-01 and ADR-03 list the stable contracts.
- **Evidence.** Domain tests import no Flutter and no sqflite. A grep gate in review: `lib/domain` contains none of the banned imports. Schema file contains one partial unique index whose comment names the N migration.
- **Trade-off.** More files than a single `main.dart`. The 4-hour risk moves from "rules in widgets" to "too much scaffolding". The file list at the end of the architecture review is the cap.

### Security and privacy

- **Target.** No real patient data. No secrets in source. Logs and `result_json` carry ids and statuses only. Authorization still runs for every command. Patients do not receive other patients' identities.
- **Decision.** Three synthetic actors. No notes column. No auth tokens. `ActorPolicy` inside the guard. Patient read model omits other patients. Demo reset and chaos stay off the command success path's copy.
- **Evidence.** Schema review (no PHI columns). Test `patientReadModelHidesOtherPatient`. Test `patientConfirmIsForbidden`. Source has no API key constant and no Firebase options file.
- **Trade-off.** The identity switcher can impersonate the desk. That is accepted for a prototype with no login. It is not a production control. Production intent is: the coordination service binds `actor_id` from a credential before `submit` runs. The policy stays where it is.

What would make us revisit security scope during the hackathon: nothing short of a judge requiring login. Login is a new product, not a patch. Decline it and keep the command boundary.

## 11. Composition root

`main.dart` wires:

- `databaseFactory` (plugin on device, ffi in tests)
- open or create `opd_slot_guard.db`
- `SqliteAppointmentAuthority` and `SqliteAppointmentReadModel` sharing the database
- `SystemClock` and `UuidGenerator`
- `DemoActorDirectory` with the three actors
- `ClinicBoardController`
- one `BoardPage`

Tests build the same graph with ffi and a fake clock. They do not pump the widget to prove invariants.

## 12. What this design refuses

- Event sourcing. The audit table is a log of commands that already committed. Rebuilding state from events is unnecessary with four tables and a judge in the room.
- CQRS frameworks. The read SQL is a join. The write path is the authority.
- Offline-first sync engines. Offline in this prototype means "the authority refused to start a transaction." There is no queue of divergent facts.
- Client-side capacity checks as the source of truth. The widget may disable a button for clarity after a refresh. The authority rechecks.
