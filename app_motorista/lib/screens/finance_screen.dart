import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api.dart';
import '../theme.dart';
import '../utils/money.dart';

const _monthNames = [
  'Janeiro',
  'Fevereiro',
  'Marco',
  'Abril',
  'Maio',
  'Junho',
  'Julho',
  'Agosto',
  'Setembro',
  'Outubro',
  'Novembro',
  'Dezembro',
];

const _paymentMethods = ['Dinheiro', 'Pix', 'Cartao', 'Outro'];

/// "Financeiro": controle manual de mensalidade. O admin gera as cobrancas do
/// mes (com base na mensalidade de cada aluno) e marca pago/pendente. Nao ha
/// gateway de pagamento -- e so um ledger pra saber quem deve.
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});
  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);
  List<dynamic> _payments = [];
  Map<String, dynamic> _summary = {};
  bool _loading = true;
  bool _generating = false;
  String _statusFilter = 'all'; // all, paid, pending
  final _searchCtrl = TextEditingController();
  String _query = '';

  String get _monthParam =>
      '${_month.year}-${_month.month.toString().padLeft(2, '0')}';
  String get _monthLabel =>
      '${_monthNames[_month.month - 1]} de ${_month.year}';

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final payments = await Api.paymentsForMonth(_monthParam);
    final summary = await Api.paymentsSummary(_monthParam);
    setState(() {
      _payments = payments;
      _summary = summary;
      _loading = false;
    });
  }

  void _changeMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta, 1));
    _load();
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    final result = await Api.generatePayments(_monthParam);
    setState(() => _generating = false);
    if (!mounted) return;
    final created = result['created'] ?? 0;
    final skipped = (result['skipped'] as List?) ?? [];
    final msg = skipped.isEmpty
        ? 'Geradas $created cobrancas para $_monthLabel.'
        : 'Geradas $created cobrancas. Sem mensalidade definida: ${skipped.join(', ')}.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    _load();
  }

  Future<void> _markAsPaid(Map<String, dynamic> payment) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _MarkPaidDialog(payment: payment, monthLabel: _monthLabel),
    );
    if (saved == true) _load();
  }

  Future<void> _reverse(Map<String, dynamic> payment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Estornar pagamento?'),
        content: Text(
            '${payment['student_name']} volta a aparecer como pendente em $_monthLabel.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Estornar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok =
        await Api.updatePayment(payment['id'] as String, status: 'pending');
    if (!mounted) return;
    if (ok) {
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Nao foi possivel estornar. Tente novamente.')),
      );
    }
  }

  Future<void> _exportCsv() async {
    final buffer =
        StringBuffer('Aluno,Valor,Status,Forma de pagamento,Observacoes\n');
    for (final p in _filteredPayments) {
      final name = (p['student_name'] as String).replaceAll(',', ' ');
      final amount = p['amount'];
      final status = p['status'] == 'paid' ? 'Pago' : 'Pendente';
      final method =
          (p['payment_method'] as String? ?? '').replaceAll(',', ' ');
      final notes = (p['notes'] as String? ?? '')
          .replaceAll(',', ' ')
          .replaceAll('\n', ' ');
      buffer.writeln('$name,$amount,$status,$method,$notes');
    }
    await Share.share(buffer.toString(), subject: 'Financeiro - $_monthLabel');
  }

  bool get _isOverdue {
    final now = DateTime.now();
    return _month.isBefore(DateTime(now.year, now.month, 1));
  }

  List<dynamic> get _filteredPayments {
    return _payments.where((p) {
      if (_statusFilter == 'paid' && p['status'] != 'paid') return false;
      if (_statusFilter == 'pending' && p['status'] != 'pending') return false;
      if (_query.isNotEmpty &&
          !(p['student_name'] as String)
              .toLowerCase()
              .contains(_query.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredPayments;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Financeiro'),
        actions: [
          IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Exportar CSV',
              onPressed: _exportCsv),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _generating ? null : _generate,
        icon: const Icon(Icons.receipt_long),
        label: Text(_generating ? 'Gerando...' : 'Gerar cobrancas do mes'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                          icon: const Icon(Icons.chevron_left),
                          onPressed: () => _changeMonth(-1)),
                      Text(_monthLabel,
                          style: Theme.of(context).textTheme.titleMedium),
                      IconButton(
                          icon: const Icon(Icons.chevron_right),
                          onPressed: () => _changeMonth(1)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _SummaryStat(
                                  label: 'Pago',
                                  value: '${_summary['paid'] ?? 0}',
                                  color: AppColors.success),
                              _SummaryStat(
                                  label: 'Pendente',
                                  value: '${_summary['pending'] ?? 0}',
                                  color: AppColors.accent),
                              _SummaryStat(
                                  label: 'Total',
                                  value: '${_summary['total'] ?? 0}',
                                  color: AppColors.primary),
                            ],
                          ),
                          const Divider(height: 24),
                          Text(
                            'Recebido: ${formatMoney(_summary['paid_amount'] ?? 0)} de ${formatMoney(_summary['total_amount'] ?? 0)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          if (_isOverdue && (_summary['pending'] ?? 0) > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${_summary['pending']} cobranca(s) em atraso',
                              style: const TextStyle(
                                  color: AppColors.error,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                        hintText: 'Buscar aluno...',
                        prefixIcon: Icon(Icons.search)),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                          label: const Text('Todos'),
                          selected: _statusFilter == 'all',
                          onSelected: (_) =>
                              setState(() => _statusFilter = 'all')),
                      ChoiceChip(
                          label: const Text('Pagos'),
                          selected: _statusFilter == 'paid',
                          onSelected: (_) =>
                              setState(() => _statusFilter = 'paid')),
                      ChoiceChip(
                          label: const Text('Pendentes'),
                          selected: _statusFilter == 'pending',
                          onSelected: (_) =>
                              setState(() => _statusFilter = 'pending')),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          _payments.isEmpty
                              ? 'Nenhuma cobranca neste mes ainda. Toque em "Gerar cobrancas do mes".'
                              : 'Nenhum resultado para esse filtro.',
                        ),
                      ),
                    )
                  else
                    ...filtered.map((p) {
                      final paid = p['status'] == 'paid';
                      final overdue = !paid && _isOverdue;
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          title: Text(p['student_name'] as String),
                          subtitle: Text(
                            [
                              formatMoney(p['amount']),
                              if (paid && p['payment_method'] != null)
                                p['payment_method'] as String,
                              if (overdue) 'Em atraso',
                            ].join(' · '),
                            style: overdue
                                ? const TextStyle(color: AppColors.error)
                                : null,
                          ),
                          trailing: PopupMenuButton<String>(
                            child: Chip(
                              label: Text(paid ? 'Pago' : 'Pendente'),
                              backgroundColor:
                                  (paid ? AppColors.success : AppColors.accent)
                                      .withValues(alpha: 0.15),
                              labelStyle: TextStyle(
                                  color: paid
                                      ? AppColors.success
                                      : AppColors.accent),
                            ),
                            onSelected: (v) {
                              if (v == 'pay') {
                                _markAsPaid(p as Map<String, dynamic>);
                              }
                              if (v == 'reverse') {
                                _reverse(p as Map<String, dynamic>);
                              }
                            },
                            itemBuilder: (context) => [
                              if (!paid)
                                const PopupMenuItem(
                                    value: 'pay',
                                    child: Text('Marcar como pago')),
                              if (paid)
                                const PopupMenuItem(
                                    value: 'reverse', child: Text('Estornar')),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SummaryStat(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _MarkPaidDialog extends StatefulWidget {
  final Map<String, dynamic> payment;
  final String monthLabel;
  const _MarkPaidDialog({required this.payment, required this.monthLabel});

  @override
  State<_MarkPaidDialog> createState() => _MarkPaidDialogState();
}

class _MarkPaidDialogState extends State<_MarkPaidDialog> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _notesCtrl;
  String _method = _paymentMethods.first;
  DateTime _paidAt = DateTime.now();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(text: '${widget.payment['amount']}');
    _notesCtrl =
        TextEditingController(text: widget.payment['notes'] as String? ?? '');
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final chosen = await showDatePicker(
      context: context,
      initialDate: _paidAt,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'Data efetiva do pagamento',
    );
    if (chosen != null) setState(() => _paidAt = chosen);
  }

  Future<void> _save() async {
    final amount =
        double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.'));
    if (amount == null || amount < 0) {
      setState(() => _error = 'Valor invalido');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final dateStr =
        '${_paidAt.year.toString().padLeft(4, '0')}-${_paidAt.month.toString().padLeft(2, '0')}-${_paidAt.day.toString().padLeft(2, '0')}';
    final ok = await Api.updatePayment(
      widget.payment['id'] as String,
      status: 'paid',
      amount: amount,
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      paymentMethod: _method,
      paidAt: dateStr,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = 'Nao foi possivel salvar. Tente novamente.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Marcar como pago'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.payment['student_name']} · ${widget.monthLabel}',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Valor', prefixText: 'R\$ '),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Data efetiva'),
                child: Text(
                    '${_paidAt.day.toString().padLeft(2, '0')}/${_paidAt.month.toString().padLeft(2, '0')}/${_paidAt.year}'),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _method,
              decoration:
                  const InputDecoration(labelText: 'Forma de pagamento'),
              items: _paymentMethods
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _method = v ?? _paymentMethods.first),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notesCtrl,
              decoration:
                  const InputDecoration(labelText: 'Observacao (opcional)'),
              maxLines: 2,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AppColors.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Confirmar'),
        ),
      ],
    );
  }
}
