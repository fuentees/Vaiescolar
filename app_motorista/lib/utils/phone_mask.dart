import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';

/// Mascara de telefone celular brasileiro `(00) 00000-0000`. Retorna uma
/// instancia NOVA a cada chamada -- o formatter guarda estado interno, entao
/// compartilhar uma unica instancia entre campos diferentes bagunçaria o
/// texto de um enquanto o outro esta sendo editado.
MaskTextInputFormatter phoneMaskFormatter() {
  return MaskTextInputFormatter(
      mask: '(##) #####-####', filter: {'#': RegExp(r'[0-9]')});
}
