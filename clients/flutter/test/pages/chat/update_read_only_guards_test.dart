// ledger:RL-force-update-staged-policy
//
// Режим чтения обязательного обновления держится ОДНОЙ проверкой в начале
// каждого действия ChatController, которое пишет в комнату. Поднять полный
// ChatPage в widget-тесте здесь нельзя (Matrix, timeline, go_router), поэтому
// страж — по исходнику: удалённая или забытая проверка краснит тест.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _guardedActions = [
  'Future<void> send() async {',
  'Future<void> addChannelStory() async {',
  'void sendFileAction({FileType type = FileType.any}) async {',
  'void sendFileSourceAction() async {',
  'void openGalleryAction() async {',
  'void openCameraAction() async {',
  'void sendLocationAction() async {',
  'void redactEventsAction() async {',
  'void forwardEventsAction() async {',
  'void sendAgainAction() {',
  'void replyAction({Event? replyTo}) {',
  'void editSelectedEventAction() {',
  'void editEventAction(Event event) {',
  'void replyToEvent(Event event) {',
  'Future<void> forwardEvent(Event event) async {',
  'Future<void> redactEvent(Event event) async {',
  'void resendEvent(Event event) {',
  'void togglePinEvent(Event event) {',
  'void toggleReaction(Event event, String emoji) {',
  'void pinEvent() {',
  'void unpinEvent(String eventId) async {',
  'void onPhoneButtonTap() async {',
  'void onDragDone(DropDoneDetails details) async {',
  'void _shareItems([dynamic _]) {',
];

void main() {
  final chat = File('lib/pages/chat/chat.dart').readAsStringSync();

  // AC:RL-force-update-staged-policy/10
  for (final signature in _guardedActions) {
    test('действие начинается с проверки режима чтения: $signature', () {
      final at = chat.indexOf('  $signature\n');
      expect(at, isNot(-1), reason: 'сигнатура не найдена — обнови список');
      // Проверка — среди первых строк тела (раньше неё могут стоять только
      // другие гейты-отказы вроде isContentProtected), до любого действия.
      final head = chat
          .substring(at + signature.length + 3)
          .split('\n')
          .take(4)
          .map((l) => l.trim())
          .toList();
      expect(head, contains('if (_blockedByUpdate()) return;'));
    });
  }

  test('вставка картинки и голосовое отбиваются', () {
    for (final (signature, guard) in [
      (
        'Future<bool> handleImagePaste() async {',
        'if (_blockedByUpdate()) return true;',
      ),
      ('Future<void> onVoiceMessageSend(', 'if (_blockedByUpdate()) return;'),
    ]) {
      final body = chat.substring(chat.indexOf(signature));
      final end = body.indexOf('\n  }\n');
      expect(
        body.substring(0, end).split('\n').take(9).join('\n'),
        contains(guard),
      );
    }
  });

  // AC:RL-force-update-staged-policy/11
  test('send() проверяет режим ДО удаления черновика', () {
    final body = chat.substring(chat.indexOf('  Future<void> send() async {'));
    expect(
      body.indexOf('_blockedByUpdate()'),
      lessThan(body.indexOf("prefs.remove('draft_\$roomId')")),
    );
  });

  test('композер заменяется плашкой в режиме чтения', () {
    final view = File('lib/pages/chat/chat_view.dart').readAsStringSync();
    expect(view, contains('showUpdateReadOnlyBar(controller.room)'));
    expect(view, contains('const UpdateReadOnlyBar()'));
    // Ветка режима чтения стоит ПЕРЕД веткой композера, иначе не сработает.
    expect(
      view.indexOf('showUpdateReadOnlyBar(controller.room)'),
      lessThan(view.indexOf('controller.room.canSendDefaultMessages &&')),
    );
  });

  test('быстрый ответ из шторки в режиме чтения уходит в черновик', () {
    final handler = File(
      'lib/utils/notification_background_handler.dart',
    ).readAsStringSync();
    final guard = handler.indexOf('UpdatePolicyController.readOnlyAnywhere(');
    expect(guard, isNot(-1));
    expect(guard, lessThan(handler.indexOf('room.sendTextEvent(')));
  });

  test('в режиме чтения кнопки «Ответить» в пуше нет', () {
    final push = File('lib/utils/push_helper.dart').readAsStringSync();
    final guard = push.indexOf('if (!updateReadOnly)');
    expect(guard, isNot(-1));
    expect(
      push.indexOf('LizaNotificationActions.reply.name', guard) - guard,
      lessThan(120),
    );
  });

  test('шаринг в Liza в режиме чтения отбивается', () {
    final list = File('lib/pages/chat_list/chat_list.dart').readAsStringSync();
    final guard = list.indexOf('blockedByUpdateReadOnly(context)');
    expect(guard, isNot(-1));
    expect(guard, lessThan(list.indexOf('ShareScaffoldDialog(')));
  });

  // AC:RL-force-update-staged-policy/12
  test('на web, в debug и на локальном стеке политика не применяется', () {
    final matrix = File('lib/widgets/matrix.dart').readAsStringSync();
    expect(
      matrix,
      contains(
        '!kIsWeb &&\n      (_forceUpdatePolicy || (!kDebugMode && !AppConfig.isLocal))',
      ),
    );
    expect(matrix, contains('if (!updatePolicyEnabled) return;'));
    final service = File(
      'lib/utils/version_gate_service.dart',
    ).readAsStringSync();
    final fetch = service.substring(service.indexOf('fetchPolicy() async {'));
    expect(fetch.split('\n')[1].trim(), 'if (kIsWeb) return null;');
  });
}
