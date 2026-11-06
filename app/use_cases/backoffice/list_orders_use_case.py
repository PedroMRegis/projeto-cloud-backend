"""Todos os pedidos da loja, com o nome completo do cliente."""

from __future__ import annotations

from typing import Any

from app.adapters import db
from app.adapters.repositories import OrderRepository
from app.application.sales import present_order


class ListOrdersUseCase:
    def __init__(self, orders: OrderRepository) -> None:
        self._orders = orders

    def execute(self, status: str | None, limit: int, offset: int) -> dict[str, Any]:
        with db.transaction() as conn:
            rows = self._orders.list(conn, status=status, limit=limit, offset=offset)
            totals = self._orders.count_by_status(conn)
        return {
            "orders": [
                {**present_order(row), "customer_name": row["customer_name"],
                 "account_email": row["account_email"], "reason": row["reason"]}
                for row in rows
            ],
            "by_status": totals,
            "total": totals.get(status, 0) if status else sum(totals.values()),
        }
