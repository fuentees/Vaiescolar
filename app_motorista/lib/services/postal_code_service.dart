import 'dart:convert';
import 'api_http.dart' as http;

class PostalAddress {
  final String postalCode;
  final String street;
  final String complement;
  final String neighborhood;
  final String city;
  final String state;

  const PostalAddress(
      {required this.postalCode,
      required this.street,
      required this.complement,
      required this.neighborhood,
      required this.city,
      required this.state});
}

class PostalCodeService {
  PostalCodeService._();

  static Future<PostalAddress?> lookup(String value) async {
    final cep = value.replaceAll(RegExp(r'\D'), '');
    if (cep.length != 8) return null;
    final response =
        await http.get(Uri.parse('https://viacep.com.br/ws/$cep/json/'));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['erro'] == true) return null;
    return PostalAddress(
      postalCode: body['cep'] as String? ?? cep,
      street: body['logradouro'] as String? ?? '',
      complement: body['complemento'] as String? ?? '',
      neighborhood: body['bairro'] as String? ?? '',
      city: body['localidade'] as String? ?? '',
      state: body['uf'] as String? ?? '',
    );
  }
}
