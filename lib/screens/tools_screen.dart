import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:gemma_vision_demo/gemma/demo_tools.dart';
import 'package:gemma_vision_demo/gemma/gemma_failure.dart';
import 'package:gemma_vision_demo/gemma/gemma_service.dart';
import 'package:gemma_vision_demo/gemma/model_catalog.dart';
import 'package:gemma_vision_demo/gemma/model_text.dart';
import 'package:gemma_vision_demo/theme.dart';
import 'package:gemma_vision_demo/widgets/auto_scroller.dart';
import 'package:gemma_vision_demo/widgets/chat_bubble.dart';
import 'package:gemma_vision_demo/widgets/message_composer.dart';
import 'package:gemma_vision_demo/widgets/status_view.dart';

/// Function calling: the model decides to call our Dart, we run it, the result
/// goes back, and it answers using that result.
///
/// The whole loop is one call — `generateChatResponseWithTools` (new in 1.5.3).
/// Before it existed every app hand-rolled this: read the stream, spot a
/// [FunctionCallResponse], run the tool, push a [Message.toolResponse], call
/// generate again, and hope you got the turn accounting right. Now the only
/// thing we supply is `onToolCall`.
class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  late final _autoScroll = AutoScroller(_scroll);
  final _workspace = ToolWorkspace();

  InferenceChat? _chat;
  final List<ChatEntry> _entries = [];

  bool _loading = true;
  bool _generating = false;
  GemmaFailure? _failure;
  String _liveText = '';

  /// Lets `isCancelled` stop the driver loop when the screen goes away
  /// mid-turn, instead of the loop running on against a closed chat.
  bool _disposed = false;

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
      final chat = await GemmaService.instance.openChat(
        tools: DemoTools.declarations,
        systemInstruction:
            'You are an assistant embedded in a Flutter app. You have tools '
            'that act on the live UI.\n'
            '- Always call a tool rather than describing what you would do.\n'
            '- Fill every argument from what the user already said. Never ask '
            'the user to repeat something they have given you.\n'
            '- Only ask a question if the request is genuinely ambiguous.\n'
            '- After a tool returns, confirm the outcome in one short '
            'sentence.\n'
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

  Future<void> _send([String? preset]) async {
    final chat = _chat;
    final text = (preset ?? _controller.text).trim();
    if (chat == null || _generating || text.isEmpty) return;

    _controller.clear();
    setState(() {
      _entries.add(ChatEntry.user(text: text));
      _generating = true;
      _liveText = '';
    });
    _scrollDown();

    try {
      await chat.addQueryChunk(Message.text(text: text, isUser: true));

      final answer = StringBuffer();

      await for (final response in chat.generateChatResponseWithTools(
        // Our side of the contract: execute the call, return the result map.
        // DemoTools.execute never throws, so a broken tool degrades into an
        // {'error': ...} the model can react to, rather than killing the turn.
        onToolCall: (call) {
          if (!mounted) return <String, dynamic>{'error': 'screen closed'};
          setState(() {
            _entries.add(ChatEntry.tool(name: call.name, args: call.args));
          });
          _scrollDown();

          final result = DemoTools.execute(call, _workspace);

          if (mounted) {
            setState(() {
              // Attach the result to the pending tool bubble.
              final i = _entries.lastIndexWhere(
                (e) => e.role == ChatRole.tool && e.toolResult == null,
              );
              if (i != -1) {
                _entries[i] = _entries[i].copyWith(toolResult: result);
              }
            });
            _scrollDown();
          }
          return result;
        },
        // Cap the loop so a model that keeps calling tools cannot spin
        // forever on stage.
        maxToolTurns: 5,
        isCancelled: () => _disposed,
        onMaxToolTurns: () {
          if (!mounted) return;
          setState(() {
            _entries.add(
              ChatEntry.error(
                'Stopped after 5 tool rounds without a final answer.',
              ),
            );
          });
        },
      )) {
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
            _scrollDown();
          case ThinkingResponse():
            // Thinking is off for this chat; nothing to render.
            break;
          case FunctionCallResponse():
          case ParallelFunctionCallResponse():
            // Already handled by onToolCall — the driver loop re-emits these
            // so a caller can log them. Rendering happens above.
            break;
        }
      }

      if (!mounted) return;
      setState(() {
        final clean = ModelText.sanitize(answer.toString());
        if (clean.isNotEmpty) {
          _entries.add(ChatEntry.model(text: clean));
        }
        _liveText = '';
        _generating = false;
      });
      _scrollDown();
    } catch (e) {
      if (!mounted) return;
      final f = GemmaFailure.from(e);
      setState(() {
        _entries.add(ChatEntry.error('${f.title}: ${f.message}'));
        _liveText = '';
        _generating = false;
      });
      _scrollDown();
    }
  }

  /// Follows the stream only while the reader has not scrolled away.
  void _scrollDown() => _autoScroll.followOutput();

  @override
  void dispose() {
    _disposed = true;
    _chat?.close();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = _workspace.accent;
    // Padding, not a constrained box: a list inside a narrow box puts its
    // scrollbar in the middle of a wide window.
    final inset = pageInset(MediaQuery.sizeOf(context).width);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Function calling', style: AppText.heading),
            Text(
              '${DemoTools.declarations.length} tools · runs your Dart',
              style: AppText.caption,
            ),
          ],
        ),
        actions: [
          if (_generating)
            const Padding(
              padding: EdgeInsets.only(right: 18),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const LoadingView(
                title: 'Opening a tool-enabled session',
                subtitle:
                    'Tool declarations go into the model context through '
                    "Gemma 4's native chat template.",
              )
            : _failure != null
            ? ErrorView(failure: _failure!, onRetry: _init)
            : Column(
                children: [
                  if (_workspace.tasks.isNotEmpty)
                    _TaskStrip(workspace: _workspace, inset: inset),
                  Expanded(
                    child: _entries.isEmpty && _liveText.isEmpty
                        ? EmptyView(
                            icon: Icons.build_outlined,
                            accent: accent,
                            title: 'Ask it to do something',
                            subtitle:
                                'It will pick a tool, run your Dart, then '
                                'answer using what came back.',
                            suggestions: const [
                              'Add buy milk, then tell me what is on my list',
                              'What time is it?',
                              'Mark buy milk as done',
                              'Make the app purple',
                              "What's 1840 * 0.18?",
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
                                    padding: EdgeInsets.fromLTRB(
                                      inset,
                                      16,
                                      inset,
                                      16,
                                    ),
                                    itemCount:
                                        _entries.length + (_generating ? 1 : 0),
                                    itemBuilder: (_, i) => i < _entries.length
                                        ? ChatBubble(entry: _entries[i])
                                        : ChatBubble(
                                            entry: ChatEntry.model(
                                              text: _liveText,
                                            ),
                                            streaming: true,
                                          ),
                                  ),
                                ),
                              ),
                              JumpToLatestButton(
                                visible: !_autoScroll.isPinned,
                                color: accent,
                                onPressed: () => setState(_autoScroll.resume),
                              ),
                            ],
                          ),
                  ),
                  MessageComposer(
                    controller: _controller,
                    busy: _generating,
                    accent: accent,
                    hintText: 'Ask it to do something…',
                    busyHintText: 'Working…',
                    onSend: _send,
                    inset: inset,
                  ),
                ],
              ),
      ),
    );
  }
}

/// Live view of the state the tools mutate — the point being that the model
/// changed real app state, not just text.
class _TaskStrip extends StatelessWidget {
  const _TaskStrip({required this.workspace, required this.inset});

  final ToolWorkspace workspace;

  /// Matches the transcript's padding, so the chips start on the same line as
  /// the messages below them.
  final double inset;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(inset, 10, inset, 12),
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.checklist_rtl,
                size: 15,
                color: AppColors.textTertiary,
              ),
              Gap.wSm,
              Text(
                'Task list the model manages · '
                '${workspace.openCount} pending, '
                '${workspace.tasks.length} total',
                style: AppText.caption.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          Gap.sm,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final task in workspace.tasks)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (task.done
                                ? AppColors.textTertiary
                                : AppColors.accentBright)
                            .withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color:
                          (task.done
                                  ? AppColors.textTertiary
                                  : AppColors.accentBright)
                              .withValues(alpha: .32),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        task.done
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 14,
                        color: task.done
                            ? AppColors.success
                            : AppColors.accentBright,
                      ),
                      Gap.wSm,
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(
                          task.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: task.done
                                ? AppColors.textTertiary
                                : AppColors.textPrimary,
                            fontSize: 14,
                            decoration: task.done
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
