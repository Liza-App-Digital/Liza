#!/usr/bin/env bash
# Этап 3 пуш-синхронизации: право Apple `com.apple.developer.usernotifications.filtering`
# у iOS NSE — только при LIZA_NSE_FILTERING=1 (ставится в build-profiles/<acc>.env
# ПОСЛЕ одобрения заявки Apple, howItWoks/pushes/apple-filtering-entitlement.md).
# Ключ без выданного права ломает подпись/загрузку, поэтому по умолчанию — 0.
#
# Фильтр stdin→stdout: строка-маркер шаблона `@LIZA_NSE_FILTERING@` превращается
# в ключ либо удаляется целиком (рендер без флага = закоммиченному файлу).
nse_filtering_filter() {
  if [ "${LIZA_NSE_FILTERING:-0}" = 1 ]; then
    sed -e 's|^\([[:space:]]*\)<!-- @LIZA_NSE_FILTERING@ -->$|\1<key>com.apple.developer.usernotifications.filtering</key>\
\1<true/>|'
  else
    sed -e '/@LIZA_NSE_FILTERING@/d'
  fi
}
