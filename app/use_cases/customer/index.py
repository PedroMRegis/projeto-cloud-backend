"""Rotas do cliente logado. Cada uma enxerga só os dados da própria conta."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Query

from app.adapters.repositories import OrderRepository
from app.domain.user import AuthUser
from app.middlewares.validate_auth_token import require_user
from app.use_cases.customer.list_my_orders_use_case import ListMyOrdersUseCase

router = APIRouter(prefix="/api/me", tags=["cliente"])

_orders = OrderRepository()


@router.get("/orders")
def my_orders(limit: int = Query(default=50, ge=1, le=100), offset: int = Query(default=0, ge=0),
              user: AuthUser = Depends(require_user)) -> dict[str, Any]:
    return ListMyOrdersUseCase(_orders).execute(user.user_id, limit, offset)
