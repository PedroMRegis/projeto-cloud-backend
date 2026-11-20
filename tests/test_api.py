"""Rotas HTTP do backend-api, ponta a ponta com banco e fila."""

from __future__ import annotations

from typing import Any

import pytest

pytestmark = pytest.mark.db

ADMIN = {"X-Admin-Token": "test-admin", "X-Admin-Actor": "pytest"}


def test_health_nao_depende_do_banco(api: Any) -> None:
    assert api.get("/health").json() == {"status": "ok"}


def test_ready_checa_o_banco(api: Any) -> None:
    assert api.get("/ready").status_code == 200


def test_listagem_paginada_e_ordenada(api: Any) -> None:
    body = api.get("/api/products", params={"sort": "price_asc", "limit": 3}).json()
    assert body["total"] == 40
    prices = [p["price_cents"] for p in body["products"]]
    assert prices == sorted(prices)


def test_busca(api: Any) -> None:
    body = api.get("/api/products", params={"q": "tolkien"}).json()
    assert {p["product_id"] for p in body["products"]} == {"BK025", "BK026"}


def test_detalhe_com_relacionados(api: Any) -> None:
    body = api.get("/api/products/BK025", params={"related": 3}).json()
    assert body["title"] == "O Hobbit"
    assert len(body["related"]) == 3
    assert api.get("/api/products/NAO").status_code == 404


def test_jornada_cotacao_pedido(api: Any) -> None:
    api.post("/api/auth/register", json={"email": "ana@cirro.test", "name": "Ana Lima",
                                         "password": "senha-forte-123"})
    quote = api.post("/api/quotes", json={
        "conversation_id": "c1", "items": [{"product_id": "BK001", "quantity": 3}],
        "requested_discount_pct": 5,
    })
    assert quote.status_code == 201
    quote_id = quote.json()["quote_id"]

    first = api.post("/api/orders", json={
        "quote_id": quote_id, "conversation_id": "c1", "customer_name": "Ana Lima"})
    again = api.post("/api/orders", json={
        "quote_id": quote_id, "conversation_id": "c1", "customer_name": "Ana Lima"})
    assert (first.status_code, again.status_code) == (201, 200)
    assert again.json()["created"] is False

    order = api.get(f"/api/orders/{quote_id}", params={"conversation_id": "c1"}).json()
    assert order["status"] == "PENDING"
    assert order["discount_pct"] == 5
    # A dona do pedido consulta de qualquer conversa (volta outro dia e pergunta).
    assert api.get(f"/api/orders/{quote_id}", params={"conversation_id": "x"}).status_code == 200


def test_preco_enviado_pelo_cliente_e_ignorado(api: Any) -> None:
    body = api.post("/api/quotes", json={
        "conversation_id": "c1",
        "items": [{"product_id": "BK001", "quantity": 1, "unit_price_cents": 1}],
    }).json()
    assert body["total_cents"] == 3990


def test_validacao_de_entrada(api: Any) -> None:
    resp = api.post("/api/quotes", json={
        "conversation_id": "c1", "items": [{"product_id": "BK001", "quantity": 0}]})
    assert resp.status_code == 422


class TestAdmin:
    def test_sem_token_e_recusado(self, api: Any) -> None:
        resp = api.post("/api/admin/products/BK001/stock", json={"delta": 1})
        assert resp.status_code == 401

    def test_admin_desligado_sem_token_configurado(
        self, api: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        from app.shared.config import reset_settings_cache

        monkeypatch.setenv("ADMIN_TOKEN", "")
        reset_settings_cache()
        resp = api.post("/api/admin/products/BK001/stock", json={"delta": 1}, headers=ADMIN)
        assert resp.status_code == 403

    def test_cadastra_edita_e_ajusta_estoque(self, api: Any, sql: Any) -> None:
        created = api.post("/api/admin/products", headers=ADMIN, json={
            "product_id": "bk041", "title": "Torto Arado", "author": "Itamar Vieira Junior",
            "category": "ficção", "tagline": "Duas irmãs no sertão baiano.",
            "description": "x" * 200, "original_year": 2019, "price_cents": 5990, "stock": 4,
        })
        assert created.status_code == 201
        assert created.json()["product_id"] == "BK041"

        patched = api.patch("/api/admin/products/BK041", headers=ADMIN,
                            json={"price_cents": 4990})
        assert patched.json()["price"] == "R$ 49,90"

        adjusted = api.post("/api/admin/products/BK041/stock", headers=ADMIN,
                            json={"delta": -4, "note": "avaria"})
        assert adjusted.json()["stock"] == 0
        negative = api.post("/api/admin/products/BK041/stock", headers=ADMIN,
                            json={"delta": -1})
        assert negative.status_code == 409

        ledger = sql.execute(
            "SELECT delta, reason, actor FROM stock_movements WHERE product_id = 'BK041' "
            "ORDER BY id").fetchall()
        assert [(m["delta"], m["reason"], m["actor"]) for m in ledger] == [
            (4, "admin_adjust", "pytest"), (-4, "admin_adjust", "pytest")]

    def test_produto_duplicado(self, api: Any) -> None:
        resp = api.post("/api/admin/products", headers=ADMIN, json={
            "product_id": "BK001", "title": "x", "author": "y", "category": "z",
            "price_cents": 1})
        assert resp.status_code == 409
