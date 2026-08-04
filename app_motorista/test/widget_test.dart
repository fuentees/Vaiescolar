import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_motorista/main.dart';

void main() {
  testWidgets('App inicia na escolha de perfil quando nao ha sessao',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VaiEscolarApp());
    expect(find.text('VaiEscolar'), findsOneWidget);
    expect(find.text('Motorista ou transportador'), findsOneWidget);
    expect(find.text('Aluno ou responsável'), findsOneWidget);
    await tester.tap(find.text('Aluno ou responsável'));
    await tester.pumpAndSettle();
    expect(find.text('Acompanhe cada caminho'), findsOneWidget);
    expect(find.text('Vincular com codigo da escola'), findsOneWidget);
  });
}
