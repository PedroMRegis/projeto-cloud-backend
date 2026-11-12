"""Clientes boto3 compartilhados.

Um cliente por processo: criar cliente boto3 por requisição custa centenas de
milissegundos. O endpoint local do SQS (ElasticMQ) entra por variável de
ambiente, o que mantém o código idêntico em local e na AWS.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Any

import boto3
from botocore.config import Config

from app.shared.config import settings

_BOTO_CONFIG = Config(
    retries={"max_attempts": 5, "mode": "adaptive"},
    connect_timeout=3,
    read_timeout=10,
    user_agent_extra="convcommerce",
)

# Long polling do SQS espera até 20 s (ver app/adapters/sqs.py), com folga
# para a viagem de rede.
LONG_POLL_READ_TIMEOUT_S = 35


@lru_cache(maxsize=1)
def sqs_client() -> Any:
    """Client de SQS com `read_timeout` maior que o long polling.

    O `receive_message` com `WaitTimeSeconds=20` mantém a conexão aberta por até
    20 s. Com o `read_timeout` padrão de 10 s, **toda** chamada de long polling
    estouraria por timeout antes de a fila responder.
    """
    cfg = settings()
    sqs_config = _BOTO_CONFIG.merge(Config(read_timeout=LONG_POLL_READ_TIMEOUT_S))
    kwargs: dict[str, Any] = {"region_name": cfg.region, "config": sqs_config}
    if cfg.sqs_endpoint:
        kwargs["endpoint_url"] = cfg.sqs_endpoint
    return boto3.client("sqs", **kwargs)


@lru_cache(maxsize=1)
def ssm_client() -> Any:
    return boto3.client("ssm", region_name=settings().region, config=_BOTO_CONFIG)


@lru_cache(maxsize=1)
def bedrock_client() -> Any:
    """Sem retry: a busca prefere cair para o full-text a esperar o embedding."""
    cfg = settings()
    config = Config(
        retries={"total_max_attempts": 1, "mode": "standard"},
        connect_timeout=2,
        read_timeout=cfg.embeddings_timeout_s,
        user_agent_extra="convcommerce",
    )
    return boto3.client("bedrock-runtime", region_name=cfg.region, config=config)


@lru_cache(maxsize=1)
def secretsmanager_client() -> Any:
    return boto3.client("secretsmanager", region_name=settings().region, config=_BOTO_CONFIG)


def reset_clients() -> None:
    for factory in (sqs_client, ssm_client, bedrock_client, secretsmanager_client):
        factory.cache_clear()
