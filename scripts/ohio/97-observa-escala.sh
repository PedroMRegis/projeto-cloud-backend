#!/usr/bin/env bash
# Grava a escala de tasks e de instâncias em CSV, uma linha por amostra.
#
# POR QUE UM CSV E NÃO SÓ O CONSOLE
#   O console da AWS mostra o estado agora; a evidência que o enunciado pede é
#   a *trajetória*: quando a task subiu, quanto tempo depois a instância entrou,
#   quanto tempo a fila levou para drenar. Isso precisa de amostragem ao longo
#   do teste de carga, e um CSV casa com o relógio do k6 na hora de montar o
#   gráfico e de narrar a gravação.
#
# O QUE CADA COLUNA SIGNIFICA
#   ts                  horário UTC da amostra (mesma base do CloudWatch)
#   <servico>_desired   o que o auto scaling pediu
#   <servico>_running   o que de fato está no ar — a diferença é o atraso real
#   asg_desired         o que o Capacity Provider pediu de EC2
#   ec2_inservice       instâncias que o ASG considera saudáveis
#   ec2_draining        instâncias em drenagem (é esta coluna que prova a troca)
#   fila_visiveis       mensagens esperando na fila
#   fila_em_voo         mensagens entregues e ainda não confirmadas
#
#   source scripts/ohio/00-config.sh && scripts/ohio/97-observa-escala.sh [SEGUNDOS] [INTERVALO]
#
# Rode em um terminal separado, ANTES de começar o k6, e deixe até o fim.

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require CLUSTER ASG ORDERS_QUEUE_URL

DURACAO="${1:-900}"
INTERVALO="${2:-15}"

SAIDA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docs/evidencias/ohio"
mkdir -p "$SAIDA_DIR"
SAIDA="${SAIDA_DIR}/escala-$(date -u +%Y%m%dT%H%M%SZ).csv"

cabecalho="ts"
for s in backend-api chatbot order-worker frontend; do
  cabecalho+=",${s}_desired,${s}_running"
done
cabecalho+=",asg_desired,ec2_inservice,ec2_draining,fila_visiveis,fila_em_voo"
echo "$cabecalho" > "$SAIDA"

echo ">> gravando em ${SAIDA}"
echo ">> ${DURACAO}s a cada ${INTERVALO}s — Ctrl-C interrompe e mantém o que já foi gravado"

# Uma falha transiente de rede NÃO pode matar a gravação. Com `set -e` herdado
# do 00-config.sh, um único "Could not connect to the endpoint URL" encerrava o
# observador no meio do ensaio e levava junto o resto do CSV (aconteceu em
# 19/11, aos 10 min). Daqui para baixo cada chamada tolera erro e a amostra
# sai com o campo vazio, que no gráfico vira um furo — visível, mas não fatal.
set +e

fim=$(( $(date +%s) + DURACAO ))
while (( $(date +%s) < fim )); do
  linha="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Uma chamada só para os quatro serviços: menos chance de as amostras
  # ficarem de relógios diferentes dentro da mesma linha.
  servicos="$(aws ecs describe-services --region "$REGION" \
    --cluster "$CLUSTER" \
    --services "${PREFIX}-backend-api" "${PREFIX}-chatbot" \
               "${PREFIX}-order-worker" "${PREFIX}-frontend" \
    --query 'services[].[serviceName,desiredCount,runningCount]' --output text)"

  for s in backend-api chatbot order-worker frontend; do
    dados="$(echo "$servicos" | grep -F "${PREFIX}-${s}" || true)"
    if [[ -n "$dados" ]]; then
      linha+=",$(echo "$dados" | awk '{print $2","$3}')"
    else
      linha+=",,"
    fi
  done

  asg="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances[?LifecycleState==`InService`]),length(Instances[?contains(LifecycleState,`Terminating`)])]' \
    --output text)"
  linha+=",$(echo "$asg" | awk '{print $1","$2","$3}')"

  fila="$(aws sqs get-queue-attributes --region "$REGION" \
    --queue-url "$ORDERS_QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' \
    --output text)"
  linha+=",$(echo "$fila" | awk '{print $1","$2}')"

  echo "$linha" | tee -a "$SAIDA"
  sleep "$INTERVALO"
done

echo ""
echo ">> fim. Evidência em ${SAIDA}"
echo ">> para a apresentação: a coluna ec2_draining > 0 é o momento da troca de instância."
