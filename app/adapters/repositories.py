"""Acesso ao PostgreSQL, em SQL explícito.

Toda função recebe a conexão de quem chama: é o caso de uso que decide o
limite da transação (por exemplo, pedido + itens + histórico + outbox numa
transação só). Os repositórios não fazem commit.
"""

from __future__ import annotations

import json
import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from app.domain.order import OrderStatus
from app.domain.pricing import Quote

Conn = psycopg.Connection[dict[str, Any]]

PRODUCT_COLUMNS = (
    "product_id, title, author, category, tagline, description, original_year, "
    "price_cents, stock, version, (embedding IS NOT NULL) AS has_embedding, "
    "created_at, updated_at"
)

# Busca semântica abaixo disso é ruído. ⚠ Calibrar com o catálogo real.
SEMANTIC_MIN_SIMILARITY = 0.55


def plain(value: Any) -> Any:
    """Converte tipos do driver (UUID, datetime, Decimal) para JSON puro."""
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    if isinstance(value, list | tuple):
        return [plain(v) for v in value]
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, datetime | date):
        return value.isoformat()
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    return value


class NotFound(Exception):
    pass


# ------------------------------------------------------------------- produtos


class ProductRepository:
    def get(self, conn: Conn, product_id: str) -> dict[str, Any] | None:
        row = conn.execute(
            f"SELECT {PRODUCT_COLUMNS} FROM products WHERE product_id = %s",
            (product_id,),
        ).fetchone()
        return plain(row) if row else None

    def get_many(self, conn: Conn, product_ids: list[str]) -> dict[str, dict[str, Any]]:
        if not product_ids:
            return {}
        rows = conn.execute(
            f"SELECT {PRODUCT_COLUMNS} FROM products WHERE product_id = ANY(%s)",
            (list(set(product_ids)),),
        ).fetchall()
        return {row["product_id"]: plain(row) for row in rows}

    def list(
        self,
        conn: Conn,
        *,
        category: str | None = None,
        sort: str = "title",
        limit: int = 20,
        offset: int = 0,
    ) -> list[dict[str, Any]]:
        order_by = {
            "title": "title",
            "price_asc": "price_cents, title",
            "price_desc": "price_cents DESC, title",
            "newest": "original_year DESC NULLS LAST, title",
            "stock": "stock DESC, title",
        }.get(sort, "title")
        rows = conn.execute(
            f"SELECT {PRODUCT_COLUMNS} FROM products "
            "WHERE (%(category)s::text IS NULL OR category = %(category)s) "
            f"ORDER BY {order_by} LIMIT %(limit)s OFFSET %(offset)s",
            {"category": category, "limit": limit, "offset": offset},
        ).fetchall()
        return plain(rows)

    def count(self, conn: Conn, *, category: str | None = None) -> int:
        row = conn.execute(
            "SELECT count(*) AS n FROM products "
            "WHERE (%(category)s::text IS NULL OR category = %(category)s)",
            {"category": category},
        ).fetchone()
        return int(row["n"]) if row else 0

    def search_lexical(
        self, conn: Conn, query: str, *, category: str | None, limit: int
    ) -> list[dict[str, Any]]:
        """Full-text em português, sem acento, com OR entre os termos.

        OR (e não AND) porque o texto vem da conversa ("quero o dom casmurro"):
        palavras que não são do livro não podem zerar o resultado. O `ts_rank`
        com peso A em título e autor põe o livro certo no topo, e o `LIKE`
        cobre prefixos que o stemmer não pega ("casm").
        """
        rows = conn.execute(
            f"""
            WITH q AS (
                SELECT
                    nullif(replace(plainto_tsquery('portuguese', f_unaccent(%(q)s))::text,
                                   '&', '|'), '')::tsquery AS tsq,
                    '%%' || lower(f_unaccent(%(q)s)) || '%%' AS pat
            )
            SELECT {PRODUCT_COLUMNS},
                   coalesce(ts_rank(search_tsv, q.tsq), 0)
                   + CASE WHEN lower(f_unaccent(title || ' ' || author)) LIKE q.pat
                          THEN 1 ELSE 0 END AS score
            FROM products, q
            WHERE (search_tsv @@ q.tsq
                   OR lower(f_unaccent(title || ' ' || author)) LIKE q.pat)
              AND (%(category)s::text IS NULL OR category = %(category)s)
            ORDER BY score DESC, title
            LIMIT %(limit)s
            """,
            {"q": query, "category": category, "limit": limit},
        ).fetchall()
        return plain(rows)

    def search_semantic(
        self, conn: Conn, vector_literal: str, *, category: str | None, limit: int
    ) -> list[dict[str, Any]]:
        rows = conn.execute(
            f"""
            SELECT {PRODUCT_COLUMNS},
                   1 - (embedding <=> %(v)s::vector) AS similarity
            FROM products
            WHERE embedding IS NOT NULL
              AND (%(category)s::text IS NULL OR category = %(category)s)
            ORDER BY embedding <=> %(v)s::vector
            LIMIT %(limit)s
            """,
            {"v": vector_literal, "category": category, "limit": limit},
        ).fetchall()
        return [plain(r) for r in rows if float(r["similarity"]) >= SEMANTIC_MIN_SIMILARITY]

    def categories(self, conn: Conn) -> list[dict[str, Any]]:
        rows = conn.execute(
            "SELECT category, count(*) AS count FROM products "
            "GROUP BY category ORDER BY count DESC, category"
        ).fetchall()
        return plain(rows)

    # --- escrita (admin) ---

    def create(self, conn: Conn, data: dict[str, Any], actor: str) -> dict[str, Any]:
        conn.execute(
            """
            INSERT INTO products (product_id, title, author, category, tagline,
                                  description, original_year, price_cents, stock)
            VALUES (%(product_id)s, %(title)s, %(author)s, %(category)s, %(tagline)s,
                    %(description)s, %(original_year)s, %(price_cents)s, %(stock)s)
            """,
            data,
        )
        if data["stock"]:
            self._movement(conn, data["product_id"], data["stock"], "admin_adjust",
                           f"create:{data['product_id']}", actor)
        created = self.get(conn, data["product_id"])
        assert created is not None
        return created

    def update(self, conn: Conn, product_id: str, fields: dict[str, Any]) -> dict[str, Any]:
        allowed = {
            "title", "author", "category", "tagline", "description",
            "original_year", "price_cents",
        }
        changes = {k: v for k, v in fields.items() if k in allowed}
        if changes:
            assignments = ", ".join(f"{k} = %({k})s" for k in changes)
            result = conn.execute(
                f"UPDATE products SET {assignments}, version = version + 1, "
                "updated_at = now() WHERE product_id = %(product_id)s",
                {**changes, "product_id": product_id},
            )
            if result.rowcount == 0:
                raise NotFound(product_id)
            # Texto mudou: o embedding antigo não descreve mais o livro.
            if changes.keys() & {"title", "author", "category", "tagline", "description"}:
                conn.execute(
                    "UPDATE products SET embedding = NULL, embedding_model = NULL "
                    "WHERE product_id = %s",
                    (product_id,),
                )
        product = self.get(conn, product_id)
        if product is None:
            raise NotFound(product_id)
        return product

    def adjust_stock(
        self, conn: Conn, product_id: str, delta: int, *, reason: str, ref: str, actor: str
    ) -> int:
        """Ajuste relativo e registrado no livro-razão. Devolve o novo estoque."""
        row = conn.execute(
            "UPDATE products SET stock = stock + %(d)s, version = version + 1, "
            "updated_at = now() WHERE product_id = %(id)s AND stock + %(d)s >= 0 "
            "RETURNING stock",
            {"d": delta, "id": product_id},
        ).fetchone()
        if row is None:
            if self.get(conn, product_id) is None:
                raise NotFound(product_id)
            raise ValueError("ajuste deixaria o estoque negativo")
        self._movement(conn, product_id, delta, reason, ref, actor)
        return int(row["stock"])

    def debit_for_order(self, conn: Conn, product_id: str, quantity: int, order_id: str) -> bool:
        """Debita o estoque de um item de pedido. False = estoque insuficiente."""
        row = conn.execute(
            "UPDATE products SET stock = stock - %(q)s, version = version + 1, "
            "updated_at = now() WHERE product_id = %(id)s AND stock >= %(q)s "
            "RETURNING stock",
            {"q": quantity, "id": product_id},
        ).fetchone()
        if row is None:
            return False
        self._movement(conn, product_id, -quantity, "order", order_id, "order-worker")
        return True

    def _movement(
        self, conn: Conn, product_id: str, delta: int, reason: str, ref: str, actor: str
    ) -> None:
        conn.execute(
            "INSERT INTO stock_movements (product_id, delta, reason, ref, actor) "
            "VALUES (%s, %s, %s, %s, %s)",
            (product_id, delta, reason, ref, actor),
        )

    # --- embeddings ---

    def missing_embeddings(self, conn: Conn, limit: int = 100) -> list[dict[str, Any]]:
        rows = conn.execute(
            "SELECT product_id, title, author, category, tagline, description "
            "FROM products WHERE embedding IS NULL ORDER BY product_id LIMIT %s",
            (limit,),
        ).fetchall()
        return plain(rows)

    def set_embedding(self, conn: Conn, product_id: str, vector_literal: str, model: str) -> None:
        conn.execute(
            "UPDATE products SET embedding = %s::vector, embedding_model = %s "
            "WHERE product_id = %s",
            (vector_literal, model, product_id),
        )


