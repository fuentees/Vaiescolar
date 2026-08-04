import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import 'school_form_screen.dart';

/// Tela de gestao: lista as escolas do tenant e permite cadastrar novas.
/// Alunos vinculam a uma escola daqui em vez de digitar o nome toda vez.
class SchoolsScreen extends StatefulWidget {
  const SchoolsScreen({super.key});
  @override
  State<SchoolsScreen> createState() => _SchoolsScreenState();
}

class _SchoolsScreenState extends State<SchoolsScreen> {
  List<dynamic> _schools = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final schools = await Api.schools();
    setState(() {
      _schools = schools;
      _loading = false;
    });
  }

  Future<void> _openAddDialog() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const SchoolFormScreen()),
    );
    if (created == true) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> school) async {
    final edited = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SchoolFormScreen(existing: school)),
    );
    if (edited == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _schools.where((item) {
      final school = item as Map<String, dynamic>;
      return '${school['name']} ${school['address'] ?? ''}'
          .toLowerCase().contains(_query.trim().toLowerCase());
    }).toList()
      ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escolas'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Buscar escola ou endereço...',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddDialog,
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
                              'Nenhuma escola cadastrada ainda. Toque em + pra adicionar.'),
                        ),
                      ),
                    ])
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final s = visible[i];
                        final address = s['address'] as String?;
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: ListTile(
                            onTap: () => _openEdit(s as Map<String, dynamic>),
                            leading: const CircleAvatar(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              child: Icon(Icons.apartment, size: 20),
                            ),
                            title: Text(s['name'] as String),
                            subtitle: Text(address?.isNotEmpty == true
                                ? address!
                                : 'Endereco nao informado'),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
