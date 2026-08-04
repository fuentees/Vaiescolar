import 'dart:async';

import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/chat_socket.dart';
import '../theme.dart';

enum _MsgStatus { sent, sending, failed }

class _Msg {
  final String senderUserId;
  final String body;
  final DateTime at;
  _MsgStatus status;
  final bool isRead;
  _Msg(this.senderUserId, this.body, this.at,
      {this.status = _MsgStatus.sent, this.isRead = false});
}

/// Conversa do pai com o motorista/admin do tenant. Carrega o historico via
/// HTTP e escuta novas mensagens ao vivo via WebSocket.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final List<_Msg> _messages = [];
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  ChatSocket _socket = ChatSocket();
  bool _loading = true;
  bool _sending = false;
  Timer? _receiptTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _connectSocket();
    _receiptTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _load(silent: true));
  }

  void _connectSocket() {
    _socket.connect(token: Api.token!, parentUserId: Api.userId!);
    _socket.messages.listen((m) {
      setState(() => _messages.add(_Msg(m.senderUserId, m.body, m.at)));
      _scrollToBottom();
    });
  }

  // O WebSocket nao sobrevive ao app ir para segundo plano (o SO derruba a
  // conexao). Ao voltar ao 1o plano, reconecta e rebusca o historico.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _socket.dispose();
      _socket = ChatSocket();
      _connectSocket();
      _load();
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final history = await Api.chatMessages();
    setState(() {
      _messages
        ..clear()
        ..addAll(history.map((m) => _Msg(
              m['sender_user_id'] as String,
              m['body'] as String,
              DateTime.parse(m['created_at'] as String).toLocal(),
              isRead: m['is_read'] == true,
            )));
      if (!silent) _loading = false;
    });
    _scrollToBottom(jump: true);
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final target = _scrollCtrl.position.maxScrollExtent;
      if (jump) {
        _scrollCtrl.jumpTo(target);
      } else {
        _scrollCtrl.animateTo(target,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _inputCtrl.clear();
    final msg =
        _Msg(Api.userId!, text, DateTime.now(), status: _MsgStatus.sending);
    setState(() => _messages.add(msg));
    _scrollToBottom();
    final ok = await Api.sendChatMessage(text);
    setState(() {
      msg.status = ok ? _MsgStatus.sent : _MsgStatus.failed;
      _sending = false;
    });
  }

  Future<void> _retry(_Msg msg) async {
    setState(() => msg.status = _MsgStatus.sending);
    final ok = await Api.sendChatMessage(msg.body);
    setState(() => msg.status = ok ? _MsgStatus.sent : _MsgStatus.failed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _socket.dispose();
    _receiptTimer?.cancel();
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    if (that == today) return 'Hoje';
    if (that == today.subtract(const Duration(days: 1))) return 'Ontem';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Falar com o motorista')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              'Este chat nao e um canal de emergencia. Em caso de urgencia, ligue direto pro motorista.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child:
                              Text('Nenhuma mensagem ainda. Mande um "oi" 👋'),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(12),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) {
                          final m = _messages[i];
                          final mine = m.senderUserId == Api.userId;
                          final hh = m.at.hour.toString().padLeft(2, '0');
                          final mm = m.at.minute.toString().padLeft(2, '0');
                          final showDaySeparator =
                              i == 0 || !_isSameDay(_messages[i - 1].at, m.at);

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (showDaySeparator)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Center(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(_dayLabel(m.at),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall),
                                    ),
                                  ),
                                ),
                              Align(
                                alignment: mine
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: GestureDetector(
                                  onTap: m.status == _MsgStatus.failed
                                      ? () => _retry(m)
                                      : null,
                                  child: Container(
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 10),
                                    constraints: BoxConstraints(
                                        maxWidth:
                                            MediaQuery.of(context).size.width *
                                                0.75),
                                    decoration: BoxDecoration(
                                      color: m.status == _MsgStatus.failed
                                          ? AppColors.error
                                              .withValues(alpha: 0.15)
                                          : mine
                                              ? AppColors.primary
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .surface,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          m.body,
                                          style: TextStyle(
                                              color: mine &&
                                                      m.status !=
                                                          _MsgStatus.failed
                                                  ? Colors.white
                                                  : null),
                                        ),
                                        const SizedBox(height: 2),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              '$hh:$mm',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: mine &&
                                                        m.status !=
                                                            _MsgStatus.failed
                                                    ? Colors.white70
                                                    : Colors.grey,
                                              ),
                                            ),
                                            if (mine) ...[
                                              const SizedBox(width: 4),
                                              if (m.status ==
                                                  _MsgStatus.sending)
                                                const SizedBox(
                                                  width: 10,
                                                  height: 10,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 1.5,
                                                          color:
                                                              Colors.white70),
                                                )
                                              else if (m.status ==
                                                  _MsgStatus.failed)
                                                const Icon(Icons.error_outline,
                                                    size: 13,
                                                    color: AppColors.error)
                                              else
                                                Icon(Icons.done_all,
                                                    size: 13,
                                                    color: m.isRead
                                                        ? Colors.lightBlueAccent
                                                        : Colors.white70),
                                            ],
                                          ],
                                        ),
                                        if (m.status == _MsgStatus.failed)
                                          const Text(
                                            'Falhou -- toque para tentar de novo',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: AppColors.error),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      decoration: const InputDecoration(
                          hintText: 'Escreva uma mensagem...'),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
