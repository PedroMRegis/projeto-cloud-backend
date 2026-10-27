"""Acesso ao SQS: publicação de eventos de pedido e consumo com long polling."""

from __future__ import annotations

import json
from typing import Any

from app.adapters.aws import sqs_client
from app.shared.config import settings

MAX_BATCH = 10
WAIT_TIME_SECONDS = 20

_queue_url: str | None = None


def queue_url() -> str:
    """URL da fila de pedidos.

    Preferimos a URL injetada por ambiente (é o que a AWS fornece e evita uma
    chamada de API no start). Sem ela, resolve pelo nome — necessário em local,
    onde a URL do ElasticMQ varia conforme a versão.
    """
    global _queue_url
    if _queue_url:
        return _queue_url

    cfg = settings()
    if cfg.orders_queue_url:
        _queue_url = cfg.orders_queue_url
    else:
        _queue_url = sqs_client().get_queue_url(QueueName=cfg.orders_queue_name)[
            "QueueUrl"
        ]
    return _queue_url


def reset_queue_url_cache() -> None:
    global _queue_url
    _queue_url = None


def receive(max_messages: int = MAX_BATCH) -> list[dict[str, Any]]:
    """Long polling: 20 s de espera evita o custo e o ruído de polling vazio."""
    response = sqs_client().receive_message(
        QueueUrl=queue_url(),
        MaxNumberOfMessages=max(1, min(max_messages, MAX_BATCH)),
        WaitTimeSeconds=WAIT_TIME_SECONDS,
        AttributeNames=["ApproximateReceiveCount"],
        MessageAttributeNames=["All"],
    )
    return response.get("Messages", [])


def delete(receipt_handle: str) -> None:
    sqs_client().delete_message(QueueUrl=queue_url(), ReceiptHandle=receipt_handle)


def release(receipt_handle: str, delay_seconds: int = 0) -> None:
    """Devolve a mensagem à fila imediatamente, sem esperar o visibility timeout."""
    sqs_client().change_message_visibility(
        QueueUrl=queue_url(),
        ReceiptHandle=receipt_handle,
        VisibilityTimeout=max(0, delay_seconds),
    )


def send_order_event(
    order_id: str, correlation_id: str | None = None, traceparent: str | None = None
) -> None:
    """Publica o evento `OrderPlaced`.

    O mesmo formato serve à publicação imediata da API, ao relay do outbox e
    ao sweeper: o worker não sabe (nem precisa saber) quem publicou.
    """
    body = {"order_id": order_id}
    if correlation_id:
        body["correlation_id"] = correlation_id
    if traceparent:
        body["traceparent"] = traceparent
    sqs_client().send_message(QueueUrl=queue_url(), MessageBody=json.dumps(body))
