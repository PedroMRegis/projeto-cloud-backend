"""Confere as credenciais e abre a sessão."""

from __future__ import annotations

from typing import Any

from app.application.sales import BusinessError
from app.use_cases.auth.auth_dto import LoginRequest
from app.use_cases.auth.ports import PasswordHasher, TokenIssuer, Transaction, UserStore

# Mesma mensagem para e-mail e senha: a resposta não revela quem tem cadastro.
INVALID_CREDENTIALS = "e-mail ou senha incorretos"


class LoginUseCase:
    def __init__(self, users: UserStore, hasher: PasswordHasher, tokens: TokenIssuer,
                 transaction: Transaction) -> None:
        self._users = users
        self._hasher = hasher
        self._tokens = tokens
        self._transaction = transaction

    def execute(self, dto: LoginRequest) -> tuple[dict[str, Any], str]:
        with self._transaction() as conn:
            user = self._users.by_email(conn, dto.email)
        if user is None:
            self._hasher.burn_time(dto.password)
            raise BusinessError(INVALID_CREDENTIALS, status=401)
        if not self._hasher.verify(user["password_hash"], dto.password) or not user["is_active"]:
            raise BusinessError(INVALID_CREDENTIALS, status=401)
        return user, self._tokens.issue(user["user_id"])