# -------------------------------------------------------------------- cotações


class QuoteRepository:
    def create(
        self,
        conn: Conn,
        *,
        quote_id: str,
        conversation_id: str,
        quote: Quote,
        requested_discount_pct: int,
        ttl_minutes: int,
    ) -> dict[str, Any]:
        row = conn.execute(
            """
            INSERT INTO quotes (quote_id, conversation_id, subtotal_cents,
                                requested_discount_pct, discount_pct, discount_cents,
                                total_cents, max_discount_pct, expires_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, now() + make_interval(mins => %s))
            RETURNING expires_at, created_at
            """,
            (
                quote_id, conversation_id, quote.subtotal_cents, requested_discount_pct,
                quote.discount_pct, quote.discount_cents, quote.total_cents,
                quote.max_discount_pct, ttl_minutes,
            ),
        ).fetchone()
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO quote_items (quote_id, product_id, quantity, unit_price_cents) "
                "VALUES (%s, %s, %s, %s)",
                [(quote_id, i.product_id, i.quantity, i.unit_price_cents) for i in quote.items],
            )
        return plain(dict(row or {}))

    def get(self, conn: Conn, quote_id: str) -> dict[str, Any] | None:
        row = conn.execute(
            "SELECT *, expires_at < now() AS expired FROM quotes WHERE quote_id = %s",
            (quote_id,),
        ).fetchone()
        if not row:
            return None
        items = conn.execute(
            "SELECT qi.product_id, qi.quantity, qi.unit_price_cents, p.title, p.author "
            "FROM quote_items qi JOIN products p USING (product_id) "
            "WHERE qi.quote_id = %s ORDER BY qi.product_id",
            (quote_id,),
        ).fetchall()
        return plain({**row, "items": items})


