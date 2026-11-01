// Demo database initialization and file-replace reset (02-HLD.md §7, 03-LLD.md §2).
//
// Reset deletes the database file and creates it afresh with schema & seed.
// Normal writes never DELETE or UPDATE audit rows (append-only triggers).

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'sqlite_schema.dart';

class DemoDatabaseManager {
  DemoDatabaseManager({this.customPath});

  final String? customPath;
  Database? _db;

  Database get db => _db!;

  Future<String> getDatabasePath() async {
    if (customPath != null) return customPath!;
    final dbDir = await getDatabasesPath();
    return p.join(dbDir, 'opd_slot_guard.db');
  }

  Future<Database> open() async {
    if (_db != null && _db!.isOpen) return _db!;
    final path = await getDatabasePath();
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await SqliteSchema.createSchema(db);
        await SqliteSchema.seedInitialSlots(db);
      },
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
    );
    return _db!;
  }

  Future<void> reset() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
    }
    final path = await getDatabasePath();
    await deleteDatabase(path);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await SqliteSchema.createSchema(db);
        await SqliteSchema.seedInitialSlots(db);
      },
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
    );
  }
}

