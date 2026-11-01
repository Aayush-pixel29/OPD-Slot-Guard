# OPD Slot Guard — Failure Matrix

Status: behavior contract.
Prototype rows are implemented with the chaos points and domain codes in `03-LLD.md`.
HTTP rows are production intent for a future `AppointmentAuthority` over HTTP. Do not implement an HTTP client for them in the hackathon unless the core demos are already green and the clock has spare time. Even then, a client must follow this matrix rather than invent per-code UI.

Patient UI copy is the banner column. Machine codes appear on the diagnostics sheet only.

## How to read a row

- **Durable command row:** a `commands` insert that committed.
- **Domain mutation:** any change to `slots` or `requests`.
- **Same key:** the client retries the identical fingerprint.
- **New key:** a later user gesture. Required after a completed rejection if the user wants a fresh decision.

## Prototype failures (implement)

| Code | When | Domain mutation | Durable command row | Retry | Patient banner | Diagnostics |
| --- | --- | --- | --- | --- | --- | --- |
| `OFFLINE` | One-shot flag before `BEGIN` | No | No | Same key, user or auto, bounded | Could not reach the clinic. Nothing was changed. | `OFFLINE` |
| `TRANSACTION_ABORT` | Throw inside the transaction after staged writes, before commit | No (rollback) | No | Same key | Could not save that action. Nothing was changed. | `TRANSACTION_ABORT` |
| `ACK_LOST` | Throw after commit, before return | Yes, already committed | Yes, `SUCCEEDED` | Same key, application retries once immediately | While checking: Connection dropped after sending. Checking the appointment. After replay: no error banner | `ACK_LOST` then `REPLAYED` |
| `STALE_VERSION` | `expected*Version` mismatch, or versioned `UPDATE` changed 0 rows | No | No, so the same key can evaluate again | Re-read, then same key if this was an automatic attempt; if the user is looking at a conflict banner, the next tap is a new key | This appointment changed. Here is the latest status. | `STALE_VERSION` |
| `NOT_FOUND` | Slot or request missing on the transactional read | No | Yes, `REJECTED` | Replay returns the same rejection. A new gesture uses a new key | That appointment is no longer on the board. | `NOT_FOUND` |
| `FORBIDDEN` | `ActorPolicy` denies | No | Yes, `REJECTED` | Replay the rejection | You cannot do that with this identity. | `FORBIDDEN` |
| `ILLEGAL_TRANSITION` | Status pair not in the table, including self-transition and `WAITLISTED` → `CONFIRMED` | No | Yes, `REJECTED` | Replay the rejection | That action is no longer available. | `ILLEGAL_TRANSITION` |
| `CAPACITY_EXCEEDED` | Policy refuses confirm | No | Yes, `REJECTED` | Replay the rejection. User may try a different request with a new key | That slot is no longer open for confirmation. | `CAPACITY_EXCEEDED` |
| `ALREADY_ACTIVE` | Live unique index would be violated, detected by pre-read so we can return a clean code | No | Yes, `REJECTED` | Replay the rejection | You already have a request for this slot. | `ALREADY_ACTIVE` |
| `IDEMPOTENCY_PAYLOAD_MISMATCH` | Key exists, fingerprint differs | No | Original row unchanged. Audit appended | Do not treat as success. New gesture, new key | That retry did not match the original action. | `IDEMPOTENCY_PAYLOAD_MISMATCH` |
| SQLite `ABORT` from `ux_one_confirmed_per_slot` | Policy bug raced the unique index | No (rollback) | No | Same key after refresh | Could not save that action. Nothing was changed. | `TRANSACTION_ABORT` / constraint name on the sheet only |
| Demo file reset | Judge taps reset on the chaos sheet | Database file replaced with seed | File replaced | n/a | Board shows six open slots | `RESET` |

Invariant checks inside confirm (confirmed count would exceed capacity, or a `REQUESTED` sibling would remain while full) roll back and surface as `TRANSACTION_ABORT`. They are defects, not patient conflicts. A test failure is the right outcome if they fire in the suite.

## Production HTTP intent (document only)

The service runs the same pipeline. The phone is a client of `AppointmentAuthority`. Assume the service stores idempotency the way ADR-02 describes.

| HTTP | Ambiguous? | Client interpretation | Retry | Patient banner |
| --- | --- | --- | --- | --- |
| 404 | No, when the body code is `NOT_FOUND` | Completed rejection. Entity missing. | Do not auto-retry. Same key would replay if the service stored it. New gesture only after the user does something else. | That appointment is no longer on the board. |
| 409 | No, when the body carries a machine code | `STALE_VERSION`, `CAPACITY_EXCEEDED`, or `IDEMPOTENCY_PAYLOAD_MISMATCH` as in the body. 409 alone is not enough to decide. | Stale: refresh read model. Mismatch: new key. Capacity: show banner, new key only for a different action. | Use the banner for that machine code. |
| 429 | No | Nothing new was accepted, or a stored result is in the body. If the body contains a stored `CommandResult`, use it and do not mutate locally. If the body is only "slow down", assume no new decision. | Same key, bounded exponential backoff, few attempts. | Could not reach the clinic. Nothing was changed. Then, if attempts exhaust: Check the appointment status before trying again. |
| 500 | Yes | The service may have committed before the error. | Same key, bounded retries. If a later response is a stored success, treat as replay. | Check the appointment status before trying again. Never "Failed" alone. |
| 502 | Yes, gateway | Same as timeout class. Prefer "not sure" over "rolled back". | Same key, bounded. | Check the appointment status before trying again. |
| 503 | Usually not committed | Service unavailable. | Same key, bounded backoff. | Could not reach the clinic. Nothing was changed. If retries exhaust, use the check-status banner. |
| 504 | Yes | Gateway timeout after the service may have committed. | Same key, bounded. | Check the appointment status before trying again. |
| 505 | No | Client cannot speak to that server. Retrying the same payload will not help. | Do not auto-retry. | Could not reach the clinic. Nothing was changed. |
| Timeout | Yes | Equivalent to 504 for this product. | Same key, bounded. | Check the appointment status before trying again. |

Body rule for production: a response that includes `result_json` matching our schema wins over the HTTP number. The client displays that stored decision and does not apply a local mutation. The prototype has no local mutation path outside the authority anyway.

404/409/429/5xx must not be shown as numerals on patient cards.

## Retry bounds

Prototype automatic retries:

- `ACK_LOST`: 1 immediate replay.
- `OFFLINE` and `TRANSACTION_ABORT`: no hidden loop. The user taps Retry on the same pending gesture, or the runbook drives the second call. A tight loop masks chaos.

Production automatic retries if a client is ever built:

- at most 3 attempts after the first call
- only for 429, 500, 502, 503, 504, and timeout
- same key, same fingerprint
- stop on any stored `CommandResult`
- stop on 505, 404, and 409

## What we will not do

- Map every HTTP status to a custom widget.
- Show `DatabaseException`, `SocketException`, or a stack on the board.
- Delete or rewrite a `SUCCEEDED` command to "undo" `ACK_LOST`. The cure for a lost ack is replay.
- Auto-confirm the next patient because a confirm call failed. Failure leaves the previous committed state, and the read model shows it.

## Evidence

- Unit test the message map: for every code above, patient string does not contain `404`, `409`, `429`, `500`, `502`, `503`, `504`, `505`, `SQLite`, `Exception`, or `HTTP`.
- ffi tests for the three chaos codes, matching the durable-row column.
- A comment in `patient_messages.dart` points here so production codes are not remapped ad hoc.
