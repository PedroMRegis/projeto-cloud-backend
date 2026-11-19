#!/usr/bin/env bash
# Task definitions, serviços ECS e auto scaling das tasks.
#
# Requisitos do enunciado atendidos aqui:
# * "a topologia deverá possuir pelo menos dois serviços ECS com
#   responsabilidades e perfis de escalabilidade distintos";
# * "os containers deverão possuir reservas e limites de CPU e memória
#   coerentes com a capacidade das instâncias";
# * "a arquitetura deverá demonstrar dois níveis de elasticidade: a alteração
#   da quantidade de tasks dos serviços ECS e a alteração da quantidade de
#   instâncias EC2";
# * "os serviços deverão possuir health checks. O ECS deverá substituir tasks
#   defeituosas".
#
# São quatro serviços com perfis deliberadamente diferentes:
#
#   backend-api   síncrono, escala por requisição/alvo    min 2  max 8
#   chatbot       síncrono, limitado por CPU              min 2  max 8
#   order-worker  assíncrono, escala por backlog da fila  min 1  max 6
#   frontend      estático, carga desprezível             2 fixas
#
#   source scripts/ohio/00-config.sh && scripts/ohio/95-services.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require CLUSTER CAPACITY_PROVIDER EXECUTION_ROLE_ARN TG_BACKEND TG_CHATBOT \
        TG_FRONTEND TG_BACKEND_INTERNAL ALB_INTERNAL_DNS ORDERS_QUEUE_URL \
        DB_HOST DB_SECRET_ARN \
        IMAGE_backend_api IMAGE_chatbot IMAGE_order_worker IMAGE_frontend

LOG_PREFIX="/${PROJECT}/${ENVIRONMENT}"
SSM_ARN="arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${SSM_PREFIX}"

# Banco: endereço em texto; usuário e senha resolvidos pelo ECS a partir do
# segredo do RDS. DB_SECRET_ARN deixa a aplicação reler a senha depois da
# rotação de 7 dias, sem novo deploy.
DB_ENV="$(cat <<JSON
    {"name": "DB_HOST", "value": "${DB_HOST}"},
    {"name": "DB_PORT", "value": "5432"},
    {"name": "DB_NAME", "value": "${DB_NAME}"},
    {"name": "DB_SSLMODE", "value": "require"},
    {"name": "DB_SECRET_ARN", "value": "${DB_SECRET_ARN}"},
JSON
)"
DB_SECRETS="$(cat <<JSON
    {"name": "DB_USER", "valueFrom": "${DB_SECRET_ARN}:username::"},
    {"name": "DB_PASSWORD", "valueFrom": "${DB_SECRET_ARN}:password::"}
JSON
)"

# --------------------------------------------------------------- log groups

for service in "${SERVICES[@]}"; do
  group="${LOG_PREFIX}/${service}"
  if ! aws logs describe-log-groups --region "$REGION" \
       --log-group-name-prefix "$group" \
       --query "logGroups[?logGroupName=='${group}'].logGroupName" --output text | grep -q .; then
    aws logs create-log-group --region "$REGION" --log-group-name "$group" \
      --tags "Project=${PROJECT},Environment=${ENVIRONMENT}" >/dev/null
    # 14 dias: cobre uma semana de demos com folga, sem acumular custo.
    aws logs put-retention-policy --region "$REGION" \
      --log-group-name "$group" --retention-in-days 14 >/dev/null
    echo ">> log group ${group} criado"
  fi
done

log_config() {
  cat <<JSON
{"logDriver":"awslogs","options":{
  "awslogs-group":"${LOG_PREFIX}/$1",
  "awslogs-region":"${REGION}",
  "awslogs-stream-prefix":"ecs"}}
JSON
}

register() {
  local family="$1" role_arn="$2" container_json="$3"
  local arn
  arn="$(aws ecs register-task-definition --region "$REGION" \
    --family "$family" \
    --network-mode bridge \
    --requires-compatibilities EC2 \
    --execution-role-arn "$EXECUTION_ROLE_ARN" \
    --task-role-arn "$role_arn" \
    --container-definitions "$container_json" \
    --tags "key=Project,value=${PROJECT}" "key=Environment,value=${ENVIRONMENT}" \
    --query 'taskDefinition.taskDefinitionArn' --output text)"
  echo ">> task definition ${arn##*/}" >&2
  echo "$arn"
}

# ----------------------------------------------------------- backend-api

