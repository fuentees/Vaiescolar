import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import 'route_detail_screen.dart';

/// Tela de gestao: lista as rotas do tenant, cria e edita. Tocar numa rota
/// abre a tela de detalhe pra vincular alunos a ela.
class RoutesScreen extends StatefulWidget {
  const RoutesScreen({super.key});
  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  List<dynamic> _routes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final routes = await Api.routes();
    setState(() {
      _routes = routes;
      _loading = false;
    });
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final saved = await showDialog<bool>(
        context: context, builder: (_) => _RouteFormDialog(existing: existing));
    if (saved == true) _load();
  }

  Future<void> _confirmDelete(Map<String, dynamic> route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir rota?'),
        content: Text(
            'Isso remove "${route['name']}" e desvincula os alunos dela. Essa acao nao pode ser desfeita.'),
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
      await Api.deleteRoute(route['id'] as String);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rotas')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _routes.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                              'Nenhuma rota cadastrada ainda. Toque em + pra criar.'),
                        ),
                      ),
                    ])
                  : ListView.builder(
                      itemCount: _routes.length,
                      itemBuilder: (context, i) {
                        final r = _routes[i] as Map<String, dynamic>;
                        final active = r['active'] as bool? ?? true;
                        final plannedTime = r['planned_time'] as String?;
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  active ? AppColors.accent : Colors.grey,
                              foregroundColor: Colors.white,
                              child: const Icon(Icons.directions_bus, size: 20),
                            ),
                            title: Text(r['name'] as String),
                            subtitle: Text(
                              [
                                if (!active) 'Inativa',
                                if (plannedTime != null)
                                  'Horario: ${plannedTime.substring(0, 5)}',
                              ].join(' · '),
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'edit') _openForm(existing: r);
                                if (v == 'delete') _confirmDelete(r);
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                    value: 'edit', child: Text('Editar')),
                                PopupMenuItem(
                                    value: 'delete', child: Text('Excluir')),
                              ],
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => RouteDetailScreen(
                                    routeId: r['id'] as String,
                                    routeName: r['name'] as String),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

const _weekdayLabels = ['S', 'T', 'Q', 'Q', 'S', 'S', 'D'];

class _RouteFormDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _RouteFormDialog({this.existing});
  @override
  State<_RouteFormDialog> createState() => _RouteFormDialogState();
}

class _RouteFormDialogState extends State<_RouteFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  final Set<int> _selectedDays = {};
  TimeOfDay? _plannedTime;
  bool _active = true;
  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?['name'] as String? ?? '');
    _active = e?['active'] as bool? ?? true;
    final days = e?['days_of_week'] as String?;
    if (days != null && days.isNotEmpty) {
      _selectedDays
          .addAll(days.split(',').map((d) => int.tryParse(d)).whereType<int>());
    }
    final timeStr = e?['planned_time'] as String?;
    if (timeStr != null) {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        _plannedTime = TimeOfDay(
            hour: int.tryParse(parts[0]) ?? 7,
            minute: int.tryParse(parts[1]) ?? 0);
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final chosen = await showTimePicker(
        context: context,
        initialTime: _plannedTime ?? const TimeOfDay(hour: 7, minute: 0));
    if (chosen != null) setState(() => _plannedTime = chosen);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final daysStr = _selectedDays.isEmpty
        ? null
        : (_selectedDays.toList()..sort()).join(',');
    final timeStr = _plannedTime != null
        ? '${_plannedTime!.hour.toString().padLeft(2, '0')}:${_plannedTime!.minute.toString().padLeft(2, '0')}'
        : null;
    final bool ok;
    if (_isEditing) {
      ok = await Api.updateRoute(
        widget.existing!['id'] as String,
        _nameCtrl.text.trim(),
        vehicleId: widget.existing!['vehicle_id'] as String?,
        driverUserId: widget.existing!['driver_user_id'] as String?,
        daysOfWeek: daysStr,
        plannedTime: timeStr,
        active: _active,
      );
    } else {
      ok = await Api.createRoute(_nameCtrl.text.trim(),
          daysOfWeek: daysStr, plannedTime: timeStr, active: _active);
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
      title: Text(_isEditing ? 'Editar rota' : 'Nova rota'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                    labelText: 'Nome da rota (ex.: Rota Manha) *'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Informe o nome' : null,
                autovalidateMode: AutovalidateMode.onUserInteraction,
              ),
              const SizedBox(height: 12),
              Text('Dias da semana (opcional)',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: List.generate(7, (i) {
                  final day = i + 1;
                  final selected = _selectedDays.contains(day);
                  return FilterChip(
                    label: Text(_weekdayLabels[i]),
                    selected: selected,
                    onSelected: (v) => setState(() =>
                        v ? _selectedDays.add(day) : _selectedDays.remove(day)),
                  );
                }),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickTime,
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: 'Horario planejado (opcional)'),
                  child: Text(_plannedTime == null
                      ? '--'
                      : _plannedTime!.format(context)),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Rota ativa'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
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
