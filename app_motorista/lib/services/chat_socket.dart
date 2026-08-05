import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../config.dart';

class ChatMessage {
  final String senderUserId;
  final String body;
  final DateTime at;
  ChatMessage(this.senderUserId, this.body, this.at);
}

/// Conecta ao WebSocket de uma thread de chat (WS /ws?chatWith=..., com JWT
/// no cabecalho Authorization) e emite as mensagens recebidas em tempo real.
class ChatSocket {
  WebSocketChannel? _channel;
  final _controller = StreamController<ChatMessage>.broadcast();

  Stream<ChatMessage> get messages => _controller.stream;

  void connect({required String token, required String parentUserId}) {
    final uri = Uri.parse('${Config.wsBase}/ws?chatWith=$parentUserId');
    _channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
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
    }, onError: (_) {}, onDone: () {});
  }

  void dispose() {
    _channel?.sink.close();
    _controller.close();
  }
}
