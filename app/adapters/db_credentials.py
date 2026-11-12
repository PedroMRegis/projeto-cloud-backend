"""Senha do Postgres relida do Secrets Manager quando o banco a recusa.

O RDS gerencia a senha do usuário principal no Secrets Manager e a troca a cada
7 dias. O ECS injeta a senha em `DB_PASSWORD` só quando a task sobe, então, sem
isto, toda conexão nova falha depois da rotação até alguém refazer o deploy
(incidente de 12/11/2026).

A conexão do pool (`RefreshingConnection`) usa a senha guardada aqui. Se o
Postgres responder "password authentication failed", ela relê o segredo e, se a
senha mudou, tenta de novo uma vez. Sem `DB_SECRET_ARN` (local e testes), nada
muda: vale a senha da conninfo.
"""

from __future__ import annotations

import json
import threading
import time
from typing import Any

import psycopg

from app.adapters import aws
from app.shared.config import settings
from app.shared.logging import get_logger

log = get_logger(__name__)

# Intervalo mínimo entre duas leituras do segredo. Evita martelar o Secrets
# Manager quando a senha errada não é a causa, e cobre a janela da rotação em
# que o banco já tem a senha nova e o segredo ainda aponta para a antiga.
MIN_REFRESH_INTERVAL_S = 10.0

AUTH_FAILED_SQLSTATE = "28P01"

_lock = threading.Lock()
_password: str | None = None
_last_refresh = 0.0


def _fetch_secret_password(secret_arn: str) -> str:
    response = aws.secretsmanager_client().get_secret_value(SecretId=secret_arn)
    return str(json.loads(response["SecretString"])["password"])


def current_password() -> str | None:
    """Senha a usar na próxima conexão, ou None para manter a da conninfo."""
    global _password
    cfg = settings()
    if not cfg.db_secret_arn:
        return None
    with _lock:
        if _password is None:
            _password = cfg.db_password or None
        return _password


def refresh_password() -> bool:
    """Relê o segredo. Devolve True se a senha mudou."""
    global _password, _last_refresh
    secret_arn = settings().db_secret_arn
    if not secret_arn:
        return False
    with _lock:
        now = time.monotonic()
        if now - _last_refresh < MIN_REFRESH_INTERVAL_S:
            return False
        _last_refresh = now
        try:
            fresh = _fetch_secret_password(secret_arn)
        except Exception:
            log.exception("falha ao reler a senha do banco no Secrets Manager")
            return False
        changed = fresh != _password
        _password = fresh
    if changed:
        log.warning("senha do banco relida do Secrets Manager depois de rotação")
    return changed


def reset() -> None:
    global _password, _last_refresh
    with _lock:
        _password = None
        _last_refresh = 0.0


def is_auth_failure(exc: BaseException) -> bool:
    if getattr(exc, "sqlstate", None) == AUTH_FAILED_SQLSTATE:
        return True
    return "password authentication failed" in str(exc)


class RefreshingConnection(psycopg.Connection[Any]):
    """Conexão que troca a senha velha pela atual e tenta de novo uma vez."""

    @classmethod
    def connect(cls, conninfo: str = "", **kwargs: Any) -> Any:  # type: ignore[override]
        password = current_password()
        if password is not None:
            kwargs["password"] = password
        try:
            return super().connect(conninfo, **kwargs)
        except psycopg.OperationalError as exc:
            if not is_auth_failure(exc):
                raise
            # Outra thread pode já ter relido a senha: vale tentar de novo sempre
            # que a senha guardada não for mais a que acabou de falhar.
            refresh_password()
            fresh = current_password()
            if fresh is None or fresh == password:
                raise
            kwargs["password"] = fresh
            return super().connect(conninfo, **kwargs)
