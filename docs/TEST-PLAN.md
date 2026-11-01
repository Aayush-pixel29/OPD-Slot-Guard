# OPD Slot Guard — Test Plan

Status: acceptance tests for the implementation phase.
Runner: `flutter test` with `sqflite_common_ffi`.
Domain tests must not open a database.
Infrastructure tests open an in-memory ffi database, apply `sqlite_schema.dart`, and seed the six slots.

A test that pumps the whole app is limited to the one presentation smoke test at the bottom. Invariants are row assertions.

## Fixture rules

- Clock starts at `1000` and advances `1000` on each `nowMs()` call unless a test pins it.
- Chaos is disarmed unless the test arms a one-shot flag.
- Actors are the three synthetic ids.
- Primary slot is `slot-1830`.
- Helper `rows()` reads `requests` and `slots` directly with SQL so a buggy read model cannot hide a bad write.

## Domain — no database

| Id | Case | Expect |
| --- | --- | --- |
| D1 | Every legal pair in the solution brief | allowed |
| D2 | Every other ordered pair among the five statuses, including self | `ILLEGAL_TRANSITION` |
| D3 | `SlotCapacityPolicy` capacity 1, count 0 | admit |
| D4 | capacity 1, count 1 | refuse |
| D5 | capacity 2 | throws `CapacitySeamException` |
| D6 | Patient confirm | `FORBIDDEN` |
| D7 | Patient cancel of another patient's request | `FORBIDDEN` |
| D8 | Clinic `RequestSlot` | `FORBIDDEN` |
| D9 | Patient `RequestSlot` for their own id | plan is insert |
| D10 | Confirm plan when one sibling is `REQUESTED` | target `CONFIRMED`, sibling `WAITLISTED`, slot version bump, nobody else `CONFIRMED` |
| D11 | Cancel `CONFIRMED` plan with two `WAITLISTED` ordered by `queue_ms` | both return to `REQUESTED`, effects listed in `queue_ms` order, none `CONFIRMED` |
| D12 | Cancel `REQUESTED` plan | only that row `CANCELLED`, slot version unchanged |
| D13 | Cancel `WAITLISTED` plan | only that row `CANCELLED`, slot version unchanged |
| D14 | Fingerprint ignores versions and changes when `requestId` changes | string equality as in ADR-02 |
| D15 | `lib/domain` import graph | no banned libraries (reviewed by a test that reads the files as text, or by review if a test is awkward on Windows paths — the import rule is mandatory either way) |

## Infrastructure — demos

| Id | Steps | Expect |
| --- | --- | --- |
| DEMO1 | Ramesh requests `slot-1830`. Priya requests `slot-1830`. Clinic confirms Ramesh. | Slot availability `BOOKED`. Ramesh `CONFIRMED`. Priya `WAITLISTED`. One confirmed row. Slot version 1. Priya `queue_ms` greater than Ramesh's if the clock advanced, and Priya's `queue_ms` unchanged by confirm. |
| DEMO2 | Continue from DEMO1. Ramesh cancels. | Ramesh `CANCELLED`. Slot `AVAILABLE`. Priya `REQUESTED`. Priya not `CONFIRMED`. Slot version 2. Priya `queue_ms` unchanged. |
| DEMO3 | Ramesh requests. Clinic confirms with ack-lost armed. Submit the same command again with the same key. | First call throws `ACK_LOST`. After the retry: stored result returned, `replayed` true, one command row, one `CONFIRMED`, slot version incremented once, one waitlist side effect if a sibling existed. With no sibling, effects length still stable across replay. |

DEMO3 is also run with Priya already `REQUESTED` so the side effect exists and must not duplicate.

## Infrastructure — invariants and pipeline

