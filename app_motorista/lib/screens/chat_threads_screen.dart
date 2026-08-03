import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import 'chat_screen.dart';

/// Lista uma thread por responsavel do tenant, com a ultima mensagem e um
/// badge de nao lidas — o motorista/admin escolhe com quem falar. Tem busca
/// por nome pra tenants com muitos responsaveis.
class ChatThreadsScreen extends StatefulWidget {
  const ChatThreadsScreen({super.key});
  @override
  State<ChatThreadsScreen> createState() => _ChatThreadsScreenState();
}

class _ChatThreadsScreenState extends State<ChatThreadsScreen> {
  List<dynamic> _threads = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final threads = await Api.chatThreads();
    setState(() {
      _threads = threads;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.trim().isEmpty
        ? _threads
        : _threads
            .where((t) => (t['parent_name'] as String)
                .toLowerCase()
                .contains(_query.toLowerCase()))
            .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Mensagens')),
      body: Column(
        children: [
          if (_threads.length > 5)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Buscar responsavel...',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: filtered.isEmpty
                        ? ListView(children: [
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Center(
                                child: Text(
                                  _threads.isEmpty
                                      ? 'Nenhum responsavel cadastrado ainda.'
                                      : 'Nenhum resultado.',
                                ),
                              ),
                            ),
                          ])
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final t = filtered[i];
                              final lastMessage = t['last_message'] as String?;
                              final unread =
                                  (t['unread_count'] as num?)?.toInt() ?? 0;
                              return ListTile(
                                leading: const CircleAvatar(
                                    child: Icon(Icons.person)),
                                title: Text(t['parent_name'] as String),
                                subtitle: Text(
                                  lastMessage ?? 'Nenhuma mensagem ainda',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: unread > 0
                                    ? CircleAvatar(
                                        radius: 11,
                                        backgroundColor: AppColors.accent,
                                        child: Text(
                                          '$unread',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11),
                                        ),
                                      )
                                    : null,
                                onTap: () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ChatScreen(
                                        parentUserId:
                                            t['parent_user_id'] as String,
                                        parentName: t['parent_name'] as String,
                                      ),
                                    ),
                                  );
                                  _load();
                                },
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}
