#!/usr/bin/env bash
# ledger:RL-push-clearing-alert-v2
# AC:RL-push-clearing-alert-v2/5
# Ключ filtering попадает в entitlements iOS NSE ТОЛЬКО при LIZA_NSE_FILTERING=1;
# без флага рендер байт-в-байт совпадает с закоммиченным файлом (подпись не
# ломается без одобрения Apple), macOS-шаблоны маркера не несут.
# Запуск: scripts/test-nse-filtering-entitlement.sh
cd "$(dirname "$0")/.."
source scripts/_nse-filtering.sh

ERRORS=0
fail() { echo "FAIL: $1" >&2; ERRORS=$((ERRORS+1)); }
KEY='com.apple.developer.usernotifications.filtering'
TPL="ios/Notification Service Extension/Notification Service Extension.entitlements.template"
OUT="ios/Notification Service Extension/Notification Service Extension.entitlements"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

grep -q '@LIZA_NSE_FILTERING@' "$TPL" || fail "в шаблоне iOS NSE нет маркера @LIZA_NSE_FILTERING@"

for flag in "" 0 1; do
  LIZA_NSE_FILTERING="$flag" nse_filtering_filter < "$TPL" \
    | sed -e "s|@LIZA_APP_GROUP@|group.ru.prodamus.liza|g" > "$tmp/out.entitlements"
  grep -q '@LIZA_NSE_FILTERING@' "$tmp/out.entitlements" && fail "flag=$flag: маркер не снят"
  plutil -lint "$tmp/out.entitlements" >/dev/null || fail "flag=$flag: plutil -lint"
  if [ "$flag" = 1 ]; then
    [ "$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$tmp/out.entitlements" 2>/dev/null)" = true ] \
      || fail "flag=1: ключа $KEY=true нет"
  else
    grep -q "$KEY" "$tmp/out.entitlements" && fail "flag=$flag: ключ есть без флага"
    cmp -s "$tmp/out.entitlements" "$OUT" || fail "flag=$flag: рендер ≠ закоммиченному $OUT"
  fi
done

for f in macos/Runner/*.entitlements.template "macos/Notification Service Extension/"*.template; do
  grep -q '@LIZA_NSE_FILTERING@' "$f" && fail "macOS-шаблон $f несёт маркер filtering"
done

# build-ios.sh пробрасывает флаг в Dart (liza_clear_v=2 только вместе с ключом).
grep -q 'LIZA_NSE_FILTERING=' scripts/build-ios.sh || fail "build-ios.sh не передаёт --dart-define=LIZA_NSE_FILTERING"

if [ "$ERRORS" -eq 0 ]; then echo "OK: filtering entitlement за флагом"; exit 0; fi
echo "ПРОВАЛЕНО: $ERRORS" >&2; exit 1
