import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';

/// Только данные представления. Произвольный user_id в карточке контакта
/// никогда не становится Matrix-пользователем или действием навигации.
class BotContact {
  final String phone;
  final String firstName;
  final String? lastName;
  const BotContact(this.phone, this.firstName, this.lastName);

  static BotContact? parse(Object? value) {
    if (value is! Map) return null;
    final phone = value['phone_number'];
    final first = value['first_name'];
    final last = value['last_name'];
    final vcard = value['vcard'];
    bool valid(Object? v, int limit) =>
        v is String && v.trim().isNotEmpty && v.length <= limit;
    if (!valid(phone, 256) ||
        !valid(first, 256) ||
        (last != null && !valid(last, 256)) ||
        (vcard != null && !valid(vcard, 2048))) {
      return null;
    }
    return BotContact(phone as String, first as String, last as String?);
  }
}

class BotDice {
  final String emoji;
  final int value;
  const BotDice(this.emoji, this.value);
  static const ranges = {'🎲': 6, '🎯': 6, '🏀': 5, '⚽': 5, '🎳': 6, '🎰': 64};

  static BotDice? parse(Object? data) {
    if (data is! Map) return null;
    final emoji = data['emoji'];
    final value = data['value'];
    final max = ranges[emoji];
    if (emoji is! String ||
        value is! int ||
        max == null ||
        value < 1 ||
        value > max) {
      return null;
    }
    return BotDice(emoji, value);
  }
}

class BotVideoNote {
  final int duration;
  final int length;
  const BotVideoNote(this.duration, this.length);
  static BotVideoNote? parse(Event event) {
    final data = event.content['com.liza.video_note'];
    if (event.messageType != MessageTypes.Video ||
        data is! Map ||
        !_mxc(event.content['url'])) {
      return null;
    }
    final duration = data['duration'];
    final length = data['length'];
    if (duration is! int ||
        duration < 1 ||
        duration > 60 ||
        length is! int ||
        length < 1 ||
        length > 4096) {
      return null;
    }
    final info = event.content['info'];
    if (info is! Map || info['w'] != length || info['h'] != length) return null;
    return BotVideoNote(duration, length);
  }
}

class BotLivePhoto {
  final int duration;
  final Uri cover;
  const BotLivePhoto(this.duration, this.cover);
  static BotLivePhoto? parse(Event event) {
    final data = event.content['com.liza.live_photo'];
    if (event.messageType != MessageTypes.Video ||
        data is! Map ||
        !_mxc(event.content['url'])) {
      return null;
    }
    final duration = data['duration'];
    final cover = data['cover'];
    if (duration is! int ||
        duration < 1 ||
        duration > 10 ||
        cover is! Map ||
        !_mxc(cover['url'])) {
      return null;
    }
    final info = cover['info'];
    if (info is! Map ||
        !{'image/jpeg', 'image/png'}.contains(info['mimetype']) ||
        info['w'] is! int ||
        (info['w'] as int) <= 0 ||
        info['h'] is! int ||
        (info['h'] as int) <= 0) {
      return null;
    }
    return BotLivePhoto(duration, Uri.parse(cover['url'] as String));
  }
}

bool _mxc(Object? value) {
  if (value is! String) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'mxc' &&
      uri.host.isNotEmpty &&
      uri.pathSegments.length == 1 &&
      uri.pathSegments.single.isNotEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.userInfo.isEmpty;
}

class BotDraft {
  final int id;
  final bool canStop;
  final bool keepOnStop;
  const BotDraft(this.id, this.canStop, this.keepOnStop);

  static BotDraft? parse(Object? value) {
    if (value is! Map) return null;
    final id = value['draft_id'];
    final canStop = value['can_stop'];
    final keep = value['keep_on_stop'];
    if (id is! int || id == 0 || canStop is! bool || keep is! bool) return null;
    return BotDraft(id, canStop, keep);
  }
}

/// Текущий display-контент определяет индикатор, исходное событие — provenance.
/// Обычная финальная правка без draft metadata больше не выглядит черновиком.
bool isBotDraft(Event original, Event display) =>
    BotDraft.parse(display.content['com.liza.draft']) != null;

class BotContactContent extends StatelessWidget {
  final BotContact contact;
  final Color color;
  const BotContactContent({
    required this.contact,
    required this.color,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.contact_phone_outlined, color: color, size: 36),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                L10n.of(context).botContact,
                style: TextStyle(color: color, fontSize: 12),
              ),
              Text(
                [
                  contact.firstName,
                  contact.lastName,
                ].whereType<String>().join(' '),
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
              Text(contact.phone, style: TextStyle(color: color)),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Никакой локальной случайности или повторного броска при rebuild.
class BotDiceContent extends StatelessWidget {
  final BotDice dice;
  final Color color;
  const BotDiceContent({required this.dice, required this.color, super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(dice.emoji, style: const TextStyle(fontSize: 40)),
        const SizedBox(width: 16),
        Text(
          '${dice.value}',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    ),
  );
}
