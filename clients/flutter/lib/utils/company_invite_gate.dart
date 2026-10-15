import 'package:flutter/material.dart';

import 'package:collection/collection.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/widgets/matrix.dart';

/// Гейт приглашений на инстансе-компании (задача 13, спека
/// 2026-10-14-search-sections-and-company-invite-admin-only).
///
/// Надежда: «если в настройках компании выбрано, что приглашать могут только
/// админы — значит, только админы … кнопка Пригласить висит у всех … если у
/// пользователя недостаточно прав — показывать плашку». Поэтому в пространствах
/// компании входы «Пригласить» видны всем, а право проверяется по факту
/// настройки — `Room.canInvite` (порог `invite` в power_levels), не по
/// константе. На общем инстансе (users.liza.ru, «компания сама по себе общая»)
/// и на старом сервере без поля `company` гейт молчит — поведение прежнее.

/// Top-level пространство, в иерархию которого входит [space] (среди комнат
/// клиента). Подпространство может жить на чужом домене (его создал участник
/// с другого инстанса), поэтому класс компании определяется по корню.
Room companyRootOf(Room space) {
  final rooms = space.client.rooms;
  var current = space;
  final seen = <String>{current.id};
  while (true) {
    final parent = rooms.firstWhereOrNull(
      (s) =>
          s.isSpace &&
          !seen.contains(s.id) &&
          s.spaceChildren.any((c) => c.roomId == current.id),
    );
    if (parent == null) return current;
    seen.add(parent.id);
    current = parent;
  }
}

String? _domainOf(String id) {
  final i = id.indexOf(':');
  return i < 0 ? null : id.substring(i + 1);
}

/// Пространство [space] — часть компании ЭТОГО инстанса: инстанс-компания и
/// корень иерархии на домене пользователя.
bool isOwnCompanySpace(Room space, {required bool companyInstance}) {
  if (!companyInstance || !space.isSpace) return false;
  final userId = space.client.userID;
  if (userId == null) return false;
  final rootDomain = _domainOf(companyRootOf(space).id);
  return rootDomain != null && rootDomain == _domainOf(userId);
}

/// Чистая таблица: приглашение надо отклонить плашкой.
bool companyInviteBlocked({
  required bool companySpace,
  required bool canInvite,
}) => companySpace && !canInvite;

void showInviteNotAllowed(BuildContext context) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(L10n.of(context).inviteNotAllowed)));
}

/// Вход «Пригласить» в пространство [room]: показывать ли его. В компании —
/// всем ([isOwnCompanySpace]); иначе решает прежний гейт [legacyVisible].
bool companyInviteEntryVisible(
  BuildContext context,
  Room room, {
  required bool legacyVisible,
}) =>
    legacyVisible ||
    isOwnCompanySpace(
      room,
      companyInstance: Matrix.of(context).singleSpaceService.isCompanyInstance,
    );

/// Перед приглашением в пространство [room]: false + плашка, если это
/// пространство компании и у пользователя нет права `invite`.
bool ensureCanInviteToSpace(BuildContext context, Room room) {
  final companySpace = isOwnCompanySpace(
    room,
    companyInstance: Matrix.of(context).singleSpaceService.isCompanyInstance,
  );
  if (!companyInviteBlocked(
    companySpace: companySpace,
    canInvite: room.canInvite,
  )) {
    return true;
  }
  showInviteNotAllowed(context);
  return false;
}

/// Перед приглашением в Лизу (ссылка регистрации): на инстансе-компании
/// регистрация по ссылке автоматически вводит в компанию, поэтому право
/// проверяется по главному пространству. Главное пространство ещё не
/// известно клиенту — не блокируем (сервер перепроверит).
bool ensureCanInviteToLiza(BuildContext context) {
  final service = Matrix.of(context).singleSpaceService;
  final client = Matrix.of(context).client;
  final mainRoom = mainCompanyRoom(service, client);
  if (mainRoom == null) return true;
  if (!companyInviteBlocked(
    companySpace: true,
    canInvite: mainRoom.canInvite,
  )) {
    return true;
  }
  showInviteNotAllowed(context);
  return false;
}

/// Главное пространство инстанса-компании среди комнат [client], либо null.
Room? mainCompanyRoom(SingleSpaceService service, Client client) {
  if (!service.isCompanyInstance) return null;
  final mainId = service.mainRootSpaceId;
  if (mainId == null) return null;
  return client.getRoomById(mainId);
}
