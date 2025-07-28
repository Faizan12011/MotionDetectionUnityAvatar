import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// SQLite helper to persist a single PIN set by the user.
///
/// Usage:
///   final pinDb = PinDb();
///   await pinDb.open();
///   final pin = await pinDb.getPin();
///   if (pin == null) await pinDb.setPin('1234');
class PinDb {
  static const _dbFileName = 'user_pin.db';
  static const _table = 'pin';

  Database? _db;

  Future<void> open() async {
    if (_db != null) return;
    final Directory dir = await getApplicationDocumentsDirectory();
    final String path = p.join(dir.path, _dbFileName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE IF NOT EXISTS $_table ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'pin TEXT NOT NULL, name TEXT NOT NULL'
          ')',
        );
      },
    );
  }

  Future<void> setCredentials(String pin, String name) async {
    if (_db == null) throw StateError('DB not open');
    await _db!.delete(_table);
    try {
      await _db!.insert(_table, {'pin': pin, 'name': name});
    } on DatabaseException catch (e) {
      if (e.toString().contains('no column named name')) {
        await _db!.execute('ALTER TABLE $_table ADD COLUMN name TEXT');
        await _db!.insert(_table, {'pin': pin, 'name': name});
      } else {
        rethrow;
      }
    }
  }

  Future<Map<String, String>?> getCredentials() async {
    if (_db == null) throw StateError('DB not open');
    final rows = await _db!.query(_table, limit: 1);
    if (rows.isNotEmpty) {
      return {
        'pin': rows.first['pin'] as String,
        'name': rows.first['name'] as String,
      };
    }
    return null;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

/// A lightweight wrapper around `sqflite` used by the video-pose screen
/// to persist every processed pose frame on disk instead of keeping them
/// all in memory.
///
/// Table schema (v1):
///   frames(
///     ts  INTEGER PRIMARY KEY,   -- video timestamp (milliseconds)
///     kp  TEXT NOT NULL,         -- JSON-encoded List<double> (length 99)
///     cat TEXT                   -- optional high-level pose label
///   )
class PoseFrameDb {
  static const _dbFileName = 'video_pose_tmp.db';
  static const _table = 'frames';

  Database? _db;

  bool get _isOpen => _db != null && _db!.isOpen;

  // Reopen the DB if it has been closed (e.g. when user taps Retake and a new
  // screen instance reuses the same helper).
  Future<void> _ensureOpen() async {
    if (_isOpen) return;
    await open();
  }

  Future<void> open() async {
    if (_db != null) return;
    final Directory dir = await getTemporaryDirectory();
    final String path = p.join(dir.path, _dbFileName);

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE $_table ('
          'ts INTEGER PRIMARY KEY, '
          'kp TEXT NOT NULL, '
          'cat TEXT'
          ')',
        );
      },
    );
  }

  Future<void> clear() async {
    await _ensureOpen();
    if (_db == null) throw StateError('DB not open');
    await _db!.delete(_table);
  }

  Future<void> insertFrame(
    int timestampMs,
    List<double> kp,
    String category,
  ) async {
    await _ensureOpen();
    if (_db == null) throw StateError('DB not open');
    await _db!.insert(_table, {
      'ts': timestampMs,
      'kp': jsonEncode(kp),
      'cat': category,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Returns the frame row whose `ts` is <= target and closest to it.
  Future<Map<String, Object?>?> getClosest(int targetTs) async {
    await _ensureOpen();
    if (_db == null) throw StateError('DB not open');
    final rows = await _db!.rawQuery(
      'SELECT * FROM $_table WHERE ts <= ? ORDER BY ts DESC LIMIT 1',
      [targetTs],
    );
    if (rows.isNotEmpty) return rows.first;

    // fallback: earliest after target (first frames)
    final after = await _db!.rawQuery(
      'SELECT * FROM $_table WHERE ts > ? ORDER BY ts ASC LIMIT 1',
      [targetTs],
    );
    return after.isNotEmpty ? after.first : null;
  }

  Future<void> clearAndClose(bool shouldClose) async {
    if (!_isOpen) return;

    if (shouldClose) await _db!.close();
    _db = null;
  }
}
