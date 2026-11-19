#!/usr/bin/env bash
# IAM Roles distintas, com o menor privilégio possível.
#
# Requisito do enunciado: "as permissões deverão ser concedidas por IAM Roles
# distintas para as instâncias EC2, execução das tasks e aplicação, seguindo o
# princípio do menor privilégio".
#
# São cinco papéis, com fronteiras deliberadas:
#
#   instance        — registra a instância no cluster. NÃO acessa dados.
#   task execution  — puxa a imagem e lê os segredos ANTES do container subir.
#                     É o ECS que a usa, não a aplicação.
#   backend-api     — lê o catálogo, escreve cotações e cria pedidos.
#                     NÃO consegue debitar estoque nem confirmar pedido.
#   order-worker    — consome a fila e debita estoque. NÃO cria pedidos.
#   chatbot         — só a tabela de conversas. Não toca em pedidos.
#   pipe            — lê o stream de pedidos e publica na fila.
#
# A separação entre backend-api e order-worker é a que tem valor prático: uma
# falha (ou um prompt injection) no caminho síncrono não consegue mexer em
# estoque, porque a credencial daquele container não tem a permissão.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/40-iam.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require ORDERS_QUEUE_ARN ORDERS_DLQ_ARN PIPE_DLQ_ARN ORDERS_STREAM_ARN

TABLE_ARN_PREFIX="arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_PREFIX}"
LOGS_ARN_PREFIX="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/${PROJECT}/${ENVIRONMENT}"
SSM_ARN_PREFIX="arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${SSM_PREFIX}"

assume_role_doc() {
  cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow","Principal":{"Service":"$1"},"Action":"sts:AssumeRole"}]}
JSON
}

ensure_role() {
  local name="$1" service="$2"
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    echo ">> role ${name} já existe"
    return
  fi
  aws iam create-role --role-name "$name" \
    --assume-role-policy-document "$(assume_role_doc "$service")" \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" \
    >/dev/null
  echo ">> role ${name} criada"
}

put_policy() {
  local role="$1" name="$2" document="$3"
  aws iam put-role-policy --role-name "$role" --policy-name "$name" \
    --policy-document "$document" >/dev/null
  echo ">> política ${name} aplicada em ${role}"
}

# ----------------------------------------------------- role das instâncias

INSTANCE_ROLE="${PREFIX}-ecs-instance"
ensure_role "$INSTANCE_ROLE" "ec2.amazonaws.com"

# As duas políticas gerenciadas são exatamente o que o agente ECS e o SSM
# Session Manager precisam — e nada além disso.
for arn in \
  arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role \
  arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy --role-name "$INSTANCE_ROLE" --policy-arn "$arn"
done

if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_ROLE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_ROLE" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_ROLE" --role-name "$INSTANCE_ROLE"
  echo ">> instance profile ${INSTANCE_ROLE} criado"
fi
remember INSTANCE_ROLE "$INSTANCE_ROLE"
remember INSTANCE_PROFILE_ARN "arn:aws:iam::${ACCOUNT_ID}:instance-profile/${INSTANCE_ROLE}"

# ------------------------------------------------ role de execução de tasks

# Usada pelo ECS (não pela aplicação) para puxar a imagem e resolver os
# segredos antes de o container existir. Por isso ela — e só ela — lê os
# parâmetros de LLM.
EXECUTION_ROLE="${PREFIX}-task-execution"
ensure_role "$EXECUTION_ROLE" "ecs-tasks.amazonaws.com"
aws iam attach-role-policy --role-name "$EXECUTION_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

put_policy "$EXECUTION_ROLE" "secrets" "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["ssm:GetParameters"],
   "Resource":["${SSM_ARN_PREFIX}/*"]},
  {"Effect":"Allow","Action":["kms:Decrypt"],
   "Resource":["arn:aws:kms:${REGION}:${ACCOUNT_ID}:alias/aws/ssm"]},
  {"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
   "Resource":["${LOGS_ARN_PREFIX}/*"]}
]}
JSON
)"
remember EXECUTION_ROLE_ARN "arn:aws:iam::${ACCOUNT_ID}:role/${EXECUTION_ROLE}"

# ------------------------------------------------------- roles de aplicação

# Blocos comuns a toda task role: escrever log, métrica de negócio e ler o
# parâmetro de injeção de falhas.
common_statements() {
  cat <<JSON
  {"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
   "Resource":["${LOGS_ARN_PREFIX}/*"]},
  {"Effect":"Allow","Action":["ssm:GetParameter"],
   "Resource":["${SSM_ARN_PREFIX}/faults"]},
  {"Effect":"Allow","Action":["cloudwatch:PutMetricData"],"Resource":"*",
   "Condition":{"StringEquals":{"cloudwatch:namespace":"ConvCommerce"}}}
JSON
}

