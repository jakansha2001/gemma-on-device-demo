import 'package:flutter/material.dart';
import 'package:gemma_vision_demo/screens/voice_screen.dart';
import 'package:gemma_vision_demo/theme.dart';

/// Shows which of the three models is currently working.
class PipelineBar extends StatelessWidget {
  const PipelineBar({super.key, required this.stage});

  final VoiceStage stage;

  @override
  Widget build(BuildContext context) {
    final steps = <(String, VoiceStage, IconData)>[
      ('Listen', VoiceStage.recording, Icons.mic_none_rounded),
      ('Transcribe', VoiceStage.transcribing, Icons.graphic_eq),
      ('Think', VoiceStage.thinking, Icons.auto_awesome),
      ('Speak', VoiceStage.speaking, Icons.volume_up_outlined),
    ];
    return Row(
      children: [
        for (final (index, step) in steps.indexed) ...[
          Expanded(
            child: _PipelineStep(
              label: step.$1,
              icon: step.$3,
              active: stage == step.$2,
              done: stage.index > step.$2.index && stage != VoiceStage.idle,
            ),
          ),
          if (index < steps.length - 1)
            const Icon(
              Icons.chevron_right,
              size: 15,
              color: AppColors.textTertiary,
            ),
        ],
      ],
    );
  }
}

class _PipelineStep extends StatelessWidget {
  const _PipelineStep({
    required this.label,
    required this.icon,
    required this.active,
    required this.done,
  });

  final String label;
  final IconData icon;
  final bool active;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? AppColors.voice
        : done
        ? AppColors.success
        : AppColors.textTertiary;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: active || done ? 1 : .45,
      child: Column(
        children: [
          Icon(icon, size: 19, color: color),
          Gap.xs,
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: 13,
              letterSpacing: .2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class VoicePanel extends StatelessWidget {
  const VoicePanel({
    super.key,
    required this.label,
    required this.color,
    required this.child,
  });

  final String label;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      borderColor: color.withValues(alpha: .25),
      color: color.withValues(alpha: .06),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              letterSpacing: .2,
              fontWeight: FontWeight.w700,
            ),
          ),
          Gap.sm,
          child,
        ],
      ),
    );
  }
}

/// Renders the reply with the already-spoken part at full strength and the
/// rest dimmed, so text visibly leads the voice instead of appearing to
/// finish long before it.
class SpokenText extends StatelessWidget {
  const SpokenText({super.key, required this.full, required this.spoken});

  final String full;
  final String spoken;

