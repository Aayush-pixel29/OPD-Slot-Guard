# OPD Slot Guard — Judge Defense

Status: answers we will give without widening scope.
Read with ADR-01, ADR-02, ADR-03, and the failure matrix.

## Opening

OPD Slot Guard coordinates one clinic slot so two patients cannot both be confirmed, a cancel of the confirmed patient reopens the slot without crowning the next patient, and a lost acknowledgement does not apply the confirm twice. The prototype's authority is one SQLite file. The production intent is the same command port on a single remote writer. Those are different guarantees.

Priority order: correctness, then recovery, then adaptability. Security is a closed synthetic demo with authorization still enforced in the command guard.

## Quality attributes, spoken form

**Correctness.** Target: invariants 1–8 on one authority. Decision: one transaction, version checks, capacity policy plus a partial unique index, idempotency row committed with the write. Evidence: `DEMO1`, `DEMO2`, `DEMO3`, `I1`, `I4`, `I10`. Trade-off: the board waits for commit and does not paint a speculative confirm.

**Resilience.** Target: pre-commit failure retries once; post-commit silence replays. Decision: three injection points and the matrix's retry rules. Evidence: `I15`, `I16`, `A2`. Trade-off: stored rejections stick to the key until the user makes a new gesture.

**Adaptability.** Target: capacity N and a remote writer are seam changes. Decision: `AppointmentAuthority`, `SlotCapacityPolicy`, and the named SQL constraint. Evidence: domain package import boundary and ADR-03's table. Trade-off: more files, a hard stop at the file list, no ORM.

**Security and privacy.** Target: no real PHI, no secrets, no cross-patient leakage, authz on every command. Decision: three actors, patient read model, `ActorPolicy`. Evidence: `I17`, `I22`. Trade-off: the switcher can impersonate the desk because authentication is out of scope on purpose.

## The fifteen questions

### 1. What stops two confirmed patients?

The confirm plan refuses when `SlotCapacityPolicy` says the slot is full, inside the same transaction that re-reads the rows. The database also has `ux_one_confirmed_per_slot`, a partial unique index on `requests(slot_id) WHERE status = 'CONFIRMED'`. `slots.capacity` is check-constrained to 1. A second confirm returns `CAPACITY_EXCEEDED` or rolls back if it hits the index. Demo 1 ends with one `CONFIRMED` row.

### 2. Why doesn't Priya get the slot when Ramesh cancels?

Because auto-confirm is the bug this product is about. Cancel of `CONFIRMED` writes Ramesh `CANCELLED`, increments the slot version, and sets each `WAITLISTED` row back to `REQUESTED` in `queue_ms` order. It does not write `CONFIRMED` for anyone. `WAITLISTED` → `CONFIRMED` is an illegal transition, so a sloppy second call cannot crown her either. The desk confirms explicitly. That is invariant 6 and Demo 2.

### 3. Why is waitlist restored in queue order if you do not auto-confirm?

Order still matters. The desk should see who asked first, and a later N policy might admit more than one without re-sorting. `queue_ms` is assigned by the authority clock at insert and is not rewritten on restore. The client cannot pass it. Fairness of display and any future admission is protected now; automatic admission is still refused.

### 4. What is the prototype guarantee, in one sentence?

One device, one SQLite authority, all demo identities, transactional invariants, idempotent commands.

### 5. What is explicitly not guaranteed?

Two phones, process crash recovery across a half-sent HTTP call, Firebase offline cache, or any phrase like "eventually consistent." Production intent is a remote implementation of the same port as the single writer. We have not built that service.

### 6. What happens on Demo 3, step by step?

The confirm transaction commits the command row, Ramesh's `CONFIRMED` status, Priya's `WAITLISTED` status, the slot version, and the audit. Then the adapter throws `ACK_LOST` before returning. The application retries the same idempotency key and fingerprint. The authority finds `SUCCEEDED`, returns the stored `result_json`, and does not run the apply plan again. Diagnostics show replay. `attempt_count` stays 1 because command rows are insert-only.

### 7. Why can a stale version retry the same key, but a decline cannot?

A version mismatch on the `UPDATE` means the command was not decided. The transaction rolls back, including the command insert, so a retry is the first real evaluation. A decline that committed stored `REJECTED` or `SUCCEEDED`. Replaying it returns that decision. A new user tap mints a new key. Mixing those two cases is how duplicates and stuck forms happen. ADR-02 is the write-up.

### 8. What if the same key is reused for a different request?

`IDEMPOTENCY_PAYLOAD_MISMATCH`. The original command row is unchanged. Domain rows are unchanged. We do not return the old success as though it applied to the new body. The fingerprint covers type, actor, slot, request id, and patient id. It omits versions on purpose.

### 9. The login is fake. Where is authorization?

