import 'package:flutter/material.dart';
import 'package:gemma_vision_demo/gemma/gemma_failure.dart';
import 'package:gemma_vision_demo/theme.dart';

/// Full-screen loading state with an optional determinate progress value and
/// a rotating set of captions, so a multi-minute download never looks hung.
class LoadingView extends StatelessWidget {
  const LoadingView({
    super.key,
    required this.title,
    this.subtitle,
    this.progress,
    this.accent = AppColors.accent,
  });

  final String title;
  final String? subtitle;

  /// 0..1, or null for indeterminate.
  final double? progress;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 54,
              height: 54,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 3,
                color: accent,
                backgroundColor: AppColors.surfaceHigh,
              ),
            ),
            Gap.lg,
            Text(title, textAlign: TextAlign.center, style: AppText.heading),
            if (subtitle != null) ...[
              Gap.sm,
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: AppText.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Full-screen failure state. Always offers a way forward: retry when the
/// failure is recoverable, and a way back out when it isn't.
class ErrorView extends StatefulWidget {
  const ErrorView({
    super.key,
    required this.failure,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  final GemmaFailure failure;
  final Future<void> Function()? onRetry;
  final String retryLabel;

  @override
  State<ErrorView> createState() => _ErrorViewState();
}

class _ErrorViewState extends State<ErrorView> {
  bool _showDetails = false;
  bool _retrying = false;

  Future<void> _retry() async {
    final onRetry = widget.onRetry;
    if (onRetry == null || _retrying) return;
    setState(() => _retrying = true);
    try {
      await onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.failure;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(f.icon, size: 46, color: f.accent),
            Gap.md,
            Text(f.title, textAlign: TextAlign.center, style: AppText.title),
            Gap.sm,
            Text(f.message, textAlign: TextAlign.center, style: AppText.body),
            if (f.hint != null) ...[
              Gap.md,
              AppCard(
                padding: const EdgeInsets.all(14),
                color: f.accent.withValues(alpha: .08),
                borderColor: f.accent.withValues(alpha: .22),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lightbulb_outline_rounded,
                      size: 17,
                      color: f.accent,
                    ),
                    Gap.wSm,
                    Expanded(child: Text(f.hint!, style: AppText.bodySmall)),
                  ],
                ),
              ),
            ],
            Gap.lg,
            if (widget.onRetry != null && f.canRetry)
              PrimaryButton(
                label: widget.retryLabel,
                icon: Icons.refresh_rounded,
                busy: _retrying,
                onPressed: _retry,
              ),
            Gap.sm,
            if (Navigator.canPop(context))
              TextButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text(
                  'Go back',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            if (f.raw != null) ...[
              Gap.sm,
              TextButton(
                onPressed: () => setState(() => _showDetails = !_showDetails),
                child: Text(
                  _showDetails ? 'Hide details' : 'Show details',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 12,
                  ),
                ),
              ),
              if (_showDetails)
                AppCard(
                  padding: const EdgeInsets.all(14),
                  color: AppColors.bgElevated,
                  child: SelectableText(f.raw!, style: AppText.mono),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Placeholder shown when a screen is ready but has nothing in it yet.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.accent = AppColors.accent,
    this.suggestions = const [],
    this.onSuggestionTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final List<String> suggestions;
  final void Function(String)? onSuggestionTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        // The column it sits in can be over a metre wide on a projector;
        // centred prose needs a much shorter measure than that to read.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: .1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 30, color: accent),
              ),
              Gap.md,
              Text(title, textAlign: TextAlign.center, style: AppText.heading),
              Gap.sm,
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: AppText.bodySmall,
              ),
              if (suggestions.isNotEmpty) ...[
                Gap.lg,
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in suggestions)
                      ActionChip(
                        label: Text(s, style: const TextStyle(fontSize: 13.5)),
                        onPressed: onSuggestionTap == null
                            ? null
                            : () => onSuggestionTap!(s),
                        backgroundColor: AppColors.surface,
                        side: const BorderSide(color: AppColors.border),
                        labelStyle: const TextStyle(
                          color: AppColors.textSecondary,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
