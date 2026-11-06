"""Cotação e pedido: as operações comerciais que o vendedor de IA dispara.

Regra de segurança central: **o cliente (ou o LLM) nunca define preço**. A
cotação recebe só produtos, quantidades e um desconto *pedido*; o preço vem do
banco e o teto de desconto vem do domínio (`app/domain/pricing.py`).

Fluxo do pedido (ADR 0002):

1. Numa única transação: valida a cotação, insere o pedido PENDING
   (`order_id = quote_id`, então no máximo um pedido por cotação), os itens, o
   histórico e o evento no **outbox**.
2. Depois do commit, tenta publicar o evento no SQS na hora. Se falhar, o
   evento continua no outbox e o relay do order-worker publica em segundos.
"""

from __future__ import annotations

import uuid
from typing import Any

from app.adapters import db, sqs
from app.adapters.repositories import (
    OrderRepository,
    OutboxRepository,
    ProductRepository,
    QuoteRepository,
)
from app.application.catalog import brl
from app.domain.order import OrderStatus, RejectionReason
from app.domain.pricing import MAX_QTY_PER_ITEM, QuoteItem, build_quote
from app.domain.user import AuthUser
from app.shared import metrics
from app.shared.config import settings
from app.shared.context import correlation_id, traceparent
from app.shared.logging import get_logger, mask_name

log = get_logger(__name__)

ORDER_PLACED = "OrderPlaced"

_products = ProductRepository()
_quotes = QuoteRepository()
_orders = OrderRepository()
_outbox = OutboxRepository()


class BusinessError(Exception):
    """Erro de negócio com mensagem para o cliente (HTTP 4xx)."""

    def __init__(self, message: str, *, status: int = 422) -> None:
        super().__init__(message)
        self.status = status


def _valid_uuid(value: str, label: str) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except ValueError as exc:
        raise BusinessError(f"{label} inválido", status=404) from exc


# --------------------------------------------------------------------- cotação


def _merge_items(items: list[dict[str, Any]]) -> dict[str, int]:
    """Soma quantidades do mesmo produto ("2 do X" + "1 do X" = 3 do X)."""
    merged: dict[str, int] = {}
    for item in items:
        pid = str(item["product_id"]).strip()
        merged[pid] = merged.get(pid, 0) + int(item["quantity"])
    return merged


def present_quote(quote: dict[str, Any], note: str | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "quote_id": quote["quote_id"],
        "conversation_id": quote["conversation_id"],
        "items": [
            {
                "product_id": i["product_id"],
                "title": i.get("title"),
                "author": i.get("author"),
                "quantity": int(i["quantity"]),
                "unit_price_cents": int(i["unit_price_cents"]),
                "unit_price": brl(int(i["unit_price_cents"])),
            }
            for i in quote["items"]
        ],
        "subtotal_cents": int(quote["subtotal_cents"]),
        "subtotal": brl(int(quote["subtotal_cents"])),
        "discount_pct": int(quote["discount_pct"]),
        "discount_cents": int(quote["discount_cents"]),
        "max_discount_pct": int(quote["max_discount_pct"]),
        "total_cents": int(quote["total_cents"]),
        "total": brl(int(quote["total_cents"])),
        "expires_at": quote["expires_at"],
    }
    if note:
        result["note"] = note
    return result


def create_quote(
    conversation_id: str, items: list[dict[str, Any]], requested_discount_pct: int = 0
) -> dict[str, Any]:
    if not conversation_id:
        raise BusinessError("conversation_id é obrigatório")
    if not items:
        raise BusinessError("informe pelo menos um item")

    try:
        merged = _merge_items(items)
    except (KeyError, TypeError, ValueError) as exc:
        raise BusinessError("itens inválidos: use product_id e quantity") from exc

    requested = max(0, int(requested_discount_pct or 0))
    quote_id = str(uuid.uuid4())

    with db.transaction() as conn:
        catalog = _products.get_many(conn, list(merged))
        missing = [pid for pid in merged if pid not in catalog]
        if missing:
            raise BusinessError(f"produtos inexistentes: {', '.join(missing)}", status=404)
        try:
            quote = build_quote(
                tuple(
                    # O preço vem do banco, nunca do chamador.
                    QuoteItem(pid, qty, int(catalog[pid]["price_cents"]))
                    for pid, qty in merged.items()
                ),
                requested,
            )
        except ValueError as exc:
            raise BusinessError(str(exc)) from exc

        _quotes.create(
            conn,
            quote_id=quote_id,
            conversation_id=conversation_id,
            quote=quote,
            requested_discount_pct=requested,
            ttl_minutes=settings().quote_ttl_minutes,
        )
        stored = _quotes.get(conn, quote_id)
    assert stored is not None

    metrics.emit("QuotesCreated", 1, discount_pct=quote.discount_pct)

    note = None
    if quote.discount_was_capped:
        note = (
            "O desconto pedido excede o permitido para este carrinho. "
            f"Aplicado o máximo de {quote.max_discount_pct}%."
        )
    elif quote.max_discount_pct > quote.discount_pct:
        note = f"Este carrinho permite até {quote.max_discount_pct}% de desconto."
    return present_quote(stored, note)


