"""Rotas da gestão, só para administradores.

Ficam fora de `/api/admin*` porque o ALB bloqueia esse prefixo na internet. Lá
vivem as rotas de escrita, protegidas por token de serviço. Aqui é só leitura.
"""

from __future__ import annotations

from typing import Any, Literal

from fastapi import APIRouter, Depends, Query

from app.adapters.repositories import OrderRepository, ProductRepository
from app.middlewares.role_checker import require_admin
from app.use_cases.backoffice.get_stock_use_case import GetStockUseCase
from app.use_cases.backoffice.list_orders_use_case import ListOrdersUseCase

router = APIRouter(prefix="/api/backoffice", tags=["gestão"],
                   dependencies=[Depends(require_admin)])

_products = ProductRepository()
_orders = OrderRepository()


@router.get("/stock")
def stock() -> dict[str, Any]:
    return GetStockUseCase(_products).execute()


@router.get("/orders")
def orders(status: Literal["PENDING", "CONFIRMED", "REJECTED"] | None = None,
           limit: int = Query(default=50, ge=1, le=100),
           offset: int = Query(default=0, ge=0)) -> dict[str, Any]:
    return ListOrdersUseCase(_orders).execute(status, limit, offset)
