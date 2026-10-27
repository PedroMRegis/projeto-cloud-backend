"""Verifica as invariantes de consistência do banco (rubrica 1/A).

1. Para cada livro, `stock` = soma dos movimentos do livro-razão.
2. Cada pedido CONFIRMED tem exatamente um movimento por item, com a
   quantidade certa; pedidos PENDING e REJECTED não têm nenhum.
3. Nenhum pedido está PENDING há mais de 10 minutos.
4. Nenhum evento do outbox está sem publicar há mais de 5 minutos.

Uso: DATABASE_URL=postgresql://... python scripts/check_consistency.py
Sai com código 1 se alguma invariante falhar, para servir de evidência em
demo (perda de EC2, falha do worker, carga).
"""

from __future__ import annotations

import os
import sys

import psycopg
from psycopg.rows import dict_row

CHECKS: dict[str, str] = {
    "estoque = Σ movimentos": """
        SELECT p.product_id, p.stock, coalesce(sum(m.delta), 0) AS ledger
        FROM products p LEFT JOIN stock_movements m USING (product_id)
        GROUP BY p.product_id, p.stock
        HAVING p.stock <> coalesce(sum(m.delta), 0)
    """,
    "pedido CONFIRMED debitou cada item uma vez": """
        SELECT o.order_id, oi.product_id, oi.quantity, coalesce(-sum(m.delta), 0) AS debited
        FROM orders o
        JOIN order_items oi USING (order_id)
        LEFT JOIN stock_movements m
          ON m.reason = 'order' AND m.ref = o.order_id::text AND m.product_id = oi.product_id
        WHERE o.status = 'CONFIRMED'
        GROUP BY o.order_id, oi.product_id, oi.quantity
        HAVING coalesce(-sum(m.delta), 0) <> oi.quantity
    """,
    "pedido não confirmado não debitou estoque": """
        SELECT o.order_id, o.status
        FROM orders o JOIN stock_movements m ON m.reason = 'order' AND m.ref = o.order_id::text
        WHERE o.status <> 'CONFIRMED'
    """,
    "nenhum pedido PENDING há mais de 10 min": """
        SELECT order_id, created_at FROM orders
        WHERE status = 'PENDING' AND created_at < now() - interval '10 minutes'
    """,
    "outbox sem evento parado há mais de 5 min": """
        SELECT id, aggregate_id, attempts, last_error FROM outbox
        WHERE published_at IS NULL AND created_at < now() - interval '5 minutes'
    """,
}


def main() -> int:
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("defina DATABASE_URL", file=sys.stderr)
        return 2
    failed = False
    with psycopg.connect(url, row_factory=dict_row) as conn:
        totals = conn.execute(
            "SELECT (SELECT count(*) FROM orders) AS orders, "
            "(SELECT count(*) FROM orders WHERE status = 'CONFIRMED') AS confirmed, "
            "(SELECT count(*) FROM orders WHERE status = 'REJECTED') AS rejected"
        ).fetchone()
        print(f"pedidos: {totals}")
        for name, sql in CHECKS.items():
            rows = conn.execute(sql).fetchall()
            if rows:
                failed = True
                print(f"FALHOU  {name}: {len(rows)} violação(ões)")
                for row in rows[:10]:
                    print(f"        {dict(row)}")
            else:
                print(f"OK      {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
