/// Недоверенный JSON не превращается в управляющие действия через toString().
class BotKeyboardButton {
  final String text;
  final String action;
  final Map<String, dynamic>? parameters;
  const BotKeyboardButton(this.text, this.action, [this.parameters]);

  static BotKeyboardButton? parse(Object? raw) {
    if (raw is String) {
      return raw.isNotEmpty && raw.length <= 256
          ? BotKeyboardButton(raw, 'text')
          : null;
    }
    if (raw is! Map || raw['text'] is! String) return null;
    final text = raw['text'] as String;
    if (text.isEmpty || text.length > 256) return null;
    const actions = {
      'request_contact',
      'request_location',
      'web_app',
      'request_users',
      'request_chat',
    };
    if (raw.keys.any((key) => key != 'text' && !actions.contains(key))) {
      return null;
    }
    final used = actions.where(raw.containsKey).toList();
    if (used.length > 1) return null;
    if (used.isEmpty) return BotKeyboardButton(text, 'text');
    final action = used.single;
    final value = raw[action];
    if (action == 'request_contact' || action == 'request_location') {
      return value == true ? BotKeyboardButton(text, action) : null;
    }
    if (value is! Map<String, dynamic>) return null;
    if (action == 'web_app' && (value.length != 1 || value['url'] is! String)) {
      return null;
    }
    return BotKeyboardButton(text, action, Map.of(value));
  }
}

class BotReplyMarkup {
  final List<List<BotKeyboardButton>> rows;
  final bool remove;
  final bool forceReply;
  final bool oneTime;
  final bool selective;
  const BotReplyMarkup._({
    this.rows = const [],
    this.remove = false,
    this.forceReply = false,
    this.oneTime = false,
    this.selective = false,
  });

  static BotReplyMarkup? parse(Object? raw) {
    if (raw is! Map) return null;
    const allowed = {
      'keyboard',
      'inline_keyboard',
      'remove_keyboard',
      'force_reply',
      'selective',
      'one_time_keyboard',
      'resize_keyboard',
      'is_persistent',
      'input_field_placeholder',
    };
    if (raw.keys.any((key) => !allowed.contains(key))) return null;
    for (final key in [
      'remove_keyboard',
      'force_reply',
      'selective',
      'one_time_keyboard',
      'resize_keyboard',
      'is_persistent',
    ]) {
      if (raw.containsKey(key) && raw[key] is! bool) return null;
    }
    if (raw.containsKey('keyboard') && raw.containsKey('inline_keyboard')) {
      return null;
    }
    if (raw['remove_keyboard'] == true &&
        (raw.containsKey('keyboard') ||
            raw.containsKey('inline_keyboard') ||
            raw['force_reply'] == true)) {
      return null;
    }
    if (raw['remove_keyboard'] == true) {
      return BotReplyMarkup._(
        remove: true,
        selective: raw['selective'] == true,
      );
    }
    if (raw['force_reply'] == true && !raw.containsKey('keyboard')) {
      return BotReplyMarkup._(
        forceReply: true,
        selective: raw['selective'] == true,
      );
    }
    final keyboard = raw['keyboard'];
    if (keyboard is! List || keyboard.isEmpty || keyboard.length > 20) {
      return null;
    }
    final rows = <List<BotKeyboardButton>>[];
    var count = 0;
    for (final row in keyboard) {
      if (row is! List || row.isEmpty || row.length > 8) return null;
      final buttons = <BotKeyboardButton>[];
      for (final rawButton in row) {
        final button = BotKeyboardButton.parse(rawButton);
        if (button == null || ++count > 160) return null;
        buttons.add(button);
      }
      rows.add(buttons);
    }
    return BotReplyMarkup._(
      rows: rows,
      oneTime: raw['one_time_keyboard'] == true,
      forceReply: raw['force_reply'] == true,
      selective: raw['selective'] == true,
    );
  }
}
