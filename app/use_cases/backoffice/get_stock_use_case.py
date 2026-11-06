"""Visão de estoque para a gestão.

`ledger_ok` compara o estoque com a soma do livro-razão. Se der falso, algum
caminho alterou o estoque sem registrar o movimento.
"""

from __future__ import annotations

from typing import Any

from app.adapters import db
from app.adapters.repositories import ProductRepository
from app.application.catalog import brl


class GetStockUseCase:
    def __init__(self, products: ProductRepository) -> None:
        self._products = products

    def execute(self) -> dict[str, Any]:
        with db.transaction() as conn:
            rows = self._products.stock_report(conn)
        items = [
            {**row, "price": brl(int(row["price_cents"])),
             "ledger_ok": row["stock"] == row["ledger_stock"]}
            for row in rows
        ]
        return {
            "items": items,
            "summary": {
                "titles": len(items),
                "units": sum(i["stock"] for i in items),
                "out_of_stock": sum(1 for i in items if i["stock"] == 0),
                "sold": sum(i["sold"] for i in items),
                "ledger_mismatches": sum(1 for i in items if not i["ledger_ok"]),
            },
        }
