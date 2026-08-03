import 'package:flutter/material.dart';

class _Faq {
  final String question;
  final String answer;
  const _Faq(this.question, this.answer);
}

const _faqs = [
  _Faq(
    'Como inicio uma rota?',
    'Na aba "Rota", escolha a rota, a direcao (ida/volta) e o veiculo, e '
        'toque em "Iniciar rota". Se o app foi fechado com uma rota em '
        'aberto, ele oferece continuar ou finalizar assim que reabrir.',
  ),
  _Faq(
    'O app perdeu conexao no meio da rota, os dados se perdem?',
    'Nao. Os pontos de GPS ficam numa fila local ate a conexao voltar -- '
        'nada e perdido, so chega atrasado pros pais acompanharem.',
  ),
  _Faq(
    'Como cadastro um novo aluno ou responsavel?',
    'Em "Gestao > Alunos" (so admin). Depois de cadastrar, gere o codigo de '
        'convite do aluno para o responsavel se auto-cadastrar no app dele.',
  ),
  _Faq(
    'Esqueci minha senha, e agora?',
    'Peca pra outro administrador do tenant resetar sua senha em '
        '"Gestao > Equipe e responsaveis". Se voce e o unico admin, ainda '
        'nao ha recuperacao automatica via e-mail/SMS.',
  ),
  _Faq(
    'O responsavel marcou falta do filho, onde eu vejo?',
    'Na tela da rota, o aluno aparece com um chip laranja "Ausente" -- e '
        'tambem em "Alertas do dia" na aba Inicio.',
  ),
  _Faq(
    'Como funciona o financeiro?',
    'E um controle manual (sem gateway de pagamento). Em "Gestao > '
        'Financeiro", gere as cobrancas do mes e marque pago/pendente '
        'conforme recebe.',
  ),
];

/// FAQ estatico -- sem CMS, texto direto no Dart (produto pequeno, nao
/// justifica infraestrutura de conteudo separada ainda).
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
