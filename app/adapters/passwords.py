"""Hash de senha com argon2id."""

from __future__ import annotations

from argon2 import PasswordHasher
from argon2 import exceptions as argon2_exceptions


class Argon2PasswordHasher:
    def __init__(self) -> None:
        self._hasher = PasswordHasher()
        # Conta inexistente também paga uma verificação: sem isso, o tempo de
        # resposta revelaria quais e-mails têm cadastro.
        self._decoy = self._hasher.hash("senha-que-nao-pertence-a-ninguem")

    def hash(self, password: str) -> str:
        return self._hasher.hash(password)

    def verify(self, password_hash: str, password: str) -> bool:
        try:
            return self._hasher.verify(password_hash, password)
        except (argon2_exceptions.VerificationError, argon2_exceptions.InvalidHashError):
            return False

    def burn_time(self, password: str) -> None:
        self.verify(self._decoy, password)
