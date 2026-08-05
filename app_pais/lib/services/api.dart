import 'dart:convert';
import 'api_http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config.dart';

class Api {
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static String? _token;
  static String? _userId;
  static String? lastError;
  static String? lastLinkedStudentName;
  static bool lastLinkUsedExistingAccount = false;

  static Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = await _secureStorage.read(key: 'session_token');
    final legacyToken = prefs.getString('token');
    if (_token == null && legacyToken != null) {
      _token = legacyToken;
      await _secureStorage.write(key: 'session_token', value: legacyToken);
      await prefs.remove('token');
    }
    _userId = prefs.getString('userId');
    // Sessao salva antes do userId existir (versao antiga do app) -- forca
    // um novo login em vez de deixar o resto do app quebrar sem esse dado.
    if (_token != null && _userId == null) {
      await logout();
    }
  }

  static String? get token => _token;
  static String? get userId => _userId;

  static Future<void> _saveSession(String token, String userId) async {
    _token = token;
    _userId = userId;
    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.write(key: 'session_token', value: token);
    await prefs.setString('userId', userId);
  }

  /// Atualiza so o token (mesma sessao) -- usado depois de trocar a propria
  /// senha, ja que isso invalida o token antigo no backend.
  static Future<void> _updateToken(String token) async {
    _token = token;
    await _secureStorage.write(key: 'session_token', value: token);
  }

  static Future<void> logout() async {
    _token = null;
    _userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await _secureStorage.delete(key: 'session_token');
    await prefs.remove('userId');
  }

  static Future<String?> deleteAccount(String password) async {
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/auth/account'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'password': password}),
    );
    if (res.statusCode == 200) {
      await logout();
      return null;
    }
    try {
      return jsonDecode(res.body)['error'] as String? ??
          'Não foi possível excluir a conta.';
    } catch (_) {
      return 'Não foi possível excluir a conta.';
    }
  }

  static Future<bool> login(String email, String password) async {
    lastError = null;
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(
          {'email': email.trim().toLowerCase(), 'password': password}),
    );
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body);
      if (body['role'] != 'parent') {
        lastError = 'Este acesso pertence ao perfil de motorista.';
        return false;
      }
      await _saveSession(body['token'] as String, body['userId'] as String);
      return true;
    }
    if (res.statusCode == 599) {
      lastError = 'Sem conexão com o servidor. Verifique sua internet.';
    } else {
      try {
        lastError = jsonDecode(res.body)['error'] as String?;
      } catch (_) {
        lastError = null;
      }
      if (lastError == 'credenciais invalidas') {
        lastError = 'E-mail ou senha incorretos.';
      }
      lastError ??= 'E-mail ou senha incorretos.';
    }
    return false;
  }

  /// Viagens ativas hoje que envolvem algum filho do pai logado.
  static Future<List<dynamic>> activeTrips() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/trips/active'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// Todos os filhos do pai logado, tenham ou nao viagem ativa hoje -- base
  /// da home redesenhada (antes so dava pra ver quem tinha viagem rolando).
  static Future<List<dynamic>> myChildren() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/students/mine'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// Status de pagamento (mensalidade) dos proprios filhos no mes informado
  /// ("YYYY-MM"). So leitura -- e um ledger manual do admin, o pai nao paga
  /// por aqui.
  static Future<List<dynamic>> myPaymentsForMonth(String month) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/payments/mine?month=$month'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// Ultima posicao conhecida da viagem (fallback antes do WebSocket conectar).
  static Future<Map<String, dynamic>?> tripLocation(String tripId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/location'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    return body == null ? null : body as Map<String, dynamic>;
  }

  /// Eventos (embarque/desembarque) da viagem, em ordem cronologica -- usado
  /// pela tela de timeline do dia.
  static Future<List<dynamic>> tripEvents(String tripId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/events'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// Cadastro do responsavel via codigo de convite gerado pelo motorista.
  /// Retorna null em caso de erro (codigo invalido/expirado/ja usado).
  static Future<String?> registerWithCode({
    required String code,
    required String name,
    required String email,
    required String password,
  }) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/auth/register-parent'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'code': code,
        'name': name,
        'email': email.trim().toLowerCase(),
        'password': password
      }),
    );
    if (res.statusCode != 200) {
      return jsonDecode(res.body)['error'] as String? ?? 'erro desconhecido';
    }
    final body = jsonDecode(res.body);
    lastLinkedStudentName = body['studentName'] as String?;
    lastLinkUsedExistingAccount = body['existingAccount'] == true;
    await _saveSession(body['token'] as String, body['userId'] as String);
    return null;
  }

  static Future<Map<String, dynamic>?> me() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/auth/me'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Troca a propria senha. Retorna null em caso de sucesso, ou uma mensagem de erro.
  static Future<String?> changePassword(
      String currentPassword, String newPassword) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/auth/password'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode(
          {'currentPassword': currentPassword, 'newPassword': newPassword}),
    );
    if (res.statusCode == 200) {
      // O backend invalida o token antigo ao trocar a senha e devolve um
      // novo -- sem isso, a proxima chamada desse app falharia com 401.
      final token = jsonDecode(res.body)['token'] as String?;
      if (token != null) await _updateToken(token);
      return null;
    }
    return jsonDecode(res.body)['error'] as String? ?? 'erro desconhecido';
  }

  /// Envia/atualiza o token FCM do dispositivo para o backend poder enviar push.
  static Future<void> registerFcmToken(String fcmToken) async {
    if (_token == null) return;
    await http.post(
      Uri.parse('${Config.apiBase}/api/users/fcm-token'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'fcm_token': fcmToken}),
    );
  }

  /// Historico da conversa do pai logado com o motorista/admin do tenant.
  static Future<List<dynamic>> chatMessages() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/chat/$_userId'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<bool> sendChatMessage(String body) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/chat/$_userId'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'body': body}),
    );
    return res.statusCode == 200;
  }

  /// Total de mensagens nao lidas do pai (badge da aba Mensagens). -1 se a
  /// chamada falhar (rede/servidor) -- deixa o chamador decidir se mantem o
  /// ultimo valor conhecido em vez de mostrar 0 (que pareceria "tudo lido").
  static Future<int> chatUnreadCount() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/chat/unread-count'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return -1;
    return (jsonDecode(res.body)['unread'] as num).toInt();
  }

  /// Central de notificacoes: uniao de eventos recentes (embarque/desembarque
  /// dos proprios filhos, mensagens de chat novas).
  static Future<List<dynamic>> notifications({int limit = 30}) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/notifications?limit=$limit'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<bool> clearNotifications() async {
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/notifications'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  /// Historico de viagens finalizadas envolvendo um filho especifico.
  static Future<List<dynamic>> tripHistory(String studentId,
      {int limit = 20, int offset = 0}) async {
    final uri = Uri.parse('${Config.apiBase}/api/trips/history')
        .replace(queryParameters: {
      'studentId': studentId,
      'limit': '$limit',
      'offset': '$offset',
    });
    final res =
        await http.get(uri, headers: {'authorization': 'Bearer $_token'});
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// Detalhes completos de um filho (escola, endereco, contatos de
  /// emergencia, responsaveis, ultimos pagamentos).
  static Future<Map<String, dynamic>?> studentDetail(String studentId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/students/$studentId'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Vincula outro filho a conta ja logada usando um segundo codigo de
  /// convite (diferente de [registerWithCode], que so serve pra criar a
  /// primeira conta). Retorna null em caso de sucesso, ou uma mensagem de erro.
  static Future<String?> linkChild(String code) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/auth/link-child'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'code': code}),
    );
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      lastLinkedStudentName = body['studentName'] as String?;
      return null;
    }
    return jsonDecode(res.body)['error'] as String? ?? 'erro desconhecido';
  }

  /// Faltas futuras dos proprios filhos.
  static Future<List<dynamic>> myAbsences() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/absences/mine'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// Avisa que o aluno nao vai numa data especifica ("YYYY-MM-DD").
  static Future<bool> markAbsence(String studentId, String date,
      {String? notes, String direction = 'all'}) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/absences'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'student_id': studentId,
        'date': date,
        'notes': notes,
        'direction': direction
      }),
    );
    return res.statusCode == 200;
  }

  static Future<bool> cancelAbsence(String absenceId) async {
    lastError = null;
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/absences/$absenceId'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode == 200) return true;
    try {
      lastError = jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      lastError = 'Nao foi possivel cancelar a falta.';
    }
    return false;
  }
}
