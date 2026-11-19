#!/usr/bin/env bash
# Helper: roda um script Python dentro de uma task avulsa do ECS e devolve o log.
#
# POR QUE ESTE PADRÃO
#   O RDS e as rotas de administração vivem na VPC privada, inalcançáveis da
#   máquina de quem opera. As três alternativas seriam expor o banco, abrir a
#   rota de admin na internet, ou ligar ECS Exec (que substitui as tasks do
#   serviço). Nenhuma vale o preço para uma operação pontual.
#
#   Uma task avulsa reaproveita a task definition e a task role que já existem:
#   o mesmo código, as mesmas credenciais resolvidas pelo ECS a partir do
#   Parameter Store e do Secrets Manager, dentro da mesma VPC. Nada é exposto,
#   nenhum segredo passa pela linha de comando, e a task some ao terminar.
#   O `app/cli.py` do backend já documenta esse padrão como o jeito da casa.
#
# Uso:
#   source scripts/ohio/_task-avulsa.sh
#   task_avulsa "nome-para-o-started-by" "$SCRIPT_PYTHON" [NOME=valor ...]
#
# Devolve o exit code do container e imprime o log da task.

task_avulsa() {
  local motivo="$1" script="$2"
  shift 2

  require CLUSTER CAPACITY_PROVIDER

  # As variáveis extras viram `environment` no override, em vez de entrar no
  # texto do script: assim o mesmo script serve para valores diferentes.
  local extras_json="[]"
  if (( $# )); then
    extras_json="$(printf '%s\n' "$@" | python -c '
import json, sys
pares = [l.strip().split("=", 1) for l in sys.stdin if l.strip()]
print(json.dumps([{"name": k, "value": v} for k, v in pares]))')"
  fi

  local overrides
  overrides="$(SCRIPT="$script" EXTRAS="$extras_json" python -c '
import json, os
print(json.dumps({"containerOverrides": [{
    "name": "app",
    "command": ["python", "-c", os.environ["SCRIPT"]],
    "environment": json.loads(os.environ["EXTRAS"]),
}]}))')"

  local task_arn
  task_arn="$(aws ecs run-task --region "$REGION" --cluster "$CLUSTER" \
    --task-definition "${PREFIX}-backend-api" \
    --capacity-provider-strategy "capacityProvider=${CAPACITY_PROVIDER},weight=1" \
    --started-by "$motivo" \
    --overrides "$overrides" \
    --query 'tasks[0].taskArn' --output text)"

  if [[ -z "$task_arn" || "$task_arn" == "None" ]]; then
    echo "!! a task não subiu — provavelmente não há capacidade no cluster" >&2
    return 1
  fi
  echo ">> task ${task_arn##*/} rodando, aguardando…" >&2

  aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$task_arn"

  local codigo
  codigo="$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" \
    --tasks "$task_arn" --query 'tasks[0].containers[0].exitCode' --output text)"

  # O stream é `ecs/<container>/<task id>`, do awslogs-stream-prefix.
  #
  # PYTHONUTF8: o aws.exe no Windows escreve no console com a codepage ANSI e
  # morre com UnicodeEncodeError em qualquer caractere fora dela — o `Σ` de
  # "estoque = Σ movimentos" do check_consistency.py derrubava a leitura
  # inteira do log, com exit 255 e mensagem sem relação aparente com a causa.
  # Tem de ser PYTHONUTF8, não PYTHONIOENCODING: o CLI v2 é um binário
  # congelado e só o primeiro chega ao interpretador embutido.
  PYTHONUTF8=1 aws logs get-log-events --region "$REGION" \
    --log-group-name "/convcommerce/prod/backend-api" \
    --log-stream-name "ecs/app/${task_arn##*/}" \
    --query 'events[].message' --output text 2>/dev/null \
    | tr '\t' '\n' \
    | grep -v '^{"_aws"' \
    | sed 's/^/   /'
    # As linhas `{"_aws": ...}` são métricas EMF que a aplicação emite por
    # efeito colateral. Vão para o CloudWatch de qualquer forma; no terminal
    # só escondem a saída que interessa.

  echo ">> exit=${codigo}" >&2
  [[ "$codigo" == "0" ]]
}
