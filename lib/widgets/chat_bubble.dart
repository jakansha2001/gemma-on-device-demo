import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gemma_vision_demo/theme.dart';

enum ChatRole { user, model, tool, error }

/// Render LaTeX, but never let a malformed formula break the message.
///
/// A 2B model's LaTeX is frequently invalid — unbalanced braces, a stray
/// backslash, occasionally a non-Latin token spliced into a command. The
/// renderer throws on those, which would take down the whole bubble. Falling
/// back to the raw expression keeps the rest of the answer readable: ugly
/// beats blank.
Widget _latexOrPlainText(
  BuildContext context,
  String tex,
  TextStyle style,
  bool inline,
) {
  try {
    return Math.tex(
      tex,
      textStyle: style,
      mathStyle: inline ? MathStyle.text : MathStyle.display,
      onErrorFallback: (_) => Text(tex, style: style),
    );
  } catch (_) {
    return Text(tex, style: style);
  }
}

/// One rendered row in a transcript.
@immutable
class ChatEntry {
  const ChatEntry({
    required this.role,
    required this.text,
    this.image,
    this.thinking,
    this.toolName,
    this.toolArgs,
    this.toolResult,
  });

  factory ChatEntry.user({required String text, Uint8List? image}) =>
      ChatEntry(role: ChatRole.user, text: text, image: image);

  factory ChatEntry.model({required String text, String? thinking}) =>
      ChatEntry(role: ChatRole.model, text: text, thinking: thinking);

  factory ChatEntry.tool({
    required String name,
    required Map<String, dynamic> args,
    Map<String, dynamic>? result,
  }) => ChatEntry(
    role: ChatRole.tool,
    text: '',
    toolName: name,
    toolArgs: args,
    toolResult: result,
  );

  factory ChatEntry.error(String message) =>
      ChatEntry(role: ChatRole.error, text: message);

  final ChatRole role;
  final String text;
  final Uint8List? image;
  final String? thinking;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final Map<String, dynamic>? toolResult;

  ChatEntry copyWith({Map<String, dynamic>? toolResult}) => ChatEntry(
    role: role,
    text: text,
    image: image,
    thinking: thinking,
    toolName: toolName,
    toolArgs: toolArgs,
    toolResult: toolResult ?? this.toolResult,
  );
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.entry, this.streaming = false});

  final ChatEntry entry;

  /// While true the answer is still arriving, so we show a caret and never
  /// render an "empty reply" placeholder.
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    return switch (entry.role) {
      ChatRole.user => _UserBubble(entry: entry),
      ChatRole.tool => _ToolBubble(entry: entry),
      ChatRole.error => _ErrorBubble(message: entry.text),
      ChatRole.model => _ModelBubble(entry: entry, streaming: streaming),
    };
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.entry});

  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    return _BubbleAlign(
      alignment: Alignment.centerRight,
      widthFactor: .82,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14, left: 40),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(AppRadius.bubble),
            topRight: Radius.circular(AppRadius.bubble),
            bottomLeft: Radius.circular(AppRadius.bubble),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (entry.image != null)
              Padding(
                padding: EdgeInsets.only(bottom: entry.text.isEmpty ? 0 : 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    entry.image!,
                    height: 170,
                    fit: BoxFit.cover,
                    // A corrupt or unreadable pick must not take the list down.
                    errorBuilder: (_, _, _) => Container(
                      height: 80,
                      alignment: Alignment.center,
                      color: Colors.black26,
                      child: const Text(
                        'Image could not be displayed',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ),
            if (entry.text.isNotEmpty)
              Text(
                entry.text,
                style: const TextStyle(
                  color: AppColors.onAccent,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModelBubble extends StatelessWidget {
  const _ModelBubble({required this.entry, required this.streaming});

  final ChatEntry entry;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final hasThinking = (entry.thinking ?? '').trim().isNotEmpty;
    final body = entry.text.trim();

    return _BubbleAlign(
      alignment: Alignment.centerLeft,
      widthFactor: .86,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14, right: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasThinking) _ThinkingBlock(content: entry.thinking!),
            if (body.isNotEmpty || streaming)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(AppRadius.bubble),
                    bottomLeft: Radius.circular(AppRadius.bubble),
                    bottomRight: Radius.circular(AppRadius.bubble),
                  ),
                  border: Border.all(color: AppColors.border),
                ),
                child: body.isEmpty && streaming
                    ? const _TypingDots()
                    // The model emits markdown — headings, **bold**, bullets.
                    // Rendering it as plain text shows the reader the raw
                    // syntax, which is exactly what an end user should never
                    // see. GptMarkdown tolerates the INCOMPLETE markdown that
                    // arrives mid-stream (an unclosed `**`, a half-written
                    // heading) instead of throwing.
                    : GptMarkdown(
                        streaming ? '$body ▍' : body,
                        // Models write maths as `$$...$$`, and this defaults
                        // to OFF — which is why formulas rendered as raw
                        // markup. On, it maps them to the LaTeX renderer.
                        useDollarSignsForLatex: true,
                        latexBuilder: _latexOrPlainText,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                          height: 1.45,
                        ),
                      ),
              ),
            // A finished turn that produced nothing at all — e.g. the user hit
            // stop immediately. Say so rather than showing a blank bubble.
            if (body.isEmpty && !streaming && !hasThinking)
              Text('(no response)', style: AppText.caption),
          ],
        ),
      ),
    );
  }
}

