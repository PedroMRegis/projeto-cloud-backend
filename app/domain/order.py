"""Estado do pedido e transições válidas (PLANO §5.3, §6)."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class OrderStatus(StrEnum):
    PENDING = "PENDING"
    CONFIRMED = "CONFIRMED"
    REJECTED = "REJECTED"


class RejectionReason(StrEnum):
    OUT_OF_STOCK = "OUT_OF_STOCK"
    QUOTE_EXPIRED = "QUOTE_EXPIRED"


# PENDING é o único estado de onde se sai. CONFIRMED e REJECTED são terminais,
# o que é exatamente a propriedade que torna o reprocessamento idempotente.
_ALLOWED: dict[OrderStatus, frozenset[OrderStatus]] = {
    OrderStatus.PENDING: frozenset({OrderStatus.CONFIRMED, OrderStatus.REJECTED}),
    OrderStatus.CONFIRMED: frozenset(),
    OrderStatus.REJECTED: frozenset(),
}


class InvalidTransition(Exception):
    pass


def can_transition(current: OrderStatus, target: OrderStatus) -> bool:
    return target in _ALLOWED[current]


def assert_transition(current: OrderStatus, target: OrderStatus) -> None:
    if not can_transition(current, target):
        raise InvalidTransition(f"{current} -> {target} não é permitido")


def is_terminal(status: OrderStatus) -> bool:
    return not _ALLOWED[status]


@dataclass(frozen=True)
class HistoryEntry:
    status: OrderStatus
    at: str
    by: str
    reason: str | None = None

    def to_item(self) -> dict[str, str]:
        entry = {"status": str(self.status), "at": self.at, "by": self.by}
        if self.reason:
            entry["reason"] = self.reason
        return entry
