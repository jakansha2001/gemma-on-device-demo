import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:gemma_vision_demo/gemma/gemma_failure.dart';
import 'package:gemma_vision_demo/gemma/gemma_service.dart';
import 'package:gemma_vision_demo/gemma/model_catalog.dart';
import 'package:gemma_vision_demo/gemma/model_text.dart';
import 'package:gemma_vision_demo/theme.dart';
import 'package:gemma_vision_demo/widgets/auto_scroller.dart';
import 'package:gemma_vision_demo/widgets/chat_bubble.dart';
import 'package:gemma_vision_demo/widgets/message_composer.dart';
import 'package:gemma_vision_demo/widgets/status_view.dart';
import 'package:image_picker/image_picker.dart';

/// Streaming chat with an optional image attachment.
///
/// With [thinking] on, the same weights run with `enableThinking: true` and the
/// stream starts emitting [ThinkingResponse] alongside [TextResponse] — the
/// model's scratchpad, rendered in its own collapsible block.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.thinking = false});

  final bool thinking;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  late final _autoScroll = AutoScroller(_scroll);
  final _picker = ImagePicker();

  InferenceChat? _chat;
  final List<ChatEntry> _messages = [];

  bool _loading = true;
  bool _generating = false;
  GemmaFailure? _failure;

  String _liveText = '';
  String _liveThinking = '';
  Uint8List? _pendingImage;
  bool _disposed = false;

  Color get _accent => widget.thinking ? AppColors.thinking : AppColors.vision;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      // Weights are already resident if another screen loaded them — this
      // only opens a fresh conversation on top of them.
      final chat = await GemmaService.instance.openChat(
        supportImage: true,
        enableThinking: widget.thinking,
        systemInstruction: widget.thinking
            // Do not tell a thinking model to be brief — that fights the
            // reasoning we are trying to show off. But DO pin the language:
            // reasoning streams from the same distribution as the answer, so
            // it code-switches the same way, and the user reads it.
            ? 'Think step by step and show your reasoning. '
                  '${Models.languagePin} ${Models.readableOutputPin}'
            : 'You are a concise assistant running on a phone. Answer in a '
                  'few sentences unless the user asks for more detail. '
                  '${Models.languagePin} ${Models.readableOutputPin}',
      );
      if (_disposed) {
        await chat.close();
        return;
      }
      setState(() {
        _chat = chat;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = GemmaFailure.from(e);
      });
    }
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        // Downscale before the vision encoder sees it: full-resolution camera
        // frames are pure memory pressure on a device already holding 2.6 GB
        // of weights, and the encoder resizes anyway.
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (picked == null) return; // User cancelled — not an error.
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        _toast('That image appears to be empty.');
        return;
      }
      if (mounted) setState(() => _pendingImage = bytes);
    } catch (e) {
      // Most often a denied camera/photos permission.
      _toast('Could not open that image: $e');
    }
  }

  /// image_picker exposes no camera on desktop — `ImageSource.camera` there
  /// either throws or silently does nothing. So on desktop we skip the sheet
  /// entirely and open the file dialog directly, which is also what a Mac user
  /// expects from an "attach" button.
  static bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  void _showPicker() {
    if (_isDesktop) {
      _pick(ImageSource.gallery);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(Icons.camera_alt_outlined, color: _accent),
              title: const Text(
                'Take a photo',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pick(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: _accent),
              title: const Text(
                'Choose from gallery',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              subtitle: const Text(
                'More reliable than the camera on 6 GB devices',
                style: AppText.caption,
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pick(ImageSource.gallery);
              },
            ),
            Gap.sm,
          ],
        ),
      ),
    );
  }

  Future<void> _send([String? preset]) async {
    final chat = _chat;
    final text = (preset ?? _controller.text).trim();
    final image = _pendingImage;
    if (chat == null || _generating || (text.isEmpty && image == null)) return;

    _controller.clear();
    setState(() {
      _messages.add(ChatEntry.user(text: text, image: image));
      _pendingImage = null;
      _generating = true;
      _liveText = '';
      _liveThinking = '';
    });
    _scrollDown();

    try {
      await chat.addQueryChunk(
        image != null
            ? Message.withImage(
                text: text.isEmpty ? 'What do you see in this image?' : text,
                imageBytes: image,
                isUser: true,
              )
            : Message.text(text: text, isUser: true),
      );

      final answer = StringBuffer();
      final reasoning = StringBuffer();

      await for (final response in chat.generateChatResponseAsync()) {
        if (_disposed) break;
        // ModelResponse is sealed, so this switch is exhaustive: a future
        // variant fails to compile here instead of silently vanishing.
        switch (response) {
          case TextResponse(:final token):
            answer.write(token);
            if (mounted) {
              // Sanitize the ACCUMULATED buffer, not the token: a
              // marker can be split across two tokens.
              setState(() {
                _liveText = ModelText.sanitize(
                  answer.toString(),
                  streaming: true,
                );
              });
            }
          case ThinkingResponse(:final content):
            reasoning.write(content);
            if (mounted) setState(() => _liveThinking = reasoning.toString());
          case FunctionCallResponse():
          case ParallelFunctionCallResponse():
            break; // No tools on this chat — see ToolsScreen.
        }
        _scrollDown();
      }

      if (!mounted) return;
      setState(() {
        _messages.add(
          ChatEntry.model(
            text: ModelText.sanitize(answer.toString()),
            thinking: reasoning.isEmpty ? null : reasoning.toString(),
          ),
        );
        _liveText = '';
        _liveThinking = '';
        _generating = false;
      });
      _scrollDown();
    } catch (e) {
      if (!mounted) return;
      final f = GemmaFailure.from(e);
      setState(() {
        _messages.add(ChatEntry.error('${f.title}: ${f.message}'));
        _liveText = '';
        _liveThinking = '';
        _generating = false;
      });
      _scrollDown();
    }
  }

  /// Reaches the native decoder, unlike merely cancelling the Dart stream.
  /// Since 1.0.1 a stopped turn no longer leaves an empty assistant message
  /// polluting the history.
  Future<void> _stop() async {
    try {
      await _chat?.stopGeneration();
    } catch (e) {
      _toast('Could not stop generation: $e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Follow the stream only while the reader has not scrolled away — see
  /// [AutoScroller]. Previously this yanked the view to the bottom on every
  /// token, which made it impossible to read back through a long answer while
  /// it was still being generated.
  void _scrollDown() => _autoScroll.followOutput();

  @override
  void dispose() {
    _disposed = true;
    // Close the chat, not the model — other screens share those weights.
    _chat?.close();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final streaming = _liveText.isNotEmpty || _liveThinking.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.thinking ? 'Thinking mode' : 'Vision chat',
              style: AppText.heading,
            ),
            Text(
              widget.thinking
                  ? 'Reasoning is streamed separately'
                  : 'Gemma 4 E2B · GPU · offline',
              style: AppText.caption,
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: _loading
            ? LoadingView(
                title: 'Loading Gemma 4 onto the GPU',
                accent: _accent,
                subtitle:
                    'The weights load once and are shared by every screen.',
              )
            : _failure != null
            ? ErrorView(failure: _failure!, onRetry: _init)
            : Column(
                children: [
                  Expanded(
                    child: _messages.isEmpty && !streaming
                        ? EmptyView(
                            icon: widget.thinking
                                ? Icons.psychology_outlined
                                : Icons.image_outlined,
                            accent: _accent,
                            title: widget.thinking
                                ? 'Give it something to think about'
                                : 'Attach a photo, or just ask',
                            subtitle: widget.thinking
                                ? 'Its reasoning appears above the answer, '
                                      'collapsed by default.'
                                : 'Everything runs locally — try it with the '
                                      'network switched off.',
                            suggestions: widget.thinking
                                ? const [
                                    'If a bat and ball cost 1.10 and the bat costs 1 more than the ball, what does the ball cost?',
                                    'Plan a 3-day trip to Jaipur on a tight budget',
                                  ]
                                : const [
                                    'Explain on-device AI to a beginner',
                                    'Write a haiku about offline models',
                                  ],
                            onSuggestionTap: _generating ? null : _send,
                          )
                        : Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              NotificationListener<ScrollNotification>(
                                onNotification: (n) {
                                  if (_autoScroll.handleNotification(n)) {
                                    setState(() {});
                                  }
                                  return false;
                                },
                                child: SelectionArea(
                                  child: ListView.builder(
                                    controller: _scroll,
                                    padding: const EdgeInsets.all(16),
                                    itemCount:
                                        _messages.length + (_generating ? 1 : 0),
                                    itemBuilder: (_, i) => i < _messages.length
                                        ? ChatBubble(entry: _messages[i])
                                        : ChatBubble(
                                            entry: ChatEntry.model(
                                              text: _liveText,
                                              thinking: _liveThinking.isEmpty
                                                  ? null
                                                  : _liveThinking,
                                            ),
                                            streaming: true,
                                          ),
                                  ),
                                ),
                              ),
                              JumpToLatestButton(
                                visible: !_autoScroll.isPinned,
                                color: _accent,
                                onPressed: () =>
                                    setState(_autoScroll.resume),
                              ),
                            ],
                          ),
                  ),
                  MessageComposer(
                    controller: _controller,
                    pendingImage: _pendingImage,
                    busy: _generating,
                    accent: _accent,
                    attachTooltip: _isDesktop
                        ? 'Choose an image from this Mac'
                        : 'Attach an image',
                    onAttach: _showPicker,
                    onClearImage: () => setState(() => _pendingImage = null),
                    onSend: _send,
                    onStop: _stop,
                  ),
                ],
              ),
      ),
    );
  }
}