# --- backend-api: lê catálogo, escreve cotação, CRIA pedido.
#     Não tem UpdateItem em products nem em orders: confirmar um pedido ou
#     debitar estoque é privilégio exclusivo do worker.
BACKEND_ROLE="${PREFIX}-backend-api"
ensure_role "$BACKEND_ROLE" "ecs-tasks.amazonaws.com"
put_policy "$BACKEND_ROLE" "app" "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
$(common_statements),
  {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:BatchGetItem",
    "dynamodb:Query","dynamodb:Scan","dynamodb:UpdateItem","dynamodb:PutItem"],
   "Resource":["${TABLE_ARN_PREFIX}products","${TABLE_ARN_PREFIX}products/index/*"]},
  {"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:Query"],
   "Resource":["${TABLE_ARN_PREFIX}stock_movements"]},
  {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem"],
   "Resource":["${TABLE_ARN_PREFIX}quotes"]},
  {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem"],
   "Resource":["${TABLE_ARN_PREFIX}orders"]}
]}
JSON
)"
remember BACKEND_ROLE_ARN "arn:aws:iam::${ACCOUNT_ID}:role/${BACKEND_ROLE}"

# --- order-worker: consome a fila e executa a transação de confirmação.
#     Não tem PutItem em orders: não consegue criar pedido, só transicionar.
WORKER_ROLE="${PREFIX}-order-worker"
ensure_role "$WORKER_ROLE" "ecs-tasks.amazonaws.com"
put_policy "$WORKER_ROLE" "app" "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
$(common_statements),
  {"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility","sqs:GetQueueUrl","sqs:GetQueueAttributes",
    "sqs:SendMessage"],
   "Resource":["${ORDERS_QUEUE_ARN}"]},
  {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:UpdateItem",
    "dynamodb:Query"],
   "Resource":["${TABLE_ARN_PREFIX}orders","${TABLE_ARN_PREFIX}orders/index/*"]},
  {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:UpdateItem"],
   "Resource":["${TABLE_ARN_PREFIX}products"]},
  {"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:Query"],
   "Resource":["${TABLE_ARN_PREFIX}stock_movements"]}
]}
JSON
)"
remember WORKER_ROLE_ARN "arn:aws:iam::${ACCOUNT_ID}:role/${WORKER_ROLE}"

# --- chatbot: só conversas. O catálogo e os pedidos ele alcança por HTTP,
#     através da backend-api — nunca direto no banco.
#     O DeleteItem é do item `REQ#<request_id>`: quando um turno falha, o
#     chatbot libera o request_id para o cliente poder tentar de novo.
CHATBOT_ROLE="${PREFIX}-chatbot"
ensure_role "$CHATBOT_ROLE" "ecs-tasks.amazonaws.com"
put_policy "$CHATBOT_ROLE" "app" "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
$(common_statements),
  {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem",
    "dynamodb:UpdateItem","dynamodb:Query","dynamodb:DeleteItem"],
   "Resource":["${TABLE_ARN_PREFIX}conversations"]}
]}
JSON
)"
remember CHATBOT_ROLE_ARN "arn:aws:iam::${ACCOUNT_ID}:role/${CHATBOT_ROLE}"

# --- frontend: nginx servindo arquivos estáticos. Só precisa escrever log.
FRONTEND_ROLE="${PREFIX}-frontend"
ensure_role "$FRONTEND_ROLE" "ecs-tasks.amazonaws.com"
put_policy "$FRONTEND_ROLE" "app" "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
   "Resource":["${LOGS_ARN_PREFIX}/*"]}
]}
JSON
)"
remember FRONTEND_ROLE_ARN "arn:aws:iam::${ACCOUNT_ID}:role/${FRONTEND_ROLE}"

# ----------------------------------------------------------- role do Pipe

PIPE_ROLE="${PREFIX}-pipe"
ensure_role "$PIPE_ROLE" "pipes.amazonaws.com"
put_policy "$PIPE_ROLE" "stream-to-queue" "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["dynamodb:DescribeStream","dynamodb:GetRecords",
    "dynamodb:GetShardIterator","dynamodb:ListStreams"],
   "Resource":["${ORDERS_STREAM_ARN}"]},
  {"Effect":"Allow","Action":["sqs:SendMessage"],
   "Resource":["${ORDERS_QUEUE_ARN}","${PIPE_DLQ_ARN}"]}
]}
JSON
)"
remember PIPE_ROLE_ARN "arn:aws:iam::${ACCOUNT_ID}:role/${PIPE_ROLE}"

echo ">> IAM pronto. As roles levam alguns segundos para propagar."
