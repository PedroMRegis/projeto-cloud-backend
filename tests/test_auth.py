"""Contas, sessão por cookie e separação entre cliente e administrador."""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

import jwt
import pytest

pytestmark = pytest.mark.db

SECRET = "segredo-de-teste-com-mais-de-trinta-e-dois-bytes"
PASSWORD = "senha-forte-123"


def _register(api: Any, email: str = "ana@cirro.test", name: str = "Ana Lima") -> dict[str, Any]:
    response = api.post("/api/auth/register",
                        json={"email": email, "name": name, "password": PASSWORD})
    assert response.status_code == 201, response.text
    return response.json()


def _new_session(api: Any, sql: Any, email: str, *, admin: bool = False) -> None:
    api.cookies.clear()
    _register(api, email)
    if admin:
        sql.execute("UPDATE users SET role = 'admin' WHERE email = %s", (email,))


def _buy(api: Any, conversation_id: str, **kwargs: Any) -> str:
    quote = api.post("/api/quotes", json={
        "conversation_id": conversation_id,
        "items": [{"product_id": "BK001", "quantity": 1}],
    }).json()
    order = api.post("/api/orders", json={
        "quote_id": quote["quote_id"], "conversation_id": conversation_id,
        "customer_name": "Ana Lima",
    }, **kwargs)
    assert order.status_code == 201, order.text
    return order.json()["order_id"]


def test_cadastro_abre_sessao_com_cookie_httponly(api: Any) -> None:
    response = api.post("/api/auth/register", json={
        "email": "Ana@Cirro.test", "name": "  Ana   Lima ", "password": PASSWORD})
    assert response.status_code == 201
    body = response.json()
    assert body["email"] == "ana@cirro.test"
    assert body["name"] == "Ana Lima"
    assert body["role"] == "customer"
    assert "password_hash" not in body

    cookie = response.headers["set-cookie"]
    assert cookie.startswith("cirro_session=")
    assert "HttpOnly" in cookie
    assert "SameSite=lax" in cookie
    assert api.get("/api/auth/me").json()["email"] == "ana@cirro.test"


def test_cadastro_nao_aceita_papel_enviado_pelo_cliente(api: Any) -> None:
    response = api.post("/api/auth/register", json={
        "email": "x@cirro.test", "name": "Xis", "password": PASSWORD, "role": "admin"})
    assert response.json()["role"] == "customer"


def test_senha_fica_so_como_hash(api: Any, sql: Any) -> None:
    _register(api)
    stored = sql.execute("SELECT password_hash FROM users").fetchone()["password_hash"]
    assert stored.startswith("$argon2id$")
    assert PASSWORD not in stored


def test_email_repetido_nao_cria_conta(api: Any, sql: Any) -> None:
    _register(api)
    again = api.post("/api/auth/register", json={
        "email": "ANA@cirro.test", "name": "Outra", "password": PASSWORD})
    assert again.status_code == 409
    assert sql.execute("SELECT count(*) AS n FROM users").fetchone()["n"] == 1


@pytest.mark.parametrize("payload", [
    {"email": "sem-arroba", "name": "Ana", "password": PASSWORD},
    {"email": "a@b.test", "name": "Ana", "password": "curta"},
    {"email": "a@b.test", "name": " ", "password": PASSWORD},
])
def test_cadastro_invalido(api: Any, payload: dict[str, str]) -> None:
    assert api.post("/api/auth/register", json=payload).status_code == 422


def test_login_e_logout(api: Any) -> None:
    _register(api)
    api.cookies.clear()
    assert api.get("/api/auth/me").status_code == 401

    response = api.post("/api/auth/login", json={"email": "ana@cirro.test", "password": PASSWORD})
    assert response.status_code == 200
    assert api.get("/api/auth/me").status_code == 200

    assert api.post("/api/auth/logout").status_code == 204
    assert api.get("/api/auth/me").status_code == 401


