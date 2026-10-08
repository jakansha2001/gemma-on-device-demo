import 'package:flutter/material.dart';
import 'package:gemma_vision_demo/gemma/gemma_failure.dart';
import 'package:gemma_vision_demo/gemma/gemma_service.dart';
import 'package:gemma_vision_demo/gemma/model_catalog.dart';
import 'package:gemma_vision_demo/theme.dart';
import 'package:gemma_vision_demo/widgets/status_view.dart';

/// Gate in front of every demo: ensure the weights exist, then hand off to
/// [next]. Already installed? It forwards immediately, so the user only ever
/// sees this screen once.
class ModelDownloadScreen extends StatefulWidget {
  const ModelDownloadScreen({super.key, required this.next});

  final Widget next;

  @override
  State<ModelDownloadScreen> createState() => _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends State<ModelDownloadScreen> {
  bool _checking = true;
  bool _downloading = false;
  int _progress = 0;
  GemmaFailure? _failure;

  /// Progress can sit at the same percent for a while on a slow link. Tracking
  /// the last change lets us say "still going" instead of looking frozen.
  DateTime _lastProgressAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      if (await GemmaService.instance.isInstalled()) {
        _goNext();
        return;
      }
      if (mounted) setState(() => _checking = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _failure = GemmaFailure.from(e);
        });
      }
    }
  }

  void _goNext() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => widget.next),
    );
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _progress = 0;
      _failure = null;
      _lastProgressAt = DateTime.now();
    });
    try {
      await GemmaService.instance.install(
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p.clamp(0, 100);
            _lastProgressAt = DateTime.now();
          });
        },
      );
      _goNext();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _failure = GemmaFailure.from(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Leaving mid-download would orphan the transfer, so block the back
        // affordance while it runs.
        automaticallyImplyLeading: !_downloading,
      ),
      body: SafeArea(
        child: _checking
            ? const LoadingView(title: 'Checking for the model…')
            : _failure != null && !_downloading
            ? ErrorView(
                failure: _failure!,
                onRetry: _download,
                retryLabel: 'Retry download',
              )
            : PageWidth(
                medium: 620,
                expanded: 720,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                  child: _downloading ? _progressBody() : _introBody(),
                ),
              ),
      ),
    );
  }

  Widget _introBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('One-time setup', style: AppText.label),
        Gap.sm,
        const Text(Models.llmDisplayName, style: AppText.title),
        Gap.md,
        const Text(
          'Everything after this runs offline. The model is downloaded once '
          'and kept on the device.',
          style: AppText.body,
        ),
        Gap.lg,
        AppCard(
          child: Column(
            children: const [
              _SpecRow(
                icon: Icons.sd_storage_outlined,
                label: 'Download size',
                value: Models.llmSize,
              ),
              Divider(height: 22),
              _SpecRow(
                icon: Icons.memory_outlined,
                label: 'Free RAM needed',
                value: '~3 GB',
              ),
              Divider(height: 22),
              _SpecRow(
                icon: Icons.key_off_outlined,
                label: 'Access token',
                value: 'Not required',
              ),
              Divider(height: 22),
              _SpecRow(
                icon: Icons.bolt_outlined,
                label: 'Backend',
                value: 'GPU',
              ),
            ],
          ),
        ),
        Gap.md,
        AppCard(
          color: AppColors.warning.withValues(alpha: .07),
          borderColor: AppColors.warning.withValues(alpha: .22),
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Icon(Icons.wifi_rounded, size: 16, color: AppColors.warning),
              Gap.wSm,
              Expanded(
                child: Text(
                  'Use Wi-Fi, and keep the app in the foreground if you can. '
                  'This is the only time the app touches the network.',
                  style: AppText.caption,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        PrimaryButton(
          label: 'Download model',
          icon: Icons.download_rounded,
          onPressed: _download,
        ),
      ],
    );
  }

  Widget _progressBody() {
    final stalledFor = DateTime.now().difference(_lastProgressAt);
    final looksStalled = stalledFor > const Duration(seconds: 25);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Downloading ${Models.llmDisplayName}', style: AppText.label),
        Gap.md,
        Text(
          '$_progress%',
          style: AppText.hero.copyWith(
            fontSize: 64,
            color: AppColors.accentBright,
          ),
        ),
        Gap.md,
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: _progress == 0 ? null : _progress / 100,
            minHeight: 6,
            backgroundColor: AppColors.surfaceHigh,
            valueColor: const AlwaysStoppedAnimation(AppColors.accent),
          ),
        ),
        Gap.lg,
        Text(
          _progress == 0
              ? 'Connecting to Hugging Face…'
              : looksStalled
              ? 'Still going — large chunks can take a while to land.'
              : 'Downloading ${Models.llmSize}. This happens once.',
          textAlign: TextAlign.center,
          style: AppText.bodySmall,
        ),
        Gap.sm,
        const Text(
          'On Android this runs as a foreground service with a notification, '
          'so the download keeps going when you leave the app.',
          textAlign: TextAlign.center,
          style: AppText.caption,
        ),
      ],
    );
  }
}

class _SpecRow extends StatelessWidget {
  const _SpecRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: AppColors.textTertiary),
        Gap.wMd,
        Expanded(child: Text(label, style: AppText.bodySmall)),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
