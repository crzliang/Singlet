import 'package:flutter/material.dart';

import '../screens/connections_screen.dart';
import '../screens/home_screen.dart';
import '../screens/profiles_screen.dart';
import '../screens/proxies_screen.dart';
import '../screens/settings_screen.dart';
import '../services/clash_api_client.dart';
import '../services/config_store.dart';
import '../services/helper_channel.dart';
import '../services/profile_store.dart';
import '../services/singbox_core_channel.dart';
import '../services/subscription_service.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.core,
    required this.helper,
    required this.clashApi,
    required this.subscriptions,
    required this.configStore,
    required this.profileStore,
  });

  final SingboxCoreChannel core;
  final HelperChannel helper;
  final ClashApiClient clashApi;
  final SubscriptionService subscriptions;
  final ConfigStore configStore;
  final ProfileStore profileStore;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  int _proxiesRefreshToken = 0;

  static const _destinations = [
    NavigationRailDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: Text('首页'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.folder_outlined),
      selectedIcon: Icon(Icons.folder),
      label: Text('订阅'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.hub_outlined),
      selectedIcon: Icon(Icons.hub),
      label: Text('节点'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.lan_outlined),
      selectedIcon: Icon(Icons.lan),
      label: Text('连接'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: Text('设置'),
    ),
  ];

  void _onSubscriptionApplied() {
    setState(() => _proxiesRefreshToken++);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(
        core: widget.core,
        configStore: widget.configStore,
        profileStore: widget.profileStore,
        clashApi: widget.clashApi,
        helper: widget.helper,
      ),
      ProfilesScreen(
        subscriptions: widget.subscriptions,
        profiles: widget.profileStore,
        core: widget.core,
        helper: widget.helper,
        onApplied: _onSubscriptionApplied,
      ),
      ProxiesScreen(
        clashApi: widget.clashApi,
        profileStore: widget.profileStore,
        refreshToken: _proxiesRefreshToken,
        activeProfileId: widget.profileStore.activeId,
      ),
      ConnectionsScreen(clashApi: widget.clashApi),
      SettingsScreen(
        helper: widget.helper,
        core: widget.core,
        configStore: widget.configStore,
      ),
    ];

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) {
              setState(() => _index = i);
              // Entering proxies tab → refresh from API.
              if (i == 2) {
                setState(() => _proxiesRefreshToken++);
              }
            },
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Text(
                'Singlet',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
            ),
            destinations: _destinations,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[_index]),
        ],
      ),
    );
  }
}