def test_login_nao_revela_se_o_email_existe(api: Any) -> None:
    _register(api)
    api.cookies.clear()
    wrong = api.post("/api/auth/login", json={"email": "ana@cirro.test", "password": "errada-123"})
    unknown = api.post("/api/auth/login", json={"email": "nao@cirro.test", "password": "errada-123"})
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json() == unknown.json()


def test_conta_desativada_perde_a_sessao_na_hora(api: Any, sql: Any) -> None:
    _register(api)
    assert api.get("/api/auth/me").status_code == 200
    sql.execute("UPDATE users SET is_active = false")
    assert api.get("/api/auth/me").status_code == 401
    api.cookies.clear()
    login = api.post("/api/auth/login", json={"email": "ana@cirro.test", "password": PASSWORD})
    assert login.status_code == 401


@pytest.mark.parametrize("secret,claims", [
    ("outro-segredo-tambem-com-mais-de-trinta-e-dois", {}),
    (SECRET, {"aud": "outro-sistema"}),
    (SECRET, {"iss": "outro-emissor"}),
    (SECRET, {"exp": 1}),
])
def test_token_forjado_ou_expirado_nao_autentica(
    api: Any, secret: str, claims: dict[str, Any]
) -> None:
    user = _register(api)
    api.cookies.clear()
    token = jwt.encode({"sub": user["user_id"], "iss": "cirro-backend", "aud": "cirro-web",
                        "exp": 9_999_999_999, **claims}, secret, algorithm="HS256")
    response = api.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401


