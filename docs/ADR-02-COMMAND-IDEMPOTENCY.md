# ADR-02 — Client idempotency keys, stored with the mutation

Status: accepted for the hackathon.
Date: 2026-11-01.

## Context

Demo 3 injects `ACK_LOST`: the confirm commits, the UI does not see success, the same logical confirm is sent again. Invariant 7 says that retry must not mutate twice. Invariant 8 says a stale command must not land on top of newer state.

Those two rules conflict if "same command" is defined badly. If the fingerprint includes the optimistic version, the retry after refresh looks like a different command. If a rejection is not stored, a retry after a decline can confirm. If a rejection is stored forever, the user cannot recover from a stale screen without a new key.

## Decision

1. Every user gesture mints one `idempotency_key` and one `command_id` before the first call to `submit`.
2. Transport retries of that gesture reuse both the key and the logical payload. `command_id` on a retry is ignored if the key already exists. The stored row keeps the original `command_id`.
3. The fingerprint is:

```text
v1|{commandType}|{actorId}|{slotId}|{requestId or -}|{patientId or -}
```

   Versions, timestamps, `queue_ms`, and `command_id` are not part of the fingerprint.

4. The `commands` row is inserted in the same transaction as the domain updates and the audit rows.
5. Status is either `SUCCEEDED` or `REJECTED`. There is no `IN_PROGRESS` row in the prototype. A crash or `TRANSACTION_ABORT` rolls the command row back with the domain rows.
6. `attempt_count` is inserted as 1 and the table is update-forbidden.
7. Retry when the key exists and the fingerprint matches: return stored `result_json`, set runtime `replayed: true`, do not update `slots` or `requests`. An audit row `IDEMPOTENCY_REPLAY` may be appended in its own short transaction. That audit row is not a domain mutation.
8. Retry when the key exists and the fingerprint differs: `IDEMPOTENCY_PAYLOAD_MISMATCH`. Do not return the old result as if it were this payload. Do not insert a second `commands` row. Append an audit event that points at the original `command_id`.
9. `STALE_VERSION` discovered by `UPDATE ... WHERE version = ?` affecting zero rows rolls back and does **not** store a command. The same key may be retried after a re-read. This is a lost race, not a completed decision.
10. Domain rejections (`FORBIDDEN`, `ILLEGAL_TRANSITION`, `NOT_FOUND`, `CAPACITY_EXCEEDED`, `ALREADY_ACTIVE`) are stored as `REJECTED` under the key once the transactional re-read has made a decision.
11. The UI mints a **new** key only when the user performs a new gesture. Terminal rejections clear the pending gesture. `OFFLINE` and `TRANSACTION_ABORT` keep it. `ACK_LOST` keeps it and the application retries it once immediately.
12. Automatic retry is allowed only when no completed decision exists or when the completed decision is a success we failed to display. Automatic retry must not mint a new key.

Patient copy for mismatch and for stale results is in the LLD message table. The chaos sheet shows the machine code.

## Why the stored rejection is a completed decision

Example: clinic declines Priya. The network ack is lost. Retry must return `DECLINED`, not try to decline again and not fall through to confirm. The stored `REJECTED` or `SUCCEEDED` result is that memory. Decline of an already-terminal row would otherwise surface as `ILLEGAL_TRANSITION` on the second attempt, which is a different observation than the first. Replay makes the second observation identical to the first.

Example that must not stick forever: confirm was built with slot version 0, but another command committed version 1 before this transaction's `UPDATE`. That confirm was never decided. Persisting `REJECTED` would force a new key even for an automatic retry that is about to re-read version 1 and succeed if the request is still `REQUESTED`. Rollback without a command row is the right branch. The second attempt is still the same gesture.

## Alternatives

### A. Server-generated idempotency only

Rejected for the prototype because there is no server round trip before commit. The client is the only party that knows two button presses were one gesture. Production intent keeps client-generated keys; the service stores them. A server that mints the key on the first HTTP response cannot dedupe a retry that never saw that response.

### B. Dedupe by `(actor, type, request)` with no client key

Rejected. It cannot tell a deliberate second cancel/request cycle from a retry, once terminal states are reused. After cancel, Ramesh must be able to request again. That is a new gesture and a new key. A natural key of `(patient, slot)` would block the second request, or would require time windows we will get wrong.

The partial unique index on live requests is a different rule: one live row per patient per slot. It is not the idempotency mechanism.

### C. Include expected versions in the fingerprint

Rejected. Demo 3's retry, and any timeout retry, often follows a refresh that loaded a new version into the form. The logical confirm is the same. Version checks belong in step 5 of the pipeline, on the first attempt that actually evaluates.

### D. Always re-execute the guard on retry and ignore stored results

Rejected. Two executions of confirm are how a side effect runs twice. The second execution might also see a different board and return a different answer than the one the clinic already acted on. The stored result is the contract.

### E. `IN_PROGRESS` row committed before the domain transaction

Rejected in the prototype. It creates a row that a crash must sweep, and it splits the atomicity Demo 3 depends on. Production may insert `IN_PROGRESS` if the HTTP gateway must record receipt before a slow transaction. That is a service-side change. The client contract (same key, same fingerprint, replay the final result) stays. We revisit the prototype schema only if we grow a real gateway.

## Cost

- The UI must keep `PendingGesture` across rebuilds of the bottom sheet. Losing the key in memory turns one gesture into two. The controller holds it, not the sheet's local `State` alone.
- A stored `FORBIDDEN` or `ILLEGAL_TRANSITION` will replay even after the board changes, until the user taps again and mints a new key. The banner has to say the action is unavailable, and the next tap is a new decision.
- `IDEMPOTENCY_REPLAY` audit rows add writes on the retry path. They are append-only and outside the domain update. If that extra transaction fails, the caller still returns the stored domain result. Audit loss on replay is acceptable. Domain double-apply is not.
- Payload mismatch is easy to cause in tests and rare in the UI if only one code path builds fingerprints. One helper, `commandFingerprint`, is mandatory.

## Failure this protects

- Demo 3 double confirm, double version bump, or a second waitlist side effect.
- A retry that confirms a different request because the key was reused by a copied handler.
- A patient jumping the queue by replaying someone else's key with a patched body. Mismatch rejects. (This is not authentication. It only stops accidental and trivial payload swaps. The identity switcher can still send a clinic command on purpose.)
- Timeout retries that would be rejected as stale solely because the form's version field changed, even when the first attempt never committed.

## Revisit when

- We add a remote gateway that must ack receipt before the domain transaction finishes. Add `IN_PROGRESS` on the service, with a sweeper. Do not change the fingerprint definition.
- A product requirement says "retry this exact decline after the slot reopens" using the old key. That is a new gesture. Keep the rule.
- Fingerprint version prefix moves from `v1` to `v2` because a new field must change identity. Old rows remain comparable only under `v1`. Do not reinterpret old fingerprints.

## Evidence expected in the build

- Demo 3 test: one confirm, chaos ack-lost, second `submit` with the same key, one `CONFIRMED` row, slot version incremented once, `replayed == true`, stored `effects` length unchanged.
- Test: same key, different `requestId`, domain rows unchanged, code `IDEMPOTENCY_PAYLOAD_MISMATCH`.
- Test: `TRANSACTION_ABORT` then retry succeeds once.
- Test: stale `UPDATE` does not leave a `commands` row; a second submit with the same key after the competing transaction can still apply if the transition is legal.
- Test: stored `REJECTED` replays without a second audit of a domain transition.
