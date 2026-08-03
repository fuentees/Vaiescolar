import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'trip_detail_report_screen.dart';

const _monthNames = [
  'Jan',
  'Fev',
  'Mar',
  'Abr',
  'Mai',
  'Jun',
  'Jul',
  'Ago',
  'Set',
  'Out',
  'Nov',
  'Dez',
];

String _formatMonth(String yyyyMm) {
  final parts = yyyyMm.split('-');
  final month = int.parse(parts[1]);
  return '${_monthNames[month - 1]}/${parts[0]}';
}

String _formatDateTime(String iso) {
  final d = DateTime.parse(iso).toLocal();
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final min = d.minute.toString().padLeft(2, '0');
  return '$dd/$mm $hh:$min';
}

String _formatDuration(dynamic seconds) {
  final s = asNum(seconds).toInt();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  if (h > 0) return '${h}h${m.toString().padLeft(2, '0')}min';
  return '${m}min';
}

const _tripPageSize = 20;

/// "Relatorios": historico financeiro com grafico + cards de resumo, e lista
/// filtravel/paginavel de viagens finalizadas, com drill-down por viagem.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  List<dynamic> _financial = [];
  Map<String, dynamic> _summary = {};
  int _months = 6;

  List<dynamic> _routes = [];
  List<dynamic> _vehicles = [];
  List<dynamic> _drivers = [];
  String? _driverId;
  String? _routeId;
  String? _vehicleId;

  List<dynamic> _trips = [];
  int _offset = 0;
  bool _hasMore = true;
  bool _loadingMore = false;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  String get _currentMonth {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      Api.financialHistory(months: _months),
      Api.paymentsSummary(_currentMonth),
      Api.routes(),
      Api.vehicles(),
      Api.users(),
    ]);
    setState(() {
      _financial = results[0] as List<dynamic>;
      _summary = results[1] as Map<String, dynamic>;
      _routes = results[2] as List<dynamic>;
      _vehicles = results[3] as List<dynamic>;
      _drivers = (results[4] as List<dynamic>)
          .where((u) => u['role'] == 'driver')
          .toList();
      _loading = false;
    });
    await _reloadTrips();
  }

  Future<void> _reloadTrips() async {
    setState(() {
      _offset = 0;
      _trips = [];
      _hasMore = true;
    });
    final page = await Api.tripsReport(
      driverId: _driverId,
      routeId: _routeId,
      vehicleId: _vehicleId,
      limit: _tripPageSize,
      offset: 0,
    );
    setState(() {
      _trips = page;
      _offset = page.length;
      _hasMore = page.length == _tripPageSize;
    });
  }

  Future<void> _loadMoreTrips() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final page = await Api.tripsReport(
      driverId: _driverId,
      routeId: _routeId,
      vehicleId: _vehicleId,
      limit: _tripPageSize,
      offset: _offset,
    );
    setState(() {
      _trips = [..._trips, ...page];
      _offset += page.length;
      _hasMore = page.length == _tripPageSize;
      _loadingMore = false;
    });
  }

  Future<void> _exportCsv() async {
    final buffer = StringBuffer(
        'Rota,Direcao,Motorista,Veiculo,Inicio,Fim,Duracao (s),Distancia (km),Alunos,Eventos\n');
    for (final t in _trips) {
      final direction = t['direction'] == 'to_school' ? 'Ida' : 'Volta';
      buffer.writeln([
        (t['route_name'] as String).replaceAll(',', ' '),
        direction,
        (t['driver_name'] as String).replaceAll(',', ' '),
        (t['vehicle_plate'] as String? ?? ''),
        t['started_at'],
        t['finished_at'] ?? '',
        t['duration_seconds'] ?? '',
        t['distance_km'] ?? '',
        t['student_count'] ?? '',
        t['event_count'] ?? '',
      ].join(','));
    }
    await Share.share(buffer.toString(), subject: 'Relatorio de viagens');
  }

  num get _pendingAmount {
    final total = asNum(_summary['total_amount']);
    final paid = asNum(_summary['paid_amount']);
    return total - paid;
  }

  double get _inadimplenciaPct {
    final total = asNum(_summary['total_amount']);
    if (total == 0) return 0;
    return (_pendingAmount / total) * 100;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Relatorios'),
        actions: [
          IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Exportar viagens (CSV)',
              onPressed: _trips.isEmpty ? null : _exportCsv),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadAll,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Resumo do mes',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                          child: _SummaryCard(
                              label: 'Faturado',
                              value: formatMoney(_summary['total_amount'] ?? 0),
                              color: AppColors.primary)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _SummaryCard(
                              label: 'Recebido',
                              value: formatMoney(_summary['paid_amount'] ?? 0),
                              color: AppColors.success)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                          child: _SummaryCard(
                              label: 'Pendente',
                              value: formatMoney(_pendingAmount),
                              color: AppColors.accent)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _SummaryCard(
                              label: 'Inadimplencia',
                              value: '${_inadimplenciaPct.toStringAsFixed(0)}%',
                              color: AppColors.error)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Financeiro (historico)',
                          style: Theme.of(context).textTheme.titleMedium),
                      DropdownButton<int>(
                        value: _months,
                        items: const [3, 6, 12]
                            .map((m) => DropdownMenuItem(
                                value: m, child: Text('$m meses')))
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _months = v);
                          final hist = await Api.financialHistory(months: v);
                          setState(() => _financial = hist);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_financial.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Sem cobrancas geradas ainda.'),
                    )
                  else ...[
                    SizedBox(
                      height: 140,
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _BarChartPainter(_financial),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._financial.map((m) => Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            title: Text(_formatMonth(m['month'] as String)),
                            subtitle: Text(
                                '${m['paid']} pago(s) · ${m['pending']} pendente(s) de ${m['total']}'),
                            trailing: Text(
                              '${formatMoney(m['paid_amount'])} / ${formatMoney(m['total_amount'])}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        )),
                  ],
                  const SizedBox(height: 24),
                  Text('Viagens',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _FilterDropdown(
                        label: 'Motorista',
                        value: _driverId,
                        items: _drivers
                            .map((d) => MapEntry(
                                d['id'] as String, d['name'] as String))
                            .toList(),
                        onChanged: (v) {
                          setState(() => _driverId = v);
                          _reloadTrips();
                        },
                      ),
                      _FilterDropdown(
                        label: 'Rota',
                        value: _routeId,
                        items: _routes
                            .map((r) => MapEntry(
                                r['id'] as String, r['name'] as String))
                            .toList(),
                        onChanged: (v) {
                          setState(() => _routeId = v);
                          _reloadTrips();
                        },
                      ),
                      _FilterDropdown(
                        label: 'Veiculo',
                        value: _vehicleId,
                        items: _vehicles
                            .map((v) => MapEntry(
                                v['id'] as String, v['plate'] as String))
                            .toList(),
                        onChanged: (v) {
                          setState(() => _vehicleId = v);
                          _reloadTrips();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_trips.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child:
                          Text('Nenhuma viagem finalizada para esse filtro.'),
                    )
                  else
                    ..._trips.map((t) {
                      final direction =
                          t['direction'] == 'to_school' ? 'Ida' : 'Volta';
                      final vehicle = t['vehicle_plate'] as String?;
                      final distance = t['distance_km'];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            child: Icon(Icons.directions_bus, size: 18),
                          ),
                          title: Text('${t['route_name']} · $direction'),
                          subtitle: Text(
                            '${t['driver_name']}'
                            '${vehicle != null ? ' · $vehicle' : ''}\n'
                            '${_formatDateTime(t['started_at'] as String)} — '
                            '${t['finished_at'] != null ? _formatDateTime(t['finished_at'] as String) : '...'}\n'
                            '${_formatDuration(t['duration_seconds'])}'
                            '${distance != null ? ' · ${asNum(distance).toStringAsFixed(1)} km' : ''}'
                            ' · ${t['student_count'] ?? 0} aluno(s)',
                          ),
                          isThreeLine: true,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => TripDetailReportScreen(
                                    tripId: t['id'] as String)),
                          ),
                        ),
                      );
                    }),
                  if (_hasMore)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: _loadingMore
                            ? const CircularProgressIndicator()
                            : OutlinedButton(
                                onPressed: _loadMoreTrips,
                                child: const Text('Carregar mais')),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SummaryCard(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  final String label;
  final String? value;
  final List<MapEntry<String, String>> items;
  final ValueChanged<String?> onChanged;
  const _FilterDropdown(
      {required this.label,
      required this.value,
      required this.items,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButton<String?>(
      value: value,
      hint: Text(label),
      underline: Container(height: 1, color: Colors.grey.shade300),
      items: [
        DropdownMenuItem<String?>(value: null, child: Text('Todos ($label)')),
        ...items.map((e) =>
            DropdownMenuItem<String?>(value: e.key, child: Text(e.value))),
      ],
      onChanged: onChanged,
    );
  }
}

/// Grafico de barras simples (faturado vs recebido por mes) sem lib de
/// charting -- so o suficiente pra dar uma leitura visual rapida da
/// evolucao no periodo selecionado.
class _BarChartPainter extends CustomPainter {
  final List<dynamic> months;
  _BarChartPainter(this.months);

  @override
  void paint(Canvas canvas, Size size) {
    if (months.isEmpty) return;
    final maxValue = months.fold<double>(0, (max, m) {
      final v = asNum(m['total_amount']).toDouble();
      return v > max ? v : max;
    });
    if (maxValue == 0) return;

    final barGroupWidth = size.width / months.length;
    final barWidth = (barGroupWidth * 0.6) / 2;
    const chartHeight = 110.0;

    final totalPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.35);
    final paidPaint = Paint()..color = AppColors.success;

    for (int i = 0; i < months.length; i++) {
      final m = months[i];
      final total = asNum(m['total_amount']).toDouble();
      final paid = asNum(m['paid_amount']).toDouble();
      final groupLeft = i * barGroupWidth + barGroupWidth * 0.2;

      final totalHeight = (total / maxValue) * chartHeight;
      final paidHeight = (paid / maxValue) * chartHeight;

      canvas.drawRect(
        Rect.fromLTWH(
            groupLeft, chartHeight - totalHeight, barWidth, totalHeight),
        totalPaint,
      );
      canvas.drawRect(
        Rect.fromLTWH(groupLeft + barWidth, chartHeight - paidHeight, barWidth,
            paidHeight),
        paidPaint,
      );

      final label = (m['month'] as String).split('-')[1];
      final tp = TextPainter(
        text: TextSpan(
            text: label,
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          canvas, Offset(groupLeft + barWidth - tp.width / 2, chartHeight + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter oldDelegate) =>
      oldDelegate.months != months;
}
