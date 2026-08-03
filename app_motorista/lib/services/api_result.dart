import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Resultado padronizado de uma chamada de API, para as telas distinguirem
/// "sem dados" de "sem internet", "sessao expirada" e "erro no servidor" em
/// vez de tratar tudo igual (lista/objeto vazio escondendo o motivo real).
sealed class ApiResult<T> {
  const ApiResult();
}

class ApiData<T> extends ApiResult<T> {
  final T data;
  const ApiData(this.data);
}

class ApiEmpty<T> extends ApiResult<T> {
  const ApiEmpty();
}

class ApiOffline<T> extends ApiResult<T> {
  const ApiOffline();
}

class ApiUnauthorized<T> extends ApiResult<T> {
  const ApiUnauthorized();
}

class ApiServerError<T> extends ApiResult<T> {
  final int? statusCode;
  const ApiServerError(this.statusCode);
}

/// Setado pelo main.dart (junto com navigatorKey) -- chamado toda vez que uma
/// chamada de API volta 401, pra deslogar e voltar pro login de um so lugar
/// em vez de cada tela ter que checar isso sozinha. Mesmo padrao de callback
/// ja usado por PushService.onTap, evita import circular com main.dart.
/// Executa [request] e classifica a resposta. [decode] recebe o corpo ja
/// decodificado (`Map`/`List`/`null`); [isEmpty] e opcional, pra marcar como
/// ApiEmpty quando o dado decodificado (ex.: lista) estiver vazio.
Future<ApiResult<T>> apiCall<T>(
  Future<http.Response> Function() request,
  T Function(dynamic decodedBody) decode, {
  bool Function(T)? isEmpty,
}) async {
  http.Response res;
  try {
    res = await request();
  } on SocketException {
    return const ApiOffline();
  } on TimeoutException {
    return const ApiOffline();
  } catch (_) {
    return const ApiOffline();
  }

  if (res.headers['x-api-offline'] == '1') return const ApiOffline();
  if (res.statusCode == 401) return const ApiUnauthorized();
  if (res.statusCode < 200 || res.statusCode >= 300) {
    return ApiServerError(res.statusCode);
  }

  try {
    final decodedBody = res.body.isEmpty ? null : jsonDecode(res.body);
    final data = decode(decodedBody);
    if (isEmpty != null && isEmpty(data)) return const ApiEmpty();
    return ApiData(data);
  } catch (_) {
    return const ApiServerError(null);
  }
}

/// Widget de conveniencia pra renderizar um ApiResult sem repetir o switch em
/// toda tela. [onEmpty]/[onRetry] sao opcionais -- sem eles cai num texto e
/// botao genericos.
class ApiResultView<T> extends StatelessWidget {
  final ApiResult<T> result;
  final Widget Function(BuildContext, T) onData;
  final WidgetBuilder? onEmpty;
  final VoidCallback? onRetry;

  const ApiResultView({
    super.key,
    required this.result,
    required this.onData,
    this.onEmpty,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return switch (result) {
      ApiData<T>(:final data) => onData(context, data),
      ApiEmpty<T>() => onEmpty?.call(context) ??
          const Center(child: Text('Nada por aqui ainda.')),
      ApiOffline<T>() => _ErrorState(
          icon: Icons.wifi_off,
          message: 'Sem conexao com a internet.',
          onRetry: onRetry,
        ),
      ApiUnauthorized<T>() => const SizedBox.shrink(), // ja navegou pro login
      ApiServerError<T>() => _ErrorState(
          icon: Icons.error_outline,
          message: 'Erro no servidor. Tente novamente.',
          onRetry: onRetry,
        ),
    };
  }
}

class _ErrorState extends StatelessWidget {
  final IconData icon;
  final String message;
  final VoidCallback? onRetry;
  const _ErrorState({required this.icon, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: onRetry, child: const Text('Tentar novamente')),
            ],
          ],
        ),
      ),
    );
  }
}
