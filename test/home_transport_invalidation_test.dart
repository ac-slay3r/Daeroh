import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';

void main() {
  test('idle observer release publishes a typed local state', () {
    final chats = ActiveChatService();
    addTearDown(chats.dispose);

    chats.publishIdleObserverReleased();

    expect(
      chats.transportUpdate.value?.state,
      ChatTransportState.idleObserverReleased,
    );
  });
}
