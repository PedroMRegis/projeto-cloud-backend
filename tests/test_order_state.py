"""Transições de estado do pedido."""

from __future__ import annotations

import pytest

from app.domain.order import (
    HistoryEntry,
    InvalidTransition,
    OrderStatus,
    RejectionReason,
    assert_transition,
    can_transition,
    is_terminal,
)


@pytest.mark.parametrize(
    "target", [OrderStatus.CONFIRMED, OrderStatus.REJECTED]
)
def test_pending_pode_ir_para_estados_terminais(target: OrderStatus) -> None:
    assert can_transition(OrderStatus.PENDING, target)


@pytest.mark.parametrize(
    ("current", "target"),
    [
        (OrderStatus.CONFIRMED, OrderStatus.REJECTED),
        (OrderStatus.REJECTED, OrderStatus.CONFIRMED),
        (OrderStatus.CONFIRMED, OrderStatus.PENDING),
        (OrderStatus.REJECTED, OrderStatus.PENDING),
        (OrderStatus.PENDING, OrderStatus.PENDING),
    ],
)
def test_transicoes_invalidas_sao_recusadas(
    current: OrderStatus, target: OrderStatus
) -> None:
    assert not can_transition(current, target)
    with pytest.raises(InvalidTransition):
        assert_transition(current, target)


def test_estados_terminais_sao_terminais() -> None:
    """É essa propriedade que torna o reprocessamento idempotente."""
    assert not is_terminal(OrderStatus.PENDING)
    assert is_terminal(OrderStatus.CONFIRMED)
    assert is_terminal(OrderStatus.REJECTED)


def test_historico_omite_reason_quando_ausente() -> None:
    entry = HistoryEntry(OrderStatus.PENDING, "2026-01-01T00:00:00Z", "chat-api")
    assert entry.to_item() == {
        "status": "PENDING",
        "at": "2026-01-01T00:00:00Z",
        "by": "chat-api",
    }


def test_historico_registra_o_motivo_da_rejeicao() -> None:
    entry = HistoryEntry(
        OrderStatus.REJECTED,
        "2026-01-01T00:00:00Z",
        "order-worker",
        str(RejectionReason.OUT_OF_STOCK),
    )
    assert entry.to_item()["reason"] == "OUT_OF_STOCK"
