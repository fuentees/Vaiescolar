import 'package:flutter_test/flutter_test.dart';

import 'package:app_pais/main.dart';

void main() {
  testWidgets('App inicia na tela de login quando nao ha token salvo', (WidgetTester tester) async {
    await tester.pumpWidget(const PaisApp());
    expect(find.text('VaiEscolar'), findsOneWidget);
    expect(find.text('Acompanhe cada caminho'), findsOneWidget);
    expect(find.text('Entrar'), findsOneWidget);
  });
}
