import 'package:flutter/material.dart';
import '../services/api.dart';
import 'parent_map.dart';

/// Aba "Localizacao" -- mostra o mapa da viagem ativa mais recente entre
/// todos os filhos do pai, ou explica quando o rastreamento vai aparecer se
/// nao houver nenhuma agora. Antes, o unico jeito de chegar no mapa era pelo
/// card do filho em "Meus filhos"; a bottom nav precisa de um destino direto.
class LocationTabScreen extends StatefulWidget {
  const LocationTabScreen({super.key});
  @override
  State<LocationTabScreen> createState() => _LocationTabScreenState();
}

class _LocationTabScreenState extends State<LocationTabScreen> {
  bool _loading = true;
  Map<String, dynamic>? _mostRecentTrip;
  Map<String, String> _studentNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await Api.activeTrips();
    if (rows.isEmpty) {
      setState(() {
        _mostRecentTrip = null;
        _loading = false;
      });
      return;
    }
    // Pode haver mais de uma linha por viagem (uma por filho na mesma rota) --
    // agrupa nomes por tripId e pega a viagem mais recente.
    final byTrip = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final row = r as Map<String, dynamic>;
      byTrip.putIfAbsent(row['trip_id'] as String, () => []).add(row);
    }
    final trips = byTrip.values.toList()
      ..sort((a, b) => (b.first['started_at'] as String)
          .compareTo(a.first['started_at'] as String));
    final mostRecent = trips.first;
    setState(() {
      _mostRecentTrip = mostRecent.first;
      _studentNames = {
        for (final row in mostRecent)
          row['student_id'] as String: row['student_name'] as String,
      };
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final trip = _mostRecentTrip;
    if (trip == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Localizacao')),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: [
              const SizedBox(height: 64),
              Icon(Icons.location_off_outlined,
                  size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              Text(
                'Nenhuma viagem ativa agora',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'O rastreamento aparece aqui assim que o motorista iniciar a rota do seu filho.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return ParentMap(
      token: Api.token!,
      tripId: trip['trip_id'] as String,
      studentNames: _studentNames,
      direction: trip['direction'] as String?,
      routeName: trip['route_name'] as String?,
    );
  }
}
