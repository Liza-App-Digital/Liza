import 'package:matrix/matrix.dart';

/// Готовит `content` для ПЕРЕСЫЛКИ сообщения (LABA-1991).
///
/// Единая точка для всех путей форварда (контекстное меню, мультивыбор, просмотр
/// изображения) — чтобы пометка «Переслано [от X]» ставилась одинаково везде, а не
/// только из одного места. Делает три вещи:
///  1. снимает НЕЗАВИСИМУЮ копию content (исходное событие таймлайна не трогаем);
///  2. убирает `m.relates_to` — reply-связь на событие, которого нет в комнате
///     назначения, иначе SDK нарисует висячую цитату;
///  3. кладёт маркер `com.liza.forwarded` со снимком имени автора, резолвленным
///     СЕЙЧАС на форвардере (`mxidLocalPartFallback: false` → пусто вместо
///     «User Xf12»). Имя резолвим ЗАЩИЩЁННО: сбой `fetchSenderUser` (ушёл автор,
///     нет сети) не должен ломать пересылку — деградируем в маркер без имени, и
///     получатель увидит честное «Переслано».
///
/// [event] ожидается уже как display-событие (`getDisplayEvent`), если у вызова
/// есть timeline; для просмотрщика изображений — как есть.
Future<Map<String, Object?>> buildForwardedContent(Event event) async {
  final content = Map<String, Object?>.from(event.content);
  content.remove('m.relates_to');
  // Пересылка никого не пингует (как в Telegram): чужой m.mentions (вкл. room:true)
  // повторно подсветил бы упомянутых в оригинале. Пустой ключ — явное «никого»
  // и заодно выключает легаси-подсветку по имени (MSC3952/MSC4210).
  content['m.mentions'] = <String, Object?>{};
  content.remove('m.new_content');
  String? fromName;
  try {
    final sender = await event.fetchSenderUser();
    fromName = sender?.calcDisplayname(mxidLocalPartFallback: false);
  } catch (_) {
    fromName = null;
  }
  content['com.liza.forwarded'] = <String, Object?>{
    if (fromName != null && fromName.isNotEmpty) 'from_name': fromName,
  };
  return content;
}
