import 'package:flutter/material.dart';
import '../theme.dart';

/// Texto placeholder -- o dono do produto ainda precisa revisar/aprovar a
/// redacao final antes de publicar nas lojas. Nao remover o aviso de
/// RASCUNHO sem essa revisao.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacidade e termos')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.edit_note, color: AppColors.accent),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'RASCUNHO -- texto provisorio. Substituir por uma politica revisada '
                    'antes de publicar o app nas lojas.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('Politica de privacidade',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const _Section(
            title: 'Quais dados voce cadastra',
            body:
                'Alunos: nome, escola, endereco, data de nascimento, contato de '
                'emergencia e, quando informado, observacoes medicas relevantes para '
                'o transporte. Responsaveis e equipe: nome, e-mail, telefone e senha '
                '(armazenada com hash, nunca em texto puro).',
          ),
          const _Section(
            title: 'Localizacao',
            body:
                'A localizacao do veiculo so e coletada enquanto uma rota esta ativa '
                '-- nunca em segundo plano fora disso. Deixe isso claro para os '
                'motoristas da equipe.',
          ),
          const _Section(
            title: 'Responsabilidade sobre os dados dos alunos',
            body:
                'Como administrador do tenant, voce e responsavel por obter o '
                'consentimento dos responsaveis para o tratamento dos dados dos '
                'alunos e por manter as observacoes medicas atualizadas e restritas '
                'ao necessario.',
          ),
          const _Section(
            title: 'Retencao',
            body:
                'O historico de localizacao e mantido pelo tempo necessario para '
                'auditoria do servico (meta: 90 dias). Dados de cadastro sao '
                'mantidos enquanto o tenant estiver ativo.',
          ),
          const _Section(
            title: 'Solicitacoes de titulares (LGPD)',
            body:
                'Responsaveis podem pedir correcao ou exclusao dos dados do filho a '
                'qualquer momento -- use "Gestao > Alunos" para atender.',
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
