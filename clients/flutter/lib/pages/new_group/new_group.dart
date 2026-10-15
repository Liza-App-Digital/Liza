import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/new_group/new_group_view.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/create_group_in_space.dart';
import 'package:liza/utils/file_selector.dart';
import 'package:liza/utils/wait_for_room_in_sync.dart';
import 'package:liza/widgets/matrix.dart';

class NewGroup extends StatefulWidget {
  final CreateGroupType createGroupType;
  const NewGroup({this.createGroupType = CreateGroupType.group, super.key});

  @override
  NewGroupController createState() => NewGroupController();
}

class NewGroupController extends State<NewGroup> {
  TextEditingController nameController = TextEditingController();

  // Компания/пространство создаётся ПРИВАТНОЙ по умолчанию (visibility:private):
  // публичность — сознательный опт-ин через свитч «Публичная компания», а не
  // дефолт. Раньше initState форсил publicGroup=true для space → все компании
  // рождались публичными и утекали в федеративный поиск.
  // См. docs/superpowers/specs/2026-08-25-companies-private-by-default-design.md.
  bool publicGroup = false;
  bool groupCanBeFound = false;
  bool enableEncryption = false;

  Uint8List? avatar;

  Uri? avatarUrl;

  Object? error;

  bool loading = false;

  CreateGroupType get createGroupType => widget.createGroupType;

  /// Места для «Где создать» (задача 10 newInterface). Считаются один раз:
  /// sync, убравший выбранное место, иначе молча сбросил бы выбор в
  /// «Автоматически», и группа ушла бы не туда. Право на месте всё равно
  /// проверит сервер на PUT `m.space.child` (провал → leave+forget и ошибка).
  List<GroupPlace> places = const [];

  /// Выбранное место; `null` — «Автоматически», поведение как до выбора.
  GroupPlace? place;

  /// Выбор показывается, только если есть из чего выбирать.
  bool get showPlacePicker =>
      createGroupType == CreateGroupType.group && places.length > 1;

  @override
  void initState() {
    super.initState();
    if (createGroupType == CreateGroupType.group) {
      places = groupPlaces(Matrix.of(context).client.rooms);
    }
  }

  /// Группа компании всегда приватная (`invite` + `invite:50`, задача 00), и
  /// никаких `restricted`-правил к чужому пространству (LABA-2539): публичность
  /// при выбранном месте сбрасывается, а свитчи скрываются.
  void setPlace(GroupPlace? p) => setState(() {
    place = p;
    if (p != null) publicGroup = groupCanBeFound = false;
  });

  void setPublicGroup(bool b) => setState(() {
    publicGroup = groupCanBeFound = b;
    if (b) enableEncryption = false;
  });

  void setGroupCanBeFound(bool b) => setState(() => groupCanBeFound = b);

  void setEnableEncryption(bool b) => setState(() => enableEncryption = b);

  void selectPhoto() async {
    final photo = await selectFiles(
      context,
      type: FileType.image,
      allowMultiple: false,
    );
    final bytes = await photo.singleOrNull?.readAsBytes();

    setState(() {
      avatarUrl = null;
      avatar = bytes;
    });
  }

  Future<void> _createGroup() async {
    if (!mounted) return;
    final place = this.place;
    if (place != null) {
      final client = Matrix.of(context).client;
      final roomId = await createGroupInSpace(
        space: place.space,
        name: nameController.text.trim(),
        avatarUrl: avatar == null ? null : avatarUrl,
        enableEncryption: enableEncryption,
      );
      // createGroupInSpace не ждёт sync, а экрану /invite комната нужна в клиенте.
      await waitForRoomInSync(client, roomId);
      if (!mounted) return;
      context.go('/rooms/$roomId/invite');
      return;
    }
    final roomId = await Matrix.of(context).client.createGroupChat(
      enableEncryption: enableEncryption,
      visibility: groupCanBeFound
          ? sdk.Visibility.public
          : sdk.Visibility.private,
      preset: publicGroup
          ? sdk.CreateRoomPreset.publicChat
          : sdk.CreateRoomPreset.privateChat,
      // Приглашать может только модератор+ (invite:50). Иначе приватная группа
      // наследует preset invite:0 и любой участник приглашает посторонних.
      powerLevelContentOverride: groupPowerLevelOverride(),
      groupName: nameController.text.trim(),
      initialState: [
        if (avatar != null)
          sdk.StateEvent(
            type: sdk.EventTypes.RoomAvatar,
            content: {'url': avatarUrl.toString()},
          ),
      ],
    );
    if (!mounted) return;
    context.go('/rooms/$roomId/invite');
  }

