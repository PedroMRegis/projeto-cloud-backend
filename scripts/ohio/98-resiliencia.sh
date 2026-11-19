#!/usr/bin/env bash
# Provas de resiliência: troca de task, perda de task e drenagem de instância.
#
# Cada demo é um subcomando, para dar para gravar uma de cada vez e narrar com
# calma. Todas pressupõem que o k6 está rodando em outro terminal (`soak` ou
# `rampa`) e que o 97-observa-escala.sh está gravando o CSV — sem carga, o
# gráfico fica plano e a evidência não mostra nada.
#
#   source scripts/ohio/00-config.sh
#   scripts/ohio/98-resiliencia.sh troca-task
#   scripts/ohio/98-resiliencia.sh perde-task
#   scripts/ohio/98-resiliencia.sh drena-instancia
#   scripts/ohio/98-resiliencia.sh estado
#
# A ordem importa na gravação: troca (planejada) → perda (não planejada) →
# drenagem (infraestrutura). É a mesma ordem do mais controlado para o mais
# violento, que é como a narrativa fica fácil de acompanhar.

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require CLUSTER


SAIDA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docs/evidencias/ohio"
mkdir -p "$SAIDA_DIR"

marca() { echo ""; echo "=== $(date -u +%H:%M:%SZ) — $* ==="; }

estado() {
  marca "serviços"
  aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" \
    --services "${PREFIX}-backend-api" "${PREFIX}-chatbot" \
               "${PREFIX}-order-worker" "${PREFIX}-frontend" \
    --query 'services[].{servico:serviceName,desejado:desiredCount,rodando:runningCount,pendente:pendingCount}' \
    --output table

  marca "instâncias do cluster"
  aws ecs list-container-instances --region "$REGION" --cluster "$CLUSTER" \
      --query 'containerInstanceArns' --output text \
    | tr '\t' '\n' | grep . \
    | xargs -r aws ecs describe-container-instances --region "$REGION" \
        --cluster "$CLUSTER" --container-instances \
    | python -c '
import json,sys
for ci in json.load(sys.stdin)["containerInstances"]:
    # A AZ não é campo de primeira classe da container instance: vem como
    # atributo `ecs.availability-zone`, posto pelo agente no registro.
    az = next((a.get("value","") for a in ci.get("attributes",[])
               if a.get("name") == "ecs.availability-zone"), "")
    print("%-20s %-10s tasks=%-3s %s" % (
        ci["ec2InstanceId"], ci["status"], ci["runningTasksCount"], az))
'
}

# ------------------------------------------------------------- troca de task

troca_task() {
  local servico="${1:-backend-api}"
  marca "TROCA DE TASK — deployment rolling de ${servico}"
  echo "O que mostrar: runningCount nunca cai abaixo do mínimo e o k6 não"
  echo "registra erro. O ALB tira a task antiga do target group e só então ela"
  echo "recebe SIGTERM; o deregistration delay cobre a requisição em curso."
  echo ""

  aws ecs update-service --region "$REGION" --cluster "$CLUSTER" \
    --service "${PREFIX}-${servico}" --force-new-deployment \
    --query 'service.deployments[].{status:status,desejado:desiredCount,rodando:runningCount}' \
    --output table

  echo ">> acompanhando até estabilizar (pode levar alguns minutos)…"
  aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" \
    --services "${PREFIX}-${servico}"
  marca "deployment estável"
  estado
}

# ------------------------------------------------------------- perda de task

perde_task() {
  # O order-worker é o alvo certo: ele é quem tem trabalho em andamento.
  # Matar um backend-api só prova o balanceamento; matar o worker no meio de
  # uma mensagem prova a entrega pelo menos uma vez + idempotência.
  local servico="${1:-order-worker}"
  marca "PERDA DE TASK — SIGKILL em uma task de ${servico}"
  echo "O que mostrar: a mensagem que estava em voo volta para a fila depois do"
  echo "visibility timeout (60 s) e é reprocessada por outra task. O pedido sai"
  echo "de PENDING sem estoque debitado duas vezes — é a idempotência, não a"
  echo "sorte, que garante isso."
  echo ""

  local task
  task="$(aws ecs list-tasks --region "$REGION" --cluster "$CLUSTER" \
    --service-name "${PREFIX}-${servico}" --desired-status RUNNING \
    --query 'taskArns[0]' --output text)"
  [[ -n "$task" && "$task" != "None" ]] || { echo "!! nenhuma task RUNNING" >&2; return 1; }

  echo ">> matando ${task##*/}"
  aws ecs stop-task --region "$REGION" --cluster "$CLUSTER" --task "$task" \
    --reason "demo de perda de task" \
    --query 'task.{task:taskArn,ultimoStatus:lastStatus}' --output table

  echo ">> a partir daqui, observe no CSV: fila_em_voo sobe, depois volta para"
  echo "   fila_visiveis, e order-worker_running volta ao desejado."
  estado
}

