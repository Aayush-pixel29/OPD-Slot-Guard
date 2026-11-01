# ADR-03 — Policy and provider boundaries

Status: accepted for the hackathon.
Date: 2026-11-01.

## Context

Three pressures will try to collapse into the confirm button during the build:

- capacity is 1 today and N later
- Gemini, Measure, and Firebase are attractive extras
- actor rules feel fake because the switcher has no password

If those land in the widget or in the SQL adapter as unnamed `if` statements, the core journey takes a dependency on an optional SDK and the N migration rewrites command handling.

## Decision

### Capacity

`SlotCapacityPolicy.canAdmitConfirmation` is the only domain function that knows the numeric rule.

Prototype implementation fails closed:

- `capacity` must equal 1 or the function throws `CapacitySeamException`
- admission is allowed only when `confirmedCount == 0`

The database mirrors that with `CHECK (capacity = 1)` and `ux_one_confirmed_per_slot`.

When the product moves to N, only these change:

| Seam | Prototype | N change |
| --- | --- | --- |
| `SlotCapacityPolicy` | throw unless capacity is 1; admit iff count is 0 | admit iff `confirmedCount < capacity`; remove the throw |
| `slots.capacity` | seed value 1 and the check constraint `= 1` | `CHECK (capacity >= 1)`, seed values per slot |
| Capacity enforcement in the database | partial unique index on `CONFIRMED` per `slot_id` | drop that index; add a `BEFORE UPDATE` / `BEFORE INSERT` trigger that aborts when the confirmed count would exceed `slots.capacity` |

No other contract changes. In particular these stay:

- `AppointmentAuthority.submit`
- command types and fingerprint `v1`
- status enum and the legal transition table
- idempotency replay rules in ADR-02
- version bump rules: slot version bumps only when the confirmed set changes
- reopen restores `WAITLISTED` → `REQUESTED` in `queue_ms` order and does not confirm
- `WAITLISTED` → `CONFIRMED` stays illegal, so N does not mean "confirm from the waitlist"
- patient versus clinic read-model boundary
- UI words `AVAILABLE` and `BOOKED`, where `BOOKED` means confirmed count has reached capacity

`Exclusive` behavior is intentional. A policy written as `count < capacity` on day one would look N-ready while the unique index still forbids a second confirm. The throw makes the unfinished seam loud.

Side effect while at capacity stays: a successful confirm that reaches capacity moves remaining `REQUESTED` rows on that slot to `WAITLISTED` in the same transaction. At N, that side effect runs only when the confirming write reaches capacity, which is the same sentence. The code that loops sibling `REQUESTED` rows does not encode the number 1.

### Providers

| Provider | On the core journey now? | Allowed attachment point | Forbidden attachment point |
| --- | --- | --- | --- |
| sqflite | Yes. It is the prototype authority. | `lib/infrastructure` | `lib/domain`, widgets |
| Firebase | No. Architecture only. | A future `AppointmentNotifier` called after `submit` returns, failure ignored. | `AppointmentAuthority`, schema, confirm transaction |
| Gemini | No. Optional after demos pass. | A sheet that explains already-loaded status text. Input is status names the user already sees. | Guard, capacity, idempotency, any write |
| Measure or any analytics SDK | No. Optional after demos pass. | Fire-and-forget counter after a result, failure ignored. | The decision to commit, retry, or authorize |

Core journey means: browse, request, confirm, decline, cancel, reopen, replay.

If an optional call throws, the command result already returned to the controller still stands. Optional code cannot roll back a commit and cannot veto one.

No API keys, Firebase options files, or model names in source for the hackathon core. Adding Gemini later uses a local secret mechanism outside git, not a constant in the repo. The core build has no secret at all.

### Authorization without authentication

`ActorPolicy` runs in `CommandGuard` for every command, using `actor_id` on the command. The switcher is an untrusted demo input that selects which synthetic actor the application will attach. It is not a bypass flag on the authority.

The prototype accepts impersonation through the switcher. Production intent: the service overwrites `actor_id` from the credential and ignores a client-supplied actor. The policy function stays.

Patients never receive other patients' ids in the read model. Clinic does.

## Alternatives

### A. Hard-code `if (confirmedCount == 0)` inside the confirm SQL only

Rejected. The insert path also needs to choose `REQUESTED` versus `WAITLISTED`. Two copies of "is there room?" will diverge. The policy is one function used by the guard for both. SQL remains the backstop, not the only copy, because the error code `CAPACITY_EXCEEDED` must be a domain result rather than a raw SQLite abort string shown to a patient.

### B. Build N now

Rejected. The judged demos are capacity 1. A general allocator spends the hour we need for idempotency and reopen. The seam is the whole future requirement.

### C. Put Gemini in the confirm path to "decide who should get the slot"

Rejected. That hands invariant 1 to a model. Confirm is a clinic command with a named request id. A model must not choose the winner and must not rewrite waitlist order.

### D. Skip `ActorPolicy` because login is fake

Rejected. The judge will ask what stops Ramesh from confirming himself if the UI hides the button. The answer has to be the guard, demonstrated by a test that calls `submit` with a patient actor and `ConfirmRequest`.

### E. Share one Firebase project as the board "so the switcher feels real"

Rejected. See ADR-01. A second writer breaks the transaction that Demo 2 is about.

## Cost

- Capacity N is a deliberate migration, not a data change alone. Shipping N without dropping the unique index will throw. That is the desired cost.
- Optional features cannot influence the board until after commit, so they cannot "suggest a confirm" in the transaction. They can only narrate.
- We will not have a cloud demo. The chaos sheet is how we show resilience instead.

## Failure this protects

- A second confirmed patient.
- An optional SDK outage failing a confirm that already had a valid plan.
- An API key in the repository or in a log.
- Patient UI listing Priya's name on Ramesh's phone.
- A future capacity edit that also "simplifies" reopen into auto-confirm.

## Revisit when

- A judged requirement says capacity is N during the hackathon. Apply the three-seam migration and add a test with `capacity = 2` and three requesters. Do not change idempotency.
- Gemini is added. New tests must show command results are identical with the explainer throwing.
- Real authentication arrives. Replace the directory at the composition root. Keep `ActorPolicy`.

## Evidence expected in the build

- `lib/domain` file imports: no Flutter, sqflite, firebase, http, google_generative_ai, or analytics packages.
- `patientConfirmIsForbidden` and `patientReadModelHidesOtherPatient` tests.
- One comment on the unique index pointing at this ADR.
- `pubspec.yaml` dependencies limited to the list in the architecture-gate summary.
