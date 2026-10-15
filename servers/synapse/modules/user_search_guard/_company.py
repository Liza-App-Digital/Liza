"""Скрытие людей приватной компании из поиска по имени.

Без импортов synapse — модуль грузится в тестах напрямую, без живого
HomeServer. Решение и разбор — docs/superpowers/specs/2026-10-14-hidden-company-members-search-design.md.

Люди компании — локальные пользователи инстанса: 1 инстанс = 1 компания
(howItWoks/lizaSpaces.md §1). Гостя с другого сервера чужая приватная
компания не прячет — за него решает его собственный сервер.
"""

from dataclasses import dataclass
from typing import Any, Collection, Iterable, Optional

POLICY_PATH = "/_matrix/federation/v1/com.liza/user_search_policy"


@dataclass(frozen=True)
class CompanyPolicy:
    """Политика поиска одного инстанса.

    hidden — люди этого сервера скрыты от посторонних;
    room_id — главное пространство компании: его участники — «свои».
    """

    hidden: bool
    room_id: Optional[str] = None

    def to_json(self) -> dict:
        return {"hidden_company": self.hidden, "room_id": self.room_id}


OPEN = CompanyPolicy(hidden=False)


def domain_of(user_id: str) -> str:
    return user_id.split(":", 1)[1] if ":" in user_id else ""


def is_company_instance(loaded_modules: Iterable[tuple[Any, Any]]) -> bool:
    """Инстанс-компания: single_space_guard объявлен и auto_add_new не false.

    Тот же признак класса, что в lizaSpaces.md §7 и
    deploy/tests/test_single_space_guard_instances.py. На общем инстансе
    (user, bots) первое личное пространство приватно, но это не компания —
    без этой проверки там пропали бы из поиска все B2C-пользователи.
    Дефолт auto_add_new = True повторяет SingleSpaceGuardModule.__init__.
    """
    for cls, config in loaded_modules:
        if getattr(cls, "__name__", "") != "SingleSpaceGuardModule":
            continue
        cfg = config if isinstance(config, dict) else {}
        return bool(cfg.get("auto_add_new", True))
    return False


def parse_policy_payload(payload: object) -> Optional[CompanyPolicy]:
    """Ответ соседа → политика; None, если формат не тот (держим прошлую)."""
    if not isinstance(payload, dict):
        return None
    hidden = payload.get("hidden_company")
    if not isinstance(hidden, bool):
        return None
    if not hidden:
        return OPEN
    room_id = payload.get("room_id")
    if not isinstance(room_id, str) or not room_id.startswith("!"):
        # Скрытая компания без валидного пространства: «своих» не определить,
        # скрываем от всех, кроме людей того же сервера.
        room_id = None
    return CompanyPolicy(hidden=True, room_id=room_id)


def needs_membership(user_id: str, searcher: Optional[str], policy: Optional[CompanyPolicy]) -> bool:
    """Нужно ли знать комнаты ищущего, чтобы решить про user_id."""
    if policy is None or not policy.hidden or searcher is None:
        return False
    return domain_of(searcher) != domain_of(user_id) and policy.room_id is not None


def is_hidden_company_member(
    user_id: str,
    searcher: Optional[str],
    policy: Optional[CompanyPolicy],
    searcher_rooms: Collection[str] = (),
) -> bool:
    """Скрыт ли user_id от searcher, потому что его компания приватна.

    searcher=None — ищущий неизвестен (federation-ответ старому соседу):
    скрыты все люди скрытой компании. Свои — ищущий с того же сервера или
    участник главного пространства компании.
    """
    if policy is None or not policy.hidden:
        return False
    if searcher is None:
        return True
    if domain_of(searcher) == domain_of(user_id):
        return False
    return policy.room_id is None or policy.room_id not in searcher_rooms


def trusted_remote_searcher(raw: str, origin: str) -> Optional[str]:
    """searcher из federation-запроса, если его домен — подписавший сервер.

    Сервер вправе говорить только за своих пользователей; чужой MXID
    означает «ищущий неизвестен».
    """
    raw = (raw or "").strip()
    if not raw.startswith("@") or not origin or domain_of(raw) != origin:
        return None
    return raw
