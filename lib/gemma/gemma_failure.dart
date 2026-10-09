import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:gemma_vision_demo/theme.dart';

/// Everything that can go wrong, normalised into something showable.
///
/// flutter_edge_ai gives us one genuinely typed family — the sealed
/// [DownloadError] behind [DownloadException] — and we use it directly. The
/// rest (native engine init, OOM, unsupported ABI) surfaces as plain
/// exceptions whose text is the only signal available, so those are matched on
/// substrings. That is best-effort by nature: [GemmaFailure.unknown] is the
/// honest fallback and still renders a usable screen rather than a stack trace.
@immutable
class GemmaFailure {
  const GemmaFailure({
    required this.title,
    required this.message,
    required this.icon,
    this.hint,
    this.canRetry = true,
    this.raw,
  });

  final String title;
  final String message;
  final IconData icon;

  /// A concrete next step, when we can name one.
  final String? hint;
  final bool canRetry;

  /// Original exception text, shown in a collapsed "details" block so a
  /// failure on stage is still diagnosable afterwards.
  final String? raw;

  static GemmaFailure from(Object error) {
    // --- Typed path: the only errors the package classifies for us. --------
    if (error is DownloadException) {
      final e = error.error;
      return GemmaFailure(
        title: e.toTitle(),
        message: e.toUserMessage(),
        icon: switch (e) {
          NetworkError() => Icons.wifi_off_rounded,
          UnauthorizedError() || ForbiddenError() => Icons.lock_outline_rounded,
          NotFoundError() => Icons.search_off_rounded,
          RateLimitedError() => Icons.hourglass_empty_rounded,
          CanceledError() => Icons.cancel_outlined,
          _ => Icons.cloud_off_rounded,
        },
        hint: e.isRetryable
            ? 'This usually clears on its own — try again.'
            : e.requiresUserAction
            ? 'This needs a change on your side before a retry will work.'
            : null,
        canRetry: true,
        raw: '$error',
      );
    }

    if (error is DownloadCancelledException) {
      return GemmaFailure(
        title: 'Download cancelled',
        message: 'The model download was stopped before it finished.',
        icon: Icons.cancel_outlined,
        raw: '$error',
      );
    }

    // --- Heuristic path: native failures arrive as plain exceptions. -------
    // Note: flutter_edge_ai's ModelException family lives under
    // core/model_management/exceptions/ and is NOT exported from the public
    // barrel, so it cannot be matched by type from an app. Matching its
    // message is the only option available.
    final text = error.toString();
    final lower = text.toLowerCase();

    if (lower.contains('modelvalidationexception') ||
        lower.contains('modelstorageexception') ||
        lower.contains('modeldownloadexception') ||
        lower.contains('corrupt') ||
        lower.contains('incomplete')) {
      return GemmaFailure(
        title: 'Model file problem',
        message:
            'The model file could not be validated or stored. A partial '
            'download is the usual cause.',
        hint: 'Download it again — the broken file is cleaned up first.',
        icon: Icons.broken_image_outlined,
        raw: text,
      );
    }

    if (lower.contains('no active inference model')) {
      return GemmaFailure(
        title: 'Model not installed',
        message: 'The model file is not on this device yet.',
        hint: 'Go back and download the model first.',
        icon: Icons.download_for_offline_outlined,
        raw: text,
      );
    }

    if (lower.contains('no engine') ||
        lower.contains('engine package') ||
        lower.contains('no inference engine')) {
      return GemmaFailure(
        title: 'No engine registered',
        message:
            'flutter_edge_ai ships no inference engine on its own. An '
            'engine package must be passed to FlutterEdgeAi.initialize().',
        hint: 'This is a build configuration bug, not a device problem.',
        canRetry: false,
        icon: Icons.extension_off_outlined,
        raw: text,
      );
    }

    if (lower.contains('arm64') ||
        lower.contains('unsupported architecture') ||
        lower.contains('abi')) {
      return GemmaFailure(
        title: 'Unsupported device',
        message:
            'The LiteRT-LM engine ships arm64 builds only. x86_64 emulators '
            'and Intel Macs cannot run it.',
        hint: 'Use a physical arm64 device or an Apple Silicon Mac.',
        canRetry: false,
        icon: Icons.memory_outlined,
        raw: text,
      );
    }

    if (lower.contains('out of memory') ||
        lower.contains('oom') ||
        lower.contains('failed to allocate') ||
        lower.contains('cannot allocate')) {
      return GemmaFailure(
        title: 'Not enough memory',
        message:
            'Gemma 4 E2B needs roughly 3 GB of free RAM. Other apps are '
            'probably holding it.',
        hint: 'Close background apps and try again.',
        icon: Icons.sd_card_alert_outlined,
        raw: text,
      );
    }

    if (lower.contains('backend') ||
        lower.contains('gpu') ||
        lower.contains('opencl') ||
        lower.contains('metal') ||
        lower.contains('vulkan')) {
      return GemmaFailure(
        title: 'GPU backend unavailable',
        message:
            'The GPU backend could not start on this device, and the CPU '
            'fallback did not take over.',
        hint: 'On Android, check the OpenCL entries in AndroidManifest.xml.',
        icon: Icons.videogame_asset_off_outlined,
        raw: text,
      );
    }

    if (error is UnsupportedError) {
      // Do NOT invent a reason here. An earlier version of this branch assumed
      // every UnsupportedError was about speech, and confidently told the user
      // "speech is native-only" when the real cause was a multimodal message
      // sent to a concurrent .litertlm session. A wrong explanation is worse
      // than none: it sends you debugging the wrong subsystem. The package's
      // own message is specific and actionable, so show it verbatim.
      return GemmaFailure(
        title: 'Not supported on this path',
        message: error.message?.toString() ?? text,
        hint: 'This combination of features is not available here.',
        canRetry: false,
        icon: Icons.block_outlined,
        raw: text,
      );
    }

    if (lower.contains('socket') ||
        lower.contains('connection') ||
        lower.contains('network') ||
        lower.contains('host')) {
      return GemmaFailure(
        title: 'Network unreachable',
        message: 'Could not reach the model host.',
        hint:
            'Only the one-time download needs the network — once installed '
            'everything runs offline.',
        icon: Icons.wifi_off_rounded,
        raw: text,
      );
    }

    return GemmaFailure(
      title: 'Something went wrong',
      message: 'An unexpected error interrupted this step.',
      icon: Icons.error_outline_rounded,
      raw: text,
    );
  }

  Color get accent => switch (icon) {
    Icons.wifi_off_rounded => AppColors.warning,
    Icons.lock_outline_rounded => AppColors.warning,
    _ => AppColors.danger,
  };
}
