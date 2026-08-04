import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RememberedLogin {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _emailKey = 'parent_remembered_email';
  static const _passwordKey = 'parent_remembered_password';

  static Future<({String email, String password})?> load() async {
    final values = await _storage.readAll();
    final email = values[_emailKey];
    final password = values[_passwordKey];
    if (email == null || password == null) return null;
    return (email: email, password: password);
  }

  static Future<void> save(String email, String password) async {
    await _storage.write(key: _emailKey, value: email);
    await _storage.write(key: _passwordKey, value: password);
  }

  static Future<void> clear() async {
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _passwordKey);
  }
}
