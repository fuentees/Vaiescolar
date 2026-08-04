import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';

/// Linha do tempo dos eventos de uma viagem ("06:42 - Pedro embarcou" ->
/// "07:10 - Pedro chegou na escola"), com visual cuidado o suficiente para
/// o pai tirar print e compartilhar.
class TimelineScreen extends StatefulWidget {
  final String tripId;
  const TimelineScreen({super.key, required this.tripId});

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  List<dynamic> _events = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final events = await Api.tripEvents(widget.tripId);
    setState(() {
      _events = events;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Timeline do dia')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _events.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                            'Nenhum evento registrado ainda nesta viagem.'),
                      ),
                    ])
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 20),
                      itemCount: _events.length,
                      itemBuilder: (context, i) {
                        final e = _events[i];
                        final isLast = i == _events.length - 1;
                        final type = e['type'] as String;
                        final studentName = e['student_name'] as String;
                        final at = DateTime.parse(e['at'] as String).toLocal();
                        final hh = at.hour.toString().padLeft(2, '0');
                        final mm = at.minute.toString().padLeft(2, '0');
                        final label = type == 'boarded'
                            ? '$studentName embarcou'
                            : '$studentName chegou / desceu';
                        final receivedBy = e['received_by'] as String?;

                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Column(
                                children: [
                                  Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: type == 'boarded'
                                          ? AppColors.success
                                          : AppColors.accent,
                                    ),
                                  ),
                                  if (!isLast)
                                    Expanded(
                                      child: Container(
                                          width: 2,
                                          color: Colors.grey.shade300),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '$hh:$mm',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                                fontWeight: FontWeight.w700),
                                      ),
                                      Text(label,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium),
                                      if (receivedBy?.isNotEmpty == true)
                                        Text('Recebido por: $receivedBy'),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
