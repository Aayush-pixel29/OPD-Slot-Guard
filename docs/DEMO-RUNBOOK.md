# OPD Slot Guard — Demo Runbook

Status: judge-facing script for one device.
Time: about six minutes after the app is on the board.
Data: synthetic identities only.

Say this out loud at the start:

> This build has one local appointment authority, a SQLite file. Ramesh, Priya, and the desk are actors on that file. It does not claim multi-device consistency. A remote service could implement the same command contract later.

If a step does not match the expected column, stop and reset. Do not improvise a second confirm.

## Setup

1. Launch the app. The board lists six slots from 4:00 PM through 6:30 PM.
2. All six show `AVAILABLE`.
3. Open Diagnostics. Confirm chaos is not armed. Leave the sheet closed, or keep it available for Demo 3.
4. If the board is dirty, tap Reset demo data. Wait until only seeded slots remain.

The identity control is in the app bar. Switching it does not book anything.

## Demo 1 — Confirm parks the other patient

| Step | Do | Expected on screen |
| --- | --- | --- |
| 1 | Switch to Ramesh. Open 6:30 PM. Request. | Ramesh: `REQUESTED`. Slot: `AVAILABLE`. |
| 2 | Switch to Priya. Open 6:30 PM. Request. | Priya: `REQUESTED`. Slot: `AVAILABLE`. |
| 3 | Switch to Clinic Desk. Open 6:30 PM. | Both requests visible. Ramesh ahead of Priya on `queue_ms`. |
| 4 | Confirm Ramesh. | Slot: `BOOKED`. Ramesh: `CONFIRMED`. Priya: `WAITLISTED`. |
| 5 | Switch to Ramesh. | He sees `CONFIRMED` and `BOOKED`. He does not see Priya's name. |
| 6 | Switch to Priya. | She sees `WAITLISTED` and `BOOKED`. She does not see Ramesh's name. |

Say:

> Confirm is one transaction. The slot version moves once. Priya is waitlisted as an effect of filling capacity. She was not declined.

If Priya is still `REQUESTED` while the slot says `BOOKED`, the demo has failed the side-effect rule. Stop.

## Demo 2 — Cancel reopens and does not auto-confirm

Continue from Demo 1 without reset.

| Step | Do | Expected |
| --- | --- | --- |
| 1 | Switch to Ramesh. Open 6:30 PM. Cancel. | Ramesh: `CANCELLED`. Slot: `AVAILABLE`. |
| 2 | Switch to Priya. | Priya: `REQUESTED`, not `CONFIRMED`. Slot: `AVAILABLE`. |
| 3 | Switch to Clinic Desk. | Priya is `REQUESTED`. Nobody is `CONFIRMED`. |

Say:

> Cancelling the confirmed patient reopens the slot and restores the waitlist to requested, in queue order. The desk still has to confirm Priya. The system will not choose her automatically.

Optional proof, only if asked: cancel is visible on Ramesh as `CANCELLED`, and the slot staying `AVAILABLE` after a waitlist cancel can be a short aside. Do not start it if time is short.

## Demo 3 — Lost acknowledgement replays

Reset demo data first so the command log is obvious.

| Step | Do | Expected |
| --- | --- | --- |
| 1 | As Ramesh, request 6:30 PM. | `REQUESTED`, slot `AVAILABLE`. |
| 2 | As Priya, request 6:30 PM. | Both `REQUESTED`. |
| 3 | Open Diagnostics. Arm `ACK_LOST` once. Close the sheet. | Flag is one-shot. |
| 4 | As Clinic Desk, confirm Ramesh. | A banner may say the connection dropped and the app is checking. It must not say the database failed. |
| 5 | Wait for the automatic retry. | Slot `BOOKED`. Ramesh `CONFIRMED`. Priya `WAITLISTED`. |
| 6 | Open Diagnostics. | One confirm command. Replay marked. Machine code shows the lost ack then the stored success. Audit does not show two confirm transitions for Ramesh. |

Say:

> The first call committed. The UI lost the ack. The retry sent the same idempotency key. The authority returned the stored result and did not confirm again, did not bump the slot version again, and did not waitlist Priya twice.

If the judge wants the failure modes that do **not** commit:

| Extra | Arm | Then | Expected |
| --- | --- | --- | --- |
| Abort | `TRANSACTION_ABORT`, then confirm a fresh requested slot | Error banner: nothing was saved. Slot still `AVAILABLE`. Retry with the same pending action succeeds once. |
| Offline | `OFFLINE`, then request | Nothing was changed. No request row until a retry with the same action. |

Do these only after Demo 3 has landed.

## Reset between full runs

Diagnostics → Reset demo data → board returns to six `AVAILABLE` slots, versions back to seed, no requests.

Reset deletes the database file and creates it again. It is a demo tool, not a clinical command.

## What not to say

- Do not say the app syncs to a server.
- Do not say Firebase is the source of truth.
- Do not say a waitlisted patient is automatically next in line to be booked. They are next in line to be **reviewed**.
- Do not show raw exception text. If it appears, that is a defect against the failure matrix. Reset and note it.

## Fallback if the UI misbehaves

The judged behavior is the ffi tests `DEMO1`, `DEMO2`, and `DEMO3`. If the device build is blocked, run `flutter test` and walk the judge through those three tests and the schema constraints. Prefer a working board. Use the tests as the proof underneath the board, not as a substitute you plan on.
