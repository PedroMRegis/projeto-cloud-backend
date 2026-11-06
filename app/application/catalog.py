"""Consultas ao catálogo: listagem, detalhe, disponibilidade e busca híbrida.

A busca combina dois rankings com Reciprocal Rank Fusion (RRF):

* **por palavra-chave** (SQL com pesos por campo, radical em português, prefixo e
  correção de digitação), que acerta título, autor e assunto;
* **semântica** (pgvector), que acerta descrições vagas como "um livro sobre
  vigilância" mesmo sem nenhuma palavra em comum com o catálogo.

Se a API de embeddings estiver desligada ou falhar, a busca semântica
simplesmente não entra no ranking: a resposta continua vindo, só menos esperta.
"""

from __future__ import annotations

from typing import Any

from app.adapters import db, embeddings
from app.adapters.repositories import ProductRepository
from app.domain.keywords import extract_keywords
from app.shared import metrics

RRF_K = 60

_products = ProductRepository()


def brl(cents: int) -> str:
    return f"R$ {cents / 100:,.2f}".replace(",", "_").replace(".", ",").replace("_", ".")


def present(product: dict[str, Any]) -> dict[str, Any]:
    """Formato público do produto: sem embedding, com preço formatado."""
    stock = int(product.get("stock", 0))
    return {
        "product_id": product["product_id"],
        "title": product["title"],
        "author": product["author"],
        "category": product["category"],
        "tagline": product.get("tagline", ""),
        "description": product.get("description", ""),
        "original_year": product.get("original_year"),
        "price_cents": int(product["price_cents"]),
        "price": brl(int(product["price_cents"])),
        "stock": stock,
        "in_stock": stock > 0,
    }


def _fuse(rankings: list[list[dict[str, Any]]], limit: int) -> list[dict[str, Any]]:
    scores: dict[str, float] = {}
    by_id: dict[str, dict[str, Any]] = {}
    for ranking in rankings:
        for position, product in enumerate(ranking):
            pid = product["product_id"]
            by_id.setdefault(pid, product)
            scores[pid] = scores.get(pid, 0.0) + 1.0 / (RRF_K + position + 1)
    ordered = sorted(scores, key=lambda pid: (-scores[pid], by_id[pid]["title"]))
    return [by_id[pid] for pid in ordered[:limit]]


def search(
    query: str, *, category: str | None = None, limit: int = 10
) -> dict[str, Any]:
    limit = max(1, min(limit, 50))
    query = query.strip()

    if not query:
        with db.transaction() as conn:
            found = _products.list(conn, category=category, limit=limit)
        return {"count": len(found), "mode": "list", "products": [present(p) for p in found]}

    # O embedding é calculado fora da transação: é uma chamada de rede externa
    # e não deve segurar conexão do pool.
    vector = embeddings.embed(query, task="RETRIEVAL_QUERY")

    with db.transaction() as conn:
        lexical = _products.search_lexical(conn, extract_keywords(query),
                                           category=category, limit=limit)
        semantic = (
            _products.search_semantic(
                conn, embeddings.to_pgvector(vector), category=category, limit=limit
            )
            if vector is not None
            else []
        )

    mode = "hybrid" if vector is not None else "lexical"
    found = _fuse([lexical, semantic], limit) if semantic else lexical
    metrics.emit("CatalogSearches", 1, mode=mode, results=len(found))
    return {"count": len(found), "mode": mode, "products": [present(p) for p in found]}


def list_products(
    *, category: str | None, sort: str, limit: int, offset: int
) -> dict[str, Any]:
    limit = max(1, min(limit, 100))
    with db.transaction() as conn:
        found = _products.list(conn, category=category, sort=sort, limit=limit, offset=offset)
        total = _products.count(conn, category=category)
    return {"total": total, "count": len(found), "products": [present(p) for p in found]}


def get_product(product_id: str) -> dict[str, Any] | None:
    with db.transaction() as conn:
        product = _products.get(conn, product_id)
    return present(product) if product else None


def related(product_id: str, limit: int = 4) -> list[dict[str, Any]]:
    """Mesma categoria, mais próximos primeiro quando há embedding."""
    with db.transaction() as conn:
        rows = conn.execute(
            """
            SELECT other.product_id
            FROM products base JOIN products other
              ON other.category = base.category AND other.product_id <> base.product_id
            WHERE base.product_id = %(id)s
            ORDER BY CASE WHEN base.embedding IS NOT NULL AND other.embedding IS NOT NULL
                          THEN other.embedding <=> base.embedding END NULLS LAST,
                     other.title
            LIMIT %(limit)s
            """,
            {"id": product_id, "limit": limit},
        ).fetchall()
        found = _products.get_many(conn, [r["product_id"] for r in rows])
    return [present(found[r["product_id"]]) for r in rows if r["product_id"] in found]


def availability(product_id: str, quantity: int) -> dict[str, Any] | None:
    # Leitura direta no primário: um pedido recém-confirmado já debitou o estoque.
    with db.transaction() as conn:
        product = _products.get(conn, product_id)
    if not product:
        return None
    stock = int(product["stock"])
    return {
        "product_id": product_id,
        "title": product["title"],
        "requested": quantity,
        "stock": stock,
        "available": stock >= quantity,
    }


def categories() -> list[dict[str, Any]]:
    with db.transaction() as conn:
        return _products.categories(conn)
