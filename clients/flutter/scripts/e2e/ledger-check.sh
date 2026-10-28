#!/usr/bin/env bash
# Реконсиляция реестра регрессии (tests/registry/) с тестами (см. tests/registry/README.md).
# Источник правды о НАЛИЧИИ стража — grep тега `ledger:RL-<slug>` в тестах, НЕ парсинг
# markdown. Зелёность даёт прогон (/e2e-full), здесь — только присутствие/потеря.
#
# Три множества:
#   OK        — у записи есть страж-тег (auto/golden), присутствует и не @Skip
#   UNCOVERED — запись есть, стража нет / он skip / manual не отмечен → «возможно потеряно»
#   ORPHAN    — тег в тесте есть, записи нет → реестр отстал
# exit≠0 при любом UNCOVERED (кроме явно manual — те идут в чек-лист, не валят grep-чек).
set -uo pipefail
cd "$(dirname "$0")/../../../.."   # корень репо

LEDGER_DIR="tests/registry"
# Сканим и серверные тесты: стражи с тегом ledger:RL-* живут не только во Flutter
# (авто-аудит 2026-07-30 нашёл теги в servers/auth-proxy/tests, невидимые скану).
# Глоб synapse-модулей разворачивается при подстановке без кавычек ниже.
TEST_DIRS="clients/flutter/test clients/flutter/integration_test servers/liza-bot-api/tests servers/miniapp-store/backend/tests servers/auth-proxy/tests servers/version-gate/tests servers/sygnal/tests servers/transcribe/tests servers/synapse/modules/*/tests servers/synapse/src/docker servers/bots servers/pf2-demo-bot/tests servers/monitoring-notifier servers/laba-pro-site/scripts deploy/tests deploy/scripts"

[ -d "$LEDGER_DIR" ] || { echo "Нет $LEDGER_DIR — реестр не заведён"; exit 0; }

