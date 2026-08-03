import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';

String _timeAgo(String iso) {
  final d = DateTime.parse(iso).toLocal();
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'agora';
  if (diff.inMinutes < 60) return 'ha ${diff.inMinutes}min';
  if (diff.inHours < 24) return 'ha ${diff.inHours}h';
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

IconData _iconFor(String type) {
  switch (type) {
    case 'approaching':
      return Icons.notifications_active_outlined;
    case 'trip_event':
      return Icons.directions_bus_outlined;
    case 'chat':
      return Icons.chat_bubble_outline;
    case 'absence':
      return Icons.event_busy_outlined;
    default:
      return Icons.notifications_outlined;
  }
}

/// Central de notificacoes: uniao de eventos recentes (embarque/desembarque
/// dos filhos, mensagens de chat) num feed so, sem depender de ter visto a
/// notificacao push na hora.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<dynamic> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await Api.notifications();
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notificacoes')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('Nenhuma notificacao recente.',
                            textAlign: TextAlign.center),
                      ),
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _items.length,
                      separatorBuilder: (context, i) =>
                          const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final n = _items[i] as Map<String, dynamic>;
                        final type = n['type'] as String;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                AppColors.primary.withValues(alpha: 0.12),
                            foregroundColor: AppColors.primary,
                            child: Icon(_iconFor(type), size: 20),
                          ),
                          title: Text(n['message'] as String),
                          trailing: Text(
                            _timeAgo(n['created_at'] as String),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
