"""Catálogo: busca textual, busca híbrida e degradação sem embeddings."""

from __future__ import annotations

import io
import json
from typing import Any

import pytest

from app.adapters import embeddings
from app.adapters.repositories import ProductRepository
from app.application import catalog
from app.shared.config import reset_settings_cache

pytestmark = pytest.mark.db


def ids(result: dict[str, Any]) -> list[str]:
    return [p["product_id"] for p in result["products"]]


class TestBuscaTextual:
    def test_titulo_exato_vem_primeiro(self, database: str) -> None:
        assert ids(catalog.search("Dom Casmurro"))[0] == "BK001"

    def test_ignora_acentos(self, database: str) -> None:
        assert ids(catalog.search("memorias postumas"))[0] == "BK002"

    def test_frase_da_conversa_nao_zera_o_resultado(self, database: str) -> None:
        # OR entre os termos: "quero", "livro" não podem esconder o título.
        assert ids(catalog.search("quero o livro dom casmurro por favor"))[0] == "BK001"

    def test_prefixo_que_o_stemmer_nao_pega(self, database: str) -> None:
        assert "BK001" in ids(catalog.search("casm"))

    def test_busca_por_autor(self, database: str) -> None:
        assert set(ids(catalog.search("Saramago"))) == {"BK014", "BK015"}

    def test_busca_pela_descricao(self, database: str) -> None:
        assert "BK029" in ids(catalog.search("especiaria"))

    def test_filtro_de_categoria(self, database: str) -> None:
        result = catalog.search("o", category="tecnologia", limit=50)
        assert result["products"]
        assert {p["category"] for p in result["products"]} == {"tecnologia"}

    def test_sem_embeddings_o_modo_e_lexical(self, database: str) -> None:
        assert catalog.search("Duna")["mode"] == "lexical"

    def test_sem_consulta_lista_o_catalogo(self, database: str) -> None:
        result = catalog.search("", limit=5)
        assert result["mode"] == "list"
        assert result["count"] == 5


class TestBuscaHibrida:
    def _seed_vectors(self, database: str) -> list[float]:
        from app.adapters import db

        vec = [0.0] * 1024
        vec[0] = 1.0
        with db.transaction() as conn:
            ProductRepository().set_embedding(conn, "BK016", embeddings.to_pgvector(vec), "fake")
        return vec

    def test_semantica_acha_livro_sem_palavra_em_comum(
        self, database: str, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        vec = self._seed_vectors(database)
        monkeypatch.setattr(embeddings, "embed", lambda *_a, **_k: vec)
        result = catalog.search("xyzzy plugh")
        assert result["mode"] == "hybrid"
        assert ids(result) == ["BK016"]

    def test_falha_do_embedding_degrada_para_textual(
        self, database: str, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("EMBEDDINGS_PROVIDER", "gemini")
        monkeypatch.setenv("GEMINI_API_KEY", "fake")
        from app.shared.config import reset_settings_cache

        reset_settings_cache()

        def boom(*_a: Any, **_k: Any) -> None:
            raise ConnectionError("sem rede")

        monkeypatch.setattr(embeddings.httpx, "post", boom)
        result = catalog.search("Duna")
        assert result["mode"] == "lexical"
        assert ids(result)[0] == "BK029"

    def test_circuito_abre_depois_de_falhas_seguidas(
        self, database: str, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("EMBEDDINGS_PROVIDER", "gemini")
        monkeypatch.setenv("GEMINI_API_KEY", "fake")
        from app.shared.config import reset_settings_cache

        reset_settings_cache()
        calls = {"n": 0}

        def boom(*_a: Any, **_k: Any) -> None:
            calls["n"] += 1
            raise TimeoutError

        monkeypatch.setattr(embeddings.httpx, "post", boom)
        for _ in range(embeddings.BREAKER_THRESHOLD + 3):
            assert embeddings.embed("qualquer coisa") is None
        # Depois de aberto, o circuito nem tenta: protege a latência da busca.
        assert calls["n"] == embeddings.BREAKER_THRESHOLD


class TestDetalhes:
    def test_produto_tem_descricao_longa(self, database: str) -> None:
        product = catalog.get_product("BK001")
        assert product is not None
        assert len(product["description"]) > 200
        assert product["tagline"]
        assert product["price"] == "R$ 39,90"

    def test_todos_os_livros_tem_descricao(self, sql: Any) -> None:
        sem = sql.execute(
            "SELECT product_id FROM products WHERE length(description) < 150"
        ).fetchall()
        assert sem == []

    def test_disponibilidade(self, database: str) -> None:
        result = catalog.availability("BK004", 4)
        assert result == {
            "product_id": "BK004", "title": "Vidas Secas",
            "requested": 4, "stock": 3, "available": False,
        }

    def test_relacionados_sao_da_mesma_categoria(self, database: str) -> None:
        related = catalog.related("BK035")
        assert related
        assert {p["category"] for p in related} == {"tecnologia"}
        assert "BK035" not in {p["product_id"] for p in related}

    def test_categorias(self, database: str) -> None:
        names = {c["category"] for c in catalog.categories()}
        assert {"clássico", "ficção", "fantasia", "tecnologia"} <= names


class FakeBedrock:
    def __init__(self, failure: Exception | None = None) -> None:
        self.failure = failure
        self.requests: list[dict[str, Any]] = []

    def invoke_model(self, modelId: str, body: str) -> dict[str, Any]:  # noqa: N803
        self.requests.append({"modelId": modelId, **json.loads(body)})
        if self.failure:
            raise self.failure
        return {"body": io.BytesIO(json.dumps({"embedding": [1.0] + [0.0] * 1023}).encode())}


class TestEmbeddingsBedrock:
    @pytest.fixture(autouse=True)
    def bedrock_provider(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("EMBEDDINGS_PROVIDER", "bedrock")
        monkeypatch.delenv("EMBEDDINGS_MODEL", raising=False)
        reset_settings_cache()

    def test_chama_o_titan_sem_precisar_de_chave(self, monkeypatch: pytest.MonkeyPatch) -> None:
        client = FakeBedrock()
        monkeypatch.setattr(embeddings, "bedrock_client", lambda: client)
        assert embeddings.enabled() is True

        vector = embeddings.embed("um livro sobre vigilância")

        assert vector is not None and len(vector) == 1024
        assert client.requests == [{
            "modelId": "amazon.titan-embed-text-v2:0",
            "inputText": "um livro sobre vigilância", "dimensions": 1024, "normalize": True,
        }]

    def test_falha_do_bedrock_degrada_para_textual(
        self, database: str, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        client = FakeBedrock(failure=RuntimeError("fora"))
        monkeypatch.setattr(embeddings, "bedrock_client", lambda: client)
        assert catalog.search("orwell")["mode"] == "lexical"

    def test_backfill_preenche_a_coluna_de_1024(
        self, database: str, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        from app.adapters import db
        from app.application import admin

        monkeypatch.setattr(embeddings, "bedrock_client", FakeBedrock)
        result = admin.backfill_embeddings(3)
        assert result == {"pending": 3, "embedded": 3}
        with db.transaction() as conn:
            row = conn.execute(
                "SELECT count(*) AS total, min(vector_dims(embedding)) AS dims, "
                "min(embedding_model) AS model FROM products WHERE embedding IS NOT NULL"
            ).fetchone()
        assert (row["total"], row["dims"]) == (3, 1024)
        assert row["model"] == "amazon.titan-embed-text-v2:0"
