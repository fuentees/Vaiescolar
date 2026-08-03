/// Postgres devolve `numeric`/`decimal` (ex.: `amount`) e `bigint` (ex.:
/// `COUNT(*)` sem `::int`) como String no JSON, pra nao perder precisao --
/// `as num?` quebra em runtime nesses casos. Usar sempre que um campo do
/// backend for jogar em conta/formatacao numerica.
num asNum(dynamic value, [num fallback = 0]) {
  if (value is num) return value;
  return num.tryParse('$value') ?? fallback;
}

/// Formata um numero (String ou num vindo do JSON) como "R$ 1.234,56".
String formatMoney(dynamic value) {
  final n = value is num ? value : num.tryParse('$value') ?? 0;
  final fixed = n.toStringAsFixed(2);
  final parts = fixed.split('.');
  final intPart = parts[0];
  final decPart = parts[1];
  final buffer = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
    buffer.write(intPart[i]);
  }
  return 'R\$ $buffer,$decPart';
}
