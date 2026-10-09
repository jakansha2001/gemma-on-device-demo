import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

import 'download_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // flutter_edge_ai's core ships without an inference engine. Register the
  // engine package you added: LiteRtLmEngine runs .litertlm models.
  await FlutterEdgeAi.initialize(inferenceEngines: const [LiteRtLmEngine()]);

  runApp(const GemmaApp());
}

class GemmaApp extends StatelessWidget {
  const GemmaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'On-Device Gemma',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1A73E8),
        brightness: Brightness.dark,
      ),
      home: const DownloadScreen(),
    );
  }
}
