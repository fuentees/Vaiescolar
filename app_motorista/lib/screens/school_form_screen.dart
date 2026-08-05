import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import '../services/api.dart';
import '../services/postal_code_service.dart';
import '../services/form_draft.dart';
import '../theme.dart';
import '../utils/phone_mask.dart';

class SchoolFormScreen extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const SchoolFormScreen({super.key, this.existing});

  @override
  State<SchoolFormScreen> createState() => _SchoolFormScreenState();
}

class _SchoolFormScreenState extends State<SchoolFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _cep;
  late final TextEditingController _street;
  late final TextEditingController _number;
  late final TextEditingController _complement;
  late final TextEditingController _neighborhood;
  late final TextEditingController _city;
  late final TextEditingController _state;
  late final TextEditingController _phone;
  final _phoneMask = phoneMaskFormatter();
  bool _lookingUp = false;
  bool _saving = false;
  String? _error;
  String? _lastCep;
  Timer? _draftTimer;

  bool get _editing => widget.existing != null;
  String? _value(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?['name'] as String? ?? '');
    _cep = TextEditingController(text: e?['postal_code'] as String? ?? '');
    _street = TextEditingController(
        text: e?['street'] as String? ?? e?['address'] as String? ?? '');
    _number = TextEditingController(text: e?['number'] as String? ?? '');
    _complement =
        TextEditingController(text: e?['complement'] as String? ?? '');
    _neighborhood =
        TextEditingController(text: e?['neighborhood'] as String? ?? '');
    _city = TextEditingController(text: e?['city'] as String? ?? '');
    _state = TextEditingController(text: e?['state'] as String? ?? '');
    _phone = TextEditingController(text: e?['phone'] as String? ?? '');
    if (!_editing) {
      for (final c in [
        _name,
        _cep,
        _street,
        _number,
        _complement,
        _neighborhood,
        _city,
        _state,
        _phone
      ]) {
        c.addListener(_changed);
      }
      _restoreDraft();
    }
  }

  void _changed() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), () {
      FormDraft.write('school_new', {
        'name': _name.text,
        'cep': _cep.text,
        'street': _street.text,
        'number': _number.text,
        'complement': _complement.text,
        'neighborhood': _neighborhood.text,
        'city': _city.text,
        'state': _state.text,
        'phone': _phone.text,
      });
    });
  }

  Future<void> _restoreDraft() async {
    final d = await FormDraft.read('school_new');
    if (!mounted || d == null) return;
    _name.text = d['name'] as String? ?? '';
    _cep.text = d['cep'] as String? ?? '';
    _street.text = d['street'] as String? ?? '';
    _number.text = d['number'] as String? ?? '';
    _complement.text = d['complement'] as String? ?? '';
    _neighborhood.text = d['neighborhood'] as String? ?? '';
    _city.text = d['city'] as String? ?? '';
    _state.text = d['state'] as String? ?? '';
    _phone.text = d['phone'] as String? ?? '';
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rascunho da escola restaurado.')),
    );
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    for (final c in [
      _name,
      _cep,
      _street,
      _number,
      _complement,
      _neighborhood,
      _city,
      _state,
      _phone
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _lookup() async {
    final cep = _cep.text.replaceAll(RegExp(r'\D'), '');
    if (cep.length != 8 || cep == _lastCep || _lookingUp) return;
    setState(() {
      _lookingUp = true;
      _error = null;
    });
    final result = await PostalCodeService.lookup(cep);
    if (!mounted) return;
    setState(() {
      _lookingUp = false;
      if (result == null) {
        _error = 'CEP nao encontrado.';
        return;
      }
      _lastCep = cep;
      _street.text = result.street;
      _neighborhood.text = result.neighborhood;
      _city.text = result.city;
      _state.text = result.state;
      if (_complement.text.isEmpty) _complement.text = result.complement;
    });
  }

  String _fullAddress() {
    final first = [_street.text.trim(), _number.text.trim()]
        .where((v) => v.isNotEmpty)
        .join(', ');
    return [
      first,
      _value(_complement),
      _value(_neighborhood),
      _value(_city),
      _value(_state),
      _value(_cep)
    ].whereType<String>().join(' - ');
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final address = _fullAddress();
    double? lat;
    double? lng;
    final unchanged = _editing &&
        address == widget.existing!['address'] &&
        widget.existing!['lat'] != null;
    if (unchanged) {
      lat = (widget.existing!['lat'] as num).toDouble();
      lng = (widget.existing!['lng'] as num).toDouble();
    } else {
      try {
        final locations = await Geocoding().locationFromAddress(address);
        if (locations.isNotEmpty) {
          lat = locations.first.latitude;
          lng = locations.first.longitude;
        }
      } catch (_) {}
    }
    if (lat == null || lng == null) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            'Nao foi possivel confirmar a escola no mapa. Confira o endereco.';
      });
      return;
    }
    final ok = _editing
        ? await Api.updateSchool(widget.existing!['id'] as String,
            name: _name.text.trim(),
            address: address,
            phone: _value(_phone),
            postalCode: _cep.text.replaceAll(RegExp(r'\D'), ''),
            street: _value(_street),
            number: _value(_number),
            complement: _value(_complement),
            neighborhood: _value(_neighborhood),
            city: _value(_city),
            state: _value(_state)?.toUpperCase(),
            lat: lat,
            lng: lng)
        : await Api.createSchool(
            name: _name.text.trim(),
            address: address,
            phone: _value(_phone),
            postalCode: _cep.text.replaceAll(RegExp(r'\D'), ''),
            street: _value(_street),
            number: _value(_number),
            complement: _value(_complement),
            neighborhood: _value(_neighborhood),
            city: _value(_city),
            state: _value(_state)?.toUpperCase(),
            lat: lat,
            lng: lng);
    if (!mounted) return;
    if (ok) {
      if (!_editing) await FormDraft.delete('school_new');
      if (!mounted) return;
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = 'Nao foi possivel salvar. Verifique se o nome ja existe.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Editar escola' : 'Nova escola')),
      body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
            children: [
              TextFormField(
                  controller: _name,
                  decoration:
                      const InputDecoration(labelText: 'Nome da escola *'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Informe o nome' : null),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _cep,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8)
                  ],
                  onChanged: (_) => _lookup(),
                  decoration: InputDecoration(
                      labelText: 'CEP *',
                      prefixIcon: const Icon(Icons.pin_drop_outlined),
                      suffixIcon: _lookingUp
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : IconButton(
                              onPressed: _lookup,
                              icon: const Icon(Icons.search))),
                  validator: (v) =>
                      (v ?? '').replaceAll(RegExp(r'\D'), '').length != 8
                          ? 'Informe os 8 digitos'
                          : null),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _street,
                  decoration:
                      const InputDecoration(labelText: 'Rua / logradouro *'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Informe a rua' : null),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    flex: 2,
                    child: TextFormField(
                        controller: _number,
                        decoration:
                            const InputDecoration(labelText: 'Numero *'),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Informe o numero'
                            : null)),
                const SizedBox(width: 12),
                Expanded(
                    flex: 3,
                    child: TextFormField(
                        controller: _complement,
                        decoration:
                            const InputDecoration(labelText: 'Complemento'))),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _neighborhood,
                  decoration: const InputDecoration(labelText: 'Bairro *'),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Informe o bairro'
                      : null),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        controller: _city,
                        decoration:
                            const InputDecoration(labelText: 'Cidade *'),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Informe a cidade'
                            : null)),
                const SizedBox(width: 12),
                SizedBox(
                    width: 80,
                    child: TextFormField(
                        controller: _state,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [LengthLimitingTextInputFormatter(2)],
                        decoration: const InputDecoration(labelText: 'UF *'),
                        validator: (v) =>
                            (v ?? '').trim().length != 2 ? 'UF' : null)),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [_phoneMask],
                  decoration:
                      const InputDecoration(labelText: 'Telefone (opcional)')),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!,
                        style: const TextStyle(color: AppColors.error))),
            ],
          )),
      bottomNavigationBar: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Salvar escola')))),
    );
  }
}
