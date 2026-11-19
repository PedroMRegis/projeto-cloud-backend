#!/usr/bin/env bash
# Tabela de conversas no DynamoDB e filas SQS de pedidos, com DLQ.
#
# Requisitos do enunciado atendidos aqui:
# * "conversas, catálogo, estoque e pedidos deverão utilizar um serviço
#   persistente adequado, como Amazon RDS ou DynamoDB";
# * "comunicação assíncrona em pelo menos uma parte relevante [...] com
#   dead-letter queue ou mecanismo equivalente".
#
# Catálogo, estoque, pedidos e contas ficam no RDS Postgres (35-rds.sh). Até
# 12/11/2026 eles moravam em quatro tabelas DynamoDB com um EventBridge Pipe;
# a troca para o Postgres com outbox está no ADR 0002 e no migrar-backend-rds.sh.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/30-data.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

# ------------------------------------------------------------ conversas

# On-demand: a carga é irregular (demos e teste de carga), e capacidade
# provisionada ociosa custaria mais que o consumo real.
CONVERSATIONS="${TABLE_PREFIX}conversations"
if aws dynamodb describe-table --region "$REGION" --table-name "$CONVERSATIONS" >/dev/null 2>&1; then
  echo ">> tabela ${CONVERSATIONS} já existe"
else
  aws dynamodb create-table --region "$REGION" --table-name "$CONVERSATIONS" \
    --billing-mode PAY_PER_REQUEST \
    --attribute-definitions \
      AttributeName=conversation_id,AttributeType=S \
      AttributeName=sk,AttributeType=S \
    --key-schema \
      AttributeName=conversation_id,KeyType=HASH \
      AttributeName=sk,KeyType=RANGE \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null
  aws dynamodb wait table-exists --region "$REGION" --table-name "$CONVERSATIONS"
  echo ">> tabela ${CONVERSATIONS} criada"
fi

# TTL em `expires_at`: só os itens de controle (`REQ#` da idempotência de turno
# e `RATE#` do limite de mensagens) recebem o atributo. As mensagens não têm
# `expires_at` e ficam para sempre, ligadas à conta do cliente.
status="$(aws dynamodb describe-time-to-live --region "$REGION" \
  --table-name "$CONVERSATIONS" --query 'TimeToLiveDescription.TimeToLiveStatus' --output text)"
if [[ "$status" != "ENABLED" && "$status" != "ENABLING" ]]; then
  aws dynamodb update-time-to-live --region "$REGION" --table-name "$CONVERSATIONS" \
    --time-to-live-specification "Enabled=true,AttributeName=expires_at" >/dev/null
  echo ">> TTL de ${CONVERSATIONS} ativado em expires_at"
fi

# --------------------------------------------------------------------- filas

queue_url() {
  aws sqs get-queue-url --region "$REGION" --queue-name "$1" \
    --query 'QueueUrl' --output text 2>/dev/null || true
}

queue_arn() {
  aws sqs get-queue-attributes --region "$REGION" --queue-url "$1" \
    --attribute-names QueueArn --query 'Attributes.QueueArn' --output text
}

# A DLQ primeiro: a fila principal precisa do ARN dela no redrive.
if [[ -z "$(queue_url "$ORDERS_DLQ")" ]]; then
  # 14 dias de retenção: tempo de sobra para investigar uma mensagem
  # problemática antes do redrive.
  aws sqs create-queue --region "$REGION" --queue-name "$ORDERS_DLQ" \
    --attributes "MessageRetentionPeriod=1209600,SqsManagedSseEnabled=true" \
    --tags "Project=${PROJECT},Environment=${ENVIRONMENT}" >/dev/null
  echo ">> fila ${ORDERS_DLQ} criada"
fi

ORDERS_DLQ_URL="$(queue_url "$ORDERS_DLQ")"
ORDERS_DLQ_ARN="$(queue_arn "$ORDERS_DLQ_URL")"
remember ORDERS_DLQ_URL "$ORDERS_DLQ_URL"
remember ORDERS_DLQ_ARN "$ORDERS_DLQ_ARN"

if [[ -z "$(queue_url "$ORDERS_QUEUE")" ]]; then
  # VisibilityTimeout 60 s: folga sobre o tempo de processar um pedido.
  # ReceiveMessageWaitTimeSeconds 20 s: long polling, sem polling vazio.
  # maxReceiveCount 3: duas retentativas antes da DLQ.
  aws sqs create-queue --region "$REGION" --queue-name "$ORDERS_QUEUE" \
    --attributes "$(cat <<JSON
{
  "VisibilityTimeout": "60",
  "ReceiveMessageWaitTimeSeconds": "20",
  "MessageRetentionPeriod": "345600",
  "SqsManagedSseEnabled": "true",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"${ORDERS_DLQ_ARN}\",\"maxReceiveCount\":\"3\"}"
}
JSON
)" --tags "Project=${PROJECT},Environment=${ENVIRONMENT}" >/dev/null
  echo ">> fila ${ORDERS_QUEUE} criada"
fi

ORDERS_QUEUE_URL="$(queue_url "$ORDERS_QUEUE")"
ORDERS_QUEUE_ARN="$(queue_arn "$ORDERS_QUEUE_URL")"
remember ORDERS_QUEUE_URL "$ORDERS_QUEUE_URL"
remember ORDERS_QUEUE_ARN "$ORDERS_QUEUE_ARN"

echo ">> conversas e filas prontas"
echo ">> em seguida: scripts/ohio/35-rds.sh"
