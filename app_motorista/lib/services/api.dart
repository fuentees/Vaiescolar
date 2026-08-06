import 'dart:convert';
import 'dart:typed_data';
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
  static String? _role;
  static String? lastError;

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
    _role = prefs.getString('role');
    // Sessao salva antes do userId/role existirem (versao antiga do app) --
    // forca um novo login em vez de deixar o resto do app quebrar sem esses dados.
    if (_token != null && (_userId == null || _role == null)) {
      await logout();
    }
  }

  static Future<void> logout() async {
    _token = null;
    _userId = null;
    _role = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await _secureStorage.delete(key: 'session_token');
    await prefs.remove('userId');
    await prefs.remove('role');
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

  static String? get token => _token;
  static String? get userId => _userId;
  static String? get role => _role;

  /// Cadastro de alunos/rotas e restrito a admin no backend -- so o dono do
  /// tenant (quem fez o onboarding) tem essa permissao, motoristas comuns nao.
  static bool get isAdmin => _role == 'admin';

  static Future<void> _saveSession(
      String token, String userId, String role) async {
    _token = token;
    _userId = userId;
    _role = role;
    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.write(key: 'session_token', value: token);
    await prefs.setString('userId', userId);
    await prefs.setString('role', role);
  }

  /// Atualiza so o token (mesma sessao) -- usado depois de trocar a propria
  /// senha, ja que isso invalida o token antigo no backend.
  static Future<void> _updateToken(String token) async {
    _token = token;
    await _secureStorage.write(key: 'session_token', value: token);
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
      if (body['role'] != 'admin' && body['role'] != 'driver') {
        lastError = 'Este acesso pertence ao perfil de responsável.';
        return false;
      }
      await _saveSession(body['token'] as String, body['userId'] as String,
          body['role'] as String);
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

  /// Cria uma nova empresa/operador (tenant) + a conta admin do dono.
  /// Retorna null em caso de sucesso, ou uma mensagem de erro.
  static Future<String?> registerTenant({
    required String tenantName,
    required String name,
    required String email,
    required String password,
  }) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/auth/register-tenant'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'tenantName': tenantName,
        'name': name,
        'email': email,
        'password': password
      }),
    );
    if (res.statusCode != 200) {
      return jsonDecode(res.body)['error'] as String? ?? 'erro desconhecido';
    }
    final body = jsonDecode(res.body);
    await _saveSession(body['token'] as String, body['userId'] as String,
        body['role'] as String);
    return null;
  }

  static Future<List<dynamic>> routes() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/routes'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<String?> startTrip(String routeId, String direction,
      {String? vehicleId}) async {
    lastError = null;
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/trips/start'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'route_id': routeId,
        'direction': direction,
        'vehicle_id': vehicleId
      }),
    );
    if (res.statusCode == 200) return jsonDecode(res.body)['tripId'];
    try {
      lastError = jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      lastError = 'Não foi possível iniciar a rota.';
    }
    return null;
  }

  static Future<bool> finishTrip(String tripId) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/finish'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  static Future<bool> cancelTrip(String tripId, String reason) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/cancel'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'reason': reason}),
    );
    return res.statusCode == 200;
  }

  static Future<bool> reportIncident(
      String tripId, String type, String description) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/incidents'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'type': type, 'description': description}),
    );
    return res.statusCode == 200;
  }

  static Future<bool> changeTripVehicle(String tripId, String vehicleId) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/vehicle'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'vehicle_id': vehicleId}),
    );
    return res.statusCode == 200;
  }

  /// A propria viagem ativa (se houver) -- usado no boot do app pra restaurar
  /// o estado "rota em andamento" depois de o processo ter sido morto.
  static Future<Map<String, dynamic>?> myActiveTrip() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/trips/mine/active'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    return body as Map<String, dynamic>?;
  }

  static Future<List<dynamic>> tripStudents(String tripId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/students'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<Map<String, dynamic>?> tripStops(String tripId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/stops'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<bool> registerEvent({
    required String tripId,
    required String studentId,
    required String type, // 'boarded' ou 'dropped'
    double? lat,
    double? lng,
    String? receivedBy,
  }) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/trips/$tripId/events'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'student_id': studentId,
        'type': type,
        'lat': lat,
        'lng': lng,
        'received_by': receivedBy,
      }),
    );
    return res.statusCode == 200;
  }

  static Future<bool> undoLastEvent(String tripId, String studentId) async {
    final res = await http.delete(
      Uri.parse(
          '${Config.apiBase}/api/trips/$tripId/students/$studentId/last-event'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  static Future<bool> startEmergencyReturn(
      String tripId, String studentId, String? reason) async {
    final res = await http.post(
      Uri.parse(
          '${Config.apiBase}/api/trips/$tripId/students/$studentId/emergency-return'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'reason': reason}),
    );
    return res.statusCode == 200;
  }

  static Future<bool> sendApproachingAlert(
      String tripId, String studentId) async {
    final res = await http.post(
      Uri.parse(
          '${Config.apiBase}/api/trips/$tripId/students/$studentId/approaching'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  /// Envia um lote de pings pendentes da fila offline. Retorna true so se o
  /// backend confirmar recebimento (200) -- so entao a fila local e limpa.
  static Future<bool> sendLocations(
      String tripId, List<Map<String, dynamic>> pings) async {
    if (pings.isEmpty) return true;
    try {
      final res = await http.post(
        Uri.parse('${Config.apiBase}/api/trips/$tripId/locations'),
        headers: {
          'authorization': 'Bearer $_token',
          'content-type': 'application/json'
        },
        body: jsonEncode(pings),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false; // sem rede: mantem os pings na fila para a proxima tentativa
    }
  }

  /// Gera um codigo de convite (7 dias) para o responsavel do aluno.
  static Future<Map<String, dynamic>?> generateInvite(
      String studentId, String relationship) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/students/$studentId/invite'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'relationship': relationship}),
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> studentInvites(String studentId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/students/$studentId/invites'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<bool> cancelInvite(String studentId, String inviteId) async {
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/students/$studentId/invites/$inviteId'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  // ---------------------------------------------------------------------
  // Gestao: alunos e rotas
  // ---------------------------------------------------------------------

  static Future<List<dynamic>> students() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/students'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<bool> createStudent({
    required String name,
    String? schoolName,
    String? homeAddress,
    String? homePostalCode,
    String? homeStreet,
    String? homeNumber,
    String? homeComplement,
    String? homeNeighborhood,
    String? homeCity,
    String? homeState,
    double? homeLat,
    double? homeLng,
    String? schoolId,
    double? monthlyFee,
    String? photoUrl,
    String? birthDate,
    String? classPeriod,
    String? emergencyContactName,
    String? emergencyContactPhone,
    String? medicalNotes,
    String? authorizedPickup,
    bool active = true,
  }) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/students'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'name': name,
        'school_name': schoolName,
        'home_address': homeAddress,
        'home_postal_code': homePostalCode,
        'home_street': homeStreet,
        'home_number': homeNumber,
        'home_complement': homeComplement,
        'home_neighborhood': homeNeighborhood,
        'home_city': homeCity,
        'home_state': homeState,
        'home_lat': homeLat,
        'home_lng': homeLng,
        'school_id': schoolId,
        'monthly_fee': monthlyFee,
        'photo_url': photoUrl,
        'birth_date': birthDate,
        'class_period': classPeriod,
        'emergency_contact_name': emergencyContactName,
        'emergency_contact_phone': emergencyContactPhone,
        'medical_notes': medicalNotes,
        'authorized_pickup': authorizedPickup,
        'active': active,
      }),
    );
    return res.statusCode == 200;
  }

  static Future<bool> createRoute(
    String name, {
    String? daysOfWeek,
    String? plannedTime,
    String? plannedTimeToSchool,
    String? plannedTimeToHome,
    bool active = true,
  }) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/routes'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'name': name,
        'days_of_week': daysOfWeek,
        'planned_time': plannedTime,
        'planned_time_to_school': plannedTimeToSchool,
        'planned_time_to_home': plannedTimeToHome,
        'active': active,
      }),
    );
    return res.statusCode == 200;
  }

  static Future<bool> updateRoute(
    String id,
    String name, {
    String? vehicleId,
    String? driverUserId,
    String? daysOfWeek,
    String? plannedTime,
    String? plannedTimeToSchool,
    String? plannedTimeToHome,
    bool active = true,
  }) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/routes/$id'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'name': name,
        'vehicle_id': vehicleId,
        'driver_user_id': driverUserId,
        'days_of_week': daysOfWeek,
        'planned_time': plannedTime,
        'planned_time_to_school': plannedTimeToSchool,
        'planned_time_to_home': plannedTimeToHome,
        'active': active,
      }),
    );
    return res.statusCode == 200;
  }

  static Future<List<dynamic>> routeStudents(String routeId,
      {String? direction}) async {
    final uri = Uri.parse('${Config.apiBase}/api/routes/$routeId/students')
        .replace(
            queryParameters:
                direction == null ? null : {'direction': direction});
    final res = await http.get(
      uri,
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<bool> linkStudentToRoute(
      String routeId, String studentId, String serviceDirection) async {
    lastError = null;
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/routes/$routeId/students'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'student_id': studentId,
        'service_direction': serviceDirection,
      }),
    );
    if (res.statusCode == 200) return true;
    try {
      lastError = jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      lastError = 'Nao foi possivel vincular o aluno.';
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // Chat
  // ---------------------------------------------------------------------

  static Future<List<dynamic>> chatThreads() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/chat/threads'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<List<dynamic>> chatMessages(String parentUserId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/chat/$parentUserId'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<bool> sendChatMessage(String parentUserId, String body) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/chat/$parentUserId'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'body': body}),
    );
    return res.statusCode == 200;
  }

  /// Soma de nao lidas em todas as threads (badge da aba Mensagens). -1 se a
  /// chamada falhar -- deixa o chamador manter o ultimo valor conhecido.
  static Future<int> chatUnreadCount() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/chat/unread-count'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return -1;
    return (jsonDecode(res.body)['unread'] as num).toInt();
  }

  /// Central de notificacoes: uniao de eventos recentes (embarque/desembarque,
  /// chat, faltas avisadas conforme o papel de quem chama).
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

  /// Auditoria administrativa (admin): quem alterou o que. `entityType`
  /// filtra por tipo (`user`/`student`/`route`/`vehicle`/`payment`).
  static Future<List<dynamic>> auditLog(
      {String? entityType, int limit = 50, int offset = 0}) async {
    final params = {
      'limit': '$limit',
      'offset': '$offset',
      if (entityType != null) 'entityType': entityType,
    };
    final uri = Uri.parse('${Config.apiBase}/api/audit-log')
        .replace(queryParameters: params);
    final res =
        await http.get(uri, headers: {'authorization': 'Bearer $_token'});
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  // ---------------------------------------------------------------------
  // Perfil, senha, usuarios, veiculos
  // ---------------------------------------------------------------------

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

  static Future<List<dynamic>> users() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/users'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<String?> createUser({
    required String role, // 'admin', 'driver' ou 'parent'
    required String name,
    required String email,
    required String password,
    String? phone,
  }) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/users'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'role': role,
        'name': name,
        'email': email,
        'password': password,
        'phone': phone
      }),
    );
    if (res.statusCode == 200) return null;
    return jsonDecode(res.body)['error'] as String? ?? 'erro desconhecido';
  }

  static Future<bool> updateUser(String userId,
      {String? name, String? phone}) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/users/$userId'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'name': name, 'phone': phone}),
    );
    return res.statusCode == 200;
  }

  /// Desativa (ou reativa) uma conta -- em vez de excluir. Erro comum: nao
  /// da pra desativar a propria conta (backend rejeita com 400).
  static Future<bool> setUserActive(String userId, bool active) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/users/$userId/active'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'active': active}),
    );
    return res.statusCode == 200;
  }

  /// Admin reseta a senha de um motorista/pai (fluxo de "esqueci a senha").
  static Future<bool> resetUserPassword(
      String userId, String newPassword) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/users/$userId/password'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'newPassword': newPassword}),
    );
    return res.statusCode == 200;
  }

  static Future<List<dynamic>> vehicles() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/vehicles'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<bool> createVehicle({
    required String plate,
    String? model,
    int? capacity,
    int? year,
    String? color,
    String? documentExpiry,
    String status = 'available',
  }) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/vehicles'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'plate': plate,
        'model': model,
        'capacity': capacity,
        'year': year,
        'color': color,
        'document_expiry': documentExpiry,
        'status': status,
      }),
    );
    return res.statusCode == 200;
  }

  static Future<bool> updateVehicle(
    String id, {
    required String plate,
    String? model,
    int? capacity,
    int? year,
    String? color,
    String? documentExpiry,
    String status = 'available',
  }) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/vehicles/$id'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'plate': plate,
        'model': model,
        'capacity': capacity,
        'year': year,
        'color': color,
        'document_expiry': documentExpiry,
        'status': status,
      }),
    );
    return res.statusCode == 200;
  }

  static Future<bool> deleteVehicle(String id) async {
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/vehicles/$id'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  static Future<bool> updateStudent(
    String id, {
    required String name,
    String? schoolName,
    String? homeAddress,
    String? homePostalCode,
    String? homeStreet,
    String? homeNumber,
    String? homeComplement,
    String? homeNeighborhood,
    String? homeCity,
    String? homeState,
    double? homeLat,
    double? homeLng,
    String? schoolId,
    double? monthlyFee,
    String? photoUrl,
    String? birthDate,
    String? classPeriod,
    String? emergencyContactName,
    String? emergencyContactPhone,
    String? medicalNotes,
    String? authorizedPickup,
    bool active = true,
  }) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/students/$id'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'name': name,
        'school_name': schoolName,
        'home_address': homeAddress,
        'home_postal_code': homePostalCode,
        'home_street': homeStreet,
        'home_number': homeNumber,
        'home_complement': homeComplement,
        'home_neighborhood': homeNeighborhood,
        'home_city': homeCity,
        'home_state': homeState,
        'home_lat': homeLat,
        'home_lng': homeLng,
        'school_id': schoolId,
        'monthly_fee': monthlyFee,
        'photo_url': photoUrl,
        'birth_date': birthDate,
        'class_period': classPeriod,
        'emergency_contact_name': emergencyContactName,
        'emergency_contact_phone': emergencyContactPhone,
        'medical_notes': medicalNotes,
        'authorized_pickup': authorizedPickup,
        'active': active,
      }),
    );
    return res.statusCode == 200;
  }

  static Future<Map<String, dynamic>?> studentDetail(String id) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/students/$id'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> studentContracts(String studentId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/students/$studentId/contracts'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<String?> issueStudentContract(String studentId) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/students/$studentId/contracts'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({}),
    );
    if (res.statusCode == 201) return null;
    try {
      return jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      return 'Nao foi possivel emitir o contrato.';
    }
  }

  static Future<String?> revokeContract(
      String contractId, String reason) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/contracts/$contractId/revoke'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'reason': reason}),
    );
    if (res.statusCode == 200) return null;
    try {
      return jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      return 'Nao foi possivel revogar o contrato.';
    }
  }

  static Future<List<dynamic>> contracts() async {
    final res = await http.get(Uri.parse('${Config.apiBase}/api/contracts'),
        headers: {'authorization': 'Bearer $_token'});
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<String?> bulkIssueContracts({bool renewSigned = false}) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/contracts/bulk-issue'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'renew_signed': renewSigned}),
    );
    if (res.statusCode == 200) return null;
    try {
      return jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      return 'Nao foi possivel emitir em lote.';
    }
  }

  static Future<List<dynamic>> contractCancellationRequests() async {
    final res = await http.get(
        Uri.parse('${Config.apiBase}/api/contracts/cancellation-requests'),
        headers: {'authorization': 'Bearer $_token'});
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<String?> resolveContractCancellation(
      String id, String decision) async {
    final res = await http.post(
        Uri.parse(
            '${Config.apiBase}/api/contracts/cancellation-requests/$id/resolve'),
        headers: {
          'authorization': 'Bearer $_token',
          'content-type': 'application/json'
        },
        body: jsonEncode({'decision': decision}));
    if (res.statusCode == 200) return null;
    try {
      return jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      return 'Nao foi possivel analisar a solicitacao.';
    }
  }

  static Future<Map<String, dynamic>?> contractSettings() async {
    final res = await http.get(
        Uri.parse('${Config.apiBase}/api/contracts/settings'),
        headers: {'authorization': 'Bearer $_token'});
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<String?> saveContractSettings(Map<String, dynamic> data) async {
    final res = await http.put(
        Uri.parse('${Config.apiBase}/api/contracts/settings'),
        headers: {
          'authorization': 'Bearer $_token',
          'content-type': 'application/json'
        },
        body: jsonEncode(data));
    if (res.statusCode == 200) return null;
    try {
      return jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      return 'Nao foi possivel salvar.';
    }
  }

  static Future<Uint8List?> contractPdf(String contractId) async {
    final res = await http.get(
        Uri.parse('${Config.apiBase}/api/contracts/$contractId/pdf?download=1'),
        headers: {'authorization': 'Bearer $_token'});
    return res.statusCode == 200 ? res.bodyBytes : null;
  }

  // ---------------------------------------------------------------------
  // Escolas
  // ---------------------------------------------------------------------

  static Future<List<dynamic>> schools() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/schools'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<bool> createSchool(
      {required String name,
      String? address,
      String? phone,
      String? postalCode,
      String? street,
      String? number,
      String? complement,
      String? neighborhood,
      String? city,
      String? state,
      double? lat,
      double? lng}) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/schools'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'name': name,
        'address': address,
        'phone': phone,
        'postal_code': postalCode,
        'street': street,
        'number': number,
        'complement': complement,
        'neighborhood': neighborhood,
        'city': city,
        'state': state,
        'lat': lat,
        'lng': lng
      }),
    );
    return res.statusCode == 200;
  }

  static Future<bool> updateSchool(String id,
      {required String name,
      String? address,
      String? phone,
      String? postalCode,
      String? street,
      String? number,
      String? complement,
      String? neighborhood,
      String? city,
      String? state,
      double? lat,
      double? lng}) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/schools/$id'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'name': name,
        'address': address,
        'phone': phone,
        'postal_code': postalCode,
        'street': street,
        'number': number,
        'complement': complement,
        'neighborhood': neighborhood,
        'city': city,
        'state': state,
        'lat': lat,
        'lng': lng
      }),
    );
    return res.statusCode == 200;
  }

  static Future<bool> deleteSchool(String id) async {
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/schools/$id'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  // ---------------------------------------------------------------------
  // Financeiro
  // ---------------------------------------------------------------------

  static Future<List<dynamic>> paymentsForMonth(String month) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/payments?month=$month'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<Map<String, dynamic>> generatePayments(String month) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/payments/generate'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'month': month}),
    );
    if (res.statusCode != 200) return {'created': 0, 'skipped': []};
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<bool> updatePayment(
    String id, {
    required String status,
    double? amount,
    String? notes,
    String? paymentMethod,
    String? paidAt,
  }) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/payments/$id'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'status': status,
        'amount': amount,
        'notes': notes,
        'payment_method': paymentMethod,
        'paid_at': paidAt,
      }),
    );
    return res.statusCode == 200;
  }

  static Future<Map<String, dynamic>> paymentsSummary(String month) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/payments/summary?month=$month'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) {
      return {
        'total': 0,
        'paid': 0,
        'pending': 0,
        'total_amount': 0,
        'paid_amount': 0
      };
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> paymentProvider() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/payment-provider'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) {
      return {'provider': 'manual_pix', 'active': false};
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<String?> savePaymentProvider({
    required String provider,
    String? pixKey,
    String? merchantName,
    String? apiToken,
  }) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/payment-provider'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({
        'provider': provider,
        'pix_key': pixKey,
        'merchant_name': merchantName,
        'api_token': apiToken
      }),
    );
    if (res.statusCode == 200) return null;
    try {
      return jsonDecode(res.body)['error'] as String?;
    } catch (_) {
      return 'Não foi possível salvar.';
    }
  }

  static Future<Map<String, dynamic>?> createPaymentCheckout(
      String paymentId) async {
    final res = await http.post(
      Uri.parse('${Config.apiBase}/api/payments/$paymentId/checkout'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------
  // Dashboard (home)
  // ---------------------------------------------------------------------

  static Future<Map<String, dynamic>?> dashboardSummary() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/dashboard/summary'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> dashboardToday() async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/dashboard/today'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<bool> deleteStudent(String id) async {
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/students/$id'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  static Future<bool> deleteRoute(String id) async {
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/routes/$id'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
  }

  static Future<bool> removeStudentFromRoute(
      String routeId, String studentId) async {
    final res = await http.delete(
      Uri.parse('${Config.apiBase}/api/routes/$routeId/students/$studentId'),
      headers: {'authorization': 'Bearer $_token'},
    );
    return res.statusCode == 200;
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

  // ---------------------------------------------------------------------
  // Falta avulsa
  // ---------------------------------------------------------------------

  /// Faltas do dia (default hoje) -- pro motorista ver quem nao vem.
  static Future<List<dynamic>> absencesForDate(String date) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/absences?date=$date'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  // ---------------------------------------------------------------------
  // Ordem de embarque
  // ---------------------------------------------------------------------

  static Future<bool> reorderRouteStudents(
      String routeId, List<String> studentIds) async {
    final res = await http.put(
      Uri.parse('${Config.apiBase}/api/routes/$routeId/students/reorder'),
      headers: {
        'authorization': 'Bearer $_token',
        'content-type': 'application/json'
      },
      body: jsonEncode({'studentIds': studentIds}),
    );
    return res.statusCode == 200;
  }

  // ---------------------------------------------------------------------
  // Relatorios
  // ---------------------------------------------------------------------

  static Future<List<dynamic>> financialHistory({int months = 6}) async {
    final res = await http.get(
      Uri.parse(
          '${Config.apiBase}/api/reports/financial-history?months=$months'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<List<dynamic>> tripsReport({
    String? driverId,
    String? routeId,
    String? vehicleId,
    int limit = 20,
    int offset = 0,
  }) async {
    final params = {
      'limit': '$limit',
      'offset': '$offset',
      if (driverId != null) 'driverId': driverId,
      if (routeId != null) 'routeId': routeId,
      if (vehicleId != null) 'vehicleId': vehicleId,
    };
    final uri = Uri.parse('${Config.apiBase}/api/reports/trips')
        .replace(queryParameters: params);
    final res =
        await http.get(uri, headers: {'authorization': 'Bearer $_token'});
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List<dynamic>;
  }

  static Future<Map<String, dynamic>?> tripReportDetail(String tripId) async {
    final res = await http.get(
      Uri.parse('${Config.apiBase}/api/reports/trips/$tripId'),
      headers: {'authorization': 'Bearer $_token'},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
