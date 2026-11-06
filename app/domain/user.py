"""Identidade de quem está autenticado."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class Role(StrEnum):
    CUSTOMER = "customer"
    ADMIN = "admin"


@dataclass(frozen=True)
class AuthUser:
    user_id: str
    email: str
    name: str
    role: Role

    @property
    def is_admin(self) -> bool:
        return self.role == Role.ADMIN

    def to_dict(self) -> dict[str, str]:
        return {"user_id": self.user_id, "email": self.email, "name": self.name,
                "role": str(self.role)}
