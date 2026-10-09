import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:image_picker/image_picker.dart';

import 'gemma_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _messages = <ChatMessage>[];
  final _picker = ImagePicker();

  Uint8List? _image;

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

  Future<void> _pickImage() async {
    // Desktop has no camera source, so fall back to the file picker.
    final isDesktop =
        !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
    final file = await _picker.pickImage(
      source: isDesktop ? ImageSource.gallery : ImageSource.camera,
      maxWidth: 1024,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => _image = bytes);
  }

  Future<void> _send() async {
    final chat = _chat;
    final image = _image;
    var text = _input.text.trim();
    if (chat == null || _busy || (text.isEmpty && image == null)) return;
    if (text.isEmpty) text = 'What do you see in this image?';

    _input.clear();
    final reply = ChatMessage(fromUser: false);
    setState(() {
      _busy = true;
      _image = null;
      _messages
        ..add(ChatMessage(fromUser: true, text: text, image: image))
        ..add(reply);
    });

    try {
      await chat.addQueryChunk(
        image == null
            ? Message.text(text: text, isUser: true)
            : Message.withImage(text: text, imageBytes: image, isUser: true),
      );
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
            if (_image != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    _image!,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            IconButton(
              onPressed: _busy ? null : _pickImage,
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
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
  ChatMessage({required this.fromUser, this.text = '', this.image});

  final bool fromUser;
  final Uint8List? image;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.image != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(message.image!, height: 180),
                  ),
                  const SizedBox(height: 8),
                ],
                Text(message.text.isEmpty ? '…' : message.text),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
