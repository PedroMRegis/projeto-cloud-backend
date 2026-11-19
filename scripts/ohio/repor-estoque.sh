#!/usr/bin/env bash
# Repõe o estoque do catálogo antes de um teste de carga.
#
# POR QUE ISTO EXISTE
#   O teste de carga compra de verdade: cada jornada tira 3 a 5 exemplares. Um
#   `pico` ou um `soak` esgota os títulos e, a partir daí, o k6 mede só o
#   caminho de leitura — o que invalida a evidência de escala do order-worker,
#   que depende de pedido entrando na fila.
#
# POR QUE TASK AVULSA, E NÃO ECS EXEC NEM A ROTA DE ADMIN
#   Três caminhos foram considerados:
#     1. `/api/admin/*` pela internet — impossível por desenho: a regra de
#        prioridade 10 do ALB devolve 403 fixo. A rota de administração não é
#        exposta, e abrir exceção para este script seria furar a própria fronteira.
#     2. ECS Exec — exigiria `--enable-execute-command`, que **substitui as
#        tasks**, mais uma política de `ssmmessages` na task role. Dois
#        deployments de produção para repor estoque é caro demais.
#     3. Task avulsa (este script) — reaproveita a task definition e a task role
#        que já existem, roda o mesmo código da aplicação, e some ao terminar.
#        Zero mudança em serviço, zero segredo em log: a credencial do banco é
#        resolvida pelo ECS a partir do Parameter Store, dentro do container.
#   O `app/cli.py` do backend já foi escrito para esse padrão ("rodados como
#   task avulsa do ECS"), então este script segue a convenção da casa.
#
# POR QUE PASSA POR `admin.adjust_stock` E NÃO POR UM UPDATE
#   Cada ajuste tem de virar um movimento no livro-razão. Um `UPDATE products
#   SET stock` quebraria a primeira invariante do `check_consistency.py`
#   (`stock` = Σ movimentos) — ou seja, repor estoque pelo caminho errado
#   destruiria justamente a evidência de "sem perda de dados" que a gravação
#   precisa mostrar no fim.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/repor-estoque.sh [ESTOQUE_ALVO]

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_task-avulsa.sh"

ALVO="${1:-300}"

echo ">> repondo o estoque de todo o catálogo para >= ${ALVO} exemplares"

read -r -d '' SCRIPT <<'PY' || true
import os
from app.adapters import db
from app.application.admin import adjust_stock

ALVO = int(os.environ.get("ALVO", "300"))

with db.transaction() as conn:
    linhas = conn.execute(
        "SELECT product_id, stock FROM products ORDER BY product_id").fetchall()

def campo(linha, nome, indice):
    # O row_factory varia entre dict_row e tupla conforme o adaptador; o
    # script roda nos dois sem precisar saber qual está configurado.
    try:
        return linha[nome]
    except (TypeError, KeyError, IndexError):
        return linha[indice]

repostos = 0
for linha in linhas:
    pid = campo(linha, "product_id", 0)
    atual = int(campo(linha, "stock", 1) or 0)
    if atual >= ALVO:
        continue
    adjust_stock(pid, ALVO - atual, "repor-estoque.sh", "reposicao para teste de carga")
    repostos += 1
    print("  %-8s %4d -> %4d" % (pid, atual, ALVO), flush=True)

print("repostos: %d de %d titulos" % (repostos, len(linhas)), flush=True)
PY

if task_avulsa "repor-estoque" "$SCRIPT" "ALVO=${ALVO}"; then
  echo ">> pronto."
else
  echo "!! a reposição falhou" >&2
  exit 1
fi
