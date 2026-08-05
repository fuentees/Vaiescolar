import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../config.dart';

class ChatMessage {
  final String senderUserId;
  final String body;
  final DateTime at;
  ChatMessage(this.senderUserId, this.body, this.at);
}

/// Conecta ao WebSocket da thread de chat do pai logado com o motorista/admin
/// (WS /ws?chatWith=<o proprio userId>, com JWT no cabecalho Authorization)
/// e emite mensagens ao vivo.
class ChatSocket {
  WebSocketChannel? _channel;
  final _controller = StreamController<ChatMessage>.broadcast();
  final ValueNotifier<bool> connected = ValueNotifier(false);
  Timer? _retryTimer;
  String? _token;
  String? _parentUserId;
  bool _disposed = false;
  int _attempt = 0;

  Stream<ChatMessage> get messages => _controller.stream;

  void connect({required String token, required String parentUserId}) {
    _token = token;
    _parentUserId = parentUserId;
    _open();
  }

  void _open() {
    if (_disposed || _token == null || _parentUserId == null) return;
    _retryTimer?.cancel();
    _channel?.sink.close();
    final uri = Uri.parse('${Config.wsBase}/ws?chatWith=$_parentUserId');
    _channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $_token'},
    );
    _channel!.ready.then<void>((_) {
      if (_disposed) return;
      _attempt = 0;
      connected.value = true;
    }, onError: (Object _, StackTrace __) {
      _disconnected();
    });
    _channel!.stream.listen((raw) {
      final msg = jsonDecode(raw as String);
      if (msg['type'] == 'message') {
        final m = msg['message'];
        _controller.add(ChatMessage(
          m['sender_user_id'] as String,
          m['body'] as String,
          DateTime.parse(m['created_at'] as String).toLocal(),
        ));
      }
    }, onError: (_) => _disconnected(), onDone: _disconnected);
  }

  void _disconnected() {
    if (_disposed) return;
    connected.value = false;
    if (_retryTimer?.isActive == true) return;
    final seconds = [2, 4, 8, 15, 30][_attempt.clamp(0, 4)];
    _attempt++;
    _retryTimer = Timer(Duration(seconds: seconds), _open);
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _channel?.sink.close();
    _controller.close();
    connected.dispose();
  }
}
