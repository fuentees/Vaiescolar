import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_motorista/main.dart';

void main() {
  testWidgets('App inicia na escolha de perfil quando nao ha sessao',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VaiEscolarApp());
    expect(find.text('Verificação de Usuário'), findsOneWidget);
    expect(find.text('Sou Motorista/Transportador'), findsOneWidget);
    expect(find.text('Sou Passageiro/Responsável'), findsOneWidget);
    await tester.tap(find.text('Sou Passageiro/Responsável'));
    await tester.pumpAndSettle();
    expect(find.text('Acompanhe cada caminho'), findsOneWidget);
    expect(find.text('Criar conta com codigo de convite'), findsOneWidget);
  });
}
