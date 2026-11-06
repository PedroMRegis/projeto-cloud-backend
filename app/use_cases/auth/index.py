"""Rotas de conta: cadastro, login, logout e sessão atual."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Response

from app.adapters import db
from app.adapters.passwords import Argon2PasswordHasher
from app.adapters.repositories import UserRepository
from app.adapters.tokens import JwtTokenService
from app.domain.user import AuthUser
from app.middlewares.rate_limiter import rate_limit
from app.middlewares.validate_auth_token import COOKIE_NAME, require_user
from app.shared.config import settings
from app.use_cases.auth.auth_dto import LoginRequest, RegisterRequest
from app.use_cases.auth.login_use_case import LoginUseCase
from app.use_cases.auth.register_use_case import RegisterUseCase

router = APIRouter(prefix="/api/auth", tags=["conta"])

_users = UserRepository()
_hasher = Argon2PasswordHasher()
_tokens = JwtTokenService()


def _set_session(response: Response, token: str) -> None:
    cfg = settings()
    response.set_cookie(
        COOKIE_NAME, token, max_age=cfg.auth_session_hours * 3600, path="/",
        httponly=True, secure=cfg.auth_cookie_secure, samesite="lax",
    )


def _public(user: dict[str, Any]) -> dict[str, str]:
    return {key: user[key] for key in ("user_id", "email", "name", "role")}


@router.post("/register", status_code=201, dependencies=[Depends(rate_limit(10))])
def register(payload: RegisterRequest, response: Response) -> dict[str, str]:
    user, token = RegisterUseCase(_users, _hasher, _tokens, db.transaction).execute(payload)
    _set_session(response, token)
    return _public(user)


@router.post("/login", dependencies=[Depends(rate_limit(10))])
def login(payload: LoginRequest, response: Response) -> dict[str, str]:
    user, token = LoginUseCase(_users, _hasher, _tokens, db.transaction).execute(payload)
    _set_session(response, token)
    return _public(user)


@router.post("/logout", status_code=204, response_model=None)
def logout(response: Response) -> None:
    cfg = settings()
    response.delete_cookie(COOKIE_NAME, path="/", httponly=True,
                           secure=cfg.auth_cookie_secure, samesite="lax")


@router.get("/me")
def me(user: AuthUser = Depends(require_user)) -> dict[str, str]:
    return user.to_dict()
