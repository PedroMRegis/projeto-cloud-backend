"""Pedidos da conta logada. A consulta filtra pelo dono no próprio banco."""

from __future__ import annotations

from typing import Any

from app.adapters import db
from app.adapters.repositories import OrderRepository
from app.application.sales import present_order


class ListMyOrdersUseCase:
    def __init__(self, orders: OrderRepository) -> None:
        self._orders = orders

    def execute(self, user_id: str, limit: int, offset: int) -> dict[str, Any]:
        with db.transaction() as conn:
            rows = self._orders.list(conn, user_id=user_id, limit=limit, offset=offset)
            totals = self._orders.count_by_status(conn, user_id=user_id)
        return {"orders": [present_order(row) for row in rows],
                "total": sum(totals.values())}
