import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_vision_demo/gemma/gemma_service.dart';

void main() {
  group('which session a chat gets', () {
    // The `.litertlm` engine replays a concurrent session's history as text
    // when it switches between them, so those sessions reject anything that
    // isn't text: "Image/audio input is not supported on concurrent
    // (openSession) .litertlm sessions." A chat that carries media has to own
    // the model's primary session instead.
    test('text-only chats stay on their own concurrent session', () {
      expect(
        GemmaService.needsPrimarySession(
          supportImage: false,
          supportAudio: false,
        ),
        isFalse,
      );
    });

    test('a chat that takes images needs the primary session', () {
      expect(
        GemmaService.needsPrimarySession(
          supportImage: true,
          supportAudio: false,
        ),
        isTrue,
      );
    });

    test('a chat that takes audio needs it just as much', () {
      expect(
        GemmaService.needsPrimarySession(
          supportImage: false,
          supportAudio: true,
        ),
        isTrue,
      );
    });
  });
}
