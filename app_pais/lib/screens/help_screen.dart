import 'package:flutter/material.dart';

class _Faq {
  final String question;
  final String answer;
  const _Faq(this.question, this.answer);
}

const _faqs = [
  _Faq(
    'Como acompanho a van no mapa?',
    'Na aba "Localizacao", assim que o motorista iniciar a rota do seu '
        'filho. Fora do horario da rota nao ha nada para mostrar -- a '
        'localizacao so e coletada com a viagem ativa.',
  ),
  _Faq(
    'Como aviso que meu filho nao vai hoje?',
    'Na aba "Inicio", toque em "Marcar falta" no card do seu filho e '
        'escolha a data. O motorista ve o aviso na lista de presenca dele.',
  ),
  _Faq(
    'Como vinculo mais de um filho?',
    'Toque em "Adicionar outro filho" no fim da lista da aba "Inicio" e '
        'use um novo codigo de convite fornecido pelo motorista.',
  ),
  _Faq(
    'Esqueci minha senha, e agora?',
    'Fale com o motorista/administrador da van -- ele pode resetar sua '
        'senha pelo painel dele. O app ainda nao envia e-mail/SMS de '
        'recuperacao automatica.',
  ),
  _Faq(
    'Como falo com o motorista?',
    'Pela aba "Mensagens". O chat nao e um canal de emergencia -- em caso '
        'de urgencia, ligue diretamente.',
  ),
  _Faq(
    'Meus dados estao seguros?',
    'Sim. Veja os detalhes em "Privacidade e termos", nas Configuracoes.',
  ),
];

/// FAQ estatico -- sem CMS, texto direto no Dart mesmo (produto pequeno,
/// nao justifica infraestrutura de conteudo separada ainda).
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Central de ajuda')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final f in _faqs)
            ExpansionTile(
              title: Text(f.question,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(f.answer)],
            ),
        ],
      ),
    );
  }
}
