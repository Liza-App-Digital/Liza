import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Канал, которым родитель подаёт в [CodeInput] код извне (СМС от системы).
/// Код идёт тем же путём, что вставка из буфера, — второго пути заполнения
/// ячеек и второго источника `onCompleted` нет.
class CodeInputFeed {
  void Function(String code)? _sink;

  void push(String code) => _sink?.call(code);
}

/// Поле ввода кода: отдельные ячейки, автопереход, вставка из буфера.
class CodeInput extends StatefulWidget {
  const CodeInput({
    super.key,
    required this.length,
    required this.onCompleted,
    this.enabled = true,
    this.autofocus = true,
    this.feed,
  });

  final int length;
  final ValueChanged<String> onCompleted;
  final bool enabled;
  final bool autofocus;
  final CodeInputFeed? feed;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _nodes;

  /// Последний отданный наружу код: повторная доставка ТОГО ЖЕ кода
  /// (автозаполнение iOS + системный диалог Android) не шлёт второй запрос
  /// проверки. Другой код (правка цифры на месте, новая СМС после
  /// «Отправить повторно») отправляется сразу.
  String? _lastSubmitted;

  @override
  void initState() {
    super.initState();
    widget.feed?._sink = _applyPasted;
    _controllers = List.generate(widget.length, (_) => TextEditingController());
    _nodes = List.generate(widget.length, (_) => FocusNode());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled && widget.autofocus) {
        _nodes.first.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    if (widget.feed?._sink == _applyPasted) widget.feed?._sink = null;
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  String get _code => _controllers.map((c) => c.text).join();

  void _onChanged(int index, String value) {
    // Вставка целого кода из буфера/автозаполнения СМС.
    if (value.length > 1) {
      _applyPasted(value);
      return;
    }

    if (value.isNotEmpty && index < widget.length - 1) {
      _nodes[index + 1].requestFocus();
    }
    if (_code.length == widget.length) {
      _complete(_nodes[index]);
    } else {
      _lastSubmitted = null;
    }
    setState(() {});
  }

  void _applyPasted(String value) {
    if (!mounted) return;
    final digits = value.replaceAll(RegExp(r'\D'), '');
    for (var i = 0; i < widget.length; i++) {
      _controllers[i].text = i < digits.length ? digits[i] : '';
    }
    final filled = digits.length.clamp(0, widget.length);
    if (filled >= widget.length) {
      _complete(_nodes[widget.length - 1]);
    } else {
      _lastSubmitted = null;
      _nodes[filled].requestFocus();
    }
    setState(() {});
  }

  void _complete(FocusNode node) {
    node.unfocus();
    final code = _code;
    if (code == _lastSubmitted) return;
    _lastSubmitted = code;
    widget.onCompleted(code);
  }

  KeyEventResult _onKey(int index, KeyEvent event) {
    // Backspace в пустой ячейке возвращает курсор назад.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[index].text.isEmpty &&
        index > 0) {
      _controllers[index - 1].clear();
      _nodes[index - 1].requestFocus();
      setState(() {});
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AutofillGroup(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(widget.length, (index) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(
              width: 48,
              child: Focus(
                onKeyEvent: (_, event) => _onKey(index, event),
                child: TextField(
                  controller: _controllers[index],
                  focusNode: _nodes[index],
                  enabled: widget.enabled,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  // Подсказка кода из СМС (iOS «Из сообщений») — только у
                  // первой ячейки: на всех шести система предлагала бы код
                  // на каждой.
                  autofillHints: index == 0
                      ? const [AutofillHints.oneTimeCode]
                      : null,
                  style: theme.textTheme.headlineSmall,
                  decoration: InputDecoration(
                    counterText: '',
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (value) => _onChanged(index, value),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
