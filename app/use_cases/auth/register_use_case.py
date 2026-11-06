"""Cria a conta de um cliente. Toda conta nova nasce com o papel `customer`."""

from __future__ import annotations

from typing import Any

from app.application.sales import BusinessError
from app.use_cases.auth.auth_dto import RegisterRequest
from app.use_cases.auth.ports import PasswordHasher, TokenIssuer, Transaction, UserStore


class RegisterUseCase:
    def __init__(self, users: UserStore, hasher: PasswordHasher, tokens: TokenIssuer,
                 transaction: Transaction) -> None:
        self._users = users
        self._hasher = hasher
        self._tokens = tokens
        self._transaction = transaction

    def execute(self, dto: RegisterRequest) -> tuple[dict[str, Any], str]:
        password_hash = self._hasher.hash(dto.password)
        with self._transaction() as conn:
            user = self._users.create(conn, email=dto.email, name=dto.name,
                                      password_hash=password_hash)
        if user is None:
            raise BusinessError("este e-mail já tem cadastro", status=409)
        return user, self._tokens.issue(user["user_id"])
