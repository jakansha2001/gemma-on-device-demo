import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// One place for everything model-related, so screens don't repeat it.
class GemmaService {
  GemmaService._();

  static const modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
  static const modelFile = 'gemma-4-E2B-it.litertlm';

  /// Keeps replies short, in one language, and free of LaTeX.
  static const chatInstruction =
      'You are a concise assistant running on a phone. Always write in '
      'English, including any reasoning. Write math in plain text, not LaTeX.';

  static InferenceModel? _model;

  /// Whether the model file is already on this device.
  static Future<bool> isInstalled() => FlutterEdgeAi.isModelInstalled(modelFile);

  /// Downloads the model once and marks it as the active model.
  static Future<void> install({
    required void Function(int percent) onProgress,
  }) {
    return FlutterEdgeAi.installModel(
          modelType: ModelType.gemma4,
          fileType: ModelFileType.litertlm,
        )
        // foreground: keeps an Android download alive past the 9-minute
        // background limit. Ignored on other platforms.
        .fromNetwork(modelUrl, foreground: true)
        .withProgress(onProgress)
        .install();
  }

  /// Loads the weights onto the GPU. This is slow, so it only happens once.
  static Future<InferenceModel> loadModel() async {
    return _model ??= await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      maxNumImages: 1,
    );
  }
}
