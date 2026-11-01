// D15: lib/domain imports no Flutter, sqflite, HTTP, Firebase, Gemini,
// analytics, or notification SDKs, and nothing outside lib/domain.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final importPattern =
      RegExp(r'''^\s*(import|export|part)\s+['"]([^'"]+)['"]''', multiLine: true);

  List<File> dartFiles(String dir) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('D15 lib/domain imports only dart: core libraries and sibling domain '
      'files', () {
    final files = dartFiles('lib/domain');
    expect(files, isNotEmpty);
    final violations = <String>[];
    for (final file in files) {
      for (final match in importPattern.allMatches(file.readAsStringSync())) {
        final uri = match.group(2)!;
        final isAllowedDart = uri.startsWith('dart:') && uri != 'dart:ui' &&
            uri != 'dart:io' && uri != 'dart:html';
        final isSibling = !uri.contains(':') && !uri.startsWith('..');
        if (!isAllowedDart && !isSibling) {
          violations.add('${file.path}: $uri');
        }
      }
    }
    expect(violations, isEmpty);
  });

  test('banned SDK names never appear in lib/domain or lib/ports imports', () {
    const banned = [
      'package:flutter',
      'package:sqflite',
      'package:http',
      'package:dio',
      'package:firebase',
      'package:cloud_firestore',
      'package:google_generative_ai',
      'package:firebase_ai',
      'package:flutter_local_notifications',
      'package:riverpod',
      'package:flutter_riverpod',
      'package:bloc',
      'package:flutter_bloc',
      'package:drift',
      'package:provider',
    ];
    final violations = <String>[];
    for (final file in [...dartFiles('lib/domain'), ...dartFiles('lib/ports')]) {
      for (final match in importPattern.allMatches(file.readAsStringSync())) {
        final uri = match.group(2)!;
        if (banned.any(uri.startsWith)) violations.add('${file.path}: $uri');
      }
    }
    expect(violations, isEmpty);
  });

  test('only CommandGuard-adjacent transition.dart defines the legal table',
      () {
    // "No other type may list transitions" (03-LLD.md §3).
    final offenders = dartFiles('lib')
        .where((f) => !f.path.replaceAll('\\', '/').endsWith('domain/transition.dart'))
        .where((f) => f.readAsStringSync().contains('Map<RequestStatus, Set<RequestStatus>>'))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });
}

