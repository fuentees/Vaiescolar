import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';

/// Mostra os alunos ja vinculados a uma rota e permite adicionar mais
/// (a partir da lista completa de alunos do tenant).
class RouteDetailScreen extends StatefulWidget {
  final String routeId;
  final String routeName;
  const RouteDetailScreen(
      {super.key, required this.routeId, required this.routeName});

  @override
  State<RouteDetailScreen> createState() => _RouteDetailScreenState();
}

class _RouteDetailScreenState extends State<RouteDetailScreen> {
  List<dynamic> _linked = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final linked = await Api.routeStudents(widget.routeId);
    setState(() {
      _linked = linked;
      _loading = false;
    });
  }

  Future<void> _openAddStudent() async {
    final all = await Api.students();
    final linkedIds = _linked.map((s) => s['id'] as String).toSet();
    final available =
        all.where((s) => !linkedIds.contains(s['id'] as String)).toList();

    if (!mounted) return;
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Todos os alunos ja estao nesta rota (ou nenhum foi cadastrado ainda).')),
      );
      return;
    }

    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: available.length,
          itemBuilder: (context, i) {
            final s = available[i] as Map<String, dynamic>;
            return ListTile(
              title: Text(s['name'] as String),
              onTap: () => Navigator.pop(context, s),
            );
          },
        ),
      ),
    );
    if (chosen == null) return;
    final ok =
        await Api.linkStudentToRoute(widget.routeId, chosen['id'] as String);
    if (ok) _load();
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    setState(() {
      final item = _linked.removeAt(oldIndex);
      _linked.insert(newIndex, item);
    });
    final ids = _linked.map((s) => s['id'] as String).toList();
    final ok = await Api.reorderRouteStudents(widget.routeId, ids);
    if (!ok) _load(); // desfaz a mudanca otimista se o backend recusar
  }

  Future<void> _confirmRemove(Map<String, dynamic> student) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover aluno da rota?'),
        content: Text(
            '${student['name']} deixara de aparecer nesta rota (o cadastro do aluno e mantido).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await Api.removeStudentFromRoute(widget.routeId, student['id'] as String);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.routeName)),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddStudent,
        tooltip: 'Adicionar aluno a rota',
        child: const Icon(Icons.person_add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _linked.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                              'Nenhum aluno nesta rota ainda. Toque no + pra adicionar.'),
                        ),
                      ),
                    ])
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: _linked.length,
                      onReorderItem: _reorder,
                      itemBuilder: (context, i) {
                        final s = _linked[i] as Map<String, dynamic>;
                        final school = s['school_name'] as String?;
                        return Card(
                          key: ValueKey(s['id'] as String),
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              child: Icon(Icons.school, size: 20),
                            ),
                            title: Text(s['name'] as String),
                            subtitle: Text(school?.isNotEmpty == true
                                ? school!
                                : 'Escola nao informada'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline,
                                      size: 20),
                                  tooltip: 'Remover da rota',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 28, minHeight: 28),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _confirmRemove(s),
                                ),
                                ReorderableDragStartListener(
                                  index: i,
                                  child: const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: Icon(Icons.drag_handle, size: 20),
                                  ),
                                ),
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
