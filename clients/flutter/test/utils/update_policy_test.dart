// ledger:RL-force-update-staged-policy
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/update_policy.dart';

final _serverNow = DateTime.utc(2026, 11, 2, 12);

UpdatePolicy _policy(UpdateStage stage, {int maxPostpones = 3}) => UpdatePolicy(
  stage: stage,
  latestBuild: 3780,
  updateUrl: 'itms-beta://',
  announceAt: DateTime.utc(2026, 10, 25),
  softAt: DateTime.utc(2026, 11, 1),
  deadlineAt: DateTime.utc(2026, 11, 8),
  serverNow: _serverNow,
  maxPostpones: maxPostpones,
);

void main() {
  late DateTime local;
  late SharedPreferences prefs;

  Future<UpdatePolicyController> controller() async =>
      UpdatePolicyController(prefs, clock: () => local);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // Часы устройства намеренно НЕ совпадают с серверными.
    local = DateTime(2030, 1, 1, 9);
    UpdatePolicyController.current.value = UpdatePolicy.none;
  });

  test('fromJson: неизвестный этап — none, даты в UTC', () {
    final p = UpdatePolicy.fromJson({
      'stage': 'mystery',
      'deadline_at': '2026-11-08T00:00:00Z',
    });
    expect(p.stage, UpdateStage.none);
    expect(p.deadlineAt, DateTime.utc(2026, 11, 8));
    expect(UpdatePolicy.fromJson({'stage': 'hard'}).readOnly, isTrue);
  });

  // AC:RL-force-update-staged-policy/8
  test('нет сети и нет кэша — экранов нет', () async {
    final c = await controller();
    await c.applyUnavailable(3771);
    expect(UpdatePolicyController.current.value.stage, UpdateStage.none);
    expect(c.shouldShowSoft, isFalse);
    expect(c.bannerVisible, isFalse);
  });

  test('нет сети — берётся кэш ЭТОЙ сборки', () async {
    final c = await controller();
    await c.applyFetched(_policy(UpdateStage.soft), 3771);
    UpdatePolicyController.current.value = UpdatePolicy.none;
    await c.applyUnavailable(3771);
    expect(UpdatePolicyController.current.value.stage, UpdateStage.soft);
  });

  test('после обновления кэш старой сборки недействителен', () async {
    final c = await controller();
    await c.applyFetched(_policy(UpdateStage.hard), 3771);
    expect(prefs.getBool(UpdatePolicyController.readOnlyKey), isTrue);
    await c.applyUnavailable(3790);
    expect(UpdatePolicyController.current.value.stage, UpdateStage.none);
    expect(prefs.getBool(UpdatePolicyController.readOnlyKey), isFalse);
  });

  test(
    'кэшированный hard старше 72 ч без подтверждения — понижается до soft',
    () async {
      final c = await controller();
      await c.applyFetched(_policy(UpdateStage.hard), 3771);
      local = local.add(const Duration(hours: 71));
      await c.applyUnavailable(3771);
      expect(UpdatePolicyController.current.value.stage, UpdateStage.hard);
      local = local.add(const Duration(hours: 2));
      await c.applyUnavailable(3771);
      expect(UpdatePolicyController.current.value.stage, UpdateStage.soft);
      expect(UpdatePolicyController.readOnly, isFalse);
    },
  );

  // AC:RL-force-update-staged-policy/9
  test('«Позже» — ровно max_postpones раз и переживает перезапуск', () async {
    var c = await controller();
    await c.applyFetched(_policy(UpdateStage.soft), 3771);
    final seen = <int>[];
    for (var i = 0; i < 4; i++) {
      // Каждый «запуск» — новый контроллер на тех же prefs.
      c = await controller();
      seen.add(c.postponesLeft);
      if (c.postponesLeft > 0) await c.postpone();
      local = local.add(const Duration(hours: 25));
    }
    expect(seen, [3, 2, 1, 0]);
    expect(c.shouldShowSoft, isFalse);
  });

  test('новая кампания (другой дедлайн) начинает счётчик с нуля', () async {
    final c = await controller();
    await c.applyFetched(_policy(UpdateStage.soft), 3771);
    await c.postpone();
    await c.postpone();
    expect(c.postponesLeft, 1);
    await c.applyFetched(
      UpdatePolicy(
        stage: UpdateStage.soft,
        deadlineAt: DateTime.utc(2027, 2, 1),
        serverNow: _serverNow,
      ),
      3771,
    );
    expect(c.postponesLeft, 3);
  });

  test(
    'мягкий экран не чаще soft_interval_h: 23:59 — нет, 24:00 — да',
    () async {
      final c = await controller();
      await c.applyFetched(_policy(UpdateStage.soft), 3771);
      expect(c.shouldShowSoft, isTrue);
      await c.markSoftShown();
      local = local.add(const Duration(hours: 23, minutes: 59));
      expect(c.shouldShowSoft, isFalse);
      local = local.add(const Duration(minutes: 1));
      expect(c.shouldShowSoft, isTrue);
    },
  );

  test('перевод часов назад не продлевает паузу мягкого экрана', () async {
    final c = await controller();
    await c.applyFetched(_policy(UpdateStage.soft), 3771);
    local = local.add(const Duration(hours: 5));
    await c.markSoftShown();
    local = local.subtract(const Duration(days: 30));
    expect(c.serverNow(), _serverNow);
    expect(c.shouldShowSoft, isTrue);
  });

  test('баннер анонса закрывается на banner_interval_h (72 ч)', () async {
    final c = await controller();
    await c.applyFetched(_policy(UpdateStage.announce), 3771);
    expect(c.bannerVisible, isTrue);
    await c.dismissBanner();
    expect(c.bannerVisible, isFalse);
    local = local.add(const Duration(hours: 71, minutes: 59));
    expect(c.bannerVisible, isFalse);
    local = local.add(const Duration(minutes: 1));
    expect(c.bannerVisible, isTrue);
  });

  test('на мягком и жёстком этапах плашку закрыть нельзя', () async {
    final c = await controller();
    await c.applyFetched(_policy(UpdateStage.soft), 3771);
    await c.dismissBanner();
    expect(c.bannerVisible, isTrue);
  });

  test('мягкий экран не показывается на других этапах', () async {
    final c = await controller();
    for (final stage in [
      UpdateStage.none,
      UpdateStage.recommended,
      UpdateStage.announce,
      UpdateStage.hard,
    ]) {
      await c.applyFetched(_policy(stage), 3771);
      expect(c.shouldShowSoft, isFalse, reason: stage.name);
    }
  });

  test('фоновый изолят видит режим чтения через prefs', () async {
    expect(
      await UpdatePolicyController.readOnlyAnywhere(background: true),
      isFalse,
    );
    final c = await controller();
    await c.applyFetched(_policy(UpdateStage.hard), 3771);
    // Фоновый изолят: статический слот пуст, флаг — только в prefs.
    UpdatePolicyController.current.value = UpdatePolicy.none;
    expect(
      await UpdatePolicyController.readOnlyAnywhere(background: true),
      isTrue,
    );
    expect(
      await UpdatePolicyController.readOnlyAnywhere(background: false),
      isFalse,
    );
  });
}
