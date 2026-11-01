// The legal transition table (01-SOLUTION-BRIEF.md "State machine").
//
// This is the ONLY place in the codebase that lists transitions.
// Pure Dart. No Flutter, sqflite, HTTP, Firebase, Gemini, or notifications.

import 'request_status.dart';

enum TransitionVerdict { allowed, illegalTransition }

const Map<RequestStatus, Set<RequestStatus>> _legal = {
  RequestStatus.requested: {
    RequestStatus.confirmed,
    RequestStatus.waitlisted,
    RequestStatus.declined,
    RequestStatus.cancelled,
  },
  // WAITLISTED -> CONFIRMED is deliberately absent.
  // WAITLISTED -> REQUESTED is only produced by the cancel-confirmed plan.
  RequestStatus.waitlisted: {
    RequestStatus.requested,
    RequestStatus.declined,
    RequestStatus.cancelled,
  },
  RequestStatus.confirmed: {
    RequestStatus.cancelled,
  },
  // DECLINED and CANCELLED are terminal: no outgoing edges.
};

/// Returns [TransitionVerdict.allowed] only for pairs in the table.
/// Self-transitions are illegal.
TransitionVerdict legalTransition(RequestStatus from, RequestStatus to) {
  final targets = _legal[from];
  if (targets != null && targets.contains(to)) {
    return TransitionVerdict.allowed;
  }
  return TransitionVerdict.illegalTransition;
}

