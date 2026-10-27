# Uma imagem por serviço ECS, a partir do mesmo código:
#   docker build --target api    -t backend-api .
#   docker build --target worker -t order-worker .
# Multi-stage: as dependências são instaladas no builder e só o venv vai para
# a imagem final, que não tem compilador nem cache de pip.
FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt


FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH"

COPY --from=builder /opt/venv /opt/venv
WORKDIR /srv
COPY app /srv/app
COPY scripts /srv/scripts


FROM base AS api

ENV SERVICE_NAME=backend-api
# curl é usado pelo HEALTHCHECK do container.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 appuser
# Não-root: o container não precisa de privilégio para servir HTTP.
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=30s --retries=3 \
  CMD curl -fsS http://localhost:8000/health || exit 1
# 2 workers: a task reserva ~0,25 vCPU e a carga é dominada por I/O de banco.
CMD ["uvicorn", "app.api.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--no-access-log", "--timeout-graceful-shutdown", "25"]


FROM base AS worker

ENV SERVICE_NAME=order-worker HEARTBEAT_PATH=/tmp/heartbeat
RUN useradd --system --uid 10002 appuser
USER appuser
# Sem porta HTTP: o health check olha a idade do heartbeat. Se o loop de
# polling travar, o arquivo envelhece e o ECS substitui a task.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD test -n "$(find /tmp/heartbeat -mmin -1 2>/dev/null)" || exit 1
CMD ["python", "-m", "app.worker.main"]