# ------------------------------------------------------- drenagem de instância

drena_instancia() {
  marca "DRENAGEM DE INSTÂNCIA — uma EC2 sai do cluster sem derrubar task"
  echo "O que mostrar: a instância vai para DRAINING, o ECS reagenda as tasks"
  echo "dela nas outras instâncias ANTES de a EC2 morrer, e o ASG sobe uma"
  echo "substituta. Em nenhum momento o serviço fica abaixo do mínimo."
  echo ""

  local ci_arn ec2_id
  # Escolhe a instância com mais tasks: drenar a mais vazia não provaria nada.
  read -r ci_arn ec2_id < <(
    aws ecs list-container-instances --region "$REGION" --cluster "$CLUSTER" \
        --query 'containerInstanceArns' --output text \
      | tr '\t' '\n' | grep . \
      | xargs -r aws ecs describe-container-instances --region "$REGION" \
          --cluster "$CLUSTER" --container-instances \
      | python -c '
import json,sys
cis = [c for c in json.load(sys.stdin)["containerInstances"] if c["status"]=="ACTIVE"]
if not cis: raise SystemExit(1)
alvo = max(cis, key=lambda c: c["runningTasksCount"])
print(alvo["containerInstanceArn"], alvo["ec2InstanceId"])
')
  [[ -n "${ec2_id:-}" ]] || { echo "!! não achei instância ACTIVE" >&2; return 1; }
  echo ">> alvo: ${ec2_id}"

  aws ecs update-container-instances-state --region "$REGION" \
    --cluster "$CLUSTER" --container-instances "$ci_arn" --status DRAINING \
    --query 'containerInstances[].{instancia:ec2InstanceId,estado:status,tasks:runningTasksCount}' \
    --output table

  echo ">> esperando as tasks saírem da instância…"
  for _ in $(seq 1 60); do
    local restantes
    restantes="$(aws ecs describe-container-instances --region "$REGION" \
      --cluster "$CLUSTER" --container-instances "$ci_arn" \
      --query 'containerInstances[0].runningTasksCount' --output text)"
    echo "   tasks ainda em ${ec2_id}: ${restantes}"
    [[ "$restantes" == "0" ]] && break
    sleep 10
  done

  marca "instância drenada"
  remember DRENADA "$ec2_id"

  if [[ "${TERMINAR:-0}" != "1" ]]; then
    echo ">> parando aqui: a drenagem é reversível, a terminação não."
    echo "   Para reverter:  $0 reativa-instancia"
    echo "   Para completar o ciclo (remoção → inclusão):"
    echo "                   TERMINAR=1 $0 drena-instancia"
    estado
    return 0
  fi

  # Termina pelo ASG, não pelo EC2: assim o ASG repõe a capacidade sozinho e a
  # demo cobre o ciclo inteiro (remoção → inclusão) que o enunciado pede.
  # É flag booleana, não parâmetro com valor: `--should-decrement-desired-capacity
  # false` faz o CLI reclamar de "Unknown options: false". A forma negativa é
  # `--no-should-decrement-...`, e é a que queremos — o ASG mantém a capacidade
  # desejada e sobe uma substituta, que é o ciclo que o enunciado pede.
  aws autoscaling terminate-instance-in-auto-scaling-group --region "$REGION" \
    --instance-id "$ec2_id" --no-should-decrement-desired-capacity \
    --query 'Activity.{descricao:Description,causa:Cause}' --output table

  echo ">> a substituta leva ~3 min para registrar no cluster. Deixe o CSV"
  echo "   gravando até ec2_inservice voltar ao valor de antes."
  estado
}

reativa_instancia() {
  # Desfaz uma drenagem que não foi terminada: a instância volta a receber task.
  require DRENADA
  marca "reativando ${DRENADA}"
  local ci_arn
  ci_arn="$(aws ecs list-container-instances --region "$REGION" --cluster "$CLUSTER" \
    --filter "ec2InstanceId == ${DRENADA}" --query 'containerInstanceArns[0]' --output text)"
  [[ -n "$ci_arn" && "$ci_arn" != "None" ]] || { echo "!! ${DRENADA} não está no cluster" >&2; return 1; }
  aws ecs update-container-instances-state --region "$REGION" \
    --cluster "$CLUSTER" --container-instances "$ci_arn" --status ACTIVE \
    --query 'containerInstances[].{instancia:ec2InstanceId,estado:status}' --output table
  estado
}

case "${1:-}" in
  troca-task)      troca_task "${2:-}" ;;
  perde-task)      perde_task "${2:-}" ;;
  drena-instancia)   drena_instancia ;;
  reativa-instancia) reativa_instancia ;;
  estado)            estado ;;
  *)
    echo "uso: $0 {troca-task|perde-task|drena-instancia|reativa-instancia|estado} [servico]" >&2
    echo "     TERMINAR=1 $0 drena-instancia   — drena E termina (ciclo completo)" >&2
    exit 2 ;;
esac
