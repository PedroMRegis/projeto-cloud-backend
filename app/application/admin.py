"""Manutenção do catálogo: o banco é a fonte da verdade, e ele muda por aqui.

Cadastro, edição e ajuste de estoque passam por esta camada (rotas
`/api/admin/*`). Todo ajuste de estoque vira um movimento no livro-razão, com
o autor da mudança, o que dá auditoria sem tabela extra.
"""

from __future__ import annotations

import re
from typing import Any

import psycopg

from app.adapters import db, embeddings
from app.adapters.repositories import NotFound, ProductRepository
from app.application.catalog import present
from app.application.sales import BusinessError
from app.shared import metrics
from app.shared.config import settings
from app.shared.logging import get_logger

log = get_logger(__name__)

_products = ProductRepository()

_ID_RE = re.compile(r"^[A-Z0-9][A-Z0-9_-]{1,31}$")


def _document_text(product: dict[str, Any]) -> str:
    """Texto que representa o livro na busca semântica."""
    return (
        f"{product['title']} — {product['author']}. Categoria: {product['category']}. "
        f"{product.get('tagline', '')} {product.get('description', '')}"
    ).strip()


def _embed_and_store(product: dict[str, Any]) -> bool:
    vector = embeddings.embed(_document_text(product), task="RETRIEVAL_DOCUMENT")
    if vector is None:
        return False
    with db.transaction() as conn:
        _products.set_embedding(
            conn, product["product_id"], embeddings.to_pgvector(vector),
            settings().embeddings_model,
        )
    return True


def create_product(data: dict[str, Any], actor: str) -> dict[str, Any]:
    product_id = str(data.get("product_id", "")).strip().upper()
    if not _ID_RE.match(product_id):
        raise BusinessError("product_id deve ter 2-32 caracteres A-Z, 0-9, _ ou -")
    payload = {
        "product_id": product_id,
        "title": data["title"],
        "author": data["author"],
        "category": data["category"],
        "tagline": data.get("tagline") or "",
        "description": data.get("description") or "",
        "original_year": data.get("original_year"),
        "price_cents": int(data["price_cents"]),
        "stock": int(data.get("stock") or 0),
    }
    try:
        with db.transaction() as conn:
            created = _products.create(conn, payload, actor)
    except psycopg.errors.UniqueViolation as exc:
        raise BusinessError(f"produto {product_id} já existe", status=409) from exc

    log.info("produto criado", extra={"product_id": product_id, "actor": actor})
    metrics.emit("CatalogChanges", 1, change="create")
    # Fora da transação: o cadastro não pode depender da API de embeddings.
    _embed_and_store(created)
    return present(created)


def update_product(product_id: str, fields: dict[str, Any], actor: str) -> dict[str, Any]:
    try:
        with db.transaction() as conn:
            updated = _products.update(conn, product_id, fields)
    except NotFound as exc:
        raise BusinessError("produto não existe", status=404) from exc
    log.info("produto atualizado",
             extra={"product_id": product_id, "actor": actor, "fields": sorted(fields)})
    metrics.emit("CatalogChanges", 1, change="update")
    if not updated.get("has_embedding"):
        _embed_and_store(updated)
    return present(updated)


def adjust_stock(product_id: str, delta: int, actor: str, note: str = "") -> dict[str, Any]:
    if delta == 0:
        raise BusinessError("delta não pode ser zero")
    try:
        with db.transaction() as conn:
            _products.adjust_stock(
                conn, product_id, delta, reason="admin_adjust",
                ref=(note or "ajuste manual")[:120], actor=actor,
            )
            product = _products.get(conn, product_id)
    except NotFound as exc:
        raise BusinessError("produto não existe", status=404) from exc
    except ValueError as exc:
        raise BusinessError(str(exc), status=409) from exc
    log.info("estoque ajustado", extra={"product_id": product_id, "delta": delta, "actor": actor})
    metrics.emit("CatalogChanges", 1, change="stock")
    assert product is not None
    return present(product)


def backfill_embeddings(limit: int = 100) -> dict[str, int]:
    """Gera embeddings que faltam. Idempotente: pode rodar quantas vezes quiser."""
    if not embeddings.enabled():
        return {"pending": -1, "embedded": 0}
    with db.transaction() as conn:
        pending = _products.missing_embeddings(conn, limit)
    embedded = sum(1 for product in pending if _embed_and_store(product))
    log.info("backfill de embeddings", extra={"pending": len(pending), "embedded": embedded})
    return {"pending": len(pending), "embedded": embedded}
