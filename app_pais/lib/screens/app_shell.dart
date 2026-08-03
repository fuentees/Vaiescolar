import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api.dart';
import 'chat_screen.dart';
import 'children_list_screen.dart';
import 'location_tab_screen.dart';
import 'profile_screen.dart';

class _NavTab {
  final String label;
  final IconData icon;
  final Widget screen;
  const _NavTab(this.label, this.icon, this.screen);
}

/// Casca de navegacao com bottom nav, substituindo os 3 icones pequenos que
/// ficavam no AppBar de "Meus filhos" (apertados em telas de 320px).
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static const _tabs = [
    _NavTab('Inicio', Icons.home_outlined, ChildrenListScreen()),
    _NavTab('Localizacao', Icons.map_outlined, LocationTabScreen()),
    _NavTab('Mensagens', Icons.chat_bubble_outline, ChatScreen()),
    _NavTab('Conta', Icons.person_outline, ProfileScreen()),
  ];
  int _index = 0;
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
    // Poll simples -- nao ha push especifico pra "atualizar badge", e o chat
    // ja tem seu proprio WebSocket por thread; isso so mantem o numero do
    // badge razoavelmente atual mesmo em abas que nao sao a de mensagens.
    _unreadTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _refreshUnread());
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
    if (!mounted || count < 0) {
      return; // -1 = falha na chamada, mantem o ultimo valor conhecido
    }
    setState(() => _unread = count);
  }

  void _onTap(int i) {
    setState(() {
      _index = i;
      _loadedTabs[i] ??= _tabs[i].screen;
    });
    if (_tabs[i].label == 'Mensagens') {
      // Abrir a aba ja marca a thread como lida no backend (GET historico) --
      // zera o badge otimisticamente em vez de esperar o proximo poll.
      Future.delayed(const Duration(milliseconds: 300), _refreshUnread);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: List.generate(
          _tabs.length,
          (i) => _loadedTabs[i] ?? const SizedBox.shrink(),
        ),
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
    );
  }
}