# Теги, реально присутствующие в тестах: ledger:RL-<slug>
present_tags=$(grep -rhoE -I --exclude-dir=__pycache__ 'ledger:RL-[a-z0-9-]+' $TEST_DIRS 2>/dev/null | sed 's/^ledger://' | sort -u)
# Те же теги, но в @Skip/skip:-контексте (страж выключен) — грубо: строка с тегом или
# файл с тегом, где есть @Skip. Best-effort: файлы со skip рядом с тегом.
skipped_files=$(grep -rlE -I --exclude-dir=__pycache__ 'ledger:RL-[a-z0-9-]+' $TEST_DIRS 2>/dev/null | while read -r f; do
  grep -qE '@Skip|[^a-z]skip:[[:space:]]*(true|['\''"])' "$f" && echo "$f"; done)

# Ассерты критериев приёмки, реально присутствующие в тестах: AC:RL-<slug>/<N>.
# (внедрено после инцидента 3704 — см. README.md → «Критерии приёмки»)
present_ac=$(grep -rhoE -I --exclude-dir=__pycache__ 'AC:RL-[a-z0-9-]+/[0-9]+' $TEST_DIRS 2>/dev/null | sort -u)
# Тот же набор, но одной строкой с разделителями — для БЕЗ-ПОДПРОЦЕССНОЙ проверки
# принадлежности ниже. Прежде на каждый из ~1100 критериев порождалась пара
# `printf | grep -qx`; под нагрузкой запуск изредка не удавался, ненулевой код
# трактовался как «ассерта нет», и гейт ФЛАКОВАЛ на неизменном дереве
# (замерено 2026-09-08: AC_OK 879–881, AC_UNASSERTED 0–2 в трёх прогонах подряд,
# каждый раз с РАЗНЫМИ пунктами). Для блокирующего гейта это хуже, чем строгость:
# красный по случайности учит его игнорировать.
present_ac_blob=$'\n'"$present_ac"$'\n'

declare -a ok uncovered manual
# Перебор записей реестра
for f in "$LEDGER_DIR"/RL-*.md; do
  [ -e "$f" ] || continue
  id=$(awk -F': *' '/^id:[[:space:]]/{print $2; exit}' "$f" | tr -d ' \r"'\''')
  gtype=$(awk '/^guard:/{g=1} g&&/^[[:space:]]+type:[[:space:]]/{sub(/.*type:[[:space:]]*/,"");print;exit}' "$f" | tr -d ' \r"'\''')
  status=$(awk -F': *' '/^status:[[:space:]]/{print $2; exit}' "$f" | tr -d ' \r"'\''')
  [ "$status" = "retired" ] && continue
  [ -z "$id" ] && continue

  case "$gtype" in
    manual) manual+=("$id") ;;
    none)   uncovered+=("$id (guard:none — нет автостража)") ;;
    auto|golden|*)
      if printf '%s\n' "$present_tags" | grep -qx "$id"; then
        # тег есть — проверим, не в skip-файле ли он
        if [ -n "$skipped_files" ] && grep -rlE -I --exclude-dir=__pycache__ "ledger:$id([^a-z0-9-]|$)" $TEST_DIRS 2>/dev/null | grep -qFf <(printf '%s\n' "$skipped_files"); then
          uncovered+=("$id (страж под @Skip)")
        else
          ok+=("$id")
        fi
      else
        uncovered+=("$id (нет страж-тега в тестах)")
      fi
      ;;
  esac
done

# Сироты: теги в тестах без записи в реестре
ledger_ids=$(for f in "$LEDGER_DIR"/RL-*.md; do [ -e "$f" ] && awk -F': *' '/^id:[[:space:]]/{print $2;exit}' "$f" | tr -d ' \r"'\''' ; done | sort -u)
declare -a orphan
while IFS= read -r t; do
  [ -z "$t" ] && continue
  printf '%s\n' "$ledger_ids" | grep -qx "$t" || orphan+=("$t")
done <<< "$present_tags"

# ── КРИТЕРИИ ПРИЁМКИ: каждое заявленное утверждение AC-N покрыто? ──
# (внедрено после инцидента 3704: требование «оба времени ВСЕГДА на одном уровне»
# было в прозе, но страж проверял РЕПЛИКУ → баг уехал. Теперь покрытие меряется
# на гранулярности УТВЕРЖДЕНИЯ, а не файла.) Для каждой записи с разделом
# «## Критерии приёмки» разбираем пункты «- [ ] **AC-N** …»:
#   AC_OK         — пункт помечен manual ИЛИ есть ассерт-тег AC:RL-<slug>/N в тестах
#   AC_MANUAL     — пункт с «manual» → в обязательный чек-лист /e2e-full
#   AC_UNASSERTED — заявлен, но ни ассерта, ни manual → БЛОКИРУЕТ (аналог UNCOVERED
#                   на уровне утверждения приёмки — ядро механизма)
declare -a ac_ok ac_manual ac_unasserted ac_stale_manual mock_only
for f in "$LEDGER_DIR"/RL-*.md; do
  [ -e "$f" ] || continue
  fid=$(awk -F': *' '/^id:[[:space:]]/{print $2; exit}' "$f" | tr -d ' \r"'\''')
  fstatus=$(awk -F': *' '/^status:[[:space:]]/{print $2; exit}' "$f" | tr -d ' \r"'\''')
  [ "$fstatus" = "retired" ] && continue
  [ -z "$fid" ] && continue
  # пункты критериев приёмки: "- [ ] **AC-N** …" — МНОГОСТРОЧНЫЕ (перенос строки в
  # markdown), поэтому склеиваем весь текст пункта до следующего AC/раздела, иначе
  # «manual» на перенесённой строке не виден (баг ретро-заполнения footer). awk
  # эмитит "N<US>полный_текст_пункта".
  while IFS= read -r item; do
    n=${item%%$'\x1f'*}
    text=${item#*$'\x1f'}
    [ -z "$n" ] && continue
    if printf '%s' "$text" | grep -qiE 'manual'; then
      ac_manual+=("$fid/AC-$n")
      # AC_STALE_MANUAL (advisory, НЕ блокирует): пункт объявлен ручным, но
      # ручной проверки не было НИ РАЗУ (`last_manual_check: —`). Без этого
      # бакета «—» неотличимо от вчерашней даты, и критерий молчит бессрочно:
      # у RL-media-send-instant-bubble так пролежали пять пунктов, один из
      # которых (AC-14) был записан ОБРАТНО реальности и вскрылся только
      # состязательной комиссией 2026-09-08.
      #
      # Почему advisory, а не блок. Сейчас достаточно, чтобы подстрока
      # `manual` встретилась в тексте пункта ГДЕ УГОДНО — включая саму подпись
      # `last_manual_check`. По репозиторию так классифицированы ~299 пунктов.
      # Ужесточение матча (только токен после «— guard:») переклассифицирует
      # неизвестную их долю в блокирующий AC_UNASSERTED и разом уронит
      # /e2e-full ВСЕМ задачам. Поэтому сперва мерим долг громко, разбираем
      # его отдельной задачей — и только потом ужесточаем.
      if printf '%s' "$text" | grep -qE 'last_manual_check:[[:space:]]*(—|-|нет|никогда)'; then
        ac_stale_manual+=("$fid/AC-$n")
      fi
    elif [[ "$present_ac_blob" == *$'\n'"AC:$fid/$n"$'\n'* ]]; then
      ac_ok+=("$fid/AC-$n")
    else
      ac_unasserted+=("$fid/AC-$n (нет ассерта AC:$fid/$n на реальном виджете)")
    fi
  done < <(awk '
    /^## Критерии приёмки/{inac=1; next}
    inac && /^## /{if(cur!="")print curN "\x1f" cur; inac=0; cur=""}
    inac && /- \[.\][[:space:]]*\*\*AC-[0-9]+\*\*/{
      if(cur!="")print curN "\x1f" cur;
      match($0,/AC-[0-9]+/); curN=substr($0,RSTART+3,RLENGTH-3); cur=$0; next
    }
    inac && cur!=""{cur=cur " " $0}
    END{if(cur!="")print curN "\x1f" cur}
  ' "$f")

  # MOCK_ONLY (advisory): UI-запись (visual required/recommended), чей страж —
  # не реальный виджет (guard.render pure-function / не указан). Это тот класс,
  # на котором горели: мок-реплика зелёная, реальный рендер багованный.
  # sub(/#.*/) — срезаем inline-комментарий (напр. «render: pure-function # ДОЛГ»),
  # иначе он утёк бы в значение и сравнение промахивается.
  vis=$(awk -F': *' '/^visual:[[:space:]]/{v=$2; sub(/[[:space:]]*#.*/,"",v); print v; exit}' "$f" | tr -d ' \r"'\''')
  render=$(awk '/^guard:/{g=1} g&&/^[[:space:]]+render:[[:space:]]/{sub(/.*render:[[:space:]]*/,"");sub(/[[:space:]]*#.*/,"");print;exit}' "$f" | tr -d ' \r"'\''')
  if [ "$vis" = "required" ] || [ "$vis" = "recommended" ]; then
    if [ "$render" = "pure-function" ] || [ -z "$render" ]; then
      mock_only+=("$fid (visual:$vis, guard.render:${render:-НЕ_УКАЗАН} — не реальный рендер)")
    fi
  fi
done

# ── ОБРАТНЫЙ АУДИТ: серверные feature-signal без ledger-стража ──
# Прежде реестр был ОДНОНАПРАВЛЕННЫМ: «у каждой RL-записи есть тег?». Он НЕ ловил
# «у каждой фичи есть RL-запись?», из-за чего серверная фича без записи давала
# ложные «UNCOVERED 0» (инцидент 2026-07-20: attach/rename задеплоены без реестра).
# Теперь: «фича» liza-bot-api = именованная button_id-константа botfather
# (_X = "prefix."). Перечисляем их ИЗ КОДА (источник истины — новый префикс
# войдёт в аудит сам) и каждую КЛАССИФИЦИРУЕМ:
#   • в карте _rl_slug_for → её RL-slug должен иметь живой тег (иначе UNPINNED);
#   • в _feat_ignored → осознанно вне аудита (не фича / задокументированный долг);
#   • ни там ни там → UNCLASSIFIED (новый сигнал — заведи RL+тег или внеси в ignore).
# НЕ блокирует (advisory): честный сигнал вместо тишины. Правила — tests/registry/README.md.
_rl_slug_for() {  # button_id-префикс → RL-slug пинованной фичи ("" = нет в карте)
  case "$1" in
    myapps.attach.|myapps.attach.pick.) echo "RL-miniapp-attach-to-bot" ;;
    mybots.rename.)                      echo "RL-botfather-rename-bot" ;;
    mybots.describe.)                    echo "RL-botfather-bot-description-topic" ;;
    mybots.visibility.)                  echo "RL-private-bots" ;;
    # конфиг кнопок быстрого доступа (вкл/выкл + label, композер и список чатов)
    mybots.buttons.|myapps.buttons.|myapps.btn.composer.label.|myapps.btn.composer.toggle.|myapps.btn.list.label.|myapps.btn.list.toggle.)
                                         echo "RL-bot-miniapp-button-config" ;;
    # пикер бота в режиме «собрать в конструкторе» (/miniapp-constraction)
    buildapp.bot.pick.|buildapp.bot.create) echo "RL-botfather-miniapp-constructor-command" ;;
    *) echo "" ;;
  esac
}
_feat_ignored() {  # префиксы осознанно вне аудита (return 0 = игнор)
  case "$1" in
    # BACKLOG (долг реестра, НЕ тихая потеря): /mybots detail и /newapp picker
    # исторически без RL — завести RL-botfather-mybots-detail / RL-newapp-bot-picker.
    mybots.show.|mybots.token.|mybots.delete.|mybots.delete_confirm.|newapp.bot.pick.) return 0 ;;
    *) return 1 ;;
  esac
}
declare -a unpinned_feat unclassified_feat
_BF="servers/liza-bot-api/botfather"
if [ -d "$_BF" ]; then
  while IFS= read -r pfx; do
    [ -z "$pfx" ] && continue
    slug=$(_rl_slug_for "$pfx")
    if [ -n "$slug" ]; then
      printf '%s\n' "$present_tags" | grep -qx "$slug" || unpinned_feat+=("$pfx → $slug (тег пропал)")
    elif _feat_ignored "$pfx"; then :
    else unclassified_feat+=("$pfx"); fi
  done < <(grep -rhoE '_[A-Z][A-Z_]*[[:space:]]*=[[:space:]]*"[a-z][a-z_]*(\.[a-z_]+)*\."' \
             "$_BF"/handlers.py "$_BF"/miniapp.py 2>/dev/null \
           | sed -E 's/.*=[[:space:]]*"([^"]+)"/\1/' | sort -u)
fi

# ── отчёт ──
echo "════════ Реконсиляция реестра регрессии ════════"
printf 'OK (%d): %s\n'        "${#ok[@]}"        "${ok[*]:-—}"
printf 'MANUAL (%d): %s\n'    "${#manual[@]}"    "${manual[*]:-—}"
printf 'UNCOVERED (%d): %s\n' "${#uncovered[@]}" "${uncovered[*]:-—}"
printf 'ORPHAN (%d): %s\n'    "${#orphan[@]}"    "${orphan[*]:-—}"
printf 'AC_OK (%d): %s\n'         "${#ac_ok[@]}"         "${ac_ok[*]:-—}"
printf 'AC_MANUAL (%d): %s\n'     "${#ac_manual[@]}"     "${ac_manual[*]:-—}"
printf 'AC_STALE_MANUAL (%d): %s\n' "${#ac_stale_manual[@]}" "${ac_stale_manual[*]:-—}"
printf 'AC_UNASSERTED (%d): %s\n' "${#ac_unasserted[@]}" "${ac_unasserted[*]:-—}"
printf 'MOCK_ONLY (%d): %s\n'     "${#mock_only[@]}"     "${mock_only[*]:-—}"
printf 'UNPINNED_FEATURES (%d): %s\n'     "${#unpinned_feat[@]}"     "${unpinned_feat[*]:-—}"
printf 'UNCLASSIFIED_FEATURES (%d): %s\n' "${#unclassified_feat[@]}" "${unclassified_feat[*]:-—}"
[ ${#ac_unasserted[@]} -gt 0 ] && echo "→ AC_UNASSERTED: критерий приёмки без стража-ассерта (AC:RL-…/N) — БЛОКИРУЕТ. Напиши ассерт на РЕАЛЬНОМ виджете или пометь пункт manual."
[ ${#ac_manual[@]} -gt 0 ] && echo "→ AC_MANUAL: ручные критерии приёмки — в обязательный чек-лист /e2e-full (нельзя пропустить молча)."
[ ${#ac_stale_manual[@]} -gt 0 ] && echo "→ ⚠ AC_STALE_MANUAL: ручной критерий, не проверявшийся НИ РАЗУ (last_manual_check: —). Не блокирует, но это долг: проверь и проставь дату либо переведи в авто-ассерт."
[ ${#mock_only[@]} -gt 0 ] && echo "→ MOCK_ONLY (advisory): UI-запись без guard.render:real-widget/device — страж, вероятно, тестирует реплику/примитив, а не реальный рендер (см. README → «страж рендерит прод-виджет»)."
[ ${#unpinned_feat[@]} -gt 0 ] && echo "→ UNPINNED_FEATURES: фича в карте, но ledger-тег стража исчез — верни тег."
[ ${#unclassified_feat[@]} -gt 0 ] && echo "→ UNCLASSIFIED_FEATURES: новый серверный button_id-сигнал. Заведи RL-запись + тег и внеси в _rl_slug_for; либо в _feat_ignored, если это не пользовательская фича. (Не блокирует — честный сигнал.)"
[ ${#manual[@]} -gt 0 ] && echo "→ MANUAL-стражи требуют ручной проверки (см. тело записей в $LEDGER_DIR)."
[ ${#orphan[@]} -gt 0 ] && echo "→ ORPHAN: заведи RL-запись на эти теги (реестр отстал)."

# ── генерируемый индекс (журнал «отражает текущее состояние», не ведётся руками) ──
# Это снимок ПОСЛЕДНЕЙ реконсиляции, а не хранимый статус: бакет (OK/UNCOVERED/MANUAL)
# вычислен прогоном, дедуп — по slug. INDEX.md в .gitignore (реестр избегает
# merge-конфликтов агрегатов — потому формат «файл-на-запись»; индекс регенерируем).
bucket_of() {  # id → бакет по уже посчитанным множествам
  printf '%s\n' "${ok[*]:-}"        | tr ' ' '\n' | grep -qx "$1" && { echo OK; return; }
  printf '%s\n' "${manual[*]:-}"    | tr ' ' '\n' | grep -qx "$1" && { echo MANUAL; return; }
  echo UNCOVERED
}
INDEX="$LEDGER_DIR/INDEX.md"
{
  echo "# Реестр регрессии — индекс (СГЕНЕРИРОВАН, не править руками)"
  echo
  echo "Снимок последней реконсиляции \`make e2e-ledger\`. Источник правды о"
  echo "зелёности — прогон \`/e2e-full\`, не этот файл. Описание — \`README.md\`,"
  echo "детали инварианта — в \`RL-<slug>.md\`."
  echo
  echo "| ID | Область | Страж | Статус реестра | Инвариант |"
  echo "|---|---|---|---|---|"
  esc() { printf '%s' "$1" | tr -d '\r' | sed 's/[|\\]/\\&/g'; }  # экранируем разделитель таблицы
  for f in "$LEDGER_DIR"/RL-*.md; do
    [ -e "$f" ] || continue
    id=$(awk -F': *' '/^id:[[:space:]]/{print $2; exit}' "$f" | tr -d ' \r"'\''')
    [ -z "$id" ] && { echo "⚠ $f без поля id: — пропущен в индексе" >&2; continue; }
    area=$(awk -F': *' '/^area:[[:space:]]/{print $2; exit}' "$f" | tr -d ' \r"'\''')
    gtype=$(awk '/^guard:/{g=1} g&&/^[[:space:]]+type:[[:space:]]/{sub(/.*type:[[:space:]]*/,"");print;exit}' "$f" | tr -d ' \r"'\''')
    status=$(awk -F': *' '/^status:[[:space:]]/{print $2; exit}' "$f" | tr -d ' \r"'\''')
    title=$(awk '/^# /{sub(/^# /,"");print;exit}' "$f")
    if [ "$status" = "retired" ]; then b="retired"; else b=$(bucket_of "$id"); fi
    echo "| \`$id\` | ${area:-—} | ${gtype:-—} | $b | $(esc "${title:-—}") |"
  done
} > "$INDEX"
echo "→ Индекс обновлён: $INDEX (gitignored, снимок реконсиляции)."

if [ ${#uncovered[@]} -eq 0 ] && [ ${#ac_unasserted[@]} -eq 0 ]; then
  echo "→ Все авто-записи имеют живой страж-тег; заявленные критерии приёмки покрыты."
  exit 0
else
  [ ${#uncovered[@]} -gt 0 ] && echo "→ UNCOVERED: возможно потеряно — заведи/почини страж."
  [ ${#ac_unasserted[@]} -gt 0 ] && echo "→ AC_UNASSERTED: критерий приёмки без покрытия — ассерт на реальном виджете или manual."
  exit 1
fi
