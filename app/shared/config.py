"""Configuração via ambiente. Nenhum segredo tem default."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from functools import lru_cache


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw else default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Settings:
    env: str = field(default_factory=lambda: _env("APP_ENV", "local"))
    region: str = field(default_factory=lambda: _env("AWS_REGION", "us-east-2"))
    service_name: str = field(default_factory=lambda: _env("SERVICE_NAME", "backend-api"))
    log_level: str = field(default_factory=lambda: _env("LOG_LEVEL", "INFO"))

    # PostgreSQL (RDS em produção). Os campos separados casam com o segredo
    # gerenciado pelo RDS no Secrets Manager, que o ECS injeta chave a chave
    # via `secrets.valueFrom` (`<arn>:password::`). DATABASE_URL tem
    # precedência e é o caminho usado em local e nos testes.
    database_url: str = field(default_factory=lambda: _env("DATABASE_URL", ""))
    db_host: str = field(default_factory=lambda: _env("DB_HOST", "localhost"))
    db_port: int = field(default_factory=lambda: _env_int("DB_PORT", 5432))
    db_name: str = field(default_factory=lambda: _env("DB_NAME", "convcommerce"))
    db_user: str = field(default_factory=lambda: _env("DB_USER", "convcommerce"))
    db_password: str = field(default_factory=lambda: _env("DB_PASSWORD", ""))
    # No RDS a conexão exige TLS. Em local o Postgres do compose não tem TLS.
    db_sslmode: str = field(default_factory=lambda: _env("DB_SSLMODE", "prefer"))
    db_pool_min: int = field(default_factory=lambda: _env_int("DB_POOL_MIN", 1))
    db_pool_max: int = field(default_factory=lambda: _env_int("DB_POOL_MAX", 5))
    # Aplica as migrations no start, sob advisory lock: N tasks subindo juntas
    # não disputam o schema, e o ambiente nasce pronto sem passo manual.
    migrate_on_start: bool = field(
        default_factory=lambda: _env_bool("MIGRATE_ON_START", True)
    )

    # SQS. Na AWS a URL é injetada; em local é resolvida pelo nome, porque a
    # URL do ElasticMQ depende da versão.
    sqs_endpoint: str = field(default_factory=lambda: _env("SQS_ENDPOINT", ""))
    orders_queue_url: str = field(default_factory=lambda: _env("ORDERS_QUEUE_URL", ""))
    orders_queue_name: str = field(
        default_factory=lambda: _env("ORDERS_QUEUE_NAME", "orders-queue")
    )

    # Busca semântica. "bedrock" gera embeddings com o Titan v2, "gemini" pela API
    # do Google; "none" deixa só a busca textual (full-text em português), que é
    # o fallback também quando a API de embeddings falha.
    embeddings_provider: str = field(
        default_factory=lambda: _env("EMBEDDINGS_PROVIDER", "none")
    )
    embeddings_model: str = field(
        default_factory=lambda: _env(
            "EMBEDDINGS_MODEL",
            "amazon.titan-embed-text-v2:0"
            if _env("EMBEDDINGS_PROVIDER", "none") == "bedrock"
            else "gemini-embedding-001",
        )
    )
    # Tem de bater com a coluna products.embedding (migration 0003).
    embeddings_dim: int = field(default_factory=lambda: _env_int("EMBEDDINGS_DIM", 1024))
    embeddings_timeout_s: int = field(
        default_factory=lambda: _env_int("EMBEDDINGS_TIMEOUT_S", 4)
    )
    gemini_api_key: str = field(default_factory=lambda: _env("GEMINI_API_KEY", ""))

    # Rotas /api/admin/*. Sem token configurado, o admin fica desligado.
    admin_token: str = field(default_factory=lambda: _env("ADMIN_TOKEN", ""))

    faults_parameter: str = field(default_factory=lambda: _env("FAULTS_PARAMETER", ""))
    quote_ttl_minutes: int = field(default_factory=lambda: _env_int("QUOTE_TTL_MINUTES", 30))

    # order-worker
    worker_threads: int = field(default_factory=lambda: _env_int("WORKER_THREADS", 2))
    outbox_relay_interval_s: int = field(
        default_factory=lambda: _env_int("OUTBOX_RELAY_INTERVAL_S", 5)
    )
    sweeper_interval_s: int = field(
        default_factory=lambda: _env_int("SWEEPER_INTERVAL_S", 300)
    )
    sweeper_pending_age_s: int = field(
        default_factory=lambda: _env_int("SWEEPER_PENDING_AGE_S", 300)
    )
    heartbeat_path: str = field(
        default_factory=lambda: _env("HEARTBEAT_PATH", "/tmp/heartbeat")
    )

    @property
    def is_local(self) -> bool:
        return self.env in ("local", "test")

    def conninfo(self) -> str:
        if self.database_url:
            return self.database_url
        return (
            f"host={self.db_host} port={self.db_port} dbname={self.db_name} "
            f"user={self.db_user} password={self.db_password} "
            f"sslmode={self.db_sslmode} connect_timeout=5 "
            f"application_name={self.service_name}"
        )


@lru_cache(maxsize=1)
def settings() -> Settings:
    return Settings()


def reset_settings_cache() -> None:
    """Usado pelos testes depois de mexer no ambiente."""
    settings.cache_clear()
