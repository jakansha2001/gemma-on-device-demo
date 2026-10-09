import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:gemma_vision_demo/gemma/model_catalog.dart';

/// Owns the one loaded copy of Gemma 4 for the whole app.
///
/// Model *weights* are the expensive thing — 2.6 GB of them. A session is
/// cheap by comparison: just its own conversation context. So the app loads
/// the model once here and every screen calls [openChat] for an independent
/// dialogue on top of it. Screens close their own chat on dispose; nobody
/// closes the model.
///
/// This is what `openChat` (0.16.2) bought us — before it, two independent
/// conversations meant either loading the weights twice or clearing history
/// every time you switched screens.
class GemmaService {
  GemmaService._();
  static final GemmaService instance = GemmaService._();

  InferenceModel? _model;

  bool get isModelLoaded => _model != null;

  /// True once the file is on disk. Cheap — no weights are read.
  Future<bool> isInstalled() =>
      FlutterEdgeAi.isModelInstalled(Models.llmFilename);

  /// Download + register the model. Idempotent: if the file is already on
  /// disk, flutter_edge_ai detects it and skips straight to marking it active.
  Future<void> install({void Function(int percent)? onProgress}) async {
    var builder =
        FlutterEdgeAi.installModel(
          modelType: Models.llmModelType,
          fileType: Models.llmFileType,
        ).fromNetwork(
          Models.llmUrl,
          // Android only: run the download as a foreground service with a
          // progress notification, so Android is less likely to pause a 2.6 GB
          // download when the app goes to the background.
          foreground: true,
        );
    if (onProgress != null) builder = builder.withProgress(onProgress);
    await builder.install();
  }

  /// Load the weights (or return the already-loaded model).
  Future<InferenceModel> loadModel() async {
    if (_model != null) return _model!;
    _model = await FlutterEdgeAi.getActiveModel(
      maxTokens: Models.llmMaxTokens,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      maxNumImages: 1,
    );
    return _model!;
  }

  /// A conversation on the shared model.
  ///
  /// [tools] and [enableThinking] are per-chat, so the vision screen, the
  /// function-calling screen and the voice loop can each configure the same
  /// weights differently.
  ///
  /// **Why this branches on [supportImage].** `openChat()` gives a fully
  /// independent, concurrent session — but on the `.litertlm` FFI engine those
  /// sessions replay their history as text when the engine switches between
  /// them, so they cannot carry images and reject them with an
  /// `UnsupportedError`. Multimodal therefore has to go through
  /// `createChat()`, which owns the model's single primary session.
  ///
  /// That is fine here because the app is a navigation stack: only one screen
  /// holds a chat at a time, and each closes its own on dispose. If you ever
  /// want a tabbed UI with a live vision chat *and* a live text chat, this is
  /// the constraint you would hit.
  Future<InferenceChat> openChat({
    bool supportImage = false,
    double? temperature,
    int? topK,
    double? topP,
    bool enableThinking = false,
    List<Tool> tools = const [],
    String? systemInstruction,
    int? maxOutputTokens,
  }) async {
    final model = await loadModel();
    // See the doc comment: images require the primary session.
    final open = supportImage ? model.createChat : model.openChat;
    return open(
      // Per-chat overrides: the voice loop runs tighter than the screens.
      temperature: temperature ?? Models.llmTemperature,
      topK: topK ?? Models.llmTopK,
      topP: topP ?? Models.llmTopP,
      supportImage: supportImage,
      tools: tools,
      supportsFunctionCalls: tools.isNotEmpty,
      enableThinking: enableThinking,
      // Without this the chat defaults to ModelType.gemmaIt and Gemma 4's
      // native tool-call tokens are never routed correctly.
      modelType: Models.llmModelType,
      systemInstruction: systemInstruction,
      maxOutputTokens: maxOutputTokens,
    );
  }

  Future<void> disposeModel() async {
    await _model?.close();
    _model = null;
  }
}
