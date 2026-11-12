"""Releitura da senha do banco depois da rotação do RDS (incidente de 12/11/2026)."""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import psycopg
import pytest

from app.adapters import db_credentials
from app.adapters.db_credentials import RefreshingConnection
from app.shared.config import settings

SECRET_ARN = "arn:aws:secretsmanager:us-east-2:123456789012:secret:rds!db-teste"


class FakePostgres:
    """Aceita só `accepted`; registra a senha de cada tentativa."""

    def __init__(self, accepted: str) -> None:
        self.accepted = accepted
        self.attempts: list[str | None] = []

    def connect(self, conninfo: str = "", **kwargs: Any) -> str:
        password = kwargs.get("password")
        self.attempts.append(password)
        if password != self.accepted:
            raise psycopg.OperationalError(
                'connection failed: FATAL:  password authentication failed for user "convcommerce"'
            )
        return "conexao"


@pytest.fixture
def secret_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[dict[str, Any]]:
    monkeypatch.setenv("DB_SECRET_ARN", SECRET_ARN)
    monkeypatch.setenv("DB_PASSWORD", "senha-velha")
    settings.cache_clear()
    db_credentials.reset()
    state: dict[str, Any] = {"secret": "senha-nova", "reads": 0}

    def fake_fetch(arn: str) -> str:
        assert arn == SECRET_ARN
        state["reads"] += 1
        return state["secret"]

    monkeypatch.setattr(db_credentials, "_fetch_secret_password", fake_fetch)
    yield state
    settings.cache_clear()
    db_credentials.reset()


def _install(monkeypatch: pytest.MonkeyPatch, server: FakePostgres) -> None:
    monkeypatch.setattr(
        psycopg.Connection, "connect", classmethod(lambda cls, conninfo="", **kw: server.connect(conninfo, **kw))
    )


def test_rele_o_segredo_e_reconecta_depois_da_rotacao(
    monkeypatch: pytest.MonkeyPatch, secret_env: dict[str, Any]
) -> None:
    server = FakePostgres(accepted="senha-nova")
    _install(monkeypatch, server)

    assert RefreshingConnection.connect("host=x") == "conexao"
    assert server.attempts == ["senha-velha", "senha-nova"]
    assert secret_env["reads"] == 1

    # As próximas conexões já usam a senha nova, sem ler o segredo de novo.
    assert RefreshingConnection.connect("host=x") == "conexao"
    assert server.attempts[-1] == "senha-nova"
    assert secret_env["reads"] == 1


def test_sem_mudanca_no_segredo_propaga_o_erro(
    monkeypatch: pytest.MonkeyPatch, secret_env: dict[str, Any]
) -> None:
    secret_env["secret"] = "senha-velha"
    server = FakePostgres(accepted="outra")
    _install(monkeypatch, server)

    with pytest.raises(psycopg.OperationalError):
        RefreshingConnection.connect("host=x")
    assert server.attempts == ["senha-velha"]


def test_releitura_tem_intervalo_minimo(
    monkeypatch: pytest.MonkeyPatch, secret_env: dict[str, Any]
) -> None:
    secret_env["secret"] = "senha-velha"
    _install(monkeypatch, FakePostgres(accepted="outra"))

    for _ in range(3):
        with pytest.raises(psycopg.OperationalError):
            RefreshingConnection.connect("host=x")
    assert secret_env["reads"] == 1


def test_outro_erro_de_conexao_nao_le_o_segredo(
    monkeypatch: pytest.MonkeyPatch, secret_env: dict[str, Any]
) -> None:
    def down(cls: Any, conninfo: str = "", **kw: Any) -> Any:
        raise psycopg.OperationalError("connection timeout expired")

    monkeypatch.setattr(psycopg.Connection, "connect", classmethod(down))
    with pytest.raises(psycopg.OperationalError):
        RefreshingConnection.connect("host=x")
    assert secret_env["reads"] == 0


def test_sem_arn_mantem_a_senha_da_conninfo(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DB_SECRET_ARN", raising=False)
    settings.cache_clear()
    db_credentials.reset()
    seen: list[dict[str, Any]] = []
    monkeypatch.setattr(
        psycopg.Connection, "connect", classmethod(lambda cls, conninfo="", **kw: seen.append(kw) or "ok")
    )

    assert RefreshingConnection.connect("postgresql://u:p@h/db") == "ok"
    assert "password" not in seen[0]
    settings.cache_clear()
