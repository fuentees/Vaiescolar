import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../config.dart';

class UpdateService {
  static DateTime? _lastAutomaticCheck;

  static Future<void> check(BuildContext context,
      {bool showUpToDate = false}) async {
    final now = DateTime.now();
    if (!showUpToDate &&
        _lastAutomaticCheck != null &&
        now.difference(_lastAutomaticCheck!) < const Duration(minutes: 5)) {
      return;
    }
    if (!showUpToDate) _lastAutomaticCheck = now;
    try {
      final uri =
          Uri.parse('${Config.apiBase}/app-version/responsavel').replace(
        queryParameters: {'t': '${now.millisecondsSinceEpoch}'},
      );
      final response = await http.get(uri, headers: const {
        'cache-control': 'no-cache'
      }).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 || !context.mounted) return;
      final latest = jsonDecode(response.body) as Map<String, dynamic>;
      final current = await PackageInfo.fromPlatform();
      if (!context.mounted) return;
      final rawCurrentBuild = int.tryParse(current.buildNumber) ?? 0;
      final currentBuild =
          rawCurrentBuild >= 1000 ? rawCurrentBuild % 1000 : rawCurrentBuild;
      final latestBuild =
          (latest['releaseBuild'] as num? ?? latest['buildNumber'] as num)
              .toInt();
      if (currentBuild >= latestBuild) {
        if (showUpToDate) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Você já está na versão mais recente (${current.version}).'),
          ));
        }
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: latest['mandatory'] != true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Nova versão disponível'),
          content: Text(
            'Instalada: ${current.version}\n'
            'Disponível: ${latest['version']}\n\n${latest['notes']}\n\n'
            'A atualização será baixada com progresso dentro do aplicativo.',
          ),
          actions: [
            if (latest['mandatory'] != true)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Depois'),
              ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext);
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => _DownloadDialog(
                    url: latest['url'] as String,
                  ),
                );
              },
              icon: const Icon(Icons.system_update),
              label: const Text('Atualizar agora'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (showUpToDate && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível verificar agora.')),
        );
      }
    }
  }
}

class _DownloadDialog extends StatefulWidget {
  final String url;
  const _DownloadDialog({required this.url});

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  double? _progress;
  String? _filePath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _download();
  }

  Future<void> _download() async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(widget.url));
      request.headers['cache-control'] = 'no-cache';
      final response = await client.send(request).timeout(
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) {
        throw HttpException('Servidor respondeu ${response.statusCode}');
      }
      final total = response.contentLength ?? 0;
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/VaiEscolar-atualizacao.apk');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (mounted) {
          setState(() => _progress = total > 0 ? received / total : null);
        }
      }
      await sink.flush();
      await sink.close();
      final size = await file.length();
      if (size < 1000000 || (total > 0 && size != total)) {
        await file.delete();
        throw const FormatException('Arquivo incompleto');
      }
      if (mounted) setState(() => _filePath = file.path);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Não foi possível concluir o download. Verifique a internet e tente novamente.');
      }
    } finally {
      client.close();
    }
  }

  Future<void> _install() async {
    final result = await OpenFilex.open(_filePath!,
        type: 'application/vnd.android.package-archive');
    if (!mounted) return;
    if (result.type != ResultType.done) {
      setState(() => _error =
          'Autorize “instalar apps desconhecidos” nas configurações e tente novamente.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final percent = ((_progress ?? 0) * 100).clamp(0, 100).round();
    return AlertDialog(
      title: Text(
          _filePath != null ? 'Pronto para instalar' : 'Baixando atualização'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            const Icon(Icons.error_outline, size: 42),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
          ] else if (_filePath != null) ...[
            const Icon(Icons.download_done, size: 42),
            const SizedBox(height: 12),
            const Text(
                'Download verificado. Toque em Instalar para continuar.'),
          ] else ...[
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 12),
            Text(_progress == null ? 'Preparando…' : '$percent%'),
          ],
        ],
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: () {
              setState(() {
                _error = null;
                _progress = null;
                _filePath = null;
              });
              _download();
            },
            child: const Text('Tentar novamente'),
          ),
        if (_filePath != null)
          FilledButton(
            onPressed: _install,
            child: const Text('Instalar'),
          ),
        if (_error != null || _filePath != null)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
      ],
    );
  }
}
