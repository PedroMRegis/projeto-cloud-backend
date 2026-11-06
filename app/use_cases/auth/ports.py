"""O que os casos de uso de autenticação esperam do mundo externo.

Eles dependem destes contratos, e não de Postgres, argon2 ou JWT. Trocar uma
implementação não muda a regra de negócio, e os testes podem usar dublês.
"""

from __future__ import annotations

from collections.abc import Callable
from contextlib import AbstractContextManager
from typing import Any, Protocol

Transaction = Callable[[], AbstractContextManager[Any]]


class UserStore(Protocol):
    def create(
        self, conn: Any, *, email: str, name: str, password_hash: str
    ) -> dict[str, Any] | None: ...

    def by_email(self, conn: Any, email: str) -> dict[str, Any] | None: ...


class PasswordHasher(Protocol):
    def hash(self, password: str) -> str: ...

    def verify(self, password_hash: str, password: str) -> bool: ...

    def burn_time(self, password: str) -> None: ...


class TokenIssuer(Protocol):
    def issue(self, user_id: str) -> str: ...
