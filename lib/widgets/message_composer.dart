import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gemma_vision_demo/theme.dart';

/// The text input at the bottom of a conversation.
///
/// Shared by the chat and tools screens, which previously carried
/// near-identical copies. The differences between them are genuinely small —
/// whether an image can be attached, and whether generation can be stopped —
/// so they are optional parameters rather than a second widget.
class MessageComposer extends StatelessWidget {
  const MessageComposer({
    super.key,
    required this.controller,
    required this.busy,
    required this.accent,
    required this.onSend,
    this.hintText = 'Ask anything…',
    this.busyHintText = 'Generating…',
    this.pendingImage,
    this.attachTooltip,
    this.onAttach,
    this.onClearImage,
    this.onStop,
    this.inset = 12,
  });

  final TextEditingController controller;

  /// True while the model is generating: input is disabled, and the send
  /// button becomes stop when [onStop] is available.
  final bool busy;
  final Color accent;
  final VoidCallback onSend;

  final String hintText;
  final String busyHintText;

  /// Attachment support is opt-in — pass [onAttach] to enable it.
  final Uint8List? pendingImage;
  final String? attachTooltip;
  final VoidCallback? onAttach;
  final VoidCallback? onClearImage;

  /// When null, the send button stays a send button while busy (disabled).
  final VoidCallback? onStop;

  /// Horizontal padding, so the field lines up with the transcript above it
  /// on a wide window. The top border still spans the whole width.
  final double inset;

  @override
  Widget build(BuildContext context) {
    final canStop = busy && onStop != null;
    return Container(
      padding: EdgeInsets.fromLTRB(inset, 10, inset, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          if (pendingImage != null)
            _AttachmentPreview(bytes: pendingImage!, onClear: onClearImage),
          Row(
            children: [
              if (onAttach != null)
                IconButton(
                  onPressed: busy ? null : onAttach,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  color: accent,
                  tooltip: attachTooltip ?? 'Attach an image',
                ),
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: !busy,
                  style: const TextStyle(color: AppColors.textPrimary),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: busy ? busyHintText : hintText,
                    hintStyle: const TextStyle(color: AppColors.textTertiary),
                    filled: true,
                    fillColor: AppColors.surface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Gap.wSm,
              IconButton.filled(
                onPressed: canStop
                    ? onStop
                    : busy
                    ? null
                    : onSend,
                style: IconButton.styleFrom(
                  backgroundColor: canStop ? AppColors.danger : accent,
                  // The accent is light enough that a white glyph on it
                  // disappears; the stop state is dark enough that it doesn't.
                  foregroundColor: canStop ? Colors.white : AppColors.onAccent,
                ),
                icon: Icon(
                  canStop ? Icons.stop_rounded : Icons.arrow_upward,
                  size: 20,
                ),
                tooltip: canStop ? 'Stop generating' : 'Send',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.bytes, required this.onClear});

  final Uint8List bytes;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 4),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                bytes,
                height: 64,
                width: 64,
                fit: BoxFit.cover,
                // A corrupt pick must not take the composer down.
                errorBuilder: (_, _, _) => Container(
                  height: 64,
                  width: 64,
                  color: AppColors.surfaceHigh,
                  child: const Icon(
                    Icons.broken_image_outlined,
                    size: 20,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
            ),
            if (onClear != null)
              Positioned(
                right: -7,
                top: -7,
                child: GestureDetector(
                  onTap: onClear,
                  child: const CircleAvatar(
                    radius: 11,
                    backgroundColor: AppColors.bg,
                    child: Icon(
                      Icons.close,
                      size: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