# `hostPort: 0` é o que dá a porta dinâmica do modo bridge: o ECS escolhe uma
# porta efêmera por task e a registra no target group. Em `awsvpc`, cada task
# consumiria uma ENI e a t3.small só comportaria ~2 tasks; em bridge cabem 6+,
# e é isso que torna o binpack e a demo de densidade possíveis.
TD_BACKEND="$(register "${PREFIX}-backend-api" "$BACKEND_ROLE_ARN" "$(cat <<JSON
[{
  "name": "app",
  "image": "${IMAGE_backend_api}",
  "essential": true,
  "cpu": 256,
  "memoryReservation": 256,
  "memory": 512,
  "portMappings": [{"containerPort": 8000, "hostPort": 0, "protocol": "tcp"}],
  "environment": [
    {"name": "AWS_REGION", "value": "${REGION}"},
    {"name": "APP_ENV", "value": "${ENVIRONMENT}"},
    {"name": "SERVICE_NAME", "value": "backend-api"},
${DB_ENV}
    {"name": "ORDERS_QUEUE_URL", "value": "${ORDERS_QUEUE_URL}"},
    {"name": "MIGRATE_ON_START", "value": "true"},
    {"name": "EMBEDDINGS_PROVIDER", "value": "bedrock"},
    {"name": "AUTH_COOKIE_SECURE", "value": "false"},
    {"name": "FAULTS_PARAMETER", "value": "${SSM_PREFIX}/faults"}
  ],
  "secrets": [
${DB_SECRETS},
    {"name": "ADMIN_TOKEN", "valueFrom": "${SSM_ARN}/admin_token"},
    {"name": "AUTH_JWT_SECRET", "valueFrom": "${SSM_ARN}/auth_jwt_secret"}
  ],
  "healthCheck": {
    "command": ["CMD-SHELL", "curl -fsS http://localhost:8000/health || exit 1"],
    "interval": 15, "timeout": 5, "retries": 3, "startPeriod": 30
  },
  "stopTimeout": 30,
  "logConfiguration": $(log_config backend-api)
}]
JSON
)")"

# ---------------------------------------------------------------- chatbot

# O chatbot alcança o backend pelo próprio ALB. Em modo bridge as portas são
# dinâmicas, então um endereço fixo task-a-task não existiria; o ALB já resolve
# descoberta e balanceamento, e o SG só permite essa origem.
TD_CHATBOT="$(register "${PREFIX}-chatbot" "$CHATBOT_ROLE_ARN" "$(cat <<JSON
[{
  "name": "app",
  "image": "${IMAGE_chatbot}",
  "essential": true,
  "cpu": 512,
  "memoryReservation": 256,
  "memory": 512,
  "portMappings": [{"containerPort": 8000, "hostPort": 0, "protocol": "tcp"}],
  "environment": [
    {"name": "AWS_REGION", "value": "${REGION}"},
    {"name": "APP_ENV", "value": "${ENVIRONMENT}"},
    {"name": "SERVICE_NAME", "value": "chatbot"},
    {"name": "TABLE_CONVERSATIONS", "value": "${TABLE_PREFIX}conversations"},
    {"name": "BACKEND_URL", "value": "http://${ALB_INTERNAL_DNS}"},
    {"name": "FAULTS_PARAMETER", "value": "${SSM_PREFIX}/faults"},
    {"name": "LLM_PROVIDER", "value": "bedrock"}
  ],
  "secrets": [
    {"name": "AUTH_JWT_SECRET", "valueFrom": "${SSM_ARN}/auth_jwt_secret"}
  ],
  "healthCheck": {
    "command": ["CMD-SHELL", "curl -fsS http://localhost:8000/health || exit 1"],
    "interval": 15, "timeout": 5, "retries": 3, "startPeriod": 30
  },
  "stopTimeout": 30,
  "logConfiguration": $(log_config chatbot)
}]
JSON
)")"

# ----------------------------------------------------------- order-worker

# Sem portMappings: o worker não recebe tráfego, ele busca na fila. O health
# check olha a idade de um arquivo de heartbeat — se o laço de polling travar,
# o arquivo envelhece e o ECS substitui a task.
TD_WORKER="$(register "${PREFIX}-order-worker" "$WORKER_ROLE_ARN" "$(cat <<JSON
[{
  "name": "app",
  "image": "${IMAGE_order_worker}",
  "essential": true,
  "cpu": 128,
  "memoryReservation": 128,
  "memory": 256,
  "environment": [
    {"name": "AWS_REGION", "value": "${REGION}"},
    {"name": "APP_ENV", "value": "${ENVIRONMENT}"},
    {"name": "SERVICE_NAME", "value": "order-worker"},
${DB_ENV}
    {"name": "ORDERS_QUEUE_URL", "value": "${ORDERS_QUEUE_URL}"},
    {"name": "MIGRATE_ON_START", "value": "false"},
    {"name": "EMBEDDINGS_PROVIDER", "value": "none"},
    {"name": "WORKER_THREADS", "value": "2"},
    {"name": "FAULTS_PARAMETER", "value": "${SSM_PREFIX}/faults"}
  ],
  "secrets": [
${DB_SECRETS}
  ],
  "healthCheck": {
    "command": ["CMD-SHELL", "test -n \"\$(find /tmp/heartbeat -mmin -1 2>/dev/null)\" || exit 1"],
    "interval": 30, "timeout": 5, "retries": 3, "startPeriod": 20
  },
  "stopTimeout": 30,
  "logConfiguration": $(log_config order-worker)
}]
JSON
)")"

