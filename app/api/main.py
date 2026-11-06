"""backend-api: catálogo, cotação e pedido (serviço ECS síncrono, FastAPI).

É a única porta de entrada para o PostgreSQL. O chatbot e o frontend falam
com o banco só através destas rotas, o que permite trocar schema, índices ou
até o banco sem tocar nos outros dois repositórios.

`/health` não checa dependências: se checasse, uma instabilidade do RDS
marcaria todas as tasks como unhealthy ao mesmo tempo e o ALB tiraria todas do
target group. O diagnóstico de dependências fica em `/ready`.
"""

from __future__ import annotations

import hmac
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.adapters import db
from app.adapters.tokens import AuthDisabled
from app.application import admin, catalog, sales
from app.application.sales import BusinessError
from app.domain.pricing import MAX_QTY_PER_ITEM
from app.domain.user import AuthUser
from app.middlewares.validate_auth_token import optional_user, require_user
from app.shared import context, metrics
from app.shared.config import settings
from app.shared.logging import configure_logging, get_logger
from app.use_cases.auth.index import router as auth_router
from app.use_cases.backoffice.index import router as backoffice_router
from app.use_cases.customer.index import router as customer_router

configure_logging()
log = get_logger(__name__)

MIGRATION_ATTEMPTS = 10


def _migrate_with_retry() -> None:
    """O banco pode subir depois da task (compose, RDS reiniciando)."""
    for attempt in range(1, MIGRATION_ATTEMPTS + 1):
        try:
            db.migrate()
            return
        except Exception as exc:  # noqa: BLE001
            if attempt == MIGRATION_ATTEMPTS:
                raise
            log.warning("banco indisponível para migrations, tentando de novo",
                        extra={"attempt": attempt, "error": type(exc).__name__})
            time.sleep(3)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    cfg = settings()
    if cfg.migrate_on_start:
        _migrate_with_retry()
    db.pool()
    log.info("backend-api iniciado",
             extra={"env": cfg.env, "region": cfg.region,
                    "embeddings": cfg.embeddings_provider})
    metrics.emit("ServiceStart", 1)
    yield
    db.close_pool()
    log.info("backend-api encerrando")


app = FastAPI(title="ConvCommerce — backend-api", docs_url="/api/docs",
              openapi_url="/api/openapi.json", redoc_url=None, lifespan=lifespan)


@app.middleware("http")
async def correlation_middleware(request: Request, call_next: Any) -> Response:
    incoming = request.headers.get("x-request-id") or context.new_id()
    tokens = context.bind(correlation_id=incoming,
                          traceparent=request.headers.get("traceparent"),
                          conversation_id=request.headers.get("x-conversation-id"))
    started = time.perf_counter()
    try:
        response = await call_next(request)
    finally:
        context.unbind(tokens)
    response.headers["X-Request-Id"] = incoming
    if request.url.path.startswith("/api/"):
        log.info("requisição concluída",
                 extra={"method": request.method, "path": request.url.path,
                        "status": response.status_code,
                        "duration_ms": round((time.perf_counter() - started) * 1000, 2),
                        "correlation_id": incoming})
    return response


@app.exception_handler(BusinessError)
async def business_error(_: Request, exc: BusinessError) -> JSONResponse:
    return JSONResponse({"detail": str(exc)}, status_code=exc.status)


@app.exception_handler(AuthDisabled)
async def auth_disabled(_: Request, __: AuthDisabled) -> JSONResponse:
    return JSONResponse({"detail": "login indisponível neste ambiente"}, status_code=503)


app.include_router(auth_router)
app.include_router(customer_router)
app.include_router(backoffice_router)


# ------------------------------------------------------------- health checks

_ready_cache: dict[str, Any] = {"at": 0.0, "ok": False, "detail": ""}
_READY_TTL_S = 10


@app.get("/health", include_in_schema=False)
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/ready", include_in_schema=False)
def ready() -> JSONResponse:
    now = time.monotonic()
    if now - _ready_cache["at"] >= _READY_TTL_S:
        try:
            db.ping()
            _ready_cache.update(at=now, ok=True, detail="postgres ok")
        except Exception as exc:  # noqa: BLE001
            _ready_cache.update(at=now, ok=False, detail=type(exc).__name__)
            log.warning("readiness falhou", extra={"error": str(exc)})
    ok = _ready_cache["ok"]
    return JSONResponse({"status": "ready" if ok else "degraded",
                         "detail": _ready_cache["detail"]},
                        status_code=200 if ok else 503)


# ------------------------------------------------------------------- catálogo


@app.get("/api/products")
def list_products(q: str = "", category: str | None = None, sort: str = "title",
                  limit: int = 20, offset: int = 0) -> dict[str, Any]:
    """Com `q`, busca híbrida (texto + semântica); sem `q`, listagem paginada."""
    category = category or None
    if q.strip():
        return catalog.search(q, category=category, limit=limit)
    return catalog.list_products(category=category, sort=sort, limit=limit, offset=offset)


@app.get("/api/categories")
def list_categories() -> dict[str, Any]:
    return {"categories": catalog.categories()}