# --------------------------------------------------------------------- pedidos


class OrderRepository:
    def create_pending(
        self,
        conn: Conn,
        *,
        quote: dict[str, Any],
        customer_name: str,
        correlation_id: str | None,
        traceparent: str | None,
    ) -> bool:
        """Insere o pedido PENDING. False = já existia pedido para a cotação."""
        row = conn.execute(
            """
            INSERT INTO orders (order_id, conversation_id, customer_name, status,
                                subtotal_cents, discount_pct, total_cents,
                                correlation_id, traceparent)
            VALUES (%s, %s, %s, 'PENDING', %s, %s, %s, %s, %s)
            ON CONFLICT (order_id) DO NOTHING
            RETURNING order_id
            """,
            (
                quote["quote_id"], quote["conversation_id"], customer_name,
                quote["subtotal_cents"], quote["discount_pct"], quote["total_cents"],
                correlation_id, traceparent,
            ),
        ).fetchone()
        if row is None:
            return False
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents) "
                "VALUES (%s, %s, %s, %s)",
                [
                    (quote["quote_id"], i["product_id"], i["quantity"], i["unit_price_cents"])
                    for i in quote["items"]
                ],
            )
        self.add_history(conn, quote["quote_id"], OrderStatus.PENDING, actor="backend-api")
        return True

    def get(self, conn: Conn, order_id: str, *, for_update: bool = False) -> dict[str, Any] | None:
        lock = " FOR UPDATE" if for_update else ""
        row = conn.execute(
            f"SELECT * FROM orders WHERE order_id = %s{lock}", (order_id,)
        ).fetchone()
        if not row:
            return None
        items = conn.execute(
            "SELECT oi.product_id, oi.quantity, oi.unit_price_cents, p.title, p.author "
            "FROM order_items oi JOIN products p USING (product_id) "
            # Ordem fixa por produto: dois workers debitando os mesmos livros
            # travam as linhas na mesma ordem e não entram em deadlock.
            "WHERE oi.order_id = %s ORDER BY oi.product_id",
            (order_id,),
        ).fetchall()
        history = conn.execute(
            "SELECT status, reason, actor AS by, at FROM order_history "
            "WHERE order_id = %s ORDER BY id",
            (order_id,),
        ).fetchall()
        return plain({**row, "items": items, "history": history})

    def set_status(
        self, conn: Conn, order_id: str, status: OrderStatus, *, reason: str | None, actor: str
    ) -> None:
        conn.execute(
            "UPDATE orders SET status = %s, reason = %s, updated_at = now() "
            "WHERE order_id = %s AND status = 'PENDING'",
            (str(status), reason, order_id),
        )
        self.add_history(conn, order_id, status, actor=actor, reason=reason)

    def add_history(
        self, conn: Conn, order_id: str, status: OrderStatus, *, actor: str,
        reason: str | None = None,
    ) -> None:
        conn.execute(
            "INSERT INTO order_history (order_id, status, reason, actor) VALUES (%s, %s, %s, %s)",
            (order_id, str(status), reason, actor),
        )

    def stale_pending(self, conn: Conn, older_than_s: int, limit: int = 25) -> list[dict[str, Any]]:
        rows = conn.execute(
            "SELECT order_id, correlation_id, traceparent FROM orders "
            "WHERE status = 'PENDING' AND created_at < now() - make_interval(secs => %s) "
            "ORDER BY created_at LIMIT %s",
            (older_than_s, limit),
        ).fetchall()
        return plain(rows)


