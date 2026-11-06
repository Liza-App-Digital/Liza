"""HA: в каком процессе Synapse выполнять побочные эффекты модулей.

Модули грузятся в КАЖДЫЙ процесс инстанса (main и все воркеры). Колбэк
``on_new_event`` (``register_third_party_rules_callbacks``) Synapse тоже зовёт
в каждом процессе: писатель событий — из ``notifier.notify_new_room_events``
сразу после персиста, остальные процессы — из того же метода, когда событие
приходит по репликации (``replication/tcp/client.py``, ``on_rdata`` потока
events). Поэтому побочный эффект в ``on_new_event`` (push, задача транскодеру,
kick/invite, мьют, запрос в MMR) при N процессах выполнялся N раз.

Эффекты выполняет ровно один процесс — писатель потока ``push_rules``
(``hs.config.worker.writers.push_rules[0]``). В нашей раскладке
(``servers/synapse/ha``) и в монопроцессе (compose) это main. Почему не
``should_run_background_tasks()`` (``background_worker``): модули мьютят
комнаты через ``store.add_push_rule``, а он вне писателя push_rules бросает
``Not a push writer``.

Ограничение: события, пришедшие, пока процесс эффектов перезапускается, эффектов
не получат — так же, как раньше при рестарте монолита. После переподключения
по репликации короткий разрыв Synapse догоняет сам.

Модуль не импортирует synapse/twisted — тестируется без Synapse
(``servers/synapse/ha/tests/test_module_effects.py``).
"""

from __future__ import annotations

import logging
from typing import Any, Awaitable, Callable

logger = logging.getLogger(__name__)


def is_effects_process(api: Any) -> bool:
    """True — этот процесс выполняет побочные эффекты модулей.

    Это процесс-писатель потока push_rules. Если определить нельзя (нет
    ``api._hs``, конфига воркера или списка писателей — старый ModuleApi,
    юнит-тесты), считаем «да»: так ведёт себя монопроцесс.
    """
    hs = getattr(api, "_hs", None)
    if hs is None:
        return True
    try:
        writers = list(hs.config.worker.writers.push_rules)
        instance = hs.get_instance_name()
    except AttributeError:
        return True
    if not writers:
        return True
    return instance == writers[0]


def register_on_new_event_once(
    api: Any, callback: Callable[[Any, Any], Awaitable[None]]
) -> bool:
    """Зарегистрировать ``on_new_event`` только в процессе эффектов.

    В остальных процессах колбэк не регистрируется вовсе: заодно Synapse не
    делает там лишние ``get_event`` и ``get_current_state`` на каждое событие.
    Возвращает True, если колбэк зарегистрирован.
    """
    if not is_effects_process(api):
        logger.info(
            "%s: on_new_event не регистрируется — эффекты выполняет процесс-писатель push_rules",
            getattr(callback, "__qualname__", callback),
        )
        return False
    api.register_third_party_rules_callbacks(on_new_event=callback)
    return True
