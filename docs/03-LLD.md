# OPD Slot Guard — Low-Level Design

Status: implementation contract for the phase after this gate.
Companion: `02-HLD.md`, ADR-01, ADR-02, ADR-03.

## 1. Seed, actors, slots

Actor directory (application composition, not a table):

| actor_id | role | display |
| --- | --- | --- |
| `patient-ramesh` | patient | Ramesh |
| `patient-priya` | patient | Priya |
| `clinic-desk` | clinic | Clinic Desk |

Slots. `capacity` is 1. `version` starts at 0. No requests.

| slot_id | label | start_minute |
| --- | --- | --- |
| `slot-1600` | 4:00 PM | 960 |
| `slot-1630` | 4:30 PM | 990 |
| `slot-1700` | 5:00 PM | 1020 |
| `slot-1730` | 5:30 PM | 1050 |
| `slot-1800` | 6:00 PM | 1080 |
| `slot-1830` | 6:30 PM | 1110 |

`slot-1830` is the only slot the runbook uses. Tests refer to ids, not parsed labels.

Availability is computed in the read model and inside the guard:

```text
BOOKED    when confirmed_count >= capacity
AVAILABLE otherwise
```

There is no `slots.status` column. A stored status can diverge from the confirmed rows. The partial unique index already protects the confirmed set.

## 2. Schema

Foreign keys are on. The adapter executes this DDL on an empty file.

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE slots (
  slot_id       TEXT PRIMARY KEY,
  label         TEXT NOT NULL,
  start_minute  INTEGER NOT NULL UNIQUE CHECK (start_minute >= 0 AND start_minute < 1440),
  capacity      INTEGER NOT NULL CHECK (capacity = 1),
  version       INTEGER NOT NULL CHECK (version >= 0)
);

