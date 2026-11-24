import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/avatar_stats.dart';
import 'package:liza/utils/reader_profile_resolver.dart';
import 'package:liza/widgets/avatar.dart';

/// Аватарка читателя («прочитано до сюда», лист «кто прочитал»).
///
/// Читателя из `m.receipt` может не быть в room state (lazyLoadMembers): тогда
/// `User` приходит без аватарки и имени. Профиль догружаем здесь, а не при
/// расчёте квитанций (тот идёт на каждый rebuild списка). Участник в state —
/// источник истины, сеть не трогаем; если его миниатюра не загрузилась,
/// один раз сверяем профиль (мог смениться `avatar_url`).
///
/// Пока миниатюра грузится — рисуется буква (без промежуточной иконки).
/// Спека: docs/superpowers/specs/2026-11-23-reader-avatars-and-avatar-monitoring-design.md
/// ledger:RL-seen-by-strip-avatar-resolution
class ReaderAvatar extends StatefulWidget {
  final User user;
  final double size;
  final bool isHexagonal;
  const ReaderAvatar({
    required this.user,
    required this.size,
    this.isHexagonal = false,
    super.key,
  });

  @override
  State<ReaderAvatar> createState() => _ReaderAvatarState();
}

class _ReaderAvatarState extends State<ReaderAvatar> {
  bool get _inState =>
      widget.user.room.getState(EventTypes.RoomMember, widget.user.id) != null;

  ReaderProfileResolver get _resolver =>
      ReaderProfileResolver.of(widget.user.room.client);

  @override
  void initState() {
    super.initState();
    AvatarStats.instance.recordEvent(AvatarEvent.mounted);
    _ensure();
  }

  @override
  void didUpdateWidget(ReaderAvatar old) {
    super.didUpdateWidget(old);
    if (old.user.id != widget.user.id ||
        !identical(old.user.room.client, widget.user.room.client)) {
      _ensure();
    }
  }

  void _ensure() {
    if (!_inState) _resolver.ensure(widget.user.id);
  }

  void _onImageFailed(Uri? failedUrl) {
    AvatarStats.instance.recordEvent(AvatarEvent.letterKnownPhoto);
    _resolver.recheckAfterThumbFailure(widget.user.id, failedUrl);
  }

  Widget _avatar(Uri? avatarUrl, String name) => Avatar(
    mxContent: avatarUrl,
    name: name,
    size: widget.size,
    client: widget.user.room.client,
    isHexagonal: widget.isHexagonal,
    letterWhileLoading: true,
    onImageFailed: avatarUrl == null ? null : () => _onImageFailed(avatarUrl),
  );

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    // watch на каждый build: вытесненный из LRU notifier не оставляет виджет
    // подписанным на мёртвую запись.
    return ValueListenableBuilder<ReaderProfile?>(
      valueListenable: _resolver.watch(user.id),
      builder: (context, resolved, _) {
        final name = resolved?.displayName;
        return _avatar(
          resolved?.avatarUrl ?? user.avatarUrl,
          name != null && name.isNotEmpty ? name : user.calcDisplayname(),
        );
      },
    );
  }
}