| Id | Case | Expect |
| --- | --- | --- |
| I1 | Two confirms of two `REQUESTED` rows, sequential | Second returns `CAPACITY_EXCEEDED` or, if it raced past policy, rollback. End state: one `CONFIRMED`. |
| I2 | Cancel `REQUESTED` while another `REQUESTED` exists and slot is `AVAILABLE` | Canceller `CANCELLED`. Other stays `REQUESTED`. Availability `AVAILABLE`. Slot version unchanged. |
| I3 | Cancel `WAITLISTED` while another patient is `CONFIRMED` | Canceller `CANCELLED`. Confirmed patient stays. Availability `BOOKED`. Slot version unchanged. |
| I4 | Reopen with two waitlisted patients, `queue_ms` 1000 and 3000 | Both `REQUESTED`. Audit restore order matches `queue_ms`. Zero `CONFIRMED`. |
| I5 | `WAITLISTED` → `CONFIRMED` submitted directly | `ILLEGAL_TRANSITION`. Rows unchanged. |
| I6 | Decline `CONFIRMED` | `ILLEGAL_TRANSITION`. |
| I7 | Decline `REQUESTED` | `DECLINED`. Slot version unchanged. Other requester unchanged. |
| I8 | Request while `BOOKED` | New row inserted as `WAITLISTED`, not `REQUESTED`. |
| I9 | Second live request same patient, same slot, new idempotency key | `ALREADY_ACTIVE`. One live row. |
| I10 | Same key, same fingerprint, after success | `replayed`, no version change, no extra request row. |
| I11 | Same key, different request id | `IDEMPOTENCY_PAYLOAD_MISMATCH`. Original rows unchanged. |
| I12 | Command expected slot version is stale | `STALE_VERSION`. No `commands` row. Versions unchanged by this call. |
| I13 | After I12, retry same key once the pending command's expected version is corrected to the re-read value | Single apply. This matches "same gesture, lost race". |
| I14 | Stored `REJECTED` (`FORBIDDEN`) retried | Same rejection, still no domain change. |
| I15 | `OFFLINE` | Throw, zero command rows, zero requests. |
| I16 | `TRANSACTION_ABORT` on confirm | Throw, zero command rows, requests still `REQUESTED`, version unchanged. Retry then succeeds once. |
| I17 | Patient read model for Ramesh after DEMO1 | Contains Ramesh status. SQL or mapper output does not contain `patient-priya` or `Priya`. |
| I18 | Clinic read model after DEMO1 | Contains both patients and both statuses. |
| I19 | `UPDATE` on `audit_events` | SQLite abort. |
| I20 | `DELETE` on `audit_events` | SQLite abort. |
| I21 | `UPDATE` on `commands` | SQLite abort. |
| I22 | Confirm as `patient-ramesh` | `FORBIDDEN`, still `REQUESTED`. |
| I23 | Unknown `actor_id` | `FORBIDDEN`. |
| I24 | Insert path does not accept a client `queue_ms` | Only the command fields in the LLD exist on `AppointmentCommand`. Review plus a constructor test. |
| I25 | Reset replaces the file | Seed only. Versions 0. No requests. Triggers exist again (I19 still holds). |

## Application

| Id | Case | Expect |
| --- | --- | --- |
| A1 | Message map for every code in `FAILURE-MATRIX.md` | Non-empty banner. Forbidden substrings absent: `404` `409` `429` `500` `502` `503` `504` `505` `SQLite` `Exception` `HTTP`. |
| A2 | `ACK_LOST` on confirm | Application retries once. Controller ends on success state. One domain confirm. |
| A3 | `OFFLINE` | Pending gesture retained. Second call uses the same key. |
| A4 | `ILLEGAL_TRANSITION` | Pending gesture cleared. A following tap generates a different key (fake id generator). |

## Presentation smoke

| Id | Case | Expect |
| --- | --- | --- |
| P1 | Pump `BoardPage` with the controller on a ffi database | Six slot labels visible, including `6:30 PM`. Switcher shows Ramesh, Priya, and Clinic Desk. |
| P2 | Switch to Clinic Desk | Widget shows clinic actions on the sheet for `slot-1830` after a request exists. This can be a controller test if widget pumps are brittle. Prefer controller test plus P1. |

Do not block the architecture on golden image tests.

## Command to run

```text
flutter test
```

Demo rehearsal is manual and follows `DEMO-RUNBOOK.md` after the suite is green.

## Failure discipline

A red DEMO or I-test stops feature work. Optional Gemini, Firebase, and Measure are not started while any DEMO test is red.

A constraint test (`I19`–`I21`) failing means the adapter caught errors and continued. Fix the adapter. Do not drop the trigger to make reset easier. Reset deletes the file.
