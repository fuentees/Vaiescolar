import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api.dart';
import '../services/update_service.dart';
import 'active_route_screen.dart';
import 'chat_threads_screen.dart';
import 'home_screen.dart';
import 'management_hub_screen.dart';
import '../widgets/permission_reminder.dart';

class _NavTab {
  final String label;
  final IconData icon;
  final Widget screen;
  const _NavTab(this.label, this.icon, this.screen);
}

/// Casca de navegacao com bottom nav, substituindo o drawer de 10 itens.
/// Motorista comum ve 3 abas (Inicio, Rota, Mensagens); admin ve tambem
/// "Gestao" (cadastros que antes ficavam soltos no drawer) e comeca na aba
/// Inicio -- motorista comum comeca direto em "Rota", que e a acao do dia a
/// dia dele.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final List<_NavTab> _tabs = [
    const _NavTab('Inicio', Icons.home_outlined, HomeScreen()),
    const _NavTab('Rota', Icons.directions_bus_filled, ActiveRouteScreen()),
    const _NavTab('Mensagens', Icons.chat_bubble_outline, ChatThreadsScreen()),
    if (Api.isAdmin)
      const _NavTab('Gestao', Icons.dashboard_outlined, ManagementHubScreen()),
  ];
  late int _index = Api.isAdmin ? 0 : 1;
  late final List<Widget?> _loadedTabs;
  int _unread = 0;
  Timer? _unreadTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadedTabs = List<Widget?>.filled(_tabs.length, null);
    _loadedTabs[_index] = _tabs[_index].screen;
    _refreshUnread();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdateService.check(context);
    });
    _unreadTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _refreshUnread());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unreadTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshUnread();
  }

  Future<void> _refreshUnread() async {
    final count = await Api.chatUnreadCount();
    if (!mounted || count < 0) return;
    setState(() => _unread = count);
  }

  void _onTap(int i) {
    setState(() {
      _index = i;
      _loadedTabs[i] ??= _tabs[i].screen;
    });
    if (_tabs[i].label == 'Mensagens') {
      // A lista de threads recarrega ao ganhar foco, mas o badge global so
      // reflete leituras feitas dentro de uma conversa individual (que marca
      // a thread como lida no backend) -- reconfere apos um respiro.
      Future.delayed(const Duration(milliseconds: 300), _refreshUnread);
    }
  }

  Future<void> _handleBack() async {
    if (_index != 0) {
      _onTap(0);
      return;
    }
    final minimize = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Minimizar aplicativo?'),
        content: const Text(
          'Sua sessão continuará conectada e você continuará recebendo notificações.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuar no app'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Minimizar'),
          ),
        ],
      ),
    );
    if (minimize == true) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        body: Column(
          children: [
            const PermissionReminder(),
            Expanded(
                child: IndexedStack(
              index: _index,
              children: List.generate(
                _tabs.length,
                (i) => _loadedTabs[i] ?? const SizedBox.shrink(),
              ),
            )),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _index,
          onTap: _onTap,
          type: BottomNavigationBarType.fixed,
          items: _tabs.map((t) {
            final icon = t.label == 'Mensagens' && _unread > 0
                ? Badge(label: Text('$_unread'), child: Icon(t.icon))
                : Icon(t.icon);
            return BottomNavigationBarItem(icon: icon, label: t.label);
          }).toList(),
        ),
      ),
    );
  }
}
