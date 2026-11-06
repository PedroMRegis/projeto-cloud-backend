"""Fixtures: PostgreSQL real (pgvector) e SQS em memória (moto).

O banco de teste é o `convcommerce_test` do Postgres do docker-compose:

    docker compose up -d postgres
    pytest

Usar um Postgres de verdade (e não SQLite ou mock) é deliberado: o que se
testa aqui é justamente SQL específico do Postgres — `FOR UPDATE`,
`SKIP LOCKED`, savepoint, full-text em português e pgvector.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import boto3
import psycopg
import pytest

ROOT = Path(__file__).resolve().parents[1]
SEED_SQL = ROOT / "app" / "migrations" / "0002_seed_catalog.sql"

TEST_DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    "postgresql://convcommerce:convcommerce@localhost:5433/convcommerce_test",
)

TABLES = (
    "outbox, order_history, order_items, orders, quote_items, quotes, "
    "stock_movements, products, users"
)


@pytest.fixture(autouse=True)
def app_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Credenciais falsas antes de tudo: nenhum teste alcança a AWS real."""
    for key, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_SESSION_TOKEN": "testing",
        "AWS_DEFAULT_REGION": "us-east-2",
        "AWS_REGION": "us-east-2",
        "APP_ENV": "test",
        "DATABASE_URL": TEST_DATABASE_URL,
        "MIGRATE_ON_START": "false",
        "EMBEDDINGS_PROVIDER": "none",
        "GEMINI_API_KEY": "",
        "ADMIN_TOKEN": "test-admin",
        "AUTH_JWT_SECRET": "segredo-de-teste-com-mais-de-trinta-e-dois-bytes",
        "AUTH_COOKIE_SECURE": "false",
        "RATE_LIMIT_DISABLED": "1",
        "ORDERS_QUEUE_NAME": "orders-queue",
        "ORDERS_QUEUE_URL": "",
        "SQS_ENDPOINT": "",
        "FAULTS_PARAMETER": "",
        "DB_POOL_MAX": "4",
    }.items():
        monkeypatch.setenv(key, value)
    _reset_caches()
    yield
    _reset_caches()


def _reset_caches() -> None:
    from app.adapters import aws, db, embeddings, sqs
    from app.shared import config, faults

    db.close_pool()
    config.reset_settings_cache()
    aws.reset_clients()
    sqs.reset_queue_url_cache()
    faults.reset_cache()
    embeddings.reset_breaker()


@pytest.fixture(scope="session")
def _schema() -> None:
    """Recria o schema do zero com as migrations reais, uma vez por sessão."""
    try:
        conn = psycopg.connect(TEST_DATABASE_URL, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError as exc:
        pytest.fail(
            f"PostgreSQL de teste indisponível em {TEST_DATABASE_URL} "
            f"({exc}). Rode: docker compose up -d postgres",
            pytrace=False,
        )
    with conn:
        conn.execute("DROP SCHEMA IF EXISTS public CASCADE")
        conn.execute("CREATE SCHEMA public")
    from app.adapters.db import migrate

    migrate(TEST_DATABASE_URL)


@pytest.fixture
def database(_schema: None) -> Iterator[str]:
    """Banco no estado inicial (catálogo do seed) a cada teste."""
    with psycopg.connect(TEST_DATABASE_URL, autocommit=True) as conn:
        conn.execute(f"TRUNCATE {TABLES} RESTART IDENTITY CASCADE")
        conn.execute(SEED_SQL.read_text(encoding="utf-8"))
    yield TEST_DATABASE_URL


@pytest.fixture
def sql(database: str) -> Iterator[Any]:
    """Conexão auxiliar para os asserts lerem o banco diretamente."""
    from psycopg.rows import dict_row

    with psycopg.connect(database, autocommit=True, row_factory=dict_row) as conn:
        yield conn


@pytest.fixture
def queue(database: str) -> Iterator[dict[str, Any]]:
    """`orders-queue` e `orders-dlq` em memória (moto)."""
    from moto import mock_aws

    with mock_aws():
        import sys

        sys.path.insert(0, str(ROOT / "scripts"))
        from provision_queues import create_queues

        client = boto3.client("sqs", region_name="us-east-2")
        urls = create_queues(client)

        def drain() -> list[dict[str, Any]]:
            messages = client.receive_message(
                QueueUrl=urls["queue"], MaxNumberOfMessages=10, WaitTimeSeconds=0
            ).get("Messages", [])
            for message in messages:
                client.delete_message(QueueUrl=urls["queue"],
                                      ReceiptHandle=message["ReceiptHandle"])
            return messages

        yield {"client": client, "urls": urls, "drain": drain}


@pytest.fixture
def api(queue: dict[str, Any]) -> Iterator[Any]:
    from fastapi.testclient import TestClient

    from app.api.main import app

    with TestClient(app) as client:
        yield client
