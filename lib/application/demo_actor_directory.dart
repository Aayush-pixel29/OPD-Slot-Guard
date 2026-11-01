// Demo actor directory (03-LLD.md §1).
//
// Application composition, not a database table.
// Three synthetic demo identities.

import '../domain/actor_policy.dart';

class DemoActorEntry {
  const DemoActorEntry({
    required this.actor,
    required this.displayName,
  });

  final Actor actor;
  final String displayName;

  String get id => actor.id;
  ActorRole get role => actor.role;
}

class DemoActorDirectory {
  DemoActorDirectory();

  static const ramesh = DemoActorEntry(
    actor: Actor(id: 'patient-ramesh', role: ActorRole.patient),
    displayName: 'Ramesh',
  );

  static const priya = DemoActorEntry(
    actor: Actor(id: 'patient-priya', role: ActorRole.patient),
    displayName: 'Priya',
  );

  static const clinicDesk = DemoActorEntry(
    actor: Actor(id: 'clinic-desk', role: ActorRole.clinic),
    displayName: 'Clinic Desk',
  );

  static const List<DemoActorEntry> all = [ramesh, priya, clinicDesk];

  Actor? findActor(String actorId) {
    for (final entry in all) {
      if (entry.id == actorId) return entry.actor;
    }
    return null;
  }

  String? displayNameFor(String actorId) {
    for (final entry in all) {
      if (entry.id == actorId) return entry.displayName;
    }
    return null;
  }
}