In `ActorPolicy`, called from `CommandGuard` on every `submit`. A patient confirm is `FORBIDDEN` even if a test bypasses the widget. Patients can cancel only their own rows. The clinic cannot file a patient request. The switcher only chooses which synthetic `actor_id` the application places on the command. Production would overwrite that id from a credential. We did not skip the policy just because the credential is missing.

### 10. What data could leak?

The schema has ids, statuses, versions, queue timestamps, and command results. There is no notes, phone, address, or document column. Patient queries do not select the other patient's id. Logs are command id, key, slot id, and machine code. Display names are constants for three synthetic people. There is no API key in source. Optional Gemini is not on this path; if it is added later it may only see statuses already on screen and must not be required for confirm.

### 11. How do you map 500, 409, 404, timeouts?

We do not implement HTTP in the core build. The intended client behavior is in `FAILURE-MATRIX.md`. 404 is a completed missing-entity result. 409 must carry a machine code: stale, capacity, or fingerprint mismatch. 429 backs off with the same key. 500, 502, 504, and timeout are ambiguous, so we retry the same key a few times and then tell the patient to check status rather than saying the booking failed. 503 is treated as unavailable. 505 is not retried. Patients never see the numerals. The prototype's real injections are `OFFLINE`, `TRANSACTION_ABORT`, and `ACK_LOST`.

### 12. Why SQLite and not Drift, Bloc, Riverpod, or Firebase?

Drift and `build_runner` spend the hackathon on codegen for four tables. Bloc and Riverpod add state machinery for one screen; `ChangeNotifier` is enough. Firebase as a writer would be a second authority and would break the confirm/reopen transaction. sqflite with ffi tests lets us show the unique index and the append-only triggers. The remote service, if built later, sits behind `AppointmentAuthority` and does not require those UI frameworks.

### 13. What has to change for capacity N?

Three seams: `SlotCapacityPolicy` (today it throws if capacity is not 1), the `slots.capacity` check and seed, and the database enforcement (drop the one-confirm unique index, add a trigger that compares confirmed count to `slots.capacity`). Command types, fingerprint, status machine, idempotency, version rules, and "reopen does not confirm" stay. The UI already treats `BOOKED` as "at capacity," not as the number 1.

### 14. What did you refuse to build, and what does that cost?

No login, no second route, no event sourcing, no auto-confirm, no cloud replica, no model picking the winner. The cost is that we cannot impress with multi-device magic or generated UI. The gain is that Demo 1–3 and the constraint tests fit the afternoon and answer the consistency questions directly.

### 15. What is the weakest point in this design?

The pending idempotency key lives in the controller's memory. If the process dies after commit and before the user sees success, the in-memory key is gone. On a single device the rows are still correct, and a refresh shows them, but the app cannot replay a key it forgot. A durable outbox would close that. We did not build one, because the judged lost-ack case keeps the process alive. A remote authority with a durable client outbox is the production fix, and it uses the same key contract. I would rather state that limit than fake an outbox in the last half hour.

## Short answers to likely follow-ups

**Why bump slot version on confirm and confirmed-cancel only?** Those are the occupancy changes. Bumping on every waitlist edit would cause false conflicts for an in-flight confirm that is still valid.

**Why insert-only commands?** So replay cannot "fix" history. `attempt_count` stays 1. A production gateway that must record `IN_PROGRESS` can relax that trigger on the service without changing the client fingerprint.

**Why can the clinic cancel?** Desk staff cancel on behalf of patients in real OPDs. Patients can still cancel only their own rows. If the product later forbids desk cancel, delete one row of `ActorPolicy` and one test. The reopen plan stays.

**Why an explicit waitlist command if the button is hidden?** The transition is legal and must be tested. The judged path is the confirm side effect. A visible extra button invites a demo mis-click. The command can be invoked from a test.

**Audit failed to append on replay. Is the booking valid?** Yes. Domain commit already happened. Replay audit is best-effort. The reverse is not acceptable: audit without a committed booking is a rolled-back transaction.

**Can Ramesh request again after cancel?** Yes. `CANCELLED` is terminal for that row and is not a live status, so the partial unique live index allows a new insert. That new request is a new idempotency key.

## If we are wrong

| Observation | Likely cause | Response during the hackathon |
| --- | --- | --- |
| Two `CONFIRMED` | Policy skipped and index missing | Stop. Fix schema before any UI polish. |
| Priya `CONFIRMED` after Ramesh cancels | Apply plan crowns the head of the queue | Remove that write. Re-run DEMO2. |
| Demo 3 creates two command rows | Retry minted a new key, or ack-lost threw before commit | Fix pending-gesture retention and the injection point. |
| Patient sees Priya | Read SQL selects all patients | Split the clinic query from the patient query. |
| Banner shows `SQLiteException` | Message map bypassed | Route the error through `patient_messages.dart`. |

We do not answer those by adding Firebase or a model.
