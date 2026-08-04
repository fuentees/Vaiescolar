import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import 'student_detail_screen.dart';
import 'student_form_screen.dart';

/// Tela de gestao: lista os alunos do tenant e permite cadastrar novos.
/// E daqui que o motorista/admin monta a base antes de criar rotas.
class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key});
  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  List<dynamic> _students = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final students = await Api.students();
    setState(() {
      _students = students;
      _loading = false;
    });
  }

  Future<void> _openStudentForm({Map<String, dynamic>? existing}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => StudentFormScreen(existing: existing)),
    );
    if (saved == true) _load();
  }

  Future<void> _confirmDelete(Map<String, dynamic> student) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir aluno?'),
        content: Text(
            'Isso remove ${student['name']} de todas as rotas. Essa acao nao pode ser desfeita.'),
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
      await Api.deleteStudent(student['id'] as String);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _students.where((item) {
      final student = item as Map<String, dynamic>;
      final text = '${student['name']} ${student['school_display_name'] ?? student['school_name'] ?? ''}'.toLowerCase();
      return text.contains(_query.trim().toLowerCase());
    }).toList()
      ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alunos'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Buscar aluno ou escola...',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openStudentForm(),
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
                              'Nenhum aluno cadastrado ainda. Toque em + pra adicionar.'),
                        ),
                      ),
                    ])
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final s = visible[i] as Map<String, dynamic>;
                        final school = (s['school_display_name'] ??
                            s['school_name']) as String?;
                        return Card(
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
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => StudentDetailScreen(
                                        studentId: s['id'] as String)),
                              );
                              _load();
                            },
                            trailing: PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'edit') _openStudentForm(existing: s);
                                if (v == 'delete') _confirmDelete(s);
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
