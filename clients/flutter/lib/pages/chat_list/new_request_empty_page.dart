import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/composer_enter_key.dart';
import 'package:liza/utils/liza_new_request.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/update_read_only_bar.dart';

/// Правая панель на компьютере, когда чат не выбран (`/rooms` в column-mode):
/// вместо пустого силуэта — новый запрос к Лизе (задача 14, макет Надежды
/// «Какую задачу решим, Надежда?»). Отправка = «Новый запрос» с этим текстом
/// первым сообщением (`sendNewLizaRequest`).
class NewRequestEmptyPage extends StatefulWidget {
  const NewRequestEmptyPage({super.key});

  @override
  State<NewRequestEmptyPage> createState() => _NewRequestEmptyPageState();
}

/// Имя для заголовка: первое слово displayname. Email/MXID вместо имени и
/// пустое имя — заголовок без обращения.
@visibleForTesting
String? greetingFirstName(String? displayName) {
  final first = (displayName ?? '').trim().split(RegExp(r'\s+')).first;
  if (first.isEmpty || first.contains('@')) return null;
  return first;
}

@visibleForTesting
List<String> newRequestExamples(L10n l10n) => [
  l10n.newRequestExample1,
  l10n.newRequestExample2,
  l10n.newRequestExample3,
  l10n.newRequestExample4,
  l10n.newRequestExample5,
];

@visibleForTesting
List<String> newRequestPresets(L10n l10n) => [
  l10n.newRequestPreset1,
  l10n.newRequestPreset2,
  l10n.newRequestPreset3,
];

class _NewRequestEmptyPageState extends State<NewRequestEmptyPage> {
  static const double _maxWidth = 560;

