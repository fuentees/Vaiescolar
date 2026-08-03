// No emulador Android o default (10.0.2.2) ja aponta pro backend local.
// Pra outros ambientes (device fisico, producao), builde com:
//   flutter build apk --dart-define=API_BASE=https://sua-api.com --dart-define=WS_BASE=wss://sua-api.com
class Config {
  static const String apiBase =
      String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:3000');
  static const String wsBase =
      String.fromEnvironment('WS_BASE', defaultValue: 'ws://10.0.2.2:3000');
}