# --------------------------------------------------------------- frontend

TD_FRONTEND="$(register "${PREFIX}-frontend" "$FRONTEND_ROLE_ARN" "$(cat <<JSON
[{
  "name": "app",
  "image": "${IMAGE_frontend}",
  "essential": true,
  "cpu": 64,
  "memoryReservation": 64,
  "memory": 128,
  "portMappings": [{"containerPort": 8080, "hostPort": 0, "protocol": "tcp"}],
  "healthCheck": {
    "command": ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/health >/dev/null || exit 1"],
    "interval": 15, "timeout": 5, "retries": 3, "startPeriod": 10
  },
  "stopTimeout": 30,
  "logConfiguration": $(log_config frontend)
}]
JSON
)")"

# --------------------------------------------------------------- serviços

service_exists() {
  aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$1" \
    --query 'services[?status==`ACTIVE`].serviceName' --output text | grep -q .
}

# Placement: spread por AZ primeiro (uma task em cada zona sobrevive à perda de
# uma AZ), binpack de memória depois (concentra o resto, o que libera instâncias
# inteiras no scale-in em vez de deixar quatro máquinas pela metade).
PLACEMENT='[{"type":"spread","field":"attribute:ecs.availability-zone"},{"type":"binpack","field":"memory"}]'

# minimumHealthyPercent 100 + maximumPercent 200: durante o deploy sobe a nova
# task antes de derrubar a antiga, então a capacidade nunca cai abaixo do
# desejado. O circuit breaker faz rollback sozinho se a nova versão não ficar
# saudável — é o que a demo de "deploy com problema" exercita.
DEPLOY_CONF='maximumPercent=200,minimumHealthyPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}'

# `load_balancers` vai em JSON, e não na shorthand `chave=valor`: o backend é
# registrado em **dois** grupos — o público (tráfego do navegador, via regra
# /api/*) e o interno (chamadas do chatbot) — e a shorthand não consegue
# expressar dois elementos com as mesmas chaves.
lb_json() {
  local tg="$1" container="$2" port="$3"
  echo "{\"targetGroupArn\":\"${tg}\",\"containerName\":\"${container}\",\"containerPort\":${port}}"
}

create_service() {
  local name="$1" task_def="$2" desired="$3" load_balancers="${4:-}"
  if service_exists "$name"; then
    echo ">> serviço ${name} já existe, atualizando"
    local update=(
      --region "$REGION" --cluster "$CLUSTER" --service "$name"
      --task-definition "$task_def"
    )
    [[ -n "$load_balancers" ]] && update+=(--load-balancers "$load_balancers")
    aws ecs update-service "${update[@]}" >/dev/null
    return
  fi
  local args=(
    --region "$REGION" --cluster "$CLUSTER" --service-name "$name"
    --task-definition "$task_def" --desired-count "$desired"
    --capacity-provider-strategy "capacityProvider=${CAPACITY_PROVIDER},weight=1,base=0"
    --placement-strategy "$PLACEMENT"
    --deployment-configuration "$DEPLOY_CONF"
    --tags "key=Project,value=${PROJECT}" "key=Environment,value=${ENVIRONMENT}"
  )
  if [[ -n "$load_balancers" ]]; then
    args+=(--load-balancers "$load_balancers")
    # Grace period: o ALB só começa a julgar a task depois de ela ter tido
    # tempo de subir, senão o primeiro health check derrubaria toda task nova.
    args+=(--health-check-grace-period-seconds 60)
  fi
  aws ecs create-service "${args[@]}" >/dev/null
  echo ">> serviço ${name} criado (desired=${desired})"
}

create_service "${PREFIX}-backend-api" "$TD_BACKEND" 2 \
  "[$(lb_json "$TG_BACKEND" app 8000),$(lb_json "$TG_BACKEND_INTERNAL" app 8000)]"
create_service "${PREFIX}-chatbot"  "$TD_CHATBOT"  2 \
  "[$(lb_json "$TG_CHATBOT" app 8000)]"
create_service "${PREFIX}-frontend" "$TD_FRONTEND" 2 \
  "[$(lb_json "$TG_FRONTEND" app 8080)]"
create_service "${PREFIX}-order-worker" "$TD_WORKER" 1

for service in "${SERVICES[@]}"; do
  remember "SERVICE_${service//-/_}" "${PREFIX}-${service}"
done

echo ">> serviços criados. O primeiro deploy leva ~2 min."
echo ">> em seguida: scripts/ohio/96-autoscaling.sh"
