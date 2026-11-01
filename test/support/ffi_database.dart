// Test support: creates an in-memory database using sqflite_common_ffi.

import 'package:opd_slot_guard/infrastructure/sqlite_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openTestDatabase({bool seed = true}) async {
  sqfliteFfiInit();
  final databaseFactory = databaseFactoryFfi;
  final db = await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        await SqliteSchema.createSchema(db);
        if (seed) {
          await SqliteSchema.seedInitialSlots(db);
        }
      },
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
    ),
  );
  return db;
}
