#!/usr/bin/env bash
# Auto scaling das tasks — o primeiro dos dois níveis de elasticidade.
#
# Requisito do enunciado: "a arquitetura deverá demonstrar dois níveis de
# elasticidade: a alteração da quantidade de tasks dos serviços ECS e a
# alteração da quantidade de instâncias EC2 que fornecem capacidade ao
# cluster". O segundo nível já está no Capacity Provider (80-ecs-cluster.sh);
# este script trata do primeiro.
#
# Cada serviço escala pela métrica que descreve a sua própria pressão:
#
#   backend-api   requisições por alvo   carga vem do navegador e do chatbot
#   chatbot       requisições por alvo   idem, mas cada turno é mais caro
#   order-worker  backlog por task       carga vem da fila, não de requisição
#   frontend      não escala             arquivo estático, carga desprezível
#
# O worker é o caso interessante: escalar por CPU seria errado, porque ele
# passa a maior parte do tempo bloqueado em long polling e em I/O do DynamoDB.
# A CPU ficaria baixa com a fila crescendo. A métrica certa é quantas
# mensagens existem por task — que é construída com metric math, já que o
# CloudWatch não a oferece pronta.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/96-autoscaling.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require CLUSTER TG_CHATBOT TG_BACKEND_INTERNAL ALB_ARN ALB_INTERNAL_ARN ORDERS_QUEUE

# O ResourceLabel do ALBRequestCountPerTarget é `app/nome/hash/targetgroup/nome/hash`:
# os dois sufixos dos ARNs, não os ARNs inteiros.
#
# O ALB tem de ser o que de fato recebe o tráfego daquele serviço. Até
# 17/11/2026 esta função era fixa no ALB público, e a política do backend-api
# acabou vigiando um target group que recebe 0,1 req/min — o tráfego real do
# backend (590-632 req/alvo/min) entra pelo ALB **interno**, vindo do chatbot.
# A política nunca disparava, e o serviço escalava só por CPU, por acidente.
alb_dimension() { echo "${1#*:loadbalancer/}"; }
tg_dimension() { echo "${1#*:targetgroup/}"; }

register_target() {
  local service="$1" min="$2" max="$3"
  aws application-autoscaling register-scalable-target --region "$REGION" \
    --service-namespace ecs \
    --resource-id "service/${CLUSTER}/${service}" \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity "$min" --max-capacity "$max" >/dev/null
  echo ">> ${service}: min=${min} max=${max}"
}

put_policy() {
  local service="$1" policy_name="$2" config="$3"
  aws application-autoscaling put-scaling-policy --region "$REGION" \
    --service-namespace ecs \
    --resource-id "service/${CLUSTER}/${service}" \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name "$policy_name" \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration "$config" >/dev/null
  echo ">> política ${policy_name} aplicada em ${service}"
}

# ---------------------------------------------------- serviços síncronos

# ScaleOut 60 s / ScaleIn 300 s: subir rápido custa alguns centavos, descer
# rápido custa disponibilidade se a carga voltar. A assimetria é deliberada.
#
# ATENÇÃO À UNIDADE: ALBRequestCountPerTarget é a **soma por minuto**, não por
# segundo. O valor original (60 para o backend, 30 para o chatbot) equivalia a
# 0,5-1 req/s por task — nenhuma aplicação real fica abaixo disso, então as
# políticas viviam pedindo o máximo. Os alvos abaixo vieram da medição de
# 17/11/2026 (docs/evidencias/ohio/ANALISE.md).
request_tracking() {
  local alb="$1" tg="$2" target="$3"
  cat <<JSON
{
  "TargetValue": ${target},
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ALBRequestCountPerTarget",
    "ResourceLabel": "$(alb_dimension "$alb")/targetgroup/$(tg_dimension "$tg")"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 300
}
JSON
}

cpu_tracking() {
  cat <<JSON
{
  "TargetValue": 60.0,
  "PredefinedMetricSpecification": {"PredefinedMetricType": "ECSServiceAverageCPUUtilization"},
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 300
}
JSON
}

register_target "${PREFIX}-backend-api" 2 8
# ALB **interno** e TG interno: é por aí que o chatbot chama o backend. Alvo
# 1500 req/alvo/min — no soak mediu-se ~4960 req/min no total com a CPU em
# 14-20%, ou seja, 8 tasks era folga demais; 1500 põe o serviço em 3-4 tasks
# nessa carga, que é proporcional.
put_policy "${PREFIX}-backend-api" "requests-per-target" \
  "$(request_tracking "$ALB_INTERNAL_ARN" "$TG_BACKEND_INTERNAL" 1500)"
# Segunda política, de CPU: cobre o caso de requisições pesadas (uma busca
# semântica custa muito mais que um GET de produto). A que pedir mais tasks vence.
put_policy "${PREFIX}-backend-api" "cpu" "$(cpu_tracking)"

register_target "${PREFIX}-chatbot" 2 8
# Alvo 250: mediu-se ~290 req/alvo/min com 8 tasks. O chatbot é limitado por
# CPU (72-150% de média contra alvo de 60%), não por contagem de requisição —
# esta política existe para o caso de carga leve e numerosa; quem manda no
# chatbot, na prática, é a de CPU.
put_policy "${PREFIX}-chatbot" "requests-per-target" \
  "$(request_tracking "$ALB_ARN" "$TG_CHATBOT" 250)"
put_policy "${PREFIX}-chatbot" "cpu" "$(cpu_tracking)"

# ---------------------------------------------------- worker, por backlog

register_target "${PREFIX}-order-worker" 1 6

# BacklogPerTask = mensagens visíveis / tasks rodando.
#
# `ReturnData: false` nas duas primeiras: elas alimentam a expressão, mas não
# são a métrica da política. A divisão usa FILL(...,1) para não dividir por
# zero quando o serviço está em transição e RunningTaskCount vem vazio.
#
# Alvo 20: com ~0,5 s por mensagem, 20 na fila por task significa ~10 s de
# espera na pior hipótese — aceitável para uma confirmação assíncrona.
put_policy "${PREFIX}-order-worker" "backlog-per-task" "$(cat <<JSON
{
  "TargetValue": 20.0,
  "CustomizedMetricSpecification": {
    "Metrics": [
      {
        "Id": "visiveis",
        "MetricStat": {
          "Metric": {
            "Namespace": "AWS/SQS",
            "MetricName": "ApproximateNumberOfMessagesVisible",
            "Dimensions": [{"Name": "QueueName", "Value": "${ORDERS_QUEUE}"}]
          },
          "Stat": "Average"
        },
        "ReturnData": false
      },
      {
        "Id": "tasks",
        "MetricStat": {
          "Metric": {
            "Namespace": "ECS/ContainerInsights",
            "MetricName": "RunningTaskCount",
            "Dimensions": [
              {"Name": "ClusterName", "Value": "${CLUSTER}"},
              {"Name": "ServiceName", "Value": "${PREFIX}-order-worker"}
            ]
          },
          "Stat": "Average"
        },
        "ReturnData": false
      },
      {
        "Id": "backlog",
        "Expression": "visiveis / FILL(tasks, 1)",
        "Label": "BacklogPerTask",
        "ReturnData": true
      }
    ]
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 300
}
JSON
)"

echo ">> auto scaling configurado"
echo ">> nota: a métrica RunningTaskCount exige Container Insights no cluster"