def get_quote(quote_id: str) -> dict[str, Any] | None:
    quote_id = _valid_uuid(quote_id, "quote_id")
    with db.transaction() as conn:
        quote = _quotes.get(conn, quote_id)
    return present_quote(quote) if quote else None


# ---------------------------------------------------------------------- pedido


def present_order(order: dict[str, Any]) -> dict[str, Any]:
    result = {
        "order_id": order["order_id"],
        "conversation_id": order["conversation_id"],
        "status": order["status"],
        # Mascarado: a rota é pública e não deve devolver PII.
        "customer_name": mask_name(order.get("customer_name")),
        "items": [
            {
                "product_id": i["product_id"],
                "title": i.get("title"),
                "author": i.get("author"),
                "quantity": int(i["quantity"]),
                "unit_price": brl(int(i["unit_price_cents"])),
            }
            for i in order.get("items", [])
        ],
        "subtotal": brl(int(order["subtotal_cents"])),
        "discount_pct": int(order["discount_pct"]),
        "total_cents": int(order["total_cents"]),
        "total": brl(int(order["total_cents"])),
        "created_at": order["created_at"],
        "updated_at": order["updated_at"],
        "history": order.get("history", []),
    }
    if order["status"] == OrderStatus.REJECTED:
        reason = order.get("reason") or RejectionReason.OUT_OF_STOCK
        result["reason"] = reason
        result["explanation"] = (
            "Estoque insuficiente no momento da confirmação."
            if reason == RejectionReason.OUT_OF_STOCK
            else str(reason)
        )
    return result


def _event_payload(order_id: str, corr: str | None, trace: str | None) -> dict[str, str]:
    payload = {"order_id": order_id}
    if corr:
        payload["correlation_id"] = corr
    if trace:
        payload["traceparent"] = trace
    return payload


def place_order(
    quote_id: str, conversation_id: str, customer_name: str, user_id: str | None = None
) -> tuple[dict[str, Any], bool]:
    """Registra o pedido. Devolve (pedido, criado_agora)."""
    quote_id = _valid_uuid(quote_id, "quote_id")
    name = (customer_name or "").strip()
    if len(name) < 2:
        raise BusinessError("informe o nome do cliente para registrar o pedido")

    corr, trace = correlation_id(), traceparent()
    outbox_id: int | None = None

    with db.transaction() as conn:
        quote = _quotes.get(conn, quote_id)
        if not quote:
            raise BusinessError("cotação não existe", status=404)
        if quote["conversation_id"] != conversation_id:
            # Não revela que a cotação existe: só que não serve aqui.
            raise BusinessError("cotação não pertence a esta conversa", status=403)

        existing = _orders.get(conn, quote_id)
        if existing:
            log.info("pedido já existia para a cotação", extra={"order_id": quote_id})
            return present_order(existing), False
        if quote["expired"]:
            raise BusinessError("cotação expirada, crie uma nova", status=409)

        created = _orders.create_pending(
            conn, quote=quote, customer_name=name, correlation_id=corr, traceparent=trace,
            user_id=user_id,
        )
        if created:
            outbox_id = _outbox.add(
                conn, quote_id, ORDER_PLACED, _event_payload(quote_id, corr, trace)
            )
        order = _orders.get(conn, quote_id)
    assert order is not None

    if not created:
        # Corrida com outra requisição da mesma cotação: o ON CONFLICT segurou.
        return present_order(order), False

    metrics.emit("OrdersCreated", 1, total_cents=order["total_cents"])
    log.info("pedido registrado",
             extra={"order_id": quote_id, "customer": mask_name(name)})

    if outbox_id is not None:
        publish_now(outbox_id, quote_id, corr, trace)
    return present_order(order), True


def publish_now(outbox_id: int, order_id: str, corr: str | None, trace: str | None) -> bool:
    """Publicação imediata, best-effort. O relay do worker cobre a falha."""
    try:
        sqs.send_order_event(order_id, corr, trace)
    except Exception as exc:  # noqa: BLE001
        log.warning("publicação imediata falhou, fica para o relay do outbox",
                    extra={"error": type(exc).__name__, "order_id": order_id})
        metrics.emit("OutboxPublishDeferred", 1)
        return False
    try:
        with db.transaction() as conn:
            _outbox.mark_published(conn, outbox_id)
    except Exception:  # noqa: BLE001
        # Publicado mas não marcado: o relay publica de novo e o worker
        # descarta como duplicata. Duplicata é aceitável; perda não.
        log.warning("evento publicado mas não marcado no outbox", extra={"order_id": order_id})
    return True


def get_order(
    order_id: str, conversation_id: str | None = None, viewer: AuthUser | None = None
) -> dict[str, Any] | None:
    order_id = _valid_uuid(order_id, "order_id")
    with db.transaction() as conn:
        order = _orders.get(conn, order_id)
    if not order:
        return None
    owner = order.get("user_id")
    if owner and not (viewer and (viewer.is_admin or viewer.user_id == owner)):
        # Pedido de uma conta: para os outros, é como se não existisse.
        return None
    if conversation_id and order["conversation_id"] != conversation_id:
        raise BusinessError("pedido não pertence a esta conversa", status=403)
    return present_order(order)


__all__ = [
    "MAX_QTY_PER_ITEM",
    "BusinessError",
    "create_quote",
    "get_order",
    "get_quote",
    "place_order",
]
