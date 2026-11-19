#!/usr/bin/env bash
# Tabelas DynamoDB, filas SQS com DLQ e o EventBridge Pipe do outbox.
#
# Requisitos do enunciado atendidos aqui:
# * "conversas, catálogo, estoque e pedidos deverão utilizar um serviço
#   persistente adequado, como Amazon RDS ou DynamoDB";
# * "comunicação assíncrona em pelo menos uma parte relevante [...] com
#   dead-letter queue ou mecanismo equivalente".
#
# O Pipe lê o stream da tabela `orders` e publica na fila: é o que garante que
# não exista pedido sem evento, sem a aplicação precisar de uma segunda escrita.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/30-data.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

table_name() { echo "${TABLE_PREFIX}$1"; }

table_exists() {
  aws dynamodb describe-table --region "$REGION" --table-name "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------- tabelas

# On-demand: a carga do MVP é irregular (demos e teste de carga), e capacidade
# provisionada ociosa custaria mais que o consumo real.
create_table() {
  local logical="$1"; shift
  local name; name="$(table_name "$logical")"
  if table_exists "$name"; then
    echo ">> tabela ${name} já existe"
    return
  fi
  aws dynamodb create-table --region "$REGION" --table-name "$name" \
    --billing-mode PAY_PER_REQUEST \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" \
    "$@" >/dev/null
  echo ">> tabela ${name} criada"
}

create_table products \
  --attribute-definitions \
    AttributeName=product_id,AttributeType=S \
    AttributeName=category,AttributeType=S \
    AttributeName=title,AttributeType=S \
  --key-schema AttributeName=product_id,KeyType=HASH \
  --global-secondary-indexes \
    "[{\"IndexName\":\"gsi_category\",
       \"KeySchema\":[{\"AttributeName\":\"category\",\"KeyType\":\"HASH\"},
                      {\"AttributeName\":\"title\",\"KeyType\":\"RANGE\"}],
       \"Projection\":{\"ProjectionType\":\"ALL\"}}]"

create_table stock_movements \
  --attribute-definitions \
    AttributeName=product_id,AttributeType=S \
    AttributeName=sk,AttributeType=S \
  --key-schema \
    AttributeName=product_id,KeyType=HASH \
    AttributeName=sk,KeyType=RANGE

create_table quotes \
  --attribute-definitions AttributeName=quote_id,AttributeType=S \
  --key-schema AttributeName=quote_id,KeyType=HASH

# O stream é o que alimenta o Pipe: a gravação do pedido É o evento.
create_table orders \
  --attribute-definitions \
    AttributeName=order_id,AttributeType=S \
    AttributeName=pending_shard,AttributeType=S \
    AttributeName=created_at,AttributeType=S \
  --key-schema AttributeName=order_id,KeyType=HASH \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_IMAGE \
  --global-secondary-indexes \
    "[{\"IndexName\":\"gsi_pending\",
       \"KeySchema\":[{\"AttributeName\":\"pending_shard\",\"KeyType\":\"HASH\"},
                      {\"AttributeName\":\"created_at\",\"KeyType\":\"RANGE\"}],
       \"Projection\":{\"ProjectionType\":\"INCLUDE\",
                       \"NonKeyAttributes\":[\"correlation_id\",\"traceparent\"]}}]"

create_table conversations \
  --attribute-definitions \
    AttributeName=conversation_id,AttributeType=S \
    AttributeName=sk,AttributeType=S \
  --key-schema \
    AttributeName=conversation_id,KeyType=HASH \
    AttributeName=sk,KeyType=RANGE

for logical in "${TABLES[@]}"; do
  aws dynamodb wait table-exists --region "$REGION" --table-name "$(table_name "$logical")"
done

# TTL: as cotações expiram em 30 min e as conversas em 7 dias. É só faxina —
# a expiração que vale para o negócio é avaliada na leitura, porque o TTL do
# DynamoDB pode levar horas para apagar de fato.
enable_ttl() {
  local name attribute
  name="$(table_name "$1")"; attribute="$2"
  local status
  status="$(aws dynamodb describe-time-to-live --region "$REGION" \
    --table-name "$name" --query 'TimeToLiveDescription.TimeToLiveStatus' --output text)"
  if [[ "$status" == "ENABLED" || "$status" == "ENABLING" ]]; then
    echo ">> TTL de ${name} já ativo"
    return
  fi
  aws dynamodb update-time-to-live --region "$REGION" --table-name "$name" \
    --time-to-live-specification "Enabled=true,AttributeName=${attribute}" >/dev/null
  echo ">> TTL de ${name} ativado em ${attribute}"
}

enable_ttl quotes ttl
enable_ttl conversations expires_at

# PITR nas tabelas que guardam a transação: o enunciado exige recuperar a
# capacidade "sem perda dos dados persistentes".
for logical in products orders stock_movements; do
  aws dynamodb update-continuous-backups --region "$REGION" \
    --table-name "$(table_name "$logical")" \
    --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true \
    >/dev/null 2>&1 || true
done

ORDERS_STREAM_ARN="$(aws dynamodb describe-table --region "$REGION" \
  --table-name "$(table_name orders)" --query 'Table.LatestStreamArn' --output text)"
remember ORDERS_STREAM_ARN "$ORDERS_STREAM_ARN"

# --------------------------------------------------------------------- filas

queue_url() {
  aws sqs get-queue-url --region "$REGION" --queue-name "$1" \
    --query 'QueueUrl' --output text 2>/dev/null || true
}

queue_arn() {
  aws sqs get-queue-attributes --region "$REGION" --queue-url "$1" \
    --attribute-names QueueArn --query 'Attributes.QueueArn' --output text
}

# DLQs primeiro: a fila principal precisa do ARN delas no redrive.
for dlq in "$ORDERS_DLQ" "$PIPE_DLQ"; do
  if [[ -z "$(queue_url "$dlq")" ]]; then
    # 14 dias de retenção: tempo de sobra para investigar uma mensagem
    # problemática antes do redrive.
    aws sqs create-queue --region "$REGION" --queue-name "$dlq" \
      --attributes "MessageRetentionPeriod=1209600,SqsManagedSseEnabled=true" \
      --tags "Project=${PROJECT},Environment=${ENVIRONMENT}" >/dev/null
    echo ">> fila ${dlq} criada"
  fi
done

ORDERS_DLQ_URL="$(queue_url "$ORDERS_DLQ")"
ORDERS_DLQ_ARN="$(queue_arn "$ORDERS_DLQ_URL")"
PIPE_DLQ_URL="$(queue_url "$PIPE_DLQ")"
PIPE_DLQ_ARN="$(queue_arn "$PIPE_DLQ_URL")"
remember ORDERS_DLQ_URL "$ORDERS_DLQ_URL"
remember ORDERS_DLQ_ARN "$ORDERS_DLQ_ARN"
remember PIPE_DLQ_URL "$PIPE_DLQ_URL"
remember PIPE_DLQ_ARN "$PIPE_DLQ_ARN"

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

echo ">> dados e mensageria prontos"
echo ">> em seguida: scripts/ohio/40-iam.sh (o Pipe precisa da role)"
