"""order-worker: confirmação, rejeição, duplicidade, concorrência e sweeper."""

from __future__ import annotations

import json
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any

import pytest

from app.application import fulfillment, sales
from app.application.fulfillment import MalformedMessage
from app.worker import main as worker

pytestmark = pytest.mark.db

CONV = "conv-1"
ROOT = Path(__file__).resolve().parents[1]


def place(items: list[tuple[str, int]]) -> str:
    q = sales.create_quote(CONV, [{"product_id": p, "quantity": n} for p, n in items])
    order, _ = sales.place_order(q["quote_id"], CONV, "Maria")
    return order["order_id"]


def stock(sql: Any, product_id: str) -> int:
    return sql.execute("SELECT stock FROM products WHERE product_id = %s",
                       (product_id,)).fetchone()["stock"]


def test_confirma_e_debita_o_estoque(queue: dict[str, Any], sql: Any) -> None:
    order_id = place([("BK001", 2), ("BK016", 1)])

    assert fulfillment.process_order(order_id) == "confirmed"
    assert stock(sql, "BK001") == 13
    assert stock(sql, "BK016") == 4
    order = sales.get_order(order_id)
    assert order and order["status"] == "CONFIRMED"
    assert [h["status"] for h in order["history"]] == ["PENDING", "CONFIRMED"]


def test_duplicata_nao_debita_duas_vezes(queue: dict[str, Any], sql: Any) -> None:
    order_id = place([("BK001", 2)])
    assert fulfillment.process_order(order_id) == "confirmed"
    assert fulfillment.process_order(order_id) == "duplicate"
    assert stock(sql, "BK001") == 13


def test_falta_de_estoque_rejeita_sem_debito_parcial(queue: dict[str, Any], sql: Any) -> None:
    # BK001 tem estoque, BK004 só tem 3: o débito de BK001 precisa ser desfeito.
    order_id = place([("BK001", 1), ("BK004", 5)])

    assert fulfillment.process_order(order_id) == "rejected"
    assert stock(sql, "BK001") == 15
    assert stock(sql, "BK004") == 3
    order = sales.get_order(order_id)
    assert order and order["status"] == "REJECTED"
    assert order["reason"] == "OUT_OF_STOCK"


def test_ultimo_exemplar_disputado_por_dois_pedidos(queue: dict[str, Any], sql: Any) -> None:
    first = place([("BK004", 3)])
    second = place([("BK004", 3)])
    outcomes = {fulfillment.process_order(first), fulfillment.process_order(second)}
    assert outcomes == {"confirmed", "rejected"}
    assert stock(sql, "BK004") == 0


def test_dois_workers_com_a_mesma_mensagem(queue: dict[str, Any], sql: Any) -> None:
    order_id = place([("BK001", 1)])
    results: list[str] = []
    barrier = threading.Barrier(4)

    def run() -> None:
        barrier.wait()
        results.append(fulfillment.process_order(order_id))

    threads = [threading.Thread(target=run) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert sorted(results) == ["confirmed", "duplicate", "duplicate", "duplicate"]
    assert stock(sql, "BK001") == 14


def test_pedido_inexistente_e_malformado(database: str) -> None:
    with pytest.raises(MalformedMessage):
        fulfillment.process_order("00000000-0000-0000-0000-000000000000")


def test_falha_injetada_propaga_como_transitoria(
    queue: dict[str, Any], sql: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.shared import faults

    order_id = place([("BK001", 1)])
    monkeypatch.setattr(faults, "current", lambda: {**faults.DEFAULTS, "worker_error_rate": 1.0})
    with pytest.raises(faults.InjectedFault):
        fulfillment.process_order(order_id)
    assert stock(sql, "BK001") == 15
    order = sales.get_order(order_id)
    assert order and order["status"] == "PENDING"


def test_sweeper_reenfileira_pedido_preso(queue: dict[str, Any], sql: Any) -> None:
    order_id = place([("BK001", 1)])
    queue["drain"]()  # simula a mensagem perdida
    sql.execute("UPDATE orders SET created_at = now() - interval '10 minutes'")

    assert fulfillment.sweep_once(older_than_s=300) == 1
    assert [json.loads(m["Body"])["order_id"] for m in queue["drain"]()] == [order_id]


class TestHandleMessage:
    def _receive(self, queue: dict[str, Any]) -> dict[str, Any]:
        messages = queue["client"].receive_message(
            QueueUrl=queue["urls"]["queue"], MaxNumberOfMessages=1, WaitTimeSeconds=0,
            AttributeNames=["ApproximateReceiveCount"],
        )["Messages"]
        return messages[0]

    def test_sucesso_apaga_a_mensagem(self, queue: dict[str, Any]) -> None:
        place([("BK001", 1)])
        worker.handle_message(self._receive(queue))
        assert queue["drain"]() == []

    def test_malformada_nao_e_apagada(self, queue: dict[str, Any]) -> None:
        queue["client"].send_message(QueueUrl=queue["urls"]["queue"], MessageBody="{oops")
        message = self._receive(queue)
        worker.handle_message(message)
        # Continua na fila (invisível): o redrive a levará para a DLQ.
        attrs = queue["client"].get_queue_attributes(
            QueueUrl=queue["urls"]["queue"],
            AttributeNames=["ApproximateNumberOfMessagesNotVisible"],
        )["Attributes"]
        assert attrs["ApproximateNumberOfMessagesNotVisible"] == "1"

    @pytest.mark.parametrize("body", ["[]", '{"x": 1}', '{"order_id": ""}', "não é json"])
    def test_parse_recusa_payload_invalido(self, body: str) -> None:
        with pytest.raises(MalformedMessage):
            worker.parse_message(body)


def test_invariantes_de_consistencia(queue: dict[str, Any], database: str) -> None:
    for items in ([("BK001", 2)], [("BK004", 5)], [("BK016", 1), ("BK017", 2)]):
        fulfillment.process_order(place(items))
    place([("BK020", 1)])  # fica PENDING, mas recente

    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "check_consistency.py")],
        env={**__import__("os").environ, "DATABASE_URL": database},
        capture_output=True, text=True, encoding="utf-8", check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
