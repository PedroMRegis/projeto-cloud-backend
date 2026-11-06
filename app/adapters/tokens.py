"""Token de sessão: JWT HS256 com emissor e audiência próprios.

O chatbot valida o mesmo token com o mesmo segredo, sem chamar o backend.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import jwt

from app.shared.config import settings

ISSUER = "cirro-backend"
AUDIENCE = "cirro-web"


class AuthDisabled(Exception):
    """AUTH_JWT_SECRET ausente: a loja funciona, mas sem login."""


class JwtTokenService:
    def _secret(self) -> str:
        secret = settings().auth_jwt_secret
        if not secret:
            raise AuthDisabled
        return secret

    def issue(self, user_id: str) -> str:
        now = datetime.now(UTC)
        return jwt.encode(
            {
                "sub": user_id, "iss": ISSUER, "aud": AUDIENCE, "iat": now,
                "exp": now + timedelta(hours=settings().auth_session_hours),
            },
            self._secret(), algorithm="HS256",
        )

    def read(self, token: str) -> dict[str, Any] | None:
        """Payload do token, ou None se ele for inválido ou tiver expirado."""
        try:
            return jwt.decode(token, self._secret(), algorithms=["HS256"],
                              audience=AUDIENCE, issuer=ISSUER, leeway=30,
                              options={"require": ["exp", "sub"]})
        except jwt.InvalidTokenError:
            return None
