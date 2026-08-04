import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api.dart';
import '../theme.dart';

/// Tela de gestao: lista os veiculos do tenant, cadastra, edita e exclui.
class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({super.key});
  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  List<dynamic> _vehicles = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final vehicles = await Api.vehicles();
    setState(() {
      _vehicles = vehicles;
      _loading = false;
    });
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _VehicleFormDialog(existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _confirmDelete(Map<String, dynamic> vehicle) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir veiculo?'),
        content: Text(
            'Isso remove ${vehicle['plate']} da frota. Rotas que usam esse veiculo ficam sem veiculo padrao.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await Api.deleteVehicle(vehicle['id'] as String);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _vehicles.where((v) => '${v['plate']} ${v['model'] ?? ''}'
        .toLowerCase().contains(_query.trim().toLowerCase())).toList()
      ..sort((a, b) => (a['plate'] as String).compareTo(b['plate'] as String));
    return Scaffold(
      appBar: AppBar(title: const Text('Veículos'), bottom: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: TextField(
          onChanged: (value) => setState(() => _query = value),
          decoration: const InputDecoration(hintText: 'Buscar placa ou modelo...', prefixIcon: Icon(Icons.search), isDense: true),
        )),
      )),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: visible.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                              'Nenhum veiculo cadastrado ainda. Toque em + pra adicionar.'),
                        ),
                      ),
                    ])
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final v = visible[i] as Map<String, dynamic>;
                        final model = v['model'] as String?;
                        final capacity = v['capacity'];
                        final year = v['year'];
                        final status = v['status'] as String? ?? 'available';
                        final docExpiry = v['document_expiry'] as String?;
                        final docSoon = docExpiry != null &&
                            DateTime.parse(docExpiry).isBefore(
                                DateTime.now().add(const Duration(days: 30)));
                        final parts = <String>[
                          if (model?.isNotEmpty == true) model!,
                          if (year != null) '$year',
                          if (capacity != null) '$capacity lugares',
                        ];
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: status == 'maintenance'
                                  ? AppColors.error
                                  : AppColors.accent,
                              foregroundColor: Colors.white,
                              child: const Icon(Icons.local_shipping, size: 20),
                            ),
                            title: Text(v['plate'] as String),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(parts.isEmpty
                                    ? 'Sem detalhes cadastrados'
                                    : parts.join(' · ')),
                                if (status == 'maintenance')
                                  const Text('Em manutencao',
                                      style: TextStyle(
                                          color: AppColors.error,
                                          fontSize: 12)),
                                if (docSoon)
                                  const Text('Documento vencendo/vencido',
                                      style: TextStyle(
                                          color: AppColors.accent,
                                          fontSize: 12)),
                              ],
                            ),
                            isThreeLine: status == 'maintenance' || docSoon,
                            trailing: PopupMenuButton<String>(
                              onSelected: (val) {
                                if (val == 'edit') _openForm(existing: v);
                                if (val == 'delete') _confirmDelete(v);
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                    value: 'edit', child: Text('Editar')),
                                PopupMenuItem(
                                    value: 'delete', child: Text('Excluir')),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

class _VehicleFormDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _VehicleFormDialog({this.existing});

  @override
  State<_VehicleFormDialog> createState() => _VehicleFormDialogState();
}

