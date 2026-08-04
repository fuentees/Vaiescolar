import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config.dart';

class UpdateService {
  static Future<void> check(BuildContext context,
      {bool showUpToDate = false}) async {
    try {
      final uri =
          Uri.parse('${Config.apiBase}/app-version/responsavel').replace(
        queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch}'},
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
            'Disponível: ${latest['version']}\n\n${latest['notes']}',
          ),
          actions: [
            if (latest['mandatory'] != true)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Depois'),
              ),
            FilledButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(latest['url'] as String),
                mode: LaunchMode.externalApplication,
              ),
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
