import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'backend_service.dart';
import 'home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AvNetworkToolbagApp());
}

class AvNetworkToolbagApp extends StatefulWidget {
  const AvNetworkToolbagApp({super.key, this.backend});

  final NetworkBackend? backend;

  @override
  State<AvNetworkToolbagApp> createState() => _AvNetworkToolbagAppState();
}

class _AvNetworkToolbagAppState extends State<AvNetworkToolbagApp> {
  late final NetworkBackend _backend =
      widget.backend ?? WindowsNetworkBackend();
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void dispose() {
    unawaited(_backend.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
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
      backend: _backend,
      themeMode: _themeMode,
      onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
    ),
  );
}
