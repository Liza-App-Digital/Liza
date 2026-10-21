import 'package:matrix/matrix.dart';

/// `Room.leave()`, для которого «сервер не знает комнату» — успех.
///
/// На `M_NOT_FOUND`/`M_UNKNOWN` (Synapse: 404 «Not a known room» — комната-
/// призрак после отката сервера, заявка №55) SDK уже удалил комнату локально,
/// но всё равно пробрасывает ошибку: пользователь видел диалог ошибки и
/// оставался на экране удалённого чата.
Future<void> leaveRoomTolerant(Room room) async {
  try {
    await room.leave();
  } on MatrixException catch (e) {
    if (!isUnknownRoomLeaveError(e)) rethrow;
    Logs().w('[ghost-room] leave неизвестной серверу комнаты ${room.id}', e);
  }
}

bool isUnknownRoomLeaveError(MatrixException e) =>
    e.error == MatrixError.M_NOT_FOUND || e.error == MatrixError.M_UNKNOWN;