  Future<void> _createChannel() async {
    if (!mounted) return;
    final roomId = await Matrix.of(context).client.createRoom(
      preset: publicGroup
          ? sdk.CreateRoomPreset.publicChat
          : sdk.CreateRoomPreset.privateChat,
      creationContent: {'com.liza.chat.type': 'channel'},
      visibility: publicGroup ? sdk.Visibility.public : sdk.Visibility.private,
      roomAliasName: publicGroup
          ? nameController.text.trim().toLowerCase().replaceAll(' ', '_')
          : null,
      name: nameController.text.trim(),
      powerLevelContentOverride: channelPowerLevelOverride(),
      initialState: [
        if (avatar != null)
          sdk.StateEvent(
            type: sdk.EventTypes.RoomAvatar,
            content: {'url': avatarUrl.toString()},
          ),
        if (!publicGroup)
          sdk.StateEvent(
            type: sdk.EventTypes.RoomJoinRules,
            content: {'join_rule': 'invite'},
          ),
        // Открытый канал читается БЕЗ вступления (как в Liza): пресет
        // publicChat даёт history_visibility=shared, при котором Synapse
        // отвечает 403 «room previews are disabled» неучастнику, и клиенту
        // приходилось джойнить комнату только чтобы показать ленту — канал
        // сразу попадал в список чатов, хотя на него не подписывались.
        // Закрытый канал видимость не меняет: его контент не публичен.
        if (publicGroup)
          sdk.StateEvent(
            type: sdk.EventTypes.HistoryVisibility,
            content: {'history_visibility': 'world_readable'},
          ),
      ],
    );
    // createRoom возвращает успех сразу после записи на сервере, но
    // getRoomById видит комнату только после /sync — без ожидания переход
    // натыкается на room==null (ChatPage: "вы больше не участвуете в чате").
    await waitForRoomInSync(Matrix.of(context).client, roomId);
    if (!mounted) return;
    context.go('/rooms/$roomId');
  }

  Future<void> _createSpace() async {
    if (!mounted) return;
    final spaceId = await Matrix.of(context).client.createRoom(
      preset: publicGroup
          ? sdk.CreateRoomPreset.publicChat
          : sdk.CreateRoomPreset.privateChat,
      creationContent: {'type': RoomCreationTypes.mSpace},
      visibility: publicGroup ? sdk.Visibility.public : sdk.Visibility.private,
      roomAliasName: publicGroup
          ? nameController.text.trim().toLowerCase().replaceAll(' ', '_')
          : null,
      name: nameController.text.trim(),
      powerLevelContentOverride: spacePowerLevelOverride(
        companyInstance: Matrix.of(
          context,
        ).singleSpaceService.isCompanyInstance,
      ),
      initialState: [
        if (avatar != null)
          sdk.StateEvent(
            type: sdk.EventTypes.RoomAvatar,
            content: {'url': avatarUrl.toString()},
          ),
        if (!publicGroup)
          sdk.StateEvent(
            type: sdk.EventTypes.RoomJoinRules,
            content: {'join_rule': 'invite'},
          ),
      ],
    );
    if (!mounted) return;
    context.pop<String>(spaceId);
  }

  void submitAction([dynamic _]) async {
    // Второй тап до перерисовки (кнопка ещё активна) создал бы вторую группу.
    if (loading) return;
    final client = Matrix.of(context).client;

    try {
      // Пустое имя недопустимо ни для одного типа. У публичного канала alias
      // выводится из имени (_createChannel), а Synapse пустой localpart НЕ
      // отвергает (handlers/room.py) — первый такой канал МОЛЧА получает
      // мусорный alias «#:<домен>» в директории, второй падает с M_ROOM_IN_USE
      // «Room alias already taken» сырой английской строкой.
      // Группа (LABA-2630): _createGroup создаёт комнату БЕЗ invite — участники
      // добавляются позже на /invite, — поэтому без имени heroes пусты и SDK
      // называет её «Пустой чат».
      if (nameController.text.trim().isEmpty) {
        setState(() => error = L10n.of(context).pleaseEnterAName);
        return;
      }

      setState(() {
        loading = true;
        error = null;
      });

      final avatar = this.avatar;
      avatarUrl ??= avatar == null ? null : await client.uploadContent(avatar);

      if (!mounted) return;

      switch (createGroupType) {
        case CreateGroupType.group:
          await _createGroup();
        case CreateGroupType.space:
          await _createSpace();
        case CreateGroupType.channel:
          await _createChannel();
      }
    } catch (e, s) {
      sdk.Logs().d('Unable to create group', e, s);
      setState(() {
        error = e;
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => NewGroupView(this);
}

enum CreateGroupType { group, space, channel }
