import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PendingPing {
  final int id;
  final Map<String, dynamic> data;
  PendingPing(this.id, this.data);
}

/// Fila local (SQLite) de pings de GPS pendentes de envio. Garante que nada
/// se perde quando a van passa por uma area sem sinal: cada ping e gravado
/// aqui antes de tentar o POST; so sai da fila apos confirmacao do backend.
class OfflineQueue {
  static Database? _db;
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static String _payloadKey(int id) => 'pending_gps_$id';

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = p.join(await getDatabasesPath(), 'vaiescolar_queue.db');
    final opened = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) => db.execute(
        "CREATE TABLE pending_pings (id INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL DEFAULT '')",
      ),
    );
    final legacyRows = await opened.query(
      'pending_pings',
      columns: ['id', 'payload'],
      where: "payload <> ''",
    );
    for (final row in legacyRows) {
      final id = row['id'] as int;
      await _secureStorage.write(
        key: _payloadKey(id),
        value: row['payload'] as String,
      );
      await opened.update('pending_pings', {'payload': ''},
          where: 'id=?', whereArgs: [id]);
    }
    _db = opened;
    return opened;
  }

  static Future<void> enqueue(Map<String, dynamic> ping) async {
    final db = await _open();
    // O SQLite guarda apenas a ordem. Coordenadas ficam no Keystore/armazenamento
    // criptografado do Android e nunca aparecem em texto puro no banco local.
    final id = await db.insert('pending_pings', {'payload': ''});
    try {
      await _secureStorage.write(key: _payloadKey(id), value: jsonEncode(ping));
    } catch (_) {
      await db.delete('pending_pings', where: 'id=?', whereArgs: [id]);
      rethrow;
    }
  }

  static Future<List<PendingPing>> pending({int limit = 200}) async {
    final db = await _open();
    final rows =
        await db.query('pending_pings', orderBy: 'id ASC', limit: limit);
    final result = <PendingPing>[];
    for (final row in rows) {
      final id = row['id'] as int;
      final payload = await _secureStorage.read(key: _payloadKey(id));
      if (payload != null) {
        result
            .add(PendingPing(id, jsonDecode(payload) as Map<String, dynamic>));
      }
    }
    return result;
  }

  static Future<void> remove(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _open();
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('pending_pings',
        where: 'id IN ($placeholders)', whereArgs: ids);
    for (final id in ids) {
      await _secureStorage.delete(key: _payloadKey(id));
    }
  }

  static Future<int> count() async {
    final db = await _open();
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM pending_pings');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
