import 'package:flutter_test/flutter_test.dart';

import 'package:app_motorista/main.dart';

void main() {
  testWidgets('App inicia na tela de login quando nao ha token salvo', (WidgetTester tester) async {
    await tester.pumpWidget(const MotoristaApp());
    expect(find.text('VaiEscolar'), findsOneWidget);
    expect(find.text('Central do motorista'), findsOneWidget);
    expect(find.text('Entrar'), findsOneWidget);
  });
}
