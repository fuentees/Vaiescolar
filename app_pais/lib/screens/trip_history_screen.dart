import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';

String _formatDateTime(String iso) {
  final d = DateTime.parse(iso).toLocal();
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final min = d.minute.toString().padLeft(2, '0');
  return '$dd/$mm $hh:$min';
}

const _pageSize = 20;

/// Historico de viagens finalizadas de um filho especifico -- rota,
/// motorista, horario e se o proprio filho chegou a embarcar naquele dia
/// (algumas viagens da rota podem ter acontecido sem ele, ex.: falta avisada).
class TripHistoryScreen extends StatefulWidget {
  final String studentId;
  final String name;
  const TripHistoryScreen(
      {super.key, required this.studentId, required this.name});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  List<dynamic> _trips = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _offset = 0;
      _trips = [];
      _hasMore = true;
    });
    final page =
        await Api.tripHistory(widget.studentId, limit: _pageSize, offset: 0);
    setState(() {
      _trips = page;
      _offset = page.length;
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final page = await Api.tripHistory(widget.studentId,
        limit: _pageSize, offset: _offset);
    setState(() {
      _trips = [..._trips, ...page];
      _offset += page.length;
      _hasMore = page.length == _pageSize;
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Viagens de ${widget.name}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _trips.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('Nenhuma viagem finalizada ainda.',
                            textAlign: TextAlign.center),
                      ),
                    ])
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _trips.length + 1,
                      itemBuilder: (context, i) {
                        if (i == _trips.length) {
                          if (!_hasMore) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: _loadingMore
                                  ? const CircularProgressIndicator()
                                  : OutlinedButton(
                                      onPressed: _loadMore,
                                      child: const Text('Carregar mais')),
                            ),
                          );
                        }
                        final t = _trips[i];
                        final direction =
                            t['direction'] == 'to_school' ? 'Ida' : 'Volta';
                        final boarded = t['last_event_type'] == 'boarded';
                        final dropped = t['last_event_type'] == 'dropped';
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              child: Icon(
                                  direction == 'Ida'
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  size: 18),
                            ),
                            title: Text('${t['route_name']} · $direction'),
                            subtitle: Text(
                              '${t['driver_name']}\n'
                              '${_formatDateTime(t['started_at'] as String)}'
                              '${t['finished_at'] != null ? ' — ${_formatDateTime(t['finished_at'] as String)}' : ''}\n'
                              '${boarded ? 'Embarcou' : dropped ? 'Desceu' : 'Sem registro de embarque'}',
                            ),
                            isThreeLine: true,
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
