import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'backend_service.dart';
import 'home_screen.dart';
import 'ipv4_presets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AvNetworkToolbagApp());
}

class AvNetworkToolbagApp extends StatefulWidget {
  const AvNetworkToolbagApp({super.key, this.backend, this.presetStore});

  final NetworkBackend? backend;
  final Ipv4PresetStore? presetStore;

  @override
  State<AvNetworkToolbagApp> createState() => _AvNetworkToolbagAppState();
}

class _AvNetworkToolbagAppState extends State<AvNetworkToolbagApp> {
  late final NetworkBackend _backend =
      widget.backend ?? WindowsNetworkBackend();
  ThemeMode _themeMode = ThemeMode.dark;
  late final AppLifecycleListener _lifecycle;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        try {
          await _backend.close();
          return AppExitResponse.exit;
        } on Object catch (error) {
          debugPrint('Application cleanup failed: $error');
          _messengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text(
                'Could not remove the temporary DHCP firewall rule. '
                'Close the window again to retry. $error',
              ),
            ),
          );
          return AppExitResponse.cancel;
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(
      _backend.close().catchError((Object error) {
        debugPrint('Application cleanup failed: $error');
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    scaffoldMessengerKey: _messengerKey,
    title: 'AV Network Toolbag',
    debugShowCheckedModeBanner: false,
    themeMode: _themeMode,
    theme: buildLightTheme(),
    darkTheme: buildDarkTheme(),
    highContrastTheme: buildLightTheme(highContrast: true),
    highContrastDarkTheme: buildDarkTheme(highContrast: true),
    builder: (context, child) => LayoutBuilder(
      builder: (context, constraints) => Theme(
        data: constraints.maxWidth < 900
            ? buildCompactTheme(Theme.of(context))
            : Theme.of(context),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
    home: NetworkHomeScreen(
      presetStore: widget.presetStore,
      backend: _backend,
      themeMode: _themeMode,
      onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
    ),
  );
}
