import 'package:flutter/foundation.dart';

/// Sinal leve entre a notificação push e as telas que exibem dados ao vivo.
/// Evita esperar o próximo polling quando a rota começa ou muda de estado.
class AppRefreshSignal {
  static final ValueNotifier<int> trips = ValueNotifier<int>(0);

  static void notifyTripsChanged() => trips.value++;
}
