import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import '../services/api.dart';
import '../services/postal_code_service.dart';
import '../theme.dart';
import '../utils/phone_mask.dart';
import 'school_form_screen.dart';

/// Cadastro/edicao de aluno como pagina propria (antes era um dialog) --
/// ganhou campos demais pra caber confortavelmente num AlertDialog. Usa
/// Form/TextFormField com validacao de verdade em vez das checagens manuais
/// que o dialog antigo fazia, e confirma antes de sair com alteracao
/// pendente.
class StudentFormScreen extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const StudentFormScreen({super.key, this.existing});

  @override
  State<StudentFormScreen> createState() => _StudentFormScreenState();
}

class _StudentFormScreenState extends State<StudentFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _postalCodeCtrl;
  late final TextEditingController _numberCtrl;
  late final TextEditingController _complementCtrl;
  late final TextEditingController _neighborhoodCtrl;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _stateCtrl;
  late final TextEditingController _feeCtrl;
  late final TextEditingController _classPeriodCtrl;
  late final TextEditingController _emergencyNameCtrl;
  late final TextEditingController _emergencyPhoneCtrl;
  late final TextEditingController _medicalNotesCtrl;
  late final TextEditingController _authorizedPickupCtrl;
  late final TextEditingController _photoUrlCtrl;
  final _emergencyPhoneMask = phoneMaskFormatter();

  String? _schoolId;
  DateTime? _birthDate;
  bool _active = true;
  List<dynamic> _schools = [];
  bool _saving = false;
  String? _error;
  bool _dirty = false;
  bool _lookingUpPostalCode = false;
  String? _postalCodeError;
  String? _lastPostalCode;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?['name'] as String? ?? '');
    _addressCtrl = TextEditingController(
        text: e?['home_street'] as String? ??
            e?['home_address'] as String? ??
            '');
    _postalCodeCtrl =
        TextEditingController(text: e?['home_postal_code'] as String? ?? '');
    _numberCtrl =
        TextEditingController(text: e?['home_number'] as String? ?? '');
    _complementCtrl =
        TextEditingController(text: e?['home_complement'] as String? ?? '');
    _neighborhoodCtrl =
        TextEditingController(text: e?['home_neighborhood'] as String? ?? '');
    _cityCtrl = TextEditingController(text: e?['home_city'] as String? ?? '');
    _stateCtrl = TextEditingController(text: e?['home_state'] as String? ?? '');
    _feeCtrl = TextEditingController(
        text: e?['monthly_fee'] != null ? e!['monthly_fee'].toString() : '');
    _classPeriodCtrl =
        TextEditingController(text: e?['class_period'] as String? ?? '');
    _emergencyNameCtrl = TextEditingController(
        text: e?['emergency_contact_name'] as String? ?? '');
    _emergencyPhoneCtrl = TextEditingController(
        text: e?['emergency_contact_phone'] as String? ?? '');
    _medicalNotesCtrl =
        TextEditingController(text: e?['medical_notes'] as String? ?? '');
    _authorizedPickupCtrl =
        TextEditingController(text: e?['authorized_pickup'] as String? ?? '');
    _photoUrlCtrl =
        TextEditingController(text: e?['photo_url'] as String? ?? '');
    _schoolId = e?['school_id'] as String?;
    _active = e?['active'] as bool? ?? true;
    final birthRaw = e?['birth_date'] as String?;
    if (birthRaw != null) _birthDate = DateTime.tryParse(birthRaw);

    for (final c in [
      _nameCtrl,
      _addressCtrl,
      _postalCodeCtrl,
      _numberCtrl,
      _complementCtrl,
      _neighborhoodCtrl,
      _cityCtrl,
      _stateCtrl,
      _feeCtrl,
      _classPeriodCtrl,
      _emergencyNameCtrl,
      _emergencyPhoneCtrl,
      _medicalNotesCtrl,
      _authorizedPickupCtrl,
      _photoUrlCtrl,
    ]) {
      c.addListener(() => _dirty = true);
    }

    _loadSchools();
  }

  Future<void> _loadSchools() async {
    final schools = await Api.schools();
    if (!mounted) return;
    setState(() => _schools = schools);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _postalCodeCtrl.dispose();
    _numberCtrl.dispose();
    _complementCtrl.dispose();
    _neighborhoodCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _feeCtrl.dispose();
    _classPeriodCtrl.dispose();
    _emergencyNameCtrl.dispose();
    _emergencyPhoneCtrl.dispose();
    _medicalNotesCtrl.dispose();
    _authorizedPickupCtrl.dispose();
    _photoUrlCtrl.dispose();
    super.dispose();
  }

  Future<String?> _openInlineSchoolDialog() async {
    final before = _schools.map((s) => s['id']).toSet();
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const SchoolFormScreen()),
    );
    if (created != true) return null;
    final schools = await Api.schools();
    final added = schools.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s != null && !before.contains(s['id']),
          orElse: () => null,
        );
    return added?['id'] as String?;
  }

  Future<void> _pickBirthDate() async {
    final chosen = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(DateTime.now().year - 8),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
      helpText: 'Data de nascimento',
    );
    if (chosen != null) {
      setState(() {
        _birthDate = chosen;
        _dirty = true;
      });
    }
  }

  Future<void> _lookupPostalCode() async {
    final cep = _postalCodeCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (cep.length != 8 || cep == _lastPostalCode || _lookingUpPostalCode) {
      return;
    }
    setState(() {
      _lookingUpPostalCode = true;
      _postalCodeError = null;
    });
    final address = await PostalCodeService.lookup(cep);
    if (!mounted) return;
    setState(() {
      _lookingUpPostalCode = false;
      if (address == null) {
        _postalCodeError = 'CEP nao encontrado. Confira os 8 digitos.';
        return;
      }
      _lastPostalCode = cep;
      _postalCodeCtrl.text = address.postalCode.replaceAll(RegExp(r'\D'), '');
      _addressCtrl.text = address.street;
      _neighborhoodCtrl.text = address.neighborhood;
      _cityCtrl.text = address.city;
      _stateCtrl.text = address.state;
      if (_complementCtrl.text.isEmpty && address.complement.isNotEmpty) {
        _complementCtrl.text = address.complement;
      }
      _dirty = true;
    });
  }

  String? _value(TextEditingController controller) =>
      controller.text.trim().isEmpty ? null : controller.text.trim();

  String? _fullAddress() {
    final street = _value(_addressCtrl);
    if (street == null) return null;
    final first = [street, _value(_numberCtrl)].whereType<String>().join(', ');
    return [
      first,
      _value(_complementCtrl),
      _value(_neighborhoodCtrl),
      _value(_cityCtrl),
      _value(_stateCtrl),
      _value(_postalCodeCtrl)
    ].whereType<String>().join(' - ');
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final fee = _feeCtrl.text.trim().isEmpty
        ? null
        : double.tryParse(_feeCtrl.text.trim().replaceAll(',', '.'));
    final birthStr = _birthDate != null
        ? '${_birthDate!.year.toString().padLeft(4, '0')}-${_birthDate!.month.toString().padLeft(2, '0')}-${_birthDate!.day.toString().padLeft(2, '0')}'
        : null;

    final fullAddress = _fullAddress();
    double? homeLat;
    double? homeLng;
    final unchangedAddress = _isEditing &&
        fullAddress == widget.existing!['home_address'] as String? &&
        widget.existing!['home_lat'] != null &&
        widget.existing!['home_lng'] != null;
    if (unchangedAddress) {
      homeLat = (widget.existing!['home_lat'] as num).toDouble();
      homeLng = (widget.existing!['home_lng'] as num).toDouble();
    } else if (fullAddress != null) {
      try {
        final locations = await Geocoding().locationFromAddress(fullAddress);
        if (locations.isNotEmpty) {
          homeLat = locations.first.latitude;
          homeLng = locations.first.longitude;
        }
      } catch (_) {
        // Exibe uma mensagem amigavel abaixo.
      }
      if (homeLat == null || homeLng == null) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error =
              'Nao foi possivel localizar esse endereco no mapa. Confira CEP, rua, numero e cidade.';
        });
        return;
      }
    }

    final bool ok;
    if (_isEditing) {
      ok = await Api.updateStudent(
        widget.existing!['id'] as String,
        name: _nameCtrl.text.trim(),
        homeAddress: fullAddress,
        homePostalCode:
            _postalCodeCtrl.text.replaceAll(RegExp(r'\D'), '').isEmpty
                ? null
                : _postalCodeCtrl.text.replaceAll(RegExp(r'\D'), ''),
        homeStreet: _value(_addressCtrl),
        homeNumber: _value(_numberCtrl),
        homeComplement: _value(_complementCtrl),
        homeNeighborhood: _value(_neighborhoodCtrl),
        homeCity: _value(_cityCtrl),
        homeState: _value(_stateCtrl)?.toUpperCase(),
        homeLat: homeLat,
        homeLng: homeLng,
        schoolId: _schoolId,
        monthlyFee: fee,
        photoUrl: _photoUrlCtrl.text.trim().isEmpty
            ? null
            : _photoUrlCtrl.text.trim(),
        birthDate: birthStr,
        classPeriod: _classPeriodCtrl.text.trim().isEmpty
            ? null
            : _classPeriodCtrl.text.trim(),
        emergencyContactName: _emergencyNameCtrl.text.trim().isEmpty
            ? null
            : _emergencyNameCtrl.text.trim(),
        emergencyContactPhone: _emergencyPhoneCtrl.text.trim().isEmpty
            ? null
            : _emergencyPhoneCtrl.text.trim(),
        medicalNotes: _medicalNotesCtrl.text.trim().isEmpty
            ? null
            : _medicalNotesCtrl.text.trim(),
        authorizedPickup: _authorizedPickupCtrl.text.trim().isEmpty
            ? null
            : _authorizedPickupCtrl.text.trim(),
        active: _active,
      );
    } else {
      ok = await Api.createStudent(
        name: _nameCtrl.text.trim(),
        homeAddress: fullAddress,
        homePostalCode:
            _postalCodeCtrl.text.replaceAll(RegExp(r'\D'), '').isEmpty
                ? null
                : _postalCodeCtrl.text.replaceAll(RegExp(r'\D'), ''),
        homeStreet: _value(_addressCtrl),
        homeNumber: _value(_numberCtrl),
        homeComplement: _value(_complementCtrl),
        homeNeighborhood: _value(_neighborhoodCtrl),
        homeCity: _value(_cityCtrl),
        homeState: _value(_stateCtrl)?.toUpperCase(),
        homeLat: homeLat,
        homeLng: homeLng,
        schoolId: _schoolId,
        monthlyFee: fee,
        photoUrl: _photoUrlCtrl.text.trim().isEmpty
            ? null
            : _photoUrlCtrl.text.trim(),
        birthDate: birthStr,
        classPeriod: _classPeriodCtrl.text.trim().isEmpty
            ? null
            : _classPeriodCtrl.text.trim(),
        emergencyContactName: _emergencyNameCtrl.text.trim().isEmpty
            ? null
            : _emergencyNameCtrl.text.trim(),
        emergencyContactPhone: _emergencyPhoneCtrl.text.trim().isEmpty
            ? null
            : _emergencyPhoneCtrl.text.trim(),
        medicalNotes: _medicalNotesCtrl.text.trim().isEmpty
            ? null
            : _medicalNotesCtrl.text.trim(),
        authorizedPickup: _authorizedPickupCtrl.text.trim().isEmpty
            ? null
            : _authorizedPickupCtrl.text.trim(),
        active: _active,
      );
    }
    if (!mounted) return;
    if (ok) {
      _dirty = false;
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = 'Nao foi possivel salvar. Tente novamente.';
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Descartar alteracoes?'),
        content: const Text('Voce tem alteracoes nao salvas nesta tela.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Continuar editando')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final discard = await _confirmDiscard();
        if (discard) navigator.pop(false);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_isEditing ? 'Editar aluno' : 'Novo aluno')),
        body: Form(
          key: _formKey,
          onChanged: () => _dirty = true,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              Text('Dados basicos',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Nome do aluno *'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Informe o nome' : null,
                autovalidateMode: AutovalidateMode.onUserInteraction,
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _schools.any((s) => s['id'] == _schoolId)
                          ? _schoolId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Escola'),
                      items: _schools
                          .map<DropdownMenuItem<String>>(
                            (s) => DropdownMenuItem(
                                value: s['id'] as String,
                                child: Text(s['name'] as String)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() {
                        _schoolId = v;
                        _dirty = true;
                      }),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Nova escola',
                    onPressed: () async {
                      final createdSchoolId = await _openInlineSchoolDialog();
                      if (createdSchoolId != null) {
                        await _loadSchools();
                        if (mounted) {
                          setState(() {
                            _schoolId = createdSchoolId;
                            _dirty = true;
                          });
                        }
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _classPeriodCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                    labelText: 'Turma/periodo (opcional)'),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickBirthDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: 'Data de nascimento (opcional)'),
                  child: Text(
                    _birthDate == null
                        ? '--'
                        : '${_birthDate!.day.toString().padLeft(2, '0')}/${_birthDate!.month.toString().padLeft(2, '0')}/${_birthDate!.year}',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('Endereco da parada',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextFormField(
                controller: _postalCodeCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8)
                ],
                onChanged: (_) => _lookupPostalCode(),
                decoration: InputDecoration(
                  labelText: 'CEP',
                  hintText: 'Somente 8 digitos',
                  errorText: _postalCodeError,
                  prefixIcon: const Icon(Icons.pin_drop_outlined),
                  suffixIcon: _lookingUpPostalCode
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(
                          icon: const Icon(Icons.search),
                          tooltip: 'Buscar CEP',
                          onPressed: _lookupPostalCode),
                ),
                validator: (v) {
                  final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                  if (!_isEditing && digits.isEmpty) {
                    return 'Informe o CEP da parada';
                  }
                  return digits.isNotEmpty && digits.length != 8
                      ? 'Informe os 8 digitos do CEP'
                      : null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _addressCtrl,
                  textInputAction: TextInputAction.next,
                  decoration:
                      const InputDecoration(labelText: 'Rua / logradouro'),
                  validator: (v) =>
                      !_isEditing && (v == null || v.trim().isEmpty)
                          ? 'Informe a rua da parada'
                          : null),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    flex: 2,
                    child: TextFormField(
                        controller: _numberCtrl,
                        keyboardType: TextInputType.streetAddress,
                        decoration: const InputDecoration(labelText: 'Numero'),
                        validator: (v) =>
                            !_isEditing && (v == null || v.trim().isEmpty)
                                ? 'Informe o numero'
                                : null)),
                const SizedBox(width: 12),
                Expanded(
                    flex: 3,
                    child: TextFormField(
                        controller: _complementCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Complemento'))),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _neighborhoodCtrl,
                  decoration: const InputDecoration(labelText: 'Bairro')),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    flex: 3,
                    child: TextFormField(
                        controller: _cityCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Cidade'))),
                const SizedBox(width: 12),
                SizedBox(
                    width: 80,
                    child: TextFormField(
                        controller: _stateCtrl,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [LengthLimitingTextInputFormatter(2)],
                        decoration: const InputDecoration(labelText: 'UF'))),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                controller: _feeCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                    labelText: 'Mensalidade (opcional)', prefixText: 'R\$ '),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  final parsed = double.tryParse(v.trim().replaceAll(',', '.'));
                  if (parsed == null) return 'Valor invalido';
                  if (parsed < 0) return 'Nao pode ser negativo';
                  return null;
                },
                autovalidateMode: AutovalidateMode.onUserInteraction,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _photoUrlCtrl,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration:
                    const InputDecoration(labelText: 'URL da foto (opcional)'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  final uri = Uri.tryParse(v.trim());
                  return uri != null &&
                          (uri.scheme == 'https' || uri.scheme == 'http')
                      ? null
                      : 'Informe uma URL valida';
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Aluno ativo'),
                subtitle:
                    const Text('Alunos inativos nao aparecem em novas rotas'),
                value: _active,
                onChanged: (v) => setState(() {
                  _active = v;
                  _dirty = true;
                }),
              ),
              const Divider(height: 32),
              Text('Emergencia e autorizacao',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emergencyNameCtrl,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                    labelText: 'Contato de emergencia -- nome (opcional)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emergencyPhoneCtrl,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                inputFormatters: [_emergencyPhoneMask],
                decoration: const InputDecoration(
                    labelText: 'Contato de emergencia -- telefone (opcional)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _authorizedPickupCtrl,
                textInputAction: TextInputAction.next,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Pessoas autorizadas a buscar (opcional)',
                  hintText: 'Separe os nomes por virgula',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _medicalNotesCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Observacoes medicas/alergias (opcional)',
                  helperText: 'Visivel so para administradores',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: AppColors.error)),
              ],
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Salvar'),
            ),
          ),
        ),
      ),
    );
  }
}
