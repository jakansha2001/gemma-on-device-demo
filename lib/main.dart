import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:gemma_vision_demo/screens/home_screen.dart';
import 'package:gemma_vision_demo/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // THE thing to know about flutter_edge_ai: the core package registers no
  // inference engine at all. Whatever you added to pubspec.yaml, you hand to
  // initialize() here — otherwise getActiveModel() throws "no engine
  // registered" at runtime, not at compile time.
  //
  // We register one engine (.litertlm, via dart:ffi) plus the speech backends.
  // There is no MediaPipeEngine here because we ship no .task models.
  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LiteRtLmEngine()],
    sttBackends: const [LiteRtSttBackend()],
    ttsBackends: const [LiteRtTtsBackend()],
    maxDownloadRetries: 10,
    // No `huggingFaceToken:` — every model in this demo lives in a public
    // repo. The first version of this talk needed one, because Gemma 3n is
    // gated.
  );

  // Set to `verbose` to watch prompts and generated tokens in the console
  // while debugging. Release builds are silent no matter what this says.
  FlutterEdgeAi.logLevel = EdgeAiLogLevel.info;

  runApp(const GemmaDemoApp());
}

class GemmaDemoApp extends StatelessWidget {
  const GemmaDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemma On-Device Demo',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // One backdrop under every route, rather than each screen painting its
      // own and drifting apart.
      builder: (context, child) => AppBackground(child: child!),
      home: const HomeScreen(),
    );
  }
}