class _VehicleFormDialogState extends State<_VehicleFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _plateCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _capacityCtrl;
  late final TextEditingController _yearCtrl;
  late final TextEditingController _colorCtrl;
  String _status = 'available';
  DateTime? _documentExpiry;
  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _plateCtrl = TextEditingController(text: e?['plate'] as String? ?? '');
    _modelCtrl = TextEditingController(text: e?['model'] as String? ?? '');
    _capacityCtrl =
        TextEditingController(text: e?['capacity']?.toString() ?? '');
    _yearCtrl = TextEditingController(text: e?['year']?.toString() ?? '');
    _colorCtrl = TextEditingController(text: e?['color'] as String? ?? '');
    _status = e?['status'] as String? ?? 'available';
    final docRaw = e?['document_expiry'] as String?;
    if (docRaw != null) _documentExpiry = DateTime.tryParse(docRaw);
  }

  @override
  void dispose() {
    _plateCtrl.dispose();
    _modelCtrl.dispose();
    _capacityCtrl.dispose();
    _yearCtrl.dispose();
    _colorCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDocumentExpiry() async {
    final chosen = await showDatePicker(
      context: context,
      initialDate: _documentExpiry ?? DateTime.now(),
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
      helpText: 'Validade do documento',
    );
    if (chosen != null) setState(() => _documentExpiry = chosen);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final docStr = _documentExpiry != null
        ? '${_documentExpiry!.year.toString().padLeft(4, '0')}-${_documentExpiry!.month.toString().padLeft(2, '0')}-${_documentExpiry!.day.toString().padLeft(2, '0')}'
        : null;
    final bool ok;
    if (_isEditing) {
      ok = await Api.updateVehicle(
        widget.existing!['id'] as String,
        plate: _plateCtrl.text.trim(),
        model: _modelCtrl.text.trim().isEmpty ? null : _modelCtrl.text.trim(),
        capacity: int.tryParse(_capacityCtrl.text.trim()),
        year: int.tryParse(_yearCtrl.text.trim()),
        color: _colorCtrl.text.trim().isEmpty ? null : _colorCtrl.text.trim(),
        documentExpiry: docStr,
        status: _status,
      );
    } else {
      ok = await Api.createVehicle(
        plate: _plateCtrl.text.trim(),
        model: _modelCtrl.text.trim().isEmpty ? null : _modelCtrl.text.trim(),
        capacity: int.tryParse(_capacityCtrl.text.trim()),
        year: int.tryParse(_yearCtrl.text.trim()),
        color: _colorCtrl.text.trim().isEmpty ? null : _colorCtrl.text.trim(),
        documentExpiry: docStr,
        status: _status,
      );
    }
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
      title: Text(_isEditing ? 'Editar veiculo' : 'Novo veiculo'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _plateCtrl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                  LengthLimitingTextInputFormatter(7),
                  TextInputFormatter.withFunction((oldValue, newValue) =>
                      newValue.copyWith(text: newValue.text.toUpperCase())),
                ],
                decoration: const InputDecoration(
                    labelText: 'Placa *', hintText: 'ABC1D23'),
                validator: (v) => RegExp(r'^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$')
                        .hasMatch((v ?? '').trim().toUpperCase())
                    ? null
                    : 'Informe uma placa brasileira valida',
                autovalidateMode: AutovalidateMode.onUserInteraction,
              ),
              const SizedBox(height: 8),
              TextFormField(
                  controller: _modelCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Modelo (opcional)')),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    controller: _yearCtrl,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Ano (opcional)'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                      controller: _colorCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Cor (opcional)')),
                ),
              ]),
              const SizedBox(height: 8),
              TextFormField(
                controller: _capacityCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Capacidade de alunos *'),
                validator: (v) {
                  final capacity = int.tryParse((v ?? '').trim());
                  return capacity == null || capacity <= 0
                      ? 'Informe a capacidade'
                      : null;
                },
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: _pickDocumentExpiry,
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: 'Validade do documento (opcional)'),
                  child: Text(
                    _documentExpiry == null
                        ? '--'
                        : '${_documentExpiry!.day.toString().padLeft(2, '0')}/${_documentExpiry!.month.toString().padLeft(2, '0')}/${_documentExpiry!.year}',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(
                      value: 'available', child: Text('Disponivel')),
                  DropdownMenuItem(
                      value: 'maintenance', child: Text('Em manutencao')),
                ],
                onChanged: (v) => setState(() => _status = v ?? 'available'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: AppColors.error)),
              ],
            ],
          ),
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
              : const Text('Salvar'),
        ),
      ],
    );
  }
}
