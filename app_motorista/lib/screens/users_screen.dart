import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import '../utils/phone_mask.dart';

/// Tela de gestao: lista motoristas e responsaveis do tenant, permite criar
/// novas contas, editar nome/telefone, resetar senha (fluxo de "esqueci a
/// senha" assistido pelo admin) e desativar/reativar (em vez de excluir).
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});
  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<dynamic> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final users = await Api.users();
    setState(() {
      _users = users;
      _loading = false;
    });
  }

  Future<void> _openAddDialog() async {
    final created = await showDialog<bool>(
        context: context, builder: (_) => const _NewUserDialog());
    if (created == true) _load();
  }

  Future<void> _openEditDialog(Map<String, dynamic> user) async {
    final edited = await showDialog<bool>(
        context: context, builder: (_) => _EditUserDialog(user: user));
    if (edited == true) _load();
  }

  Future<void> _openResetPasswordDialog(String userId, String name) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _ResetPasswordDialog(userId: userId, name: name));
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Senha atualizada com sucesso.')),
      );
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> user) async {
    final active = user['active'] as bool? ?? true;
    final action = active ? 'Desativar' : 'Reativar';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$action ${user['name']}?'),
        content: Text(
          active
              ? 'A conta deixa de conseguir logar ate ser reativada.'
              : 'A conta volta a conseguir logar normalmente.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action)),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await Api.setUserActive(user['id'] as String, !active);
    if (!mounted) return;
    if (ok) {
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Nao foi possivel completar a acao (nao da pra desativar a propria conta).')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final admins = _users.where((u) => u['role'] == 'admin').toList();
    final drivers = _users.where((u) => u['role'] == 'driver').toList();
    final parents = _users.where((u) => u['role'] == 'parent').toList();

    Widget buildTile(dynamic u) => _UserTile(
          user: u,
          onEdit: () => _openEditDialog(u as Map<String, dynamic>),
          onResetPassword: () =>
              _openResetPasswordDialog(u['id'] as String, u['name'] as String),
          onToggleActive: () => _toggleActive(u as Map<String, dynamic>),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Equipe e responsaveis')),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddDialog,
        child: const Icon(Icons.person_add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _users.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                              'Nenhuma conta cadastrada ainda. Toque em + pra criar.'),
                        ),
                      ),
                    ])
                  : ListView(
                      children: [
                        if (admins.isNotEmpty)
                          const _SectionHeader('Administradores'),
                        ...admins.map(buildTile),
                        if (drivers.isNotEmpty)
                          const _SectionHeader('Motoristas'),
                        ...drivers.map(buildTile),
                        if (parents.isNotEmpty)
                          const _SectionHeader('Responsaveis'),
                        ...parents.map(buildTile),
                      ],
                    ),
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _UserTile extends StatelessWidget {
  final dynamic user;
  final VoidCallback onEdit;
  final VoidCallback onResetPassword;
  final VoidCallback onToggleActive;
  const _UserTile(
      {required this.user,
      required this.onEdit,
      required this.onResetPassword,
      required this.onToggleActive});

  @override
  Widget build(BuildContext context) {
    final role = user['role'] as String;
    final active = user['active'] as bool? ?? true;
    final color = switch (role) {
      'admin' => AppColors.error,
      'driver' => AppColors.primary,
      _ => AppColors.accent,
    };
    final icon = switch (role) {
      'admin' => Icons.shield_outlined,
      'driver' => Icons.directions_car,
      _ => Icons.family_restroom,
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: active ? color : Colors.grey,
          foregroundColor: Colors.white,
          child: Icon(icon, size: 20),
        ),
        title: Text(user['name'] as String),
        subtitle: Text(active
            ? (user['email'] as String)
            : '${user['email']} · desativada'),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'edit') onEdit();
            if (v == 'reset') onResetPassword();
            if (v == 'toggle') onToggleActive();
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('Editar')),
            const PopupMenuItem(value: 'reset', child: Text('Resetar senha')),
            PopupMenuItem(
                value: 'toggle',
                child: Text(active ? 'Desativar' : 'Reativar')),
          ],
        ),
      ),
    );
  }
}

class _NewUserDialog extends StatefulWidget {
  const _NewUserDialog();
  @override
  State<_NewUserDialog> createState() => _NewUserDialogState();
}

class _NewUserDialogState extends State<_NewUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _phoneMask = phoneMaskFormatter();
  String _role = 'driver';
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await Api.createUser(
      role: _role,
      name: _nameCtrl.text.trim(),
      email: _emailCtrl.text.trim(),
      password: _passCtrl.text.trim(),
      phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nova conta'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _role,
                items: const [
                  DropdownMenuItem(value: 'driver', child: Text('Motorista')),
                  DropdownMenuItem(value: 'parent', child: Text('Responsavel')),
                  DropdownMenuItem(
                      value: 'admin', child: Text('Administrador')),
                ],
                onChanged: (v) => setState(() => _role = v!),
                decoration: const InputDecoration(labelText: 'Tipo de conta'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nome *'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Informe o nome' : null,
                autovalidateMode: AutovalidateMode.onUserInteraction,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'E-mail *'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Informe o e-mail';
                  if (!v.contains('@') || !v.contains('.')) {
                    return 'E-mail invalido';
                  }
                  return null;
                },
                autovalidateMode: AutovalidateMode.onUserInteraction,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                inputFormatters: [_phoneMask],
                decoration:
                    const InputDecoration(labelText: 'Telefone (opcional)'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _passCtrl,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'Senha provisoria *',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.length < 6) ? 'Minimo 6 caracteres' : null,
                autovalidateMode: AutovalidateMode.onUserInteraction,
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
              : const Text('Criar'),
        ),
      ],
    );
  }
}

class _EditUserDialog extends StatefulWidget {
  final Map<String, dynamic> user;
  const _EditUserDialog({required this.user});
  @override
  State<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<_EditUserDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  final _phoneMask = phoneMaskFormatter();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl =
        TextEditingController(text: widget.user['name'] as String? ?? '');
    _phoneCtrl =
        TextEditingController(text: widget.user['phone'] as String? ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await Api.updateUser(
      widget.user['id'] as String,
      name: _nameCtrl.text.trim(),
      phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
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
      title: const Text('Editar conta'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nome *'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Informe o nome' : null,
              autovalidateMode: AutovalidateMode.onUserInteraction,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              inputFormatters: [_phoneMask],
              decoration:
                  const InputDecoration(labelText: 'Telefone (opcional)'),
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
              : const Text('Salvar'),
        ),
      ],
    );
  }
}

class _ResetPasswordDialog extends StatefulWidget {
  final String userId;
  final String name;
  const _ResetPasswordDialog({required this.userId, required this.name});
  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final done =
        await Api.resetUserPassword(widget.userId, _passCtrl.text.trim());
    if (!mounted) return;
    if (done) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = 'Nao foi possivel resetar a senha. Tente novamente.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Resetar senha de ${widget.name}'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _passCtrl,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'Nova senha (min. 6 caracteres)',
            suffixIcon: IconButton(
              icon: Icon(_obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            errorText: _error,
          ),
          validator: (v) =>
              (v == null || v.length < 6) ? 'Minimo 6 caracteres' : null,
          autovalidateMode: AutovalidateMode.onUserInteraction,
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
              : const Text('Resetar'),
        ),
      ],
    );
  }
}
