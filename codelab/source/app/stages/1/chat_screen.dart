import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'gemma_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _messages = <ChatMessage>[];

  InferenceChat? _chat;
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
        // Without this the chat assumes an older Gemma prompt format.
        modelType: ModelType.gemma4,
        supportImage: true,
        temperature: 0.7,
        topK: 40,
        topP: 0.9,
        systemInstruction: GemmaService.chatInstruction,
      );
      if (mounted) setState(() => _chat = chat);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _send() async {
    final chat = _chat;
    final text = _input.text.trim();
    if (chat == null || _busy || text.isEmpty) return;

    _input.clear();
    final reply = ChatMessage(fromUser: false);
    setState(() {
      _busy = true;
      _messages
        ..add(ChatMessage(fromUser: true, text: text))
        ..add(reply);
    });

    try {
      await chat.addQueryChunk(Message.text(text: text, isUser: true));
      await for (final response in chat.generateChatResponseAsync()) {
        if (!mounted) return;
        if (response is TextResponse) {
          setState(() => reply.text += response.token);
        }
      }
    } catch (e) {
      if (mounted) setState(() => reply.text = 'Error: $e');
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
      appBar: AppBar(title: const Text('Chat')),
      body: Column(
        children: [
          Expanded(child: _buildMessages()),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildMessages() {
    if (_error != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      );
    }
    if (_chat == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length,
      itemBuilder: (_, i) => MessageBubble(message: _messages[i]),
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'Ask anything…',
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
    );
  }
}

class ChatMessage {
  ChatMessage({required this.fromUser, this.text = ''});

  final bool fromUser;
  String text;
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: message.fromUser
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          color: message.fromUser
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(message.text.isEmpty ? '…' : message.text),
          ),
        ),
      ),
    );
  }
}
