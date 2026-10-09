import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'gemma_service.dart';

/// What the model can ask the app to do. Each tool is a name, a description
/// the model reads, and a JSON Schema for its arguments.
const _tools = [
  Tool(
    name: 'add_task',
    description: 'Add a task to the to-do list.',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'What needs doing.'},
      },
      'required': ['title'],
    },
  ),
  Tool(
    name: 'list_tasks',
    description: 'Return every task on the to-do list.',
    // No arguments, but still a schema. Leaving parameters out makes
    // generation fail with "Failed to start streaming (code: 13)".
    parameters: {'type': 'object', 'properties': <String, dynamic>{}},
  ),
  Tool(
    name: 'set_color',
    description: 'Change the color of the app bar.',
    parameters: {
      'type': 'object',
      'properties': {
        'color': {
          'type': 'string',
          'enum': ['blue', 'red', 'yellow', 'green'],
        },
      },
      'required': ['color'],
    },
  ),
];

const _colors = {
  'blue': Color(0xFF1A73E8),
  'red': Color(0xFFD93025),
  'yellow': Color(0xFFF9AB00),
  'green': Color(0xFF1E8E3E),
};

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  final _input = TextEditingController();
  final _log = <String>[];
  final _tasks = <String>[];

  InferenceChat? _chat;
  Color? _barColor;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _openChat();
  }

  Future<void> _openChat() async {
    try {
      final model = await GemmaService.loadModel();
      final chat = await model.createChat(
        modelType: ModelType.gemma4,
        tools: _tools,
        supportsFunctionCalls: true,
        temperature: 0.7,
        topK: 40,
        topP: 0.9,
        systemInstruction:
            'You control a to-do app through tools. Always call a tool '
            'instead of describing what you would do. After a tool returns, '
            'confirm the result in one short English sentence.',
      );
      if (mounted) setState(() => _chat = chat);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Runs one tool call. Returns an error map instead of throwing, so the
  /// model sees what went wrong and can recover.
  Map<String, dynamic> _runTool(FunctionCallResponse call) {
    switch (call.name) {
      case 'add_task':
        final title = (call.args['title'] as String? ?? '').trim();
        if (title.isEmpty) return {'error': 'title is empty'};
        setState(() => _tasks.add(title));
        return {'added': title, 'count': _tasks.length};
      case 'list_tasks':
        return {'tasks': _tasks};
      case 'set_color':
        final color = _colors[call.args['color']];
        if (color == null) {
          return {'error': 'unknown color ${call.args['color']}'};
        }
        setState(() => _barColor = color);
        return {'color': call.args['color']};
      default:
        return {'error': 'no tool named ${call.name}'};
    }
  }

  Future<void> _send() async {
    final chat = _chat;
    final text = _input.text.trim();
    if (chat == null || _busy || text.isEmpty) return;

    _input.clear();
    setState(() {
      _busy = true;
      _log
        ..add('You: $text')
        ..add('');
    });

    try {
      await chat.addQueryChunk(Message.text(text: text, isUser: true));
      await for (final response in chat.generateChatResponseWithTools(
        onToolCall: (call) {
          setState(
            () => _log.insert(_log.length - 1, '→ ${call.name}(${call.args})'),
          );
          return _runTool(call);
        },
        maxToolTurns: 5,
        isCancelled: () => !mounted,
      )) {
        if (!mounted) return;
        if (response is TextResponse) {
          setState(() => _log.last += response.token);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _log.last = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _chat?.close();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tools'), backgroundColor: _barColor),
      body: Column(
        children: [
          if (_tasks.isNotEmpty)
            Card(
              margin: const EdgeInsets.all(12),
              child: Column(
                children: [
                  for (final task in _tasks)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.check_box_outline_blank),
                      title: Text(task),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!))
                : _chat == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final line in _log)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            line.isEmpty ? '…' : line,
                            style: line.startsWith('→')
                                ? const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                  )
                                : null,
                          ),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Add “buy milk” and make it green',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
