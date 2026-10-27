"""Processamento assíncrono de pedidos (order-worker).

Garantias:

* **Idempotência.** O SQS Standard entrega *ao menos uma vez*. O pedido é lido
  com `SELECT ... FOR UPDATE`: dois workers com a mesma mensagem se
  serializam na linha, e o segundo encontra o pedido fora de PENDING e trata
  como duplicata. O índice único em `stock_movements` é a segunda barreira.
* **Tudo ou nada.** Debitar o estoque de todos os itens e mudar o status é uma
  transação só. Se faltar estoque de qualquer item, um SAVEPOINT desfaz os
  débitos já feitos e o pedido vira REJECTED.
* **Sem deadlock.** Os itens são debitados sempre na ordem do `product_id`.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from app.adapters import db, sqs
from app.adapters.repositories import OrderRepository, OutboxRepository, ProductRepository
from app.domain.order import OrderStatus, RejectionReason
from app.shared import faults, metrics
from app.shared.logging import get_logger

log = get_logger(__name__)

ACTOR = "order-worker"
# Chave fixa do advisory lock do sweeper: só um worker varre por vez.
SWEEPER_LOCK_KEY = 7_340_002

_products = ProductRepository()
_orders = OrderRepository()
_outbox = OutboxRepository()


class MalformedMessage(Exception):
    """Payload ou pedido que nenhuma repetição vai consertar. Vai para a DLQ."""


class _OutOfStock(Exception):
    def __init__(self, product_id: str) -> None:
        super().__init__(product_id)
        self.product_id = product_id


def process_order(order_id: str) -> str:
    """Processa um pedido. Devolve confirmed | rejected | duplicate.

    Erros transitórios propagam: quem chama decide não apagar a mensagem.
    """
    with db.transaction() as conn:
        order = _orders.get(conn, order_id, for_update=True)
        if order is None:
            raise MalformedMessage(f"pedido {order_id} não existe")

        if order["status"] != OrderStatus.PENDING:
            log.info("mensagem duplicada, pedido já processado",
                     extra={"status": order["status"]})
            metrics.emit("DuplicateMessages", 1)
            return "duplicate"

        faults.maybe_fail("worker_error_rate", "worker_delay_ms")

        try:
            with conn.transaction():  # SAVEPOINT
                for item in order["items"]:
                    if not _products.debit_for_order(
                        conn, item["product_id"], int(item["quantity"]), order_id
                    ):
                        raise _OutOfStock(item["product_id"])
        except _OutOfStock as exc:
            log.warning("estoque insuficiente", extra={"product_id": exc.product_id})
            _orders.set_status(
                conn, order_id, OrderStatus.REJECTED,
                reason=str(RejectionReason.OUT_OF_STOCK), actor=ACTOR,
            )
            metrics.emit("OrdersRejected", 1, reason=str(RejectionReason.OUT_OF_STOCK))
            return "rejected"

        _orders.set_status(conn, order_id, OrderStatus.CONFIRMED, reason=None, actor=ACTOR)

    created_at = order.get("created_at")
    if created_at:
        try:
            age_ms = (datetime.now(UTC) - datetime.fromisoformat(created_at)).total_seconds()
            metrics.emit("OrderProcessingLatency", round(age_ms * 1000, 2), "Milliseconds")
        except ValueError:
            pass
    log.info("pedido confirmado")
    metrics.emit("OrdersConfirmed", 1, total_cents=order.get("total_cents"))
    return "confirmed"


# ------------------------------------------------------------- relay do outbox


def relay_outbox_once(limit: int = 50) -> int:
    """Publica eventos do outbox que a API não conseguiu publicar.

    A linha fica travada (FOR UPDATE SKIP LOCKED) enquanto é publicada e só é
    marcada no mesmo commit. Se o processo morrer depois do envio e antes do
    commit, o evento é publicado de novo: duplicata, que o worker descarta.
    """
    published = 0
    with db.transaction() as conn:
        pending = _outbox.claim_unpublished(conn, limit)
        for event in pending:
            payload: dict[str, Any] = event["payload"]
            try:
                sqs.send_order_event(
                    payload["order_id"], payload.get("correlation_id"), payload.get("traceparent")
                )
            except Exception as exc:  # noqa: BLE001
                _outbox.record_failure(conn, event["id"], type(exc).__name__)
                log.warning("relay não conseguiu publicar", extra={"outbox_id": event["id"]})
                continue
            _outbox.mark_published(conn, event["id"])
            published += 1
        backlog = _outbox.backlog(conn) - published
    if published:
        log.info("relay publicou eventos do outbox", extra={"published": published})
        metrics.emit("OutboxRelayed", published)
    metrics.emit("OutboxBacklog", max(backlog, 0))
    return published


# ---------------------------------------------------------------------- sweeper


def sweep_once(older_than_s: int) -> int:
    """Reenfileira pedidos presos em PENDING (mensagem perdida ou na DLQ).

    Reenfileirar é seguro justamente porque `process_order` é idempotente.
    """
    with db.transaction() as conn:
        locked = conn.execute(
            "SELECT pg_try_advisory_xact_lock(%s) AS ok", (SWEEPER_LOCK_KEY,)
        ).fetchone()
        if not locked or not locked["ok"]:
            return 0
        stale = _orders.stale_pending(conn, older_than_s)

    for order in stale:
        sqs.send_order_event(order["order_id"], order.get("correlation_id"),
                             order.get("traceparent"))
        log.warning("pedido preso reenfileirado pelo sweeper",
                    extra={"order_id": order["order_id"]})
    if stale:
        metrics.emit("SweeperRequeued", len(stale))
    return len(stale)
