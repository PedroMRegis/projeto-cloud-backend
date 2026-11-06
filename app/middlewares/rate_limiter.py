"""Limite por IP para as rotas sujeitas a força bruta.

A janela fica na memória da task. Com N tasks, o limite efetivo é N vezes maior,
o que ainda basta para conter ataque de senha.

RATE_LIMIT_DISABLED=1 desliga o limite (usado nos testes).
"""

from __future__ import annotations

import os
import threading
import time
from collections import deque
from collections.abc import Callable

from fastapi import HTTPException, Request

MAX_TRACKED_IPS = 10_000


def _client_ip(request: Request) -> str:
    # O ALB acrescenta o IP real no fim do X-Forwarded-For. O que vem antes
    # é enviado pelo cliente e pode ser falso.
    forwarded = request.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[-1].strip()
    return request.client.host if request.client else "desconhecido"


def rate_limit(max_requests: int, window_seconds: int = 60) -> Callable[[Request], None]:
    """Dependency com contadores próprios: rotas diferentes não dividem a janela."""
    hits: dict[str, deque[float]] = {}
    lock = threading.Lock()

    def dependency(request: Request) -> None:
        if os.getenv("RATE_LIMIT_DISABLED") == "1":
            return
        ip = _client_ip(request)
        now = time.monotonic()
        with lock:
            window = hits.setdefault(ip, deque())
            while window and now - window[0] > window_seconds:
                window.popleft()
            if len(hits) > MAX_TRACKED_IPS:
                cutoff = now - window_seconds
                for key in [k for k, v in hits.items() if k != ip and (not v or v[-1] < cutoff)]:
                    del hits[key]
            if len(window) >= max_requests:
                raise HTTPException(status_code=429,
                                    detail="muitas tentativas, aguarde um minuto")
            window.append(now)

    return dependency
