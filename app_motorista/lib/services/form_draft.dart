import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class FormDraft {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<Map<String, dynamic>?> read(String key) async {
    final raw = await _storage.read(key: 'draft_$key');
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      await delete(key);
      return null;
    }
  }

  static Future<void> write(String key, Map<String, dynamic> value) =>
      _storage.write(key: 'draft_$key', value: jsonEncode(value));

  static Future<void> delete(String key) => _storage.delete(key: 'draft_$key');
}
