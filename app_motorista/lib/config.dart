// Producao usa o backend publico do Render por padrao. Para desenvolvimento
// local, sobrescreva com --dart-define=API_BASE=http://10.0.2.2:3000 e
// --dart-define=WS_BASE=ws://10.0.2.2:3000.
class Config {
  static const String apiBase = String.fromEnvironment('API_BASE',
      defaultValue: 'https://vaiescolar.onrender.com');
  static const String wsBase = String.fromEnvironment('WS_BASE',
      defaultValue: 'wss://vaiescolar.onrender.com');
}
