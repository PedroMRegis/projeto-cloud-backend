#!/usr/bin/env bash
# EventBridge Pipe: stream da tabela `orders` → `orders-queue`.
#
# Este é o elo assíncrono da arquitetura. O filtro garante que só a criação de
# um pedido vire mensagem (INSERT + status PENDING), e o input transformer
# reduz o item inteiro ao que o worker precisa, levando junto o
# `correlation_id` e o `traceparent` — é o que permite seguir uma requisição
# do chat até a confirmação do pedido nos logs.
#
# A DLQ do source cobre o caso de o Pipe não conseguir processar o registro do
# stream; a DLQ da fila cobre o caso de o worker não conseguir processar a
# mensagem. São falhas diferentes, em DLQs diferentes.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/50-messaging-pipe.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require ORDERS_STREAM_ARN ORDERS_QUEUE_ARN PIPE_DLQ_ARN PIPE_ROLE_ARN

PIPE_NAME="${PREFIX}-orders-outbox"

if aws pipes describe-pipe --region "$REGION" --name "$PIPE_NAME" >/dev/null 2>&1; then
  echo ">> pipe ${PIPE_NAME} já existe"
  remember PIPE_NAME "$PIPE_NAME"
  exit 0
fi

# O filtro usa a sintaxe de event pattern do EventBridge. `status.S` porque o
# stream entrega a imagem no formato de atributos do DynamoDB.
SOURCE_PARAMS="$(cat <<JSON
{
  "DynamoDBStreamParameters": {
    "StartingPosition": "LATEST",
    "BatchSize": 1,
    "MaximumRetryAttempts": 3,
    "DeadLetterConfig": {"Arn": "${PIPE_DLQ_ARN}"}
  },
  "FilterCriteria": {
    "Filters": [
      {"Pattern": "{\"eventName\":[\"INSERT\"],\"dynamodb\":{\"NewImage\":{\"status\":{\"S\":[\"PENDING\"]}}}}"}
    ]
  }
}
JSON
)"

# `<$.caminho>` é a sintaxe de input transformer do Pipes. O corpo resultante
# é exatamente o que `worker/main.py:parse_message` espera — o mesmo formato
# que o sweeper publica, então o worker não sabe (nem precisa saber) quem
# publicou a mensagem.
TARGET_PARAMS="$(cat <<'JSON'
{
  "InputTemplate": "{\"order_id\": \"<$.dynamodb.NewImage.order_id.S>\", \"correlation_id\": \"<$.dynamodb.NewImage.correlation_id.S>\", \"traceparent\": \"<$.dynamodb.NewImage.traceparent.S>\"}"
}
JSON
)"

aws pipes create-pipe --region "$REGION" --name "$PIPE_NAME" \
  --role-arn "$PIPE_ROLE_ARN" \
  --source "$ORDERS_STREAM_ARN" \
  --source-parameters "$SOURCE_PARAMS" \
  --target "$ORDERS_QUEUE_ARN" \
  --target-parameters "$TARGET_PARAMS" \
  --tags "Project=${PROJECT},Environment=${ENVIRONMENT}" \
  >/dev/null

echo ">> aguardando o pipe ficar em execução"
for _ in $(seq 1 30); do
  state="$(aws pipes describe-pipe --region "$REGION" --name "$PIPE_NAME" \
    --query 'CurrentState' --output text)"
  [[ "$state" == "RUNNING" ]] && break
  sleep 5
done

remember PIPE_NAME "$PIPE_NAME"
echo ">> pipe ${PIPE_NAME} em ${state}"