  @override
  Widget build(BuildContext context) {
    // The spoken buffer is rebuilt from sentences, so it will not always be a
    // byte-exact prefix of the generated text (whitespace differs). Compare on
    // length rather than assuming `full.startsWith(spoken)`.
    final spokenChars = spoken.trim().length.clamp(0, full.length);
    final said = full.substring(0, spokenChars);
    final pending = full.substring(spokenChars);

    const base = TextStyle(fontSize: 17, height: 1.45);
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: said,
            style: base.copyWith(color: AppColors.textPrimary),
          ),
          TextSpan(
            text: pending,
            style: base.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// Segmented switch between push-to-talk and hands-free.
class ModeToggle extends StatelessWidget {
  const ModeToggle({
    super.key,
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final VoiceMode mode;
  final bool enabled;
  final ValueChanged<VoiceMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : .4,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in VoiceMode.values)
              GestureDetector(
                onTap: enabled && m != mode ? () => onChanged(m) : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: m == mode ? AppColors.voice : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        m == VoiceMode.pushToTalk
                            ? Icons.touch_app_outlined
                            : Icons.hearing,
                        size: 14,
                        color: m == mode
                            ? AppColors.onAccent
                            : AppColors.textTertiary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        m.label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: m == mode
                              ? AppColors.onAccent
                              : AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MicControl extends StatelessWidget {
  const MicControl({
    super.key,
    required this.mode,
    required this.stage,
    required this.level,
    required this.preparing,
    required this.quietProgress,
    required this.onSensitivityChanged,
    required this.triggerDb,
    required this.elapsed,
    required this.maxDuration,
    required this.onTap,
    required this.onBargeIn,
    required this.onStop,
  });

  final VoiceMode mode;
  final VoiceStage stage;

  /// Current input level in dBFS, for the meter.
  final double level;

  /// True between the button being pressed and the recorder actually running
  /// — the microphone permission check can take a moment, and silence there
  /// is indistinguishable from a dead button.
  final bool preparing;

  /// 0..1 through the pause that ends a hands-free turn.
  final double quietProgress;

  /// Nudge the speech threshold, in dB. The right value depends on the
  /// microphone and the room, so it belongs in the hands of whoever is
  /// standing in that room rather than in a rebuild.
  final ValueChanged<double> onSensitivityChanged;

  final double triggerDb;
  final Duration elapsed;
  final Duration maxDuration;
  final VoidCallback? onTap;
  final VoidCallback? onBargeIn;
  final VoidCallback? onStop;

  bool get _armed => stage == VoiceStage.armed;
  bool get _recording => stage == VoiceStage.recording;
  bool get _busy =>
      stage == VoiceStage.transcribing || stage == VoiceStage.thinking;
  bool get _speaking => stage == VoiceStage.speaking;

  String get _caption {
    if (preparing) return 'Checking the microphone…';
    return _stageCaption;
  }

  String get _stageCaption => switch (stage) {
    VoiceStage.armed => 'Listening — just start talking',
    // In hands-free the countdown is a lie: the silence detector almost
    // always ends the turn long before the cap. Show elapsed time and say
    // what actually ends it.
    VoiceStage.recording =>
      mode == VoiceMode.handsFree
          ? 'Listening · ${elapsed.inSeconds}s — pause when you are done'
          : 'Recording · ${elapsed.inSeconds}s / ${maxDuration.inSeconds}s',
    VoiceStage.transcribing => 'Transcribing on-device…',
    VoiceStage.thinking => 'Gemma is composing a reply…',
    VoiceStage.speaking => 'Speaking — tap to interrupt',
    VoiceStage.idle =>
      mode == VoiceMode.handsFree
          ? 'Paused — tap to listen again'
          : 'Tap to speak',
  };

  /// Map dBFS (roughly -60 quiet … 0 full scale) onto 0..1 for the meter.
  double get _normalisedLevel => ((level + 60) / 60).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          // Hands-free: a live level meter, so it is obvious whether the mic
          // is hearing anything and where the trigger threshold sits.
          if (_armed || (_recording && mode == VoiceMode.handsFree))
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                children: [
                  _LevelMeter(
                    level: _normalisedLevel,
                    threshold: ((triggerDb + 60) / 60).clamp(0.0, 1.0),
                    active: _recording,
                  ),
                  Gap.xs,
                  _SensitivityControl(
                    thresholdDb: triggerDb,
                    onChanged: onSensitivityChanged,
                  ),
                ],
              ),
            ),
          // Hands-free: show the pause filling, so it is obvious the
          // detector heard you stop — and obvious when it did not.
          if (_recording && mode == VoiceMode.handsFree && quietProgress > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: quietProgress,
                      minHeight: 3,
                      backgroundColor: AppColors.surfaceHigh,
                      valueColor: const AlwaysStoppedAnimation(
                        AppColors.success,
                      ),
                    ),
                  ),
                  Gap.xs,
                  Text(
                    'Pause detected — sending soon',
                    style: AppText.caption.copyWith(color: AppColors.success),
                  ),
                ],
              ),
            ),
          if (_recording && mode == VoiceMode.pushToTalk)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: elapsed.inMilliseconds / maxDuration.inMilliseconds,
                  minHeight: 3,
                  backgroundColor: AppColors.surfaceHigh,
                  valueColor: const AlwaysStoppedAnimation(AppColors.voice),
                ),
              ),
            ),
          GestureDetector(
            // While speaking, the same button becomes barge-in.
            onTap: _speaking ? onBargeIn : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _recording
                    ? AppColors.recording
                    : _speaking || _busy || preparing
                    ? AppColors.surfaceHigh
                    : AppColors.voice,
                border: _armed
                    ? Border.all(color: Colors.white24, width: 2)
                    : null,
                boxShadow: _recording
                    ? [
                        BoxShadow(
                          color: AppColors.recording.withValues(alpha: .45),
                          blurRadius: 28,
                          spreadRadius: 4,
                        ),
                      ]
                    : _armed
                    ? [
                        BoxShadow(
                          color: AppColors.voice.withValues(alpha: .35),
                          blurRadius: 20 + 26 * _normalisedLevel,
                          spreadRadius: 2 + 5 * _normalisedLevel,
                        ),
                      ]
                    : null,
              ),
              child: _busy || preparing
                  ? const Padding(
                      padding: EdgeInsets.all(26),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.voice,
                      ),
                    )
                  : Icon(
                      _recording
                          ? (mode == VoiceMode.handsFree
                                ? Icons.graphic_eq
                                : Icons.stop_rounded)
                          : _speaking
                          ? Icons.volume_off_rounded
                          : _armed
                          ? Icons.hearing
                          : Icons.mic_rounded,
                      size: 32,
                      color: _recording || _speaking
                          ? Colors.white
                          : AppColors.onAccent,
                    ),
            ),
          ),
          Gap.sm,
          Text(_caption, textAlign: TextAlign.center, style: AppText.caption),
          if (onStop != null) ...[
            Gap.sm,
            TextButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: const Text('Stop', style: TextStyle(fontSize: 12.5)),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Input level with the speech-trigger threshold marked, so a mis-tuned
/// threshold is visible rather than mysterious.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({
    required this.level,
    required this.threshold,
    required this.active,
  });

  final double level;
  final double threshold;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          alignment: Alignment.centerLeft,
          children: [
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 6,
              width: constraints.maxWidth * level,
              decoration: BoxDecoration(
                // Green while the level is above the trigger, matching the
                // "pause detected" cue below it: green means the app is
                // hearing you.
                color: active ? AppColors.success : AppColors.voice,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Positioned(
              left: (constraints.maxWidth * threshold).clamp(
                0.0,
                constraints.maxWidth - 2,
              ),
              child: Container(width: 2, height: 16, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}

/// Moves the speech threshold up or down while listening.
///
/// Deliberately placed directly under the level meter: the white marker is
/// the threshold, so you can watch your own voice against it and stop as soon
/// as it clears comfortably. Tuning this by editing a constant and rebuilding
/// is hopeless — the person who can hear the room is the one who should set
/// it.
class _SensitivityControl extends StatelessWidget {
  const _SensitivityControl({
    required this.thresholdDb,
    required this.onChanged,
  });

  final double thresholdDb;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _NudgeButton(
          icon: Icons.remove,
          tooltip: 'More sensitive — picks up a quieter voice',
          onTap: () => onChanged(thresholdDb - 2),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'speech above ${thresholdDb.toStringAsFixed(0)} dB',
            style: AppText.caption.copyWith(fontSize: 10.5),
          ),
        ),
        _NudgeButton(
          icon: Icons.add,
          tooltip: 'Less sensitive — ignores more background noise',
          onTap: () => onChanged(thresholdDb + 2),
        ),
      ],
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Icon(icon, size: 13, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}