# ---------------------------------------------------------------------- outbox


class OutboxRepository:
    def add(self, conn: Conn, aggregate_id: str, event_type: str, payload: dict[str, Any]) -> int:
        row = conn.execute(
            "INSERT INTO outbox (aggregate_id, event_type, payload) VALUES (%s, %s, %s) "
            "RETURNING id",
            (aggregate_id, event_type, Jsonb(payload)),
        ).fetchone()
        assert row is not None
        return int(row["id"])

    def claim_unpublished(self, conn: Conn, limit: int = 50) -> list[dict[str, Any]]:
        """Trava as linhas pendentes. SKIP LOCKED deixa vários relays rodarem
        em paralelo sem publicar o mesmo evento duas vezes ao mesmo tempo."""
        rows = conn.execute(
            "SELECT id, aggregate_id, event_type, payload, attempts FROM outbox "
            "WHERE published_at IS NULL ORDER BY id LIMIT %s FOR UPDATE SKIP LOCKED",
            (limit,),
        ).fetchall()
        result = []
        for row in rows:
            payload = row["payload"]
            if isinstance(payload, str):
                payload = json.loads(payload)
            result.append({**plain(row), "payload": payload})
        return result

    def mark_published(self, conn: Conn, outbox_id: int) -> None:
        conn.execute(
            "UPDATE outbox SET published_at = now(), attempts = attempts + 1 "
            "WHERE id = %s AND published_at IS NULL",
            (outbox_id,),
        )

    def record_failure(self, conn: Conn, outbox_id: int, error: str) -> None:
        conn.execute(
            "UPDATE outbox SET attempts = attempts + 1, last_error = %s WHERE id = %s",
            (error[:500], outbox_id),
        )

    def backlog(self, conn: Conn) -> int:
        row = conn.execute(
            "SELECT count(*) AS n FROM outbox WHERE published_at IS NULL"
        ).fetchone()
        return int(row["n"]) if row else 0
