import 'package:butane/butane.dart';
import 'package:flutter/material.dart' hide ConnectionState;

import 'screens/rig_list_screen.dart';

void main() => runApp(const ProvisionerApp());

/// Sidecar app that provisions a whiteboard Raspberry Pi's Wi-Fi over BLE.
class ProvisionerApp extends StatefulWidget {
  const ProvisionerApp({super.key});

  @override
  State<ProvisionerApp> createState() => _ProvisionerAppState();
}

class _ProvisionerAppState extends State<ProvisionerApp> {
  // One shared central for the whole app session.
  final CentralManager manager = CentralManager(
    restorationIdentifier: 'com.nicospencer.whiteboard.provisioner',
  );

  @override
  void dispose() {
    manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0A84FF);
    return MaterialApp(
      title: 'Whiteboard Setup',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: RigListScreen(manager: manager),
    );
  }
}
