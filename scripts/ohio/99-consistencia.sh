#!/usr/bin/env bash
# Verifica as invariantes do banco — a prova de "sem perda de dados".
#
# É o fecho da gravação: rodar DEPOIS de ter matado task e drenado instância
# sob carga. Se as invariantes continuam valendo, nenhum pedido se perdeu,
# nenhum estoque foi debitado duas vezes e nada ficou preso na fila.
#
# O `scripts/check_consistency.py` já existe no repositório do backend e vai
# dentro da imagem (`COPY scripts /srv/scripts`). O que falta nele, na AWS, é a
# `DATABASE_URL`: a task recebe DB_HOST/DB_NAME/DB_USER/DB_PASSWORD separados,
# e a senha ainda pode ter sido rotacionada depois de a task subir. Por isso o
# wrapper monta a URL usando `db_credentials.current_password()`, o mesmo
# caminho que a aplicação usa para sobreviver à rotação de 7 dias do RDS.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/99-consistencia.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_task-avulsa.sh"

read -r -d '' SCRIPT <<'PY' || true
import os
import runpy
import sys
import urllib.parse as up

from app.adapters import db_credentials

senha = db_credentials.current_password() or os.environ["DB_PASSWORD"]
os.environ["DATABASE_URL"] = "postgresql://{}:{}@{}:{}/{}?sslmode={}".format(
    up.quote(os.environ["DB_USER"], safe=""),
    up.quote(senha, safe=""),
    os.environ["DB_HOST"],
    os.environ.get("DB_PORT", "5432"),
    os.environ["DB_NAME"],
    os.environ.get("DB_SSLMODE", "require"),
)

sys.path.insert(0, "/srv")
runpy.run_path("/srv/scripts/check_consistency.py", run_name="__main__")
PY

echo ">> verificando as invariantes de consistência"

SAIDA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docs/evidencias/ohio"
mkdir -p "$SAIDA_DIR"
SAIDA="${SAIDA_DIR}/consistencia-$(date -u +%Y%m%dT%H%M%SZ).txt"

if task_avulsa "check-consistency" "$SCRIPT" | tee "$SAIDA"; then
  echo ">> todas as invariantes OK — evidência em ${SAIDA}"
else
  echo "!! alguma invariante falhou — leia ${SAIDA} antes de gravar" >&2
  exit 1
fi
