import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

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

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = p.join(await getDatabasesPath(), 'vaiescolar_queue.db');
    final opened = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE pending_pings (id INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL)',
      ),
    );
    _db = opened;
    return opened;
  }

  static Future<void> enqueue(Map<String, dynamic> ping) async {
    final db = await _open();
    await db.insert('pending_pings', {'payload': jsonEncode(ping)});
  }

  static Future<List<PendingPing>> pending({int limit = 200}) async {
    final db = await _open();
    final rows =
        await db.query('pending_pings', orderBy: 'id ASC', limit: limit);
    return rows
        .map((r) => PendingPing(
              r['id'] as int,
              jsonDecode(r['payload'] as String) as Map<String, dynamic>,
            ))
        .toList();
  }

  static Future<void> remove(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _open();
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('pending_pings',
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  static Future<int> count() async {
    final db = await _open();
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM pending_pings');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
