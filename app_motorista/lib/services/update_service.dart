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
      final response = await http
          .get(Uri.parse('${Config.apiBase}/app-version/motorista'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 || !context.mounted) return;
      final latest = jsonDecode(response.body) as Map<String, dynamic>;
      final current = await PackageInfo.fromPlatform();
      if (!context.mounted) return;
      final hasUpdate = int.parse(current.buildNumber) <
          (latest['buildNumber'] as num).toInt();
      if (!hasUpdate) {
        if (showUpToDate) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Você já está na versão mais recente.')));
        }
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: latest['mandatory'] != true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Nova versão disponível'),
          content: Text('Versão ${latest['version']}\n\n${latest['notes']}'),
          actions: [
            if (latest['mandatory'] != true)
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Depois')),
            FilledButton.icon(
              onPressed: () => launchUrl(Uri.parse(latest['url'] as String),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.system_update),
              label: const Text('Atualizar agora'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (showUpToDate && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Não foi possível verificar agora.')));
      }
    }
  }
}
