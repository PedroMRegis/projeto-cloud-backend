"""Autorização por papel: separa cliente de administrador."""

from __future__ import annotations

from collections.abc import Callable

from fastapi import Depends, HTTPException

from app.domain.user import AuthUser, Role
from app.middlewares.validate_auth_token import require_user


def require_role(*allowed: Role) -> Callable[[AuthUser], AuthUser]:
    def checker(user: AuthUser = Depends(require_user)) -> AuthUser:
        if user.role not in allowed:
            raise HTTPException(status_code=403, detail="acesso restrito")
        return user

    return checker


require_admin = require_role(Role.ADMIN)
