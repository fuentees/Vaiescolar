import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';

String _fmtDateTime(String? iso) {
  if (iso == null) return '...';
  final d = DateTime.parse(iso).toLocal();
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final min = d.minute.toString().padLeft(2, '0');
  return '$dd/$mm $hh:$min';
}

String _fmtTime(String iso) {
  final d = DateTime.parse(iso).toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// Detalhe de uma viagem finalizada (drill-down a partir de "Relatorios"):
/// metadados (rota, motorista, veiculo, horarios) + timeline de embarque/
/// desembarque de cada aluno.
class TripDetailReportScreen extends StatefulWidget {
  final String tripId;
  const TripDetailReportScreen({super.key, required this.tripId});

  @override
  State<TripDetailReportScreen> createState() => _TripDetailReportScreenState();
}

class _TripDetailReportScreenState extends State<TripDetailReportScreen> {
  Map<String, dynamic>? _trip;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final trip = await Api.tripReportDetail(widget.tripId);
    setState(() {
      _trip = trip;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detalhes da viagem')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _trip == null
              ? const Center(
                  child: Text('Nao foi possivel carregar esta viagem.'))
              : _buildBody(context, _trip!),
    );
  }

  Widget _buildBody(BuildContext context, Map<String, dynamic> trip) {
    final events = (trip['events'] as List<dynamic>? ?? []);
    final direction = trip['direction'] == 'to_school' ? 'Ida' : 'Volta';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${trip['route_name']} · $direction',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _InfoRow(
                    icon: Icons.person,
                    label: 'Motorista',
                    value: '${trip['driver_name']}'),
                if (trip['vehicle_plate'] != null)
                  _InfoRow(
                      icon: Icons.directions_bus,
                      label: 'Veiculo',
                      value: '${trip['vehicle_plate']}'),
                _InfoRow(
                    icon: Icons.play_circle_outline,
                    label: 'Inicio',
                    value: _fmtDateTime(trip['started_at'] as String?)),
                _InfoRow(
                    icon: Icons.flag_outlined,
                    label: 'Fim',
                    value: _fmtDateTime(trip['finished_at'] as String?)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Timeline', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (events.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Nenhum evento registrado nesta viagem.'),
          )
        else
          ...events.map((e) {
            final type = e['type'] as String;
            final label = type == 'boarded'
                ? '${e['student_name']} embarcou'
                : '${e['student_name']} desceu';
            return ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    (type == 'boarded' ? AppColors.success : AppColors.accent)
                        .withValues(alpha: 0.15),
                foregroundColor:
                    type == 'boarded' ? AppColors.success : AppColors.accent,
                child: Icon(
                    type == 'boarded'
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                    size: 18),
              ),
              title: Text(label),
              trailing: Text(_fmtTime(e['at'] as String)),
            );
          }),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text('$label: ',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600)),
          Expanded(
              child:
                  Text(value, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
