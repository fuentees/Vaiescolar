import 'package:shared_preferences/shared_preferences.dart';

enum AppProfile { driver, parent }

class ProfileMode {
  static const _key = 'selected_app_profile';

  static Future<AppProfile?> load() async {
    final value = (await SharedPreferences.getInstance()).getString(_key);
    return switch (value) {
      'driver' => AppProfile.driver,
      'parent' => AppProfile.parent,
      _ => null,
    };
  }

  static Future<void> save(AppProfile profile) async {
    await (await SharedPreferences.getInstance()).setString(_key, profile.name);
  }

  static Future<void> clear() async {
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}
