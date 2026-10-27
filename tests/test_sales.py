"""Cotação e pedido: preço do servidor, idempotência e outbox."""

from __future__ import annotations

import json
import uuid
from typing import Any

import pytest

from app.application import fulfillment, sales
from app.application.sales import BusinessError

pytestmark = pytest.mark.db

CONV = "conv-1"


def quote(items: list[tuple[str, int]], discount: int = 0, conv: str = CONV) -> dict[str, Any]:
    return sales.create_quote(
        conv, [{"product_id": p, "quantity": q} for p, q in items], discount
    )


class TestCotacao:
    def test_preco_vem_do_banco(self, database: str) -> None:
        q = quote([("BK001", 2)])
        assert q["items"][0]["unit_price_cents"] == 3990
        assert q["total_cents"] == 7980

    def test_desconto_e_limitado_ao_teto(self, database: str) -> None:
        q = quote([("BK001", 3)], discount=50)
        assert q["discount_pct"] == 5
        assert "máximo de 5%" in q["note"]

    def test_itens_repetidos_sao_somados(self, database: str) -> None:
        q = sales.create_quote(CONV, [{"product_id": "BK001", "quantity": 1},
                                      {"product_id": "BK001", "quantity": 2}])
        assert [(i["product_id"], i["quantity"]) for i in q["items"]] == [("BK001", 3)]

    def test_produto_inexistente(self, database: str) -> None:
        with pytest.raises(BusinessError) as err:
            quote([("NAOEXISTE", 1)])
        assert err.value.status == 404

    def test_quantidade_fora_do_limite(self, database: str) -> None:
        with pytest.raises(BusinessError):
            quote([("BK001", 11)])


class TestPedido:
    def test_cria_pedido_pending_com_evento_publicado(
        self, queue: dict[str, Any], sql: Any
    ) -> None:
        q = quote([("BK001", 1)])
        order, created = sales.place_order(q["quote_id"], CONV, "Maria Silva")

        assert created
        assert order["order_id"] == q["quote_id"]
        assert order["status"] == "PENDING"
        assert order["customer_name"] == "M*** S***"
        messages = queue["drain"]()
        assert [json.loads(m["Body"])["order_id"] for m in messages] == [q["quote_id"]]
        outbox = sql.execute("SELECT published_at FROM outbox").fetchall()
        assert len(outbox) == 1 and outbox[0]["published_at"] is not None

    def test_mesma_cotacao_nao_gera_dois_pedidos(self, queue: dict[str, Any], sql: Any) -> None:
        q = quote([("BK001", 1)])
        sales.place_order(q["quote_id"], CONV, "Maria")
        order, created = sales.place_order(q["quote_id"], CONV, "Maria")

        assert not created
        assert order["order_id"] == q["quote_id"]
        assert sql.execute("SELECT count(*) AS n FROM orders").fetchone()["n"] == 1
        assert sql.execute("SELECT count(*) AS n FROM outbox").fetchone()["n"] == 1

    def test_cotacao_de_outra_conversa_e_recusada(self, queue: dict[str, Any]) -> None:
        q = quote([("BK001", 1)], conv="dono")
        with pytest.raises(BusinessError) as err:
            sales.place_order(q["quote_id"], "intruso", "Mallory")
        assert err.value.status == 403

    def test_cotacao_expirada(self, queue: dict[str, Any], sql: Any) -> None:
        q = quote([("BK001", 1)])
        sql.execute("UPDATE quotes SET expires_at = now() - interval '1 minute'")
        with pytest.raises(BusinessError) as err:
            sales.place_order(q["quote_id"], CONV, "Maria")
        assert err.value.status == 409

    def test_id_invalido_vira_404(self, database: str) -> None:
        with pytest.raises(BusinessError) as err:
            sales.place_order("nao-e-uuid", CONV, "Maria")
        assert err.value.status == 404

    def test_exige_nome(self, queue: dict[str, Any]) -> None:
        q = quote([("BK001", 1)])
        with pytest.raises(BusinessError):
            sales.place_order(q["quote_id"], CONV, " ")

    def test_pedido_de_outra_conversa_nao_e_exibido(self, queue: dict[str, Any]) -> None:
        q = quote([("BK001", 1)])
        sales.place_order(q["quote_id"], CONV, "Maria")
        with pytest.raises(BusinessError):
            sales.get_order(q["quote_id"], "outra")
        assert sales.get_order(str(uuid.uuid4())) is None


class TestOutbox:
    def test_falha_do_sqs_deixa_evento_para_o_relay(
        self, queue: dict[str, Any], sql: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        def sqs_fora(*_a: Any, **_k: Any) -> None:
            raise ConnectionError("SQS fora")

        monkeypatch.setattr(sales.sqs, "send_order_event", sqs_fora)
        q = quote([("BK001", 1)])
        _, created = sales.place_order(q["quote_id"], CONV, "Maria")

        # O pedido existe mesmo com o SQS fora: nada se perde.
        assert created
        assert queue["drain"]() == []
        assert sql.execute(
            "SELECT count(*) AS n FROM outbox WHERE published_at IS NULL"
        ).fetchone()["n"] == 1

        monkeypatch.undo()
        assert fulfillment.relay_outbox_once() == 1
        assert [json.loads(m["Body"])["order_id"] for m in queue["drain"]()] == [q["quote_id"]]
        assert fulfillment.relay_outbox_once() == 0
