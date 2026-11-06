"""Quem está fazendo a requisição.

A sessão chega de duas formas:

* cookie `cirro_session` (HttpOnly), vindo do navegador;
* `Authorization: Bearer`, vindo do chatbot, que repassa a sessão do cliente
  quando registra um pedido em nome dele.

O papel é lido do banco a cada requisição, e não do token: rebaixar ou
desativar uma conta vale na hora.
"""

from __future__ import annotations

from fastapi import Depends, HTTPException, Request

from app.adapters import db
from app.adapters.repositories import UserRepository
from app.adapters.tokens import AuthDisabled, JwtTokenService
from app.domain.user import AuthUser, Role

COOKIE_NAME = "cirro_session"

_users = UserRepository()
_tokens = JwtTokenService()


def _token_from(request: Request) -> str | None:
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        return header.removeprefix("Bearer ").strip() or None
    return request.cookies.get(COOKIE_NAME)


def optional_user(request: Request) -> AuthUser | None:
    """A conta da sessão, ou None para visitante e para sessão inválida."""
    token = _token_from(request)
    if not token:
        return None
    try:
        payload = _tokens.read(token)
    except AuthDisabled:
        return None
    if not payload:
        return None
    with db.transaction() as conn:
        user = _users.by_id(conn, payload["sub"])
    if not user or not user["is_active"]:
        return None
    return AuthUser(user_id=user["user_id"], email=user["email"], name=user["name"],
                    role=Role(user["role"]))


def require_user(user: AuthUser | None = Depends(optional_user)) -> AuthUser:
    if user is None:
        raise HTTPException(status_code=401, detail="faça login para continuar")
    return user
