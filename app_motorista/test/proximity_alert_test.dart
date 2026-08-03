import 'package:flutter_test/flutter_test.dart';
import 'package:app_motorista/services/tracking_service.dart';

void main() {
  group('janela automatica de aproximacao', () {
    test('avisa quando a proxima parada esta a cerca de cinco minutos', () {
      expect(
          isInsideApproachingWindow(
            distanceMeters: 1500,
            speedMetersPerSecond: 5,
            accuracyMeters: 12,
          ),
          isTrue);
    });

    test('nao avisa cedo demais nem com GPS impreciso', () {
      expect(
          isInsideApproachingWindow(
            distanceMeters: 2400,
            speedMetersPerSecond: 5,
            accuracyMeters: 12,
          ),
          isFalse);
      expect(
          isInsideApproachingWindow(
            distanceMeters: 500,
            speedMetersPerSecond: 5,
            accuracyMeters: 150,
          ),
          isFalse);
    });

    test('semaforo nao gera ETA infinito', () {
      expect(
          isInsideApproachingWindow(
            distanceMeters: 1200,
            speedMetersPerSecond: 0,
            accuracyMeters: 10,
          ),
          isTrue);
    });
  });
}
