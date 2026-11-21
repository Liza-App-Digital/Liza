import 'package:matrix/matrix.dart';

/// State-событие комнаты-запроса к Лизе («+» → «Новый запрос»). Ставится в
/// `initialState` при создании; `placeholder` — начальное имя комнаты: бот
/// переименует комнату в «Liza: <суть>» только пока имя равно ему.
/// Тип внесён в `importantStateEvents` (client_manager.dart) — иначе после
/// холодного старта partial-комната вернула бы getState=null.
const String lizaRequestStateType = 'com.liza.assistant.request';

/// Комната — отдельный запрос к Лизе, а не её основной чат.
bool isLizaRequestRoom(Room room) =>
    room.getState(lizaRequestStateType) != null;
