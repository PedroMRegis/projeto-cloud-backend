"""Pool de conexões PostgreSQL e aplicação de migrations.

Um pool por processo. As conexões devolvem linhas como `dict`, o que mantém os
repositórios legíveis sem ORM.

As migrations são arquivos SQL numerados em `app/migrations/`, aplicados em
ordem e registrados em `schema_migrations`. Rodam sob `pg_advisory_lock`: se
várias tasks sobem juntas (deploy ou scale-out), uma aplica e as outras
esperam, sem corrida no schema.
"""

from __future__ import annotations

import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from app.adapters.db_credentials import RefreshingConnection
from app.shared import faults
from app.shared.config import settings
from app.shared.logging import get_logger

log = get_logger(__name__)

MIGRATIONS_DIR = Path(__file__).resolve().parents[1] / "migrations"

# Chave arbitrária, fixa, do advisory lock das migrations.
MIGRATION_LOCK_KEY = 7_340_001

_pool: ConnectionPool | None = None
_pool_lock = threading.Lock()


def pool() -> ConnectionPool:
    global _pool
    with _pool_lock:
        if _pool is None:
            cfg = settings()
            _pool = ConnectionPool(
                conninfo=cfg.conninfo(),
                min_size=cfg.db_pool_min,
                max_size=cfg.db_pool_max,
                kwargs={"row_factory": dict_row, "autocommit": False},
                # Relê a senha do Secrets Manager depois da rotação do RDS.
                connection_class=RefreshingConnection,
                # Não bloquear o start da task se o banco ainda não respondeu:
                # o /health continua verde e o /ready mostra o problema.
                open=False,
                timeout=10,
                name=cfg.service_name,
            )
            _pool.open(wait=False)
        return _pool


def close_pool() -> None:
    global _pool
    with _pool_lock:
        if _pool is not None:
            _pool.close()
            _pool = None


@contextmanager
def transaction() -> Iterator[psycopg.Connection[dict[str, Any]]]:
    """Conexão do pool dentro de uma transação: commit no fim, rollback no erro."""
    faults.maybe_fail("db_error_rate")
    with pool().connection() as conn, conn.transaction():
        yield conn


def ping() -> None:
    with pool().connection() as conn:
        conn.execute("SELECT 1")


def _migration_files() -> list[Path]:
    return sorted(MIGRATIONS_DIR.glob("*.sql"))


def migrate(conninfo: str | None = None) -> list[str]:
    """Aplica as migrations pendentes. Devolve as versões aplicadas agora."""
    applied_now: list[str] = []
    with RefreshingConnection.connect(conninfo or settings().conninfo(), autocommit=True) as conn:
        conn.execute("SELECT pg_advisory_lock(%s)", (MIGRATION_LOCK_KEY,))
        try:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations ("
                " version text PRIMARY KEY,"
                " applied_at timestamptz NOT NULL DEFAULT now())"
            )
            done = {
                row[0]
                for row in conn.execute("SELECT version FROM schema_migrations").fetchall()
            }
            for path in _migration_files():
                version = path.stem
                if version in done:
                    continue
                log.info("aplicando migration", extra={"version": version})
                with conn.transaction():
                    conn.execute(path.read_text(encoding="utf-8"))
                    conn.execute(
                        "INSERT INTO schema_migrations (version) VALUES (%s)", (version,)
                    )
                applied_now.append(version)
        finally:
            conn.execute("SELECT pg_advisory_unlock(%s)", (MIGRATION_LOCK_KEY,))
    if applied_now:
        log.info("migrations aplicadas", extra={"versions": applied_now})
    return applied_now
