"""Embeddings para a busca semântica do catálogo (pgvector).

O provedor é o Titan Text Embeddings v2, no Bedrock, com a credencial AWS da task,
ou a API de embeddings do Gemini. Como o LLM, ele é uma dependência externa sujeita
a latência, cota e falha, então:

* timeout curto (4 s): a busca não pode ficar refém do embedding;
* circuit breaker: depois de 3 falhas em 60 s, fica 60 s sem tentar;
* qualquer falha devolve `None`, e a busca segue só com o full-text.
"""

from __future__ import annotations

import json
import math
import threading
import time

import httpx

from app.adapters.aws import bedrock_client
from app.shared import metrics
from app.shared.config import settings
from app.shared.logging import get_logger

log = get_logger(__name__)

GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:embedContent"

BREAKER_THRESHOLD = 3
BREAKER_WINDOW_S = 60
BREAKER_OPEN_S = 60

_lock = threading.Lock()
_failures: list[float] = []
_opened_at: float | None = None


def enabled() -> bool:
    cfg = settings()
    if cfg.embeddings_provider == "bedrock":
        return True
    return cfg.embeddings_provider == "gemini" and bool(cfg.gemini_api_key)


def _breaker_open() -> bool:
    global _opened_at
    with _lock:
        if _opened_at is None:
            return False
        if time.monotonic() - _opened_at >= BREAKER_OPEN_S:
            _opened_at = None
            _failures.clear()
            return False
        return True


def _record_failure() -> None:
    global _opened_at
    with _lock:
        now = time.monotonic()
        _failures[:] = [t for t in _failures if now - t < BREAKER_WINDOW_S]
        _failures.append(now)
        if len(_failures) >= BREAKER_THRESHOLD and _opened_at is None:
            _opened_at = now
            log.error("circuito de embeddings aberto")
            metrics.emit("EmbeddingsCircuitOpen", 1)


def reset_breaker() -> None:
    global _opened_at
    with _lock:
        _failures.clear()
        _opened_at = None


def _normalize(vector: list[float]) -> list[float]:
    # Com dimensão reduzida o vetor do Gemini não vem normalizado, e a distância
    # de cosseno do pgvector fica mais estável com norma 1.
    norm = math.sqrt(sum(v * v for v in vector)) or 1.0
    return [v / norm for v in vector]


def _gemini(text: str, task: str) -> list[float]:
    cfg = settings()
    response = httpx.post(
        GEMINI_URL.format(model=cfg.embeddings_model),
        headers={"x-goog-api-key": cfg.gemini_api_key},
        json={
            "content": {"parts": [{"text": text[:8000]}]},
            "taskType": task,
            "outputDimensionality": cfg.embeddings_dim,
        },
        timeout=cfg.embeddings_timeout_s,
    )
    response.raise_for_status()
    return response.json()["embedding"]["values"]


def _bedrock(text: str) -> list[float]:
    cfg = settings()
    response = bedrock_client().invoke_model(
        modelId=cfg.embeddings_model,
        body=json.dumps({"inputText": text[:8000], "dimensions": cfg.embeddings_dim,
                         "normalize": True}),
    )
    return json.loads(response["body"].read())["embedding"]


def embed(text: str, *, task: str = "RETRIEVAL_QUERY") -> list[float] | None:
    """Embedding do texto, ou None se o provedor estiver desligado ou falhar.

    `task` é RETRIEVAL_QUERY para a consulta do usuário e RETRIEVAL_DOCUMENT
    para os livros do catálogo. Só o Gemini diferencia os dois.
    """
    if not enabled() or _breaker_open() or not text.strip():
        return None

    cfg = settings()
    try:
        with metrics.timed("EmbeddingLatency"):
            values = _bedrock(text) if cfg.embeddings_provider == "bedrock" \
                else _gemini(text, task)
    except Exception as exc:  # noqa: BLE001 — qualquer falha degrada para full-text
        _record_failure()
        metrics.emit("EmbeddingErrors", 1, error=type(exc).__name__)
        log.warning("embedding falhou, seguindo sem busca semântica",
                    extra={"error": type(exc).__name__})
        return None

    if len(values) != cfg.embeddings_dim:
        log.error("dimensão de embedding inesperada", extra={"dim": len(values)})
        return None
    return _normalize(values)


def to_pgvector(vector: list[float]) -> str:
    """Literal aceito pelo tipo `vector` sem precisar do adapter do pgvector."""
    return "[" + ",".join(f"{v:.7f}" for v in vector) + "]"
