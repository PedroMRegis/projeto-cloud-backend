"""Cria `orders-queue` e `orders-dlq` (redrive em 3 tentativas).

Usado em local (ElasticMQ) e nos testes (moto). Na AWS as filas são criadas
pelo console/CLI em Ohio e pelo Terraform em São Paulo, com os mesmos
parâmetros (PLANO §8.3).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any

import boto3

QUEUE = "orders-queue"
DLQ = "orders-dlq"
MAX_RECEIVE_COUNT = 3


def create_queues(sqs: Any) -> dict[str, str]:
    dlq_url = sqs.create_queue(
        QueueName=DLQ, Attributes={"MessageRetentionPeriod": str(14 * 86400)}
    )["QueueUrl"]
    dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq_url, AttributeNames=["QueueArn"])[
        "Attributes"
    ]["QueueArn"]
    queue_url = sqs.create_queue(
        QueueName=QUEUE,
        Attributes={
            "VisibilityTimeout": "60",
            "ReceiveMessageWaitTimeSeconds": "20",
            "MessageRetentionPeriod": str(4 * 86400),
            "RedrivePolicy": json.dumps(
                {"deadLetterTargetArn": dlq_arn, "maxReceiveCount": str(MAX_RECEIVE_COUNT)}
            ),
        },
    )["QueueUrl"]
    return {"queue": queue_url, "dlq": dlq_url}


def main() -> int:
    parser = argparse.ArgumentParser()
    # Sem região padrão: vem de --region ou de AWS_REGION (o compose define).
    parser.add_argument("--region", default=os.environ.get("AWS_REGION"))
    args = parser.parse_args()
    if not args.region:
        parser.error("informe --region ou defina AWS_REGION")

    kwargs: dict[str, Any] = {"region_name": args.region}
    if os.environ.get("SQS_ENDPOINT"):
        kwargs["endpoint_url"] = os.environ["SQS_ENDPOINT"]
    sqs = boto3.client("sqs", **kwargs)

    # A imagem do ElasticMQ não tem shell para healthcheck: a espera é aqui.
    for attempt in range(30):
        try:
            print(json.dumps(create_queues(sqs)))
            return 0
        except Exception as exc:  # noqa: BLE001
            print(f"fila indisponível ({type(exc).__name__}), tentativa {attempt + 1}",
                  file=sys.stderr)
            time.sleep(2)
    return 1


if __name__ == "__main__":
    sys.exit(main())