/// The model's reasoning, collapsed by default — it is usually long and the
/// answer is what matters.
class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.content});

  final String content;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.thinking.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.thinking.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: AppColors.thinking,
                  ),
                  Gap.wSm,
                  const Text(
                    'Reasoning',
                    style: TextStyle(
                      color: AppColors.thinking,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .2,
                    ),
                  ),
                  Gap.wSm,
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 17,
                    color: AppColors.thinking.withValues(alpha: .7),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: GptMarkdown(
                widget.content.trim(),
                useDollarSignsForLatex: true,
                latexBuilder: _latexOrPlainText,
                style: AppText.bodySmall.copyWith(height: 1.55),
              ),
            ),
        ],
      ),
    );
  }
}

/// Renders a function call and, once it returns, its result.
class _ToolBubble extends StatelessWidget {
  const _ToolBubble({required this.entry});

  final ChatEntry entry;

  String _pretty(Map<String, dynamic> map) {
    try {
      return const JsonEncoder.withIndent('  ').convert(map);
    } catch (_) {
      // Non-encodable values would otherwise throw inside build().
      return map.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = entry.toolResult == null;
    return Container(
      margin: const EdgeInsets.only(bottom: 14, right: 24),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.tool.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.tool.withValues(alpha: .28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (pending)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.tool,
                  ),
                )
              else
                const Icon(
                  Icons.check_circle_outline,
                  size: 15,
                  color: AppColors.tool,
                ),
              Gap.wSm,
              Expanded(
                child: Text(
                  '${entry.toolName}()',
                  style: const TextStyle(
                    color: AppColors.tool,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    fontFamily: AppFonts.mono,
                  ),
                ),
              ),
              TagChip(
                label: pending ? 'Calling' : 'Tool call',
                color: AppColors.tool,
              ),
            ],
          ),
          // The arguments and the result are JSON, so they sit on the code
          // surface rather than loose on the card: on a projector that is what
          // tells the room "this part is data, not prose".
          if (entry.toolArgs != null && entry.toolArgs!.isNotEmpty) ...[
            Gap.sm,
            _CodeBlock(
              child: Text(_pretty(entry.toolArgs!), style: AppText.mono),
            ),
          ],
          if (entry.toolResult != null) ...[
            Gap.sm,
            _CodeBlock(
              child: Text(
                _pretty(entry.toolResult!),
                style: AppText.mono.copyWith(color: AppColors.textPrimary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14, right: 24),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: .28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: AppColors.danger,
          ),
          Gap.wSm,
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppColors.danger,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Three-dot pulse shown between "send" and the first token.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = ((_c.value + i * .22) % 1.0);
            final scale = .6 + .4 * (1 - (t * 2 - 1).abs());
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.5),
              child: Transform.scale(
                scale: scale,
                child: const CircleAvatar(
                  radius: 3.5,
                  backgroundColor: AppColors.textTertiary,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// Aligns a bubble to one side and caps it at a fraction of the width it is
/// *given* — which is the readable column, not the whole window.
class _BubbleAlign extends StatelessWidget {
  const _BubbleAlign({
    required this.alignment,
    required this.widthFactor,
    required this.child,
  });

  final Alignment alignment;
  final double widthFactor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: alignment,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: constraints.maxWidth * widthFactor,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A JSON block inside a tool card.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceCode,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}