def test_sem_segredo_o_login_fica_desligado_e_a_loja_funciona(
    api: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.shared import config

    monkeypatch.setenv("AUTH_JWT_SECRET", "")
    config.reset_settings_cache()
    response = api.post("/api/auth/register", json={
        "email": "a@cirro.test", "name": "Ana", "password": PASSWORD})
    assert response.status_code == 503
    assert api.get("/api/products", params={"limit": 1}).status_code == 200


def test_limite_de_tentativas_de_login(api: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("RATE_LIMIT_DISABLED", "0")
    payload = {"email": "nao@cirro.test", "password": "errada-123"}
    headers = {"X-Forwarded-For": "1.2.3.4, 203.0.113.9"}
    statuses = [api.post("/api/auth/login", json=payload, headers=headers).status_code
                for _ in range(11)]
    assert statuses.count(401) == 10
    assert statuses[-1] == 429
    # Mudar o começo do cabeçalho não escapa: conta o IP que o ALB acrescentou.
    spoofed = {"X-Forwarded-For": "9.9.9.9, 203.0.113.9"}
    assert api.post("/api/auth/login", json=payload, headers=spoofed).status_code == 429


# ------------------------------------------------------- pedidos e separação


def test_cliente_ve_so_os_proprios_pedidos(api: Any, sql: Any) -> None:
    _new_session(api, sql, "ana@cirro.test")
    mine = _buy(api, "conversa-ana")
    assert [o["order_id"] for o in api.get("/api/me/orders").json()["orders"]] == [mine]

    _new_session(api, sql, "bia@cirro.test")
    other = _buy(api, "conversa-bia")
    body = api.get("/api/me/orders").json()
    assert [o["order_id"] for o in body["orders"]] == [other]
    assert body["total"] == 1


def test_pedidos_exigem_login(api: Any) -> None:
    assert api.get("/api/me/orders").status_code == 401


def test_pedido_de_conta_nao_abre_para_outra_pessoa(api: Any, sql: Any) -> None:
    _new_session(api, sql, "ana@cirro.test")
    order_id = _buy(api, "conversa-ana")
    assert api.get(f"/api/orders/{order_id}").status_code == 200

    _new_session(api, sql, "bia@cirro.test")
    assert api.get(f"/api/orders/{order_id}").status_code == 404
    api.cookies.clear()
    assert api.get(f"/api/orders/{order_id}").status_code == 404


def _short(order_id: str) -> str:
    """O número que a loja mostra: o primeiro bloco do UUID, em maiúsculas."""
    return order_id.split("-")[0].upper()


def test_dono_consulta_pelo_numero_curto_de_outra_conversa(api: Any, sql: Any) -> None:
    _new_session(api, sql, "ana@cirro.test")
    order_id = _buy(api, "conversa-ana")

    for ref in (_short(order_id), f"#{_short(order_id)}", f"nº {_short(order_id)}"):
        response = api.get(f"/api/orders/{quote(ref, safe='')}",
                           params={"conversation_id": "outra-conversa"})
        assert response.status_code == 200, (ref, response.text)
        assert response.json()["order_id"] == order_id

    # O UUID inteiro também vale de outra conversa para o dono.
    assert api.get(f"/api/orders/{order_id}",
                   params={"conversation_id": "outra-conversa"}).status_code == 200


def test_numero_curto_nao_abre_pedido_de_outra_pessoa(api: Any, sql: Any) -> None:
    _new_session(api, sql, "ana@cirro.test")
    order_id = _buy(api, "conversa-ana")

    _new_session(api, sql, "bia@cirro.test")
    assert api.get(f"/api/orders/{_short(order_id)}").status_code == 404
    api.cookies.clear()
    # Sem conta, o número curto não prova posse: pede login.
    assert api.get(f"/api/orders/{_short(order_id)}").status_code == 401


def test_nome_do_pedido_vem_da_conta_e_nao_do_cliente(api: Any, sql: Any) -> None:
    _register(api, name="Ana Lima")
    quote = api.post("/api/quotes", json={
        "conversation_id": "c1", "items": [{"product_id": "BK001", "quantity": 1}],
    }).json()
    order = api.post("/api/orders", json={
        "quote_id": quote["quote_id"], "conversation_id": "c1", "customer_name": "Outra Pessoa"})
    assert order.status_code == 201
    assert sql.execute("SELECT customer_name FROM orders").fetchone()["customer_name"] == "Ana Lima"


def test_visitante_cota_mas_nao_fecha_pedido(api: Any, sql: Any) -> None:
    quote = api.post("/api/quotes", json={
        "conversation_id": "conversa-visitante",
        "items": [{"product_id": "BK001", "quantity": 1}],
    })
    assert quote.status_code == 201
    order = api.post("/api/orders", json={
        "quote_id": quote.json()["quote_id"], "conversation_id": "conversa-visitante",
        "customer_name": "Ana Lima",
    })
    assert order.status_code == 401
    assert sql.execute("SELECT count(*) AS n FROM orders").fetchone()["n"] == 0
    assert sql.execute("SELECT count(*) AS n FROM outbox").fetchone()["n"] == 0


def test_sessao_invalida_nao_fecha_pedido(api: Any, sql: Any) -> None:
    quote = api.post("/api/quotes", json={
        "conversation_id": "c1", "items": [{"product_id": "BK001", "quantity": 1}],
    }).json()
    forged = jwt.encode({"sub": "x", "iss": "cirro-backend", "aud": "cirro-web",
                         "exp": 9_999_999_999}, "outro-segredo-com-mais-de-32-bytes-aqui",
                        algorithm="HS256")
    order = api.post("/api/orders", headers={"Authorization": f"Bearer {forged}"}, json={
        "quote_id": quote["quote_id"], "conversation_id": "c1", "customer_name": "Ana Lima"})
    assert order.status_code == 401
    assert sql.execute("SELECT count(*) AS n FROM orders").fetchone()["n"] == 0


def test_pedido_antigo_sem_conta_continua_abrindo(api: Any, sql: Any) -> None:
    from app.application import sales

    quote = api.post("/api/quotes", json={
        "conversation_id": "antiga", "items": [{"product_id": "BK001", "quantity": 1}],
    }).json()
    order, _ = sales.place_order(quote["quote_id"], "antiga", "Ana Lima")
    assert sql.execute("SELECT user_id FROM orders").fetchone()["user_id"] is None
    assert api.get(f"/api/orders/{order['order_id']}").status_code == 200


def test_chatbot_repassa_a_sessao_por_bearer(api: Any, sql: Any) -> None:
    from app.adapters.tokens import JwtTokenService

    user = _register(api)
    api.cookies.clear()
    bearer = {"Authorization": f"Bearer {JwtTokenService().issue(user['user_id'])}"}
    order_id = _buy(api, "conversa-chat", headers=bearer)
    row = sql.execute("SELECT user_id FROM orders WHERE order_id = %s", (order_id,)).fetchone()
    assert str(row["user_id"]) == user["user_id"]


@pytest.mark.parametrize("path", ["/api/backoffice/stock", "/api/backoffice/orders"])
def test_gestao_bloqueia_visitante_e_cliente(api: Any, sql: Any, path: str) -> None:
    assert api.get(path).status_code == 401
    _new_session(api, sql, "ana@cirro.test")
    assert api.get(path).status_code == 403


def test_rebaixar_administrador_vale_na_hora(api: Any, sql: Any) -> None:
    _new_session(api, sql, "chefe@cirro.test", admin=True)
    assert api.get("/api/backoffice/stock").status_code == 200
    sql.execute("UPDATE users SET role = 'customer'")
    assert api.get("/api/backoffice/stock").status_code == 403


def test_gestao_ve_todos_os_pedidos_com_nome_completo(api: Any, sql: Any) -> None:
    _new_session(api, sql, "ana@cirro.test")
    from_account = _buy(api, "conversa-ana")
    from app.application import sales

    old_quote = api.post("/api/quotes", json={
        "conversation_id": "antiga", "items": [{"product_id": "BK001", "quantity": 1}],
    }).json()
    from_guest = sales.place_order(old_quote["quote_id"], "antiga", "Ana Lima")[0]["order_id"]

    _new_session(api, sql, "chefe@cirro.test", admin=True)
    body = api.get("/api/backoffice/orders").json()
    by_id = {o["order_id"]: o for o in body["orders"]}
    assert set(by_id) == {from_account, from_guest}
    assert body["total"] == 2
    assert by_id[from_account]["customer_name"] == "Ana Lima"
    assert by_id[from_account]["account_email"] == "ana@cirro.test"
    assert by_id[from_guest]["account_email"] is None
    assert by_id[from_guest]["items"][0]["title"]

    empty = api.get("/api/backoffice/orders", params={"status": "REJECTED"}).json()
    assert empty["orders"] == []
    assert empty["total"] == 0
    assert api.get("/api/backoffice/orders", params={"status": "X"}).status_code == 422


def test_gestao_mostra_estoque_e_confere_o_livro_razao(api: Any, sql: Any) -> None:
    _new_session(api, sql, "chefe@cirro.test", admin=True)
    body = api.get("/api/backoffice/stock").json()
    assert body["summary"]["titles"] == 40
    assert body["summary"]["ledger_mismatches"] == 0
    stocks = [i["stock"] for i in body["items"]]
    assert stocks == sorted(stocks)

    sql.execute("UPDATE products SET stock = stock + 1 WHERE product_id = 'BK001'")
    body = api.get("/api/backoffice/stock").json()
    assert body["summary"]["ledger_mismatches"] == 1
    item = next(i for i in body["items"] if i["product_id"] == "BK001")
    assert item["ledger_ok"] is False


def test_cli_promove_administrador(api: Any, sql: Any) -> None:
    from app import cli

    _register(api)
    assert cli.main(["set-role", "--email", "ANA@cirro.test", "--role", "admin"]) == 0
    assert sql.execute("SELECT role FROM users").fetchone()["role"] == "admin"
    assert cli.main(["set-role", "--email", "nao@cirro.test", "--role", "admin"]) == 1
