import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as base;

/// Cliente HTTP unico do app. Toda chamada passa por timeout e pelo mesmo
/// tratamento de sessao expirada, inclusive os metodos antigos da API.
class ApiHttp {
  ApiHttp._();

  static const timeout = Duration(seconds: 15);
  static Future<void> Function()? onUnauthorized;
  static String? Function()? currentToken;
  static bool _handlingUnauthorized = false;

  static Future<base.Response> _run(
      Future<base.Response> request, Map<String, String>? headers) async {
    late final base.Response response;
    try {
      response = await request.timeout(timeout);
    } on TimeoutException {
      return base.Response('{"error":"offline"}', 599,
          headers: const {'x-api-offline': '1'});
    } on SocketException {
      return base.Response('{"error":"offline"}', 599,
          headers: const {'x-api-offline': '1'});
    } on base.ClientException {
      return base.Response('{"error":"offline"}', 599,
          headers: const {'x-api-offline': '1'});
    }
    final authorization =
        headers?['authorization'] ?? headers?['Authorization'];
    final requestToken = authorization?.startsWith('Bearer ') == true
        ? authorization!.substring(7)
        : null;
    // Login nao possui Bearer e nunca pode expulsar o usuario para a escolha
    // de perfil. Uma resposta atrasada so encerra a sessao se ainda pertence
    // exatamente ao token que continua ativo.
    if (response.statusCode == 401 &&
        requestToken != null &&
        requestToken == currentToken?.call() &&
        !_handlingUnauthorized) {
      _handlingUnauthorized = true;
      try {
        await onUnauthorized?.call();
      } finally {
        _handlingUnauthorized = false;
      }
    }
    return response;
  }

  static Future<base.Response> get(Uri url, {Map<String, String>? headers}) =>
      _run(base.get(url, headers: headers), headers);

  static Future<base.Response> post(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      _run(base.post(url, headers: headers, body: body, encoding: encoding),
          headers);

  static Future<base.Response> put(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      _run(base.put(url, headers: headers, body: body, encoding: encoding),
          headers);

  static Future<base.Response> delete(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      _run(base.delete(url, headers: headers, body: body, encoding: encoding),
          headers);
}

// Mantem a mesma superficie usada por package:http para a migracao ser segura.
Future<base.Response> get(Uri url, {Map<String, String>? headers}) =>
    ApiHttp.get(url, headers: headers);
Future<base.Response> post(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    ApiHttp.post(url, headers: headers, body: body, encoding: encoding);
Future<base.Response> put(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    ApiHttp.put(url, headers: headers, body: body, encoding: encoding);
Future<base.Response> delete(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    ApiHttp.delete(url, headers: headers, body: body, encoding: encoding);
