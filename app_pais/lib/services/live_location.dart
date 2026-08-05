import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../config.dart';

class LivePosition {
  final double lat;
  final double lng;
  final double? heading;
  LivePosition(this.lat, this.lng, [this.heading]);
}

/// Evento de embarque/desembarque retransmitido pelo backend (trip_events).
class TripEvent {
  final String studentId;
  final String type; // 'boarded' ou 'dropped'
  final DateTime at;
  TripEvent(this.studentId, this.type, this.at);
}

class ApproachingAlert {
  final String studentName;
  final DateTime at;
  ApproachingAlert(this.studentName, this.at);
}

/// Conecta ao WebSocket do backend e emite posicoes e eventos recebidos.
class LiveLocation {
  WebSocketChannel? _channel;
  final _positionController = StreamController<LivePosition>.broadcast();
  final _eventController = StreamController<TripEvent>.broadcast();
  final _finishedController = StreamController<void>.broadcast();
  final _approachingController = StreamController<ApproachingAlert>.broadcast();

  /// Estado da conexao WS -- consumido pela tela do mapa pra mostrar um
  /// indicador online/offline (o WS pode cair sem o app perceber de outra
  /// forma, ja que os pings de GPS sao esporadicos).
  final ValueNotifier<bool> connected = ValueNotifier(false);

  Stream<LivePosition> get stream => _positionController.stream;
  Stream<TripEvent> get events => _eventController.stream;
  Stream<void> get finished => _finishedController.stream;
  Stream<ApproachingAlert> get approaching => _approachingController.stream;

  void connect({required String token, required String tripId}) {
    final uri = Uri.parse('${Config.wsBase}/ws?tripId=$tripId');
    _channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    _channel!.ready.then((_) {
      connected.value = true;
    }).catchError((_) {
      connected.value = false;
    });
    _channel!.stream.listen((raw) {
      final msg = jsonDecode(raw as String);
      if (msg['type'] == 'location') {
        _positionController.add(LivePosition(
          (msg['lat'] as num).toDouble(),
          (msg['lng'] as num).toDouble(),
          (msg['heading'] as num?)?.toDouble(),
        ));
      } else if (msg['type'] == 'event') {
        final e = msg['event'];
        _eventController.add(TripEvent(
          e['student_id'] as String,
          e['type'] as String,
          DateTime.parse(e['at'] as String).toLocal(),
        ));
      } else if (msg['type'] == 'approaching') {
        _approachingController.add(ApproachingAlert(
          msg['studentName'] as String,
          DateTime.parse(msg['createdAt'] as String).toLocal(),
        ));
      } else if (msg['type'] == 'emergency_return') {
        _eventController.add(TripEvent(
          msg['studentId'] as String,
          'emergency_return',
          DateTime.parse(msg['createdAt'] as String).toLocal(),
        ));
      } else if (msg['type'] == 'trip_finished' ||
          msg['type'] == 'trip_cancelled') {
        _finishedController.add(null);
      }
    }, onError: (_) {
      connected.value = false;
    }, onDone: () {
      connected.value = false;
    });
  }

  void dispose() {
    _channel?.sink.close();
    _positionController.close();
    _eventController.close();
    _finishedController.close();
    _approachingController.close();
    connected.dispose();
  }
}