  /// Морф «строка уезжает вниз, вопрос всплывает» (видео 23.10) — укладывается
  /// в создание комнаты (~1 с), переход его не ждёт.
  static const Duration _morph = Duration(milliseconds: 350);

  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onKeyEvent);

  bool _sending = false;

  // Вопрос в пузыре морфа. Живёт дольше `_sending`: после успеха панель
  // уходит под чат, и откат анимации был бы виден в кроссфейде. Сбрасывается
  // при ошибке или когда панель снова на экране.
  String? _morphText;
  bool _visible = true;

  // После успеха панель ещё ~300 мс на экране под кроссфейдом: свёрнутые
  // плашки и кнопка не должны принять второй запрос (Tab + Enter).
  bool get _busy => _sending || _morphText != null;

  // Профиль кэшируется на клиента: при смене аккаунта страница не
  // пересоздаётся, а запрос в build на каждый кадр недопустим.
  Client? _profileClient;
  Future<Profile>? _profile;

  Future<Profile>? _ownProfile(Client client) {
    if (!identical(client, _profileClient)) {
      _profileClient = client;
      _profile = client.userID == null ? null : client.fetchOwnProfile();
    }
    return _profile;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Панель снова на экране: Overlay вернул ей TickerMode, либо она снова
    // верхний маршрут — второе срабатывает и при «назад» посреди перехода,
    // когда панель ещё не успела уйти в offstage.
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (visible && !_visible && !_sending) _morphText = null;
    _visible = visible;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _controller.text).trim();
    if (_busy || text.isEmpty) return;
    if (blockedByUpdateReadOnly(context)) return;
    // Флаг — до первого await: Enter приходит в обход кнопки и раньше, чем
    // откроется барьер-диалог.
    setState(() {
      _sending = true;
      _morphText = text;
    });
    var opened = false;
    try {
      opened = await sendNewLizaRequest(context, text);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          if (!opened) {
            _morphText = null;
            // Плашка не трогала поле — при ошибке её текст встаёт в него,
            // но только в пустое: набранное человеком не затираем.
            if (preset != null && _controller.text.trim().isEmpty) {
              _controller.text = preset;
            }
          }
        });
      }
    }
    // Панель остаётся под открытым чатом в стеке /rooms — без очистки текст
    // встретил бы человека при возврате. При ошибке текст остаётся; набранное
    // до тапа по плашке — тоже.
    if (opened && mounted && preset == null) _controller.clear();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent evt) =>
      composerEnterKey(
        evt,
        _controller.value,
        isMobile: PlatformInfos.isMobile,
        onSend: _send,
      ) ??
      KeyEventResult.ignored;

  /// Блок, который при морфе гаснет и сворачивается вверх.
  Widget _collapsing({required bool hidden, required Widget child}) => ClipRect(
    child: AnimatedAlign(
      duration: _morph,
      curve: Curves.easeInOut,
      alignment: Alignment.bottomCenter,
      heightFactor: hidden ? 0 : 1,
      child: AnimatedOpacity(
        duration: _morph,
        opacity: hidden ? 0 : 1,
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final client = Matrix.of(context).client;
    final morphText = _morphText;
    final morphed = morphText != null;
    return Scaffold(
      // Невидимый appbar, как у EmptyPage: светлый статус-бар на Android-планшетах.
      appBar: AppBar(
        automaticallyImplyLeading: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: AnimatedAlign(
        duration: _morph,
        curve: Curves.easeInOut,
        alignment: morphed ? Alignment.bottomCenter : Alignment.center,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _collapsing(
                  hidden: morphed,
                  child: Column(
                    key: const Key('new_request_header'),
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          color: Colors.black,
                          padding: const EdgeInsets.all(8),
                          child: Image.asset(
                            'assets/logo.png',
                            width: 64,
                            height: 64,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      FutureBuilder<Profile>(
                        future: _ownProfile(client),
                        builder: (context, snapshot) {
                          final name = greetingFirstName(
                            snapshot.data?.displayName,
                          );
                          return Text(
                            name == null
                                ? l10n.newRequestGreetingNoName
                                : l10n.newRequestGreeting(name),
                            key: const Key('new_request_greeting'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.newRequestSubtitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
                _collapsing(
                  hidden: !morphed,
                  child: _questionBubble(theme, morphText ?? ''),
                ),
                ValueListenableBuilder<UpdatePolicy>(
                  valueListenable: UpdatePolicyController.current,
                  builder: (context, policy, _) => policy.readOnly
                      ? const UpdateReadOnlyBar()
                      : Column(
                          children: [
                            _composer(theme, l10n, morphed),
                            _collapsing(hidden: morphed, child: _presets(l10n)),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Вопрос справа в цветах своего сообщения — как он встанет в чате.
  Widget _questionBubble(ThemeData theme, String text) => Align(
    alignment: Alignment.centerRight,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16, left: 48),
      child: Container(
        key: const Key('new_request_bubble'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: theme.bubbleColor,
          borderRadius: BorderRadius.circular(AppConfig.borderRadius),
        ),
        child: Text(
          text,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.onBubbleColor,
          ),
        ),
      ),
    ),
  );

  Widget _presets(L10n l10n) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (i, preset) in newRequestPresets(l10n).indexed)
          ActionChip(
            key: Key('new_request_preset_$i'),
            label: Text(preset),
            onPressed: _busy ? null : () => _send(preset),
          ),
      ],
    ),
  );

  Widget _composer(ThemeData theme, L10n l10n, bool morphed) {
    final fieldStyle = theme.textTheme.bodyLarge;
    return AnimatedContainer(
      duration: _morph,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        // При морфе рамка гаснет — поле становится похоже на строку чата.
        borderRadius: BorderRadius.circular(morphed ? 28 : 20),
        border: Border.all(
          color: morphed
              ? theme.colorScheme.outlineVariant
              : theme.colorScheme.primary,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Stack(
              children: [
                Semantics(
                  hint: l10n.newRequestHint,
                  child: TextField(
                    key: const Key('new_request_field'),
                    controller: _controller,
                    focusNode: _focusNode,
                    readOnly: _busy,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: fieldStyle,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                // Подсказка — оверлеем: hintText перестраивал бы поле на
                // каждый символ.
                Positioned.fill(
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _controller,
                        builder: (context, value, _) {
                          final empty = value.text.isEmpty;
                          return Opacity(
                            // Opacity, а не if: состояние кругов не сбрасывается от набора.
                            opacity: empty && !morphed ? 1 : 0,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: NewRequestTypewriter(
                                examples: newRequestExamples(l10n),
                                active: empty && !_busy,
                                style: fieldStyle?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) => IconButton.filled(
              key: const Key('new_request_send'),
              tooltip: l10n.send,
              // Барьер-диалога больше нет: пока создаётся чат (~1 с), отклик — здесь.
              icon: _sending
                  ? const SizedBox.square(
                      key: Key('new_request_sending'),
                      dimension: 20,
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward),
              onPressed: _busy || value.text.trim().isEmpty ? null : _send,
            ),
          ),
        ],
      ),
    );
  }
}

/// Примеры запросов «печатаются» и стираются по кругу (видео 23.10: «как
/// будто они здесь автоматически вбиваются, стираются»).
///
/// AnimationController, а не Timer: под открытым чатом панель остаётся в
/// стеке, и Overlay глушит её тикеры — таймер крутился бы вхолостую. После
/// [loops] кругов встаёт на первом примере: бесконечная анимация вешает
/// `pumpAndSettle` интеграционных тестов на macOS. Новый показ панели
/// запускает круги заново.
class NewRequestTypewriter extends StatefulWidget {
  const NewRequestTypewriter({
    required this.examples,
    required this.active,
    this.style,
    super.key,
  });

  final List<String> examples;

  /// Поле пустое и запрос не отправляется.
  final bool active;
  final TextStyle? style;

  static const Duration typeStep = Duration(milliseconds: 45);
  static const Duration eraseStep = Duration(milliseconds: 25);
  static const Duration hold = Duration(milliseconds: 1600);
  static const Duration gap = Duration(milliseconds: 400);
  static const int loops = 2;

  static Duration cycleOf(String example) {
    final n = example.characters.length;
    return typeStep * n + hold + eraseStep * n + gap;
  }

  @override
  State<NewRequestTypewriter> createState() => _NewRequestTypewriterState();
}

class _NewRequestTypewriterState extends State<NewRequestTypewriter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this)
    ..addListener(_tick)
    ..addStatusListener(_onStatus);
  late final ValueNotifier<String> _shown = ValueNotifier(
    widget.examples.first,
  );

  int _index = 0;
  int _loopsLeft = NewRequestTypewriter.loops;
  bool _visible = true;

  bool get _done => _loopsLeft == 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_visible) _restart();
    _visible = visible;
    _sync();
  }

  @override
  void didUpdateWidget(NewRequestTypewriter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _anim.dispose();
    _shown.dispose();
    super.dispose();
  }

  void _restart() {
    _anim.stop();
    _index = 0;
    _loopsLeft = NewRequestTypewriter.loops;
  }

  void _sync() {
    final animate =
        widget.active && !_done && !MediaQuery.disableAnimationsOf(context);
    if (!animate) {
      _anim.stop();
      if (_done || MediaQuery.disableAnimationsOf(context)) {
        _shown.value = widget.examples.first;
      }
      return;
    }
    if (_anim.isAnimating) return;
    // Возобновление после паузы — с начала текущего примера.
    _anim.duration = NewRequestTypewriter.cycleOf(widget.examples[_index]);
    _anim.forward(from: 0);
  }

  void _tick() {
    final text = widget.examples[_index].characters;
    final n = text.length;
    final t = _anim.value * _anim.duration!.inMicroseconds;
    final typed = (NewRequestTypewriter.typeStep * n).inMicroseconds;
    final held = typed + NewRequestTypewriter.hold.inMicroseconds;
    final erased = held + (NewRequestTypewriter.eraseStep * n).inMicroseconds;
    final int visible;
    if (t < typed) {
      visible = (t / NewRequestTypewriter.typeStep.inMicroseconds).floor() + 1;
    } else if (t < held) {
      visible = n;
    } else if (t < erased) {
      visible =
          n -
          ((t - held) / NewRequestTypewriter.eraseStep.inMicroseconds).floor();
    } else {
      visible = 0;
    }
    _shown.value = text.take(visible.clamp(0, n)).toString();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _index = (_index + 1) % widget.examples.length;
    if (_index == 0) _loopsLeft--;
    _sync();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: _shown,
    builder: (context, text, _) => Text(
      text,
      key: const Key('new_request_typewriter'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    ),
  );
}
