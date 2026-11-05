import 'package:flutter/material.dart';

import 'services/clash_api_client.dart';
import 'services/config_store.dart';
import 'services/helper_channel.dart';
import 'services/profile_store.dart';
import 'services/singbox_core_channel.dart';
import 'services/subscription_service.dart';
import 'shell/app_shell.dart';
import 'theme/app_theme.dart';

class SingletApp extends StatelessWidget {
  factory SingletApp({
    Key? key,
    SingboxCoreChannel? core,
    HelperChannel? helper,
    ClashApiClient? clashApi,
    ConfigStore? configStore,
    SubscriptionService? subscriptions,
    ProfileStore? profileStore,
  }) {
    final store = configStore ?? ConfigStore();
    return SingletApp._(
      key: key,
      core: core ?? SingboxCoreChannel(),
      helper: helper ?? HelperChannel(),
      clashApi: clashApi ?? ClashApiClient(),
      configStore: store,
      subscriptions: subscriptions ?? SubscriptionService(store: store),
      profileStore: profileStore ?? ProfileStore(configStore: store),
    );
  }

  const SingletApp._({
    super.key,
    required this._core,
    required this._helper,
    required this._clashApi,
    required this._configStore,
    required this._subscriptions,
    required this._profileStore,
  });

  final SingboxCoreChannel _core;
  final HelperChannel _helper;
  final ClashApiClient _clashApi;
  final ConfigStore _configStore;
  final SubscriptionService _subscriptions;
  final ProfileStore _profileStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: AppShell(
        core: _core,
        helper: _helper,
        clashApi: _clashApi,
        subscriptions: _subscriptions,
        configStore: _configStore,
        profileStore: _profileStore,
      ),
    );
  }
}
