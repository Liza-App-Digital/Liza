/// State-событие комнаты, которым клиент сообщает боту поддержки, ЗАЧЕМ открыт
/// чат. Новый DM получает его в `initial_state`, существующий — `PUT /state` с
/// новым `ts` (Synapse не создаёт событие при идентичном контенте). Бот читает
/// state после join и ловит его в sync, отвечает карточкой вместо «Добрый день».
/// В ленте не виден: неизвестные типы скрыты (`isKnownHiddenStates`), в превью
/// списка чатов попадают только `roomPreviewLastEvents`.
const supportIntentStateType = 'com.liza.support.intent';

/// Намерение, с которым пользователь пришёл в поддержку.
enum SupportIntent {
  /// «Создать компанию» → «Оставить заявку» в попапе (rail-«+», плашка на чипе
  /// «Компании»). `next: request` — бот пропускает вступление (его пользователь
  /// уже прочитал в попапе) и сразу просит описать заявку. Старый бот поле
  /// игнорирует и присылает вступление с карточкой.
  createCompanyRequest('create_company', next: 'request'),

  /// «Создать компанию» → «Узнать подробности» в том же попапе. `next: question`
  /// — бот ставит подтему «Вопрос» и просит описать вопрос, вступление не
  /// повторяет; заявка появится, только если пользователь сам нажмёт
  /// «Отправить». Бот без поддержки `question` присылает вступление с карточкой.
  createCompanyQuestion('create_company', next: 'question');

  const SupportIntent(this.wireValue, {this.next});

  /// Значение `content.intent` — контракт с `servers/liza-bot-api/support`.
  final String wireValue;

  /// Значение `content.next` — шаг, с которого бот начинает сценарий.
  final String? next;

  Map<String, Object?> get content => {
    'intent': wireValue,
    if (next != null) 'next': next,
    'ts': DateTime.now().millisecondsSinceEpoch,
  };
}
