"""order-worker: serviço ECS assíncrono que consome `orders-queue`.

Três laços no mesmo processo:

* **consumidores** (N threads): long polling no SQS e `process_order`;
* **relay do outbox** (a cada 5 s): publica eventos que a API não conseguiu;
* **sweeper** (a cada 5 min, um worker por vez via advisory lock):
  reenfileira pedidos presos em PENDING.

Tratamento de mensagens:

* falha transitória **não apaga** a mensagem: ela volta após o visibility
  timeout e, no 3º recebimento, o redrive a manda para `orders-dlq`;
* mensagem malformada também vai para a DLQ, com log ERROR, para ser
  investigada em vez de descartada em silêncio;
* SIGTERM: para de buscar mensagens, termina a atual e sai dentro do
  `stopTimeout` de 30 s.
"""

from __future__ import annotations

import json
import signal
import threading
import time
from typing import Any

from app.adapters import db, sqs
from app.application.fulfillment import (
    MalformedMessage,
    process_order,
    relay_outbox_once,
    sweep_once,
)
from app.shared import context, metrics
from app.shared.config import settings
from app.shared.logging import configure_logging, get_logger

configure_logging()
log = get_logger(__name__)

_shutdown = threading.Event()


def _install_signal_handlers() -> None:
    def handler(signum: int, _frame: Any) -> None:
        log.info("sinal recebido, iniciando shutdown", extra={"signal": signum})
        _shutdown.set()

    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


def _heartbeat() -> None:
    """Toca o arquivo que o health check do container verifica.

    O worker não tem porta HTTP, então o health check é
    `find /tmp/heartbeat -mmin -1`: se o loop travar, o arquivo envelhece e o
    ECS substitui a task.
    """
    try:
        with open(settings().heartbeat_path, "w", encoding="utf-8") as handle:
            handle.write(str(time.time()))
    except OSError as exc:
        log.warning("não foi possível escrever o heartbeat", extra={"error": str(exc)})


def parse_message(body: str) -> dict[str, str]:
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise MalformedMessage(f"corpo não é JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise MalformedMessage("corpo não é um objeto JSON")
    order_id = payload.get("order_id")
    if not isinstance(order_id, str) or not order_id:
        raise MalformedMessage("campo order_id ausente ou inválido")
    return {
        "order_id": order_id,
        "correlation_id": str(payload.get("correlation_id") or ""),
        "traceparent": str(payload.get("traceparent") or ""),
    }


def handle_message(message: dict[str, Any]) -> None:
    receipt = message["ReceiptHandle"]
    receive_count = int(message.get("Attributes", {}).get("ApproximateReceiveCount", 1))
    try:
        parsed = parse_message(message["Body"])
    except MalformedMessage as exc:
        # Não apagar: o redrive leva para a DLQ depois de 3 tentativas.
        log.error("mensagem malformada, será encaminhada à DLQ",
                  extra={"error": str(exc), "receive_count": receive_count})
        metrics.emit("MalformedMessages", 1)
        return

    tokens = context.bind(
        order_id=parsed["order_id"],
        correlation_id=parsed["correlation_id"] or None,
        traceparent=parsed["traceparent"] or None,
    )
    try:
        outcome = process_order(parsed["order_id"])
        sqs.delete(receipt)
        log.info("mensagem processada", extra={"outcome": outcome})
    except MalformedMessage as exc:
        log.error("pedido inválido, será encaminhado à DLQ",
                  extra={"error": str(exc), "receive_count": receive_count})
        metrics.emit("MalformedMessages", 1)
    except Exception as exc:  # noqa: BLE001
        log.error(
            "falha transitória ao processar, mensagem devolvida à fila",
            extra={"error": type(exc).__name__, "receive_count": receive_count},
            exc_info=True,
        )
        metrics.emit("WorkerErrors", 1, error=type(exc).__name__)
    finally:
        context.unbind(tokens)


def _periodic(name: str, interval_s: int, fn: Any) -> None:
    while not _shutdown.wait(interval_s):
        try:
            fn()
        except Exception:  # noqa: BLE001
            log.error(f"{name} falhou neste ciclo", exc_info=True)


def _consumer_loop(worker_index: int) -> None:
    log.info("consumidor iniciado", extra={"worker": worker_index})
    while not _shutdown.is_set():
        try:
            messages = sqs.receive(max_messages=sqs.MAX_BATCH)
            _heartbeat()
            for message in messages:
                if _shutdown.is_set():
                    log.info("shutdown em andamento, devolvendo mensagem à fila")
                    sqs.release(message["ReceiptHandle"])
                    continue
                handle_message(message)
        except Exception:  # noqa: BLE001
            log.error("falha no loop de consumo", exc_info=True)
            metrics.emit("WorkerLoopErrors", 1)
            _shutdown.wait(5)
    log.info("consumidor encerrado", extra={"worker": worker_index})


def main() -> None:
    cfg = settings()
    try:
        resolved_queue = sqs.queue_url()
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(
            f"não foi possível resolver a fila '{cfg.orders_queue_name}': {exc}"
        ) from exc

    _install_signal_handlers()
    _heartbeat()
    log.info("order-worker iniciado",
             extra={"env": cfg.env, "region": cfg.region, "threads": cfg.worker_threads,
                    "queue": resolved_queue})
    metrics.emit("ServiceStart", 1)

    consumers = [
        threading.Thread(target=_consumer_loop, args=(i,), name=f"consumer-{i}")
        for i in range(cfg.worker_threads)
    ]
    background = [
        threading.Thread(
            target=_periodic, args=("relay do outbox", cfg.outbox_relay_interval_s,
                                    relay_outbox_once),
            name="outbox-relay", daemon=True,
        ),
        threading.Thread(
            target=_periodic,
            args=("sweeper", cfg.sweeper_interval_s,
                  lambda: sweep_once(cfg.sweeper_pending_age_s)),
            name="sweeper", daemon=True,
        ),
    ]
    for thread in consumers + background:
        thread.start()
    for thread in consumers:
        thread.join()
    db.close_pool()
    log.info("order-worker encerrado")


if __name__ == "__main__":
    main()