CREATE TABLE requests (
  request_id  TEXT PRIMARY KEY,
  patient_id  TEXT NOT NULL,
  slot_id     TEXT NOT NULL REFERENCES slots(slot_id),
  status      TEXT NOT NULL CHECK (status IN (
                'REQUESTED','CONFIRMED','WAITLISTED','DECLINED','CANCELLED')),
  queue_ms    INTEGER NOT NULL,
  version     INTEGER NOT NULL CHECK (version >= 0),
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

-- Prototype capacity enforcement for capacity = 1.
-- Replaced when capacity becomes N. See ADR-03.
CREATE UNIQUE INDEX ux_one_confirmed_per_slot
  ON requests(slot_id)
  WHERE status = 'CONFIRMED';

-- A second tap with a new idempotency key must not create a second live row.
CREATE UNIQUE INDEX ux_one_live_request_per_patient_slot
  ON requests(patient_id, slot_id)
  WHERE status IN ('REQUESTED','WAITLISTED','CONFIRMED');

CREATE INDEX ix_requests_slot_status_queue
  ON requests(slot_id, status, queue_ms);

CREATE TABLE commands (
  command_id       TEXT PRIMARY KEY,
  idempotency_key  TEXT NOT NULL UNIQUE,
  payload_hash     TEXT NOT NULL,
  command_type     TEXT NOT NULL CHECK (command_type IN (
                     'RequestSlot','ConfirmRequest','DeclineRequest',
                     'CancelRequest','WaitlistRequest')),
  actor_id         TEXT NOT NULL,
  status           TEXT NOT NULL CHECK (status IN ('SUCCEEDED','REJECTED')),
  result_json      TEXT NOT NULL,
  created_at       INTEGER NOT NULL,
  attempt_count    INTEGER NOT NULL CHECK (attempt_count = 1)
);

CREATE TRIGGER commands_no_update
BEFORE UPDATE ON commands
BEGIN
  SELECT RAISE(ABORT, 'commands are insert-only');
END;

CREATE TRIGGER commands_no_delete
BEFORE DELETE ON commands
BEGIN
  SELECT RAISE(ABORT, 'commands are insert-only');
END;

CREATE TABLE audit_events (
  event_id     TEXT PRIMARY KEY,
  command_id   TEXT NOT NULL REFERENCES commands(command_id),
  entity_type  TEXT NOT NULL CHECK (entity_type IN ('slot','request','command')),
  entity_id    TEXT NOT NULL,
  action       TEXT NOT NULL,
  from_status  TEXT,
  to_status    TEXT,
  actor_id     TEXT NOT NULL,
  at_ms        INTEGER NOT NULL,
  detail_json  TEXT NOT NULL
);

CREATE INDEX ix_audit_entity ON audit_events(entity_id, at_ms);

CREATE TRIGGER audit_no_update
BEFORE UPDATE ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit_events are append-only');
END;

CREATE TRIGGER audit_no_delete
BEFORE DELETE ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit_events are append-only');
END;
```

`payload_hash` stores the canonical fingerprint string from ADR-02. It is an equality token. It is not a credential.

`attempt_count` is always 1 because the command row is inserted once, in the same transaction as the outcome. Replays do not update it. The column exists so the production service can record in-flight attempts later without a new table. The prototype check constraint locks it to 1 so a mistaken `UPDATE` is doubly rejected (trigger and check).

`detail_json` may contain slot id, request id, from-version, to-version, and machine code. It must not contain free text typed by a user. There is no notes field in the product.

### Why these constraints

| Constraint | Failure it stops | Alternative rejected |
| --- | --- | --- |
| `CHECK (capacity = 1)` | A seed or debug write silently turning on multi-confirm while the unique index still exists, or the reverse. | `CHECK (capacity >= 1)` now. That would compile N behavior the policy still refuses. Fail closed. |
| `ux_one_confirmed_per_slot` | Two `CONFIRMED` rows if a code path skips the policy. | A Dart `if` only. The judge can ask what the database does. |
| `ux_one_live_request_per_patient_slot` | Double request from two different idempotency keys (two taps, two keys). Idempotency does not cover that. | Treating it as a UI disable only. |
| Insert-only triggers | Replay code "fixing" a stored result, or a reset path deleting audit in place and hiding history. | Application discipline alone. |
| `version >= 0` | Negative versions from a bad increment. | Unsigned trust in Dart ints. |

Demo reset removes the file and reruns DDL plus seed. It does not disable triggers.

## 3. Domain types

```text
enum RequestStatus { requested, confirmed, waitlisted, declined, cancelled }
enum SlotAvailability { available, booked }
enum ActorRole { patient, clinic }
enum CommandType {
  requestSlot, confirmRequest, declineRequest, cancelRequest, waitlistRequest
}
enum CommandStatus { succeeded, rejected }

class Slot {
  String slotId;
  String label;
  int startMinute;
  int capacity; // prototype always 1
  int version;
}

class AppointmentRequest {
  String requestId;
  String patientId;
  String slotId;
  RequestStatus status;
  int queueMs;
  int version;
}

class Actor {
  String id;
  ActorRole role;
}
```

Transition function:

```text
TransitionVerdict legalTransition(RequestStatus from, RequestStatus to)
```

Returns allowed or `ILLEGAL_TRANSITION`. No other type may list transitions.

### SlotCapacityPolicy

```text
bool canAdmitConfirmation({required int capacity, required int confirmedCount})
```

Prototype body:

- if `capacity != 1`, throw `CapacitySeamException` (fail closed)
- return `confirmedCount == 0`

Initial insert uses the same function:

- admit → new row `REQUESTED`
- refuse → new row `WAITLISTED`

This class, the `CHECK`, and `ux_one_confirmed_per_slot` are the only capacity-enforcement edits for N. See ADR-03.

### ActorPolicy

| Command | Patient, and `patient_id` on the target equals `actor.id` | Patient on someone else's row | Clinic |
| --- | --- | --- | --- |
| RequestSlot | allow when payload `patientId == actor.id` | deny | deny |
| ConfirmRequest | deny | deny | allow |
| DeclineRequest | deny | deny | allow |
| CancelRequest | allow | deny | allow |
| WaitlistRequest | deny | deny | allow |

Unknown actor id: `FORBIDDEN` before SQL.

Authorization uses ids on the command. The widget's selected chip is only how the application fills `actor_id`. A test can submit `clinic-desk` without a widget.

### CommandGuard

Pure input:

- command type and payload
- actor
- slot row or null
- target request or null
- live requests on that slot (statuses and versions)
- nowMs (only to show the planned `queue_ms` for a new insert; the adapter may overwrite with the clock read inside the transaction — tests fix the clock)

Pure output is either `Reject(code)` or `ApplyPlan`:

- request inserts
- request status updates `(requestId, from, to, expectedVersion)`
- slot version bump or not
- result snapshot to store

The guard does not open a database and does not generate the idempotency decision. The adapter runs idempotency first, then the guard, then compares the guard's expected versions to the rows it just read. If the guard and the SQL `WHERE version = ?` disagree, the transaction rolls back with `STALE_VERSION`. That last compare is defense against a plan built on a stale in-memory snapshot if a future caller moves the guard outside the transaction. **Rule for this codebase: call `CommandGuard` only after the transactional re-read.**

## 4. Command payload and fingerprint

Common fields on every command object:

```text
commandId            client-generated, primary key of commands
idempotencyKey       client-generated, stable across retries of this gesture
type
actorId
expectedSlotVersion  required for every command that names a slot
expectedRequestVersion  required when a request already exists; null for RequestSlot
slotId
requestId            null for RequestSlot until the application mints it and puts it in the payload
patientId            RequestSlot only
```

The application mints `requestId` before the first submit and keeps it in the gesture state so a retry after `TRANSACTION_ABORT` inserts the same primary key.

Fingerprint, stored as `payload_hash` (canonical string, UTF-8, fields separated by `|`):

```text
v1|{type}|{actorId}|{slotId}|{requestId or -}|{patientId or -}
```

Excluded from the fingerprint on purpose: `commandId`, both expected versions, `queue_ms`, timestamps. A retry of the same gesture must match even if the widget refreshed versions after a timeout. Including versions would turn every legitimate retry into `IDEMPOTENCY_PAYLOAD_MISMATCH`.

Included actor and target: the same key must not confirm a different request or run as a different actor.

## 5. Pipeline algorithm

```text
submit(command):
  if chaos.offline (one-shot):
      clear flag
      throw OfflineFailure          // no transaction

  BEGIN IMMEDIATE
  row = SELECT * FROM commands WHERE idempotency_key = ?

  if row exists:
      if row.payload_hash != fingerprint(command):
          insert audit IDEMPOTENCY_PAYLOAD_MISMATCH referencing row.command_id
          COMMIT
          return Reject IDEMPOTENCY_PAYLOAD_MISMATCH
      COMMIT
      // slots and requests were not written.
      // Best-effort: append audit IDEMPOTENCY_REPLAY in a new transaction.
      // If that insert fails, still return the stored result.
      return Stored(row.result_json) with runtime flag replayed=true

  snapshot = read slot, target request, sibling live requests
  plan = CommandGuard.evaluate(snapshot, command)

  if plan is reject:
      insert commands status=REJECTED result_json=rejection attempt_count=1
      insert audit COMMAND_REJECTED
      if chaos.abort: throw inside callback   // rollback, no row
      COMMIT
      return rejection

  apply plan with UPDATE ... WHERE version = expected
  if any expected row update count != 1:
      ROLLBACK
      return STALE_VERSION
      // do not persist a command row for a lost race detected at write
      // caller may retry the SAME key; the next attempt re-reads

  if after confirm, confirmed_count > capacity OR
     (confirmed_count >= capacity AND any REQUESTED remains):
      ROLLBACK
      throw TransactionAbortFailure   // defect, not a user conflict

  insert commands status=SUCCEEDED result_json=snapshot attempt_count=1
  insert one audit event per request status change and one for slot version bump
  restore audits ordered by queue_ms ascending
  if chaos.abort: throw inside callback
  COMMIT
  if chaos.ackLost (one-shot):
      clear flag
      throw AckLostFailure            // commit already durable
  return success
```

`STALE_VERSION` detected at `UPDATE` rolls back so we do not store a rejection under the key. The screen is stale; the logical command has not been decided. The automatic retry re-reads. If the user action is no longer legal, the second attempt persists `REJECTED`.

`IDEMPOTENCY_PAYLOAD_MISMATCH` does append an audit row and commits it. Domain tables stay untouched. The original command row stays untouched.

Chaos flags are consumed when observed so Demo 3's retry is a normal submit.

## 6. result_json

Stored document, ids and statuses only:

```json
{
  "outcome": "APPLIED",
  "code": "OK",
  "commandId": "cmd-...",
  "commandType": "ConfirmRequest",
  "slot": {
    "slotId": "slot-1830",
    "version": 1,
    "capacity": 1,
    "confirmedCount": 1,
    "availability": "BOOKED"
  },
  "request": {
    "requestId": "req-ramesh",
    "patientId": "patient-ramesh",
    "status": "CONFIRMED",
    "version": 1,
    "queueMs": 1000
  },
  "effects": [
    {"requestId": "req-ramesh", "from": "REQUESTED", "to": "CONFIRMED"},
    {"requestId": "req-priya", "from": "REQUESTED", "to": "WAITLISTED"}
  ]
}
```

Rejections use `"outcome": "REJECTED"` and a machine `code`, with `effects` empty and a `slot` / `request` snapshot of the rows actually read (so the client can reconcile). Snapshot may be null if the entity was missing.

Replay returns the stored JSON unchanged and sets a response flag `replayed: true` outside the stored document. The adapter must not rewrite `result_json` on replay. The insert-only trigger makes that rewrite fail.

Machine codes:

`OK`, `NOT_FOUND`, `FORBIDDEN`, `ILLEGAL_TRANSITION`, `STALE_VERSION`, `CAPACITY_EXCEEDED`, `ALREADY_ACTIVE`, `IDEMPOTENCY_PAYLOAD_MISMATCH`.

`OFFLINE`, `TRANSACTION_ABORT`, and `ACK_LOST` are transport failures. They are not stored as command status. `ACK_LOST` means the stored status is already `SUCCEEDED`.

## 7. Version rules

| Event | Request version | Slot version |
| --- | --- | --- |
| Insert request | 0 | unchanged |
| Status change on a request | +1 | +1 only if occupancy changes (confirm, cancel confirmed) |
| Park siblings to `WAITLISTED` | +1 each | already +1 for the confirm |
| Restore siblings to `REQUESTED` | +1 each | already +1 for the cancel |
| Decline, cancel non-confirmed, explicit waitlist | +1 on that row | unchanged |
| Rejected command | unchanged | unchanged |

Occupancy changes when the set of `CONFIRMED` rows changes. Waitlist membership alone does not.

Clients send the versions from the last read model response.

## 8. queue_ms

Assigned only on insert, from `Clock.nowMs()` inside the transaction. Restore and waitlist updates must not assign a new `queue_ms`.

Tests use `FakeClock` starting at 1_000 and advancing 1_000 per read so order is obvious.

Equal `queue_ms` tie-break: `request_id` ascending. The prototype clock should not produce ties. The sort still defines one.

The client has no field for `queue_ms` on the command. A patient cannot jump the restore order.

## 9. Read SQL shape

Patient:

```text
slots left join requests
  on requests.slot_id = slots.slot_id
 and requests.patient_id = :actorId
 and requests.status in (REQUESTED, WAITLISTED, CONFIRMED, DECLINED, CANCELLED)
```

The patient query must not select another patient's `patient_id`. Clinic query selects all live requests plus recently terminal ones for the detail sheet (`DECLINED`, `CANCELLED` for the current demo session).

Confirmed count is `COUNT(*) WHERE status = 'CONFIRMED'` per slot, compared with `capacity`.

## 10. Presentation controller

`ClinicBoardController extends ChangeNotifier`

State:

- `Actor actor`
- `List<SlotCardModel> cards`
- `String? banner` patient-safe sentence, or null
- `ChaosArm chaos` none / offline / abort / ackLost, one-shot
- `DiagnosticSnapshot diagnostics` last command id, key, code, replayed flag, last five audit actions

Methods:

- `switchActor`
- `refresh`
- `requestSlot`, `confirm`, `decline`, `cancel`
- `armChaos`
- `resetDemo`

`switchActor` calls `refresh` only.

Each user gesture calls `IdGenerator` for a new idempotency key and, for request, a new request id. Those ids are held in a `PendingGesture` until the call returns a stored result or a terminal rejection. Transport failures (`OFFLINE`, `TRANSACTION_ABORT`, `ACK_LOST`) keep `PendingGesture` so the retry button reuses the key. `ACK_LOST` retry is automatic once inside the application, then the success path shows the stored state. If the automatic retry also fails transport, the banner asks the user to check status; `refresh` loads authoritative rows; the pending key remains until success replay or the user dismisses and starts a new gesture.

Terminal domain rejections clear `PendingGesture`. The next tap mints a new key.

Button enablement is a hint from the read model. The authority decides.

### Patient-safe banners

| Situation | Banner |
| --- | --- |
| `OFFLINE` | Could not reach the clinic. Nothing was changed. |
| `TRANSACTION_ABORT` | Could not save that action. Nothing was changed. |
| `ACK_LOST` before the automatic retry completes | Connection dropped after sending. Checking the appointment. |
| `ACK_LOST` automatic retry replays success | (no error banner; cards show committed state) |
| `STALE_VERSION` | This appointment changed. Here is the latest status. |
| `CAPACITY_EXCEEDED` | That slot is no longer open for confirmation. |
| `ILLEGAL_TRANSITION` | That action is no longer available. |
| `ALREADY_ACTIVE` | You already have a request for this slot. |
| `NOT_FOUND` | That appointment is no longer on the board. |
| `FORBIDDEN` | You cannot do that with this identity. |
| `IDEMPOTENCY_PAYLOAD_MISMATCH` | That retry did not match the original action. |
| Ambiguous exhaustion (production timeout class) | Check the appointment status before trying again. |

The chaos sheet may show the machine code next to these sentences. The slot cards may not.

## 11. Logging

`debugPrint` / logger lines may include command type, command id, idempotency key, machine code, slot id. They must not include a display name joined to a clinical fact, SQL parameter dumps of future free-text, or any key material. There is no API key to log. Do not log `result_json` at verbose level in a way that grows into notes later; log ids and `code` only.

## 12. Tests map to fixtures

Shared ffi opener: schema DDL + seed slots, `FakeClock`, chaos disarmed.

Demo fixture helper:

```text
request(actor, slot-1830) 
confirm(clinic, requestId)
```

Assertions are on rows, not on widgets, except one widget test that the board builds six cards and the switcher lists three identities.

## 13. Module layout (when implementation starts)

```text
lib/domain/request_status.dart
lib/domain/transition.dart
lib/domain/slot_capacity_policy.dart
lib/domain/actor_policy.dart
lib/domain/command_guard.dart
lib/domain/command_fingerprint.dart
lib/domain/failures.dart
lib/ports/appointment_authority.dart
lib/ports/appointment_read_model.dart
lib/ports/clock.dart
lib/ports/id_generator.dart
lib/infrastructure/sqlite_schema.dart
lib/infrastructure/sqlite_appointment_authority.dart
lib/infrastructure/sqlite_appointment_read_model.dart
lib/infrastructure/demo_database.dart
lib/application/demo_actor_directory.dart
lib/application/patient_messages.dart
lib/application/appointment_application.dart
lib/presentation/clinic_board_controller.dart
lib/presentation/board_page.dart
lib/main.dart
test/domain/...
test/infrastructure/demo1_test.dart
test/infrastructure/demo2_test.dart
test/infrastructure/demo3_test.dart
test/support/ffi_database.dart
```

That list is the cap. Extra files need a reason tied to a failing test, not to layering taste.