@app.get("/api/products/{product_id}")
def get_product(product_id: str, related: int = 0) -> dict[str, Any]:
    product = catalog.get_product(product_id)
    if not product:
        raise HTTPException(status_code=404, detail="produto não encontrado")
    if related:
        product["related"] = catalog.related(product_id, limit=min(related, 8))
    return product


@app.get("/api/products/{product_id}/availability")
def availability(product_id: str, quantity: int = 1) -> dict[str, Any]:
    result = catalog.availability(product_id, max(1, quantity))
    if not result:
        raise HTTPException(status_code=404, detail="produto não encontrado")
    return result


# ------------------------------------------------------------ cotação e pedido


class QuoteItemIn(BaseModel):
    product_id: str = Field(min_length=1, max_length=32)
    quantity: int = Field(ge=1, le=MAX_QTY_PER_ITEM)


class QuoteIn(BaseModel):
    conversation_id: str = Field(min_length=1, max_length=64)
    items: list[QuoteItemIn] = Field(min_length=1, max_length=20)
    requested_discount_pct: int = Field(default=0, ge=0, le=100)


class OrderIn(BaseModel):
    quote_id: str = Field(min_length=1, max_length=64)
    conversation_id: str = Field(min_length=1, max_length=64)


@app.post("/api/quotes", status_code=201)
def create_quote(payload: QuoteIn) -> dict[str, Any]:
    return sales.create_quote(payload.conversation_id,
                              [i.model_dump() for i in payload.items],
                              payload.requested_discount_pct)


@app.get("/api/quotes/{quote_id}")
def get_quote(quote_id: str) -> dict[str, Any]:
    quote = sales.get_quote(quote_id)
    if not quote:
        raise HTTPException(status_code=404, detail="cotação não encontrada")
    return quote


@app.post("/api/orders")
def place_order(payload: OrderIn, response: Response,
                user: AuthUser = Depends(require_user)) -> dict[str, Any]:
    """Só com login, e o nome vem da conta.

    201 = pedido criado agora; 200 = a cotação já tinha gerado este pedido.
    """
    order, created = sales.place_order(payload.quote_id, payload.conversation_id,
                                       user.name, user.user_id)
    response.status_code = 201 if created else 200
    return {**order, "created": created}


@app.get("/api/orders/{order_id}")
def get_order(order_id: str, conversation_id: str | None = None,
              user: AuthUser | None = Depends(optional_user)) -> dict[str, Any]:
    order = sales.get_order(order_id, conversation_id, user)
    if not order:
        raise HTTPException(status_code=404, detail="pedido não encontrado")
    return order


# ---------------------------------------------------------------------- admin


def _require_admin(token: str | None) -> None:
    expected = settings().admin_token
    if not expected:
        raise HTTPException(status_code=403, detail="admin desabilitado neste ambiente")
    if not token or not hmac.compare_digest(token, expected):
        raise HTTPException(status_code=401, detail="token de admin inválido")


class ProductIn(BaseModel):
    product_id: str = Field(min_length=2, max_length=32)
    title: str = Field(min_length=1, max_length=200)
    author: str = Field(min_length=1, max_length=200)
    category: str = Field(min_length=1, max_length=60)
    tagline: str = Field(default="", max_length=300)
    description: str = Field(default="", max_length=4000)
    original_year: int | None = Field(default=None, ge=-3000, le=2100)
    price_cents: int = Field(ge=0, le=10_000_000)
    stock: int = Field(default=0, ge=0, le=100_000)


class ProductPatch(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    author: str | None = Field(default=None, min_length=1, max_length=200)
    category: str | None = Field(default=None, min_length=1, max_length=60)
    tagline: str | None = Field(default=None, max_length=300)
    description: str | None = Field(default=None, max_length=4000)
    original_year: int | None = Field(default=None, ge=-3000, le=2100)
    price_cents: int | None = Field(default=None, ge=0, le=10_000_000)


class StockAdjustIn(BaseModel):
    delta: int = Field(ge=-100_000, le=100_000)
    note: str = Field(default="", max_length=120)


@app.post("/api/admin/products", status_code=201)
def admin_create(payload: ProductIn, x_admin_token: str | None = Header(default=None),
                 x_admin_actor: str = Header(default="admin")) -> dict[str, Any]:
    _require_admin(x_admin_token)
    return admin.create_product(payload.model_dump(), x_admin_actor)


@app.patch("/api/admin/products/{product_id}")
def admin_update(product_id: str, payload: ProductPatch,
                 x_admin_token: str | None = Header(default=None),
                 x_admin_actor: str = Header(default="admin")) -> dict[str, Any]:
    _require_admin(x_admin_token)
    return admin.update_product(product_id, payload.model_dump(exclude_none=True), x_admin_actor)


@app.post("/api/admin/products/{product_id}/stock")
def admin_stock(product_id: str, payload: StockAdjustIn,
                x_admin_token: str | None = Header(default=None),
                x_admin_actor: str = Header(default="admin")) -> dict[str, Any]:
    _require_admin(x_admin_token)
    return admin.adjust_stock(product_id, payload.delta, x_admin_actor, payload.note)


@app.post("/api/admin/embeddings/backfill")
def admin_backfill(limit: int = 100,
                   x_admin_token: str | None = Header(default=None)) -> dict[str, int]:
    _require_admin(x_admin_token)
    return admin.backfill_embeddings(limit)
