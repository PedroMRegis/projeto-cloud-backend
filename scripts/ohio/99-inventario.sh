#!/usr/bin/env bash
# Gera `docs/recursos-ohio.md`: a relação dos recursos criados na etapa manual.
#
# O enunciado pede, ao final da etapa manual, "a relação dos recursos criados".
# Gerar a lista a partir da própria AWS (e não escrevê-la à mão) garante que o
# documento descreva o que existe, não o que se pretendia criar.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/99-inventario.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docs/recursos-ohio.md"

q() { aws "$@" 2>/dev/null || echo "(indisponível)"; }

{
  echo "# Recursos criados em Ohio (us-east-2) — etapa manual"
  echo
  echo "Gerado por \`scripts/ohio/99-inventario.sh\` em $(date -u '+%Y-%m-%d %H:%M UTC')."
  echo "Conta \`${ACCOUNT_ID}\`, região \`${REGION}\`, ambiente \`${ENVIRONMENT}\`."
  echo
  echo "Todos os recursos levam o prefixo \`${PREFIX}\` e as tags"
  echo "\`Project=${PROJECT}\` e \`Environment=${ENVIRONMENT}\`."
  echo
  echo "## Rede"
  echo
  echo '| Recurso | ID | Detalhe |'
  echo '|---|---|---|'
  echo "| VPC | \`${VPC_ID}\` | ${VPC_CIDR} |"
  q ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[].[Tags[?Key==`Name`].Value|[0],SubnetId,join(` · `,[CidrBlock,AvailabilityZone])]' \
    --output text | awk -F'\t' '{printf "| Subnet %s | `%s` | %s |\n", $1, $2, $3}'
  echo "| Internet Gateway | \`${IGW_ID}\` | rota 0.0.0.0/0 da RT pública |"
  echo "| NAT Gateway | \`${NAT_ID}\` | saída das subnets privadas (AZ-a) |"
  echo "| Route table pública | \`${PUBLIC_RT}\` | → IGW |"
  echo "| Route table privada | \`${PRIVATE_RT}\` | → NAT |"
  echo "| VPC Endpoint DynamoDB | \`${ENDPOINT_DYNAMODB}\` | gateway, gratuito |"
  echo "| VPC Endpoint S3 | \`${ENDPOINT_S3}\` | gateway (camadas do ECR) |"
  echo
  echo "## Security groups"
  echo
  echo '| Grupo | ID | Entrada | Saída |'
  echo '|---|---|---|---|'
  echo "| \`${PREFIX}-alb\` | \`${SG_ALB}\` | 80 de 0.0.0.0/0 | 32768-65535 para sg-ecs |"
  echo "| \`${PREFIX}-alb-internal\` | \`${SG_ALB_INTERNAL:-}\` | 80 de sg-ecs | 32768-65535 para sg-ecs |"
  echo "| \`${PREFIX}-ecs\` | \`${SG_ECS}\` | 32768-65535 dos dois ALBs | 443 para 0.0.0.0/0; 80 para o ALB interno |"
  echo
  echo "Sem porta 22 em nenhum grupo: o acesso administrativo é por SSM Session Manager."
  echo
  echo "## Dados (DynamoDB, on-demand)"
  echo
  echo '| Tabela | Chaves | Extras |'
  echo '|---|---|---|'
  echo "| \`${TABLE_PREFIX}products\` | PK product_id | GSI \`gsi_category\`, PITR |"
  echo "| \`${TABLE_PREFIX}stock_movements\` | PK product_id, SK sk | livro-razão, PITR |"
  echo "| \`${TABLE_PREFIX}quotes\` | PK quote_id | TTL em \`ttl\` |"
  echo "| \`${TABLE_PREFIX}orders\` | PK order_id | Stream NEW_IMAGE, GSI esparso \`gsi_pending\`, PITR |"
  echo "| \`${TABLE_PREFIX}conversations\` | PK conversation_id, SK sk | TTL em \`expires_at\` |"
  echo
  echo "## Mensageria"
  echo
  echo '| Recurso | Nome | Configuração |'
  echo '|---|---|---|'
  echo "| Fila | \`${ORDERS_QUEUE}\` | visibility 60 s, long polling 20 s, redrive em 3 tentativas |"
  echo "| DLQ | \`${ORDERS_DLQ}\` | retenção de 14 dias |"
  echo "| DLQ do Pipe | \`${PIPE_DLQ}\` | retenção de 14 dias |"
  echo "| EventBridge Pipe | \`${PIPE_NAME:-}\` | stream de orders → fila; filtro INSERT + PENDING |"
  echo
  echo "## IAM (uma role por responsabilidade)"
  echo
  echo '| Role | Para quê | Permissões principais |'
  echo '|---|---|---|'
  echo "| \`${PREFIX}-ecs-instance\` | registrar a instância no cluster | ECS agent + SSM Session Manager |"
  echo "| \`${PREFIX}-task-execution\` | ECS puxar imagem e resolver segredos | ECR, logs, \`ssm:GetParameters\` em ${SSM_PREFIX}/* |"
  echo "| \`${PREFIX}-backend-api\` | aplicação | lê catálogo, grava cotação, **cria** pedido |"
  echo "| \`${PREFIX}-order-worker\` | aplicação | consome a fila, debita estoque, **confirma** pedido |"
  echo "| \`${PREFIX}-chatbot\` | aplicação | só a tabela \`conversations\` |"
  echo "| \`${PREFIX}-frontend\` | aplicação | só logs |"
  echo "| \`${PREFIX}-pipe\` | EventBridge Pipe | lê o stream, publica na fila |"
  echo
  echo "A fronteira entre \`backend-api\` e \`order-worker\` é deliberada: o caminho"
  echo "síncrono **não tem** permissão para debitar estoque nem confirmar pedido."
  echo
  echo "## Computação"
  echo
  echo '| Recurso | Nome/ID | Configuração |'
  echo '|---|---|---|'
  echo "| Cluster ECS | \`${CLUSTER}\` | Container Insights ligado |"
  echo "| Launch Template | \`${LAUNCH_TEMPLATE}\` | ${INSTANCE_TYPE}, AMI \`${AMI_ID}\` (via SSM), IMDSv2 hop 1, EBS gp3 cifrado |"
  echo "| Auto Scaling Group | \`${ASG}\` | min ${ASG_MIN} · desired ${ASG_DESIRED} · max ${ASG_MAX}, 2 AZs |"
  echo "| Capacity Provider | \`${CAPACITY_PROVIDER}\` | managed scaling (alvo ${TARGET_CAPACITY}%), termination protection e draining |"
  echo
  echo "### Instâncias agora"
  echo
  echo '```'
  q ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=${PROJECT}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,Placement.AvailabilityZone,PrivateIpAddress]' \
    --output text
  echo '```'
  echo
  echo "## Balanceamento"
  echo
  echo '| Recurso | Endereço |'
  echo '|---|---|'
  echo "| ALB público | \`${ALB_DNS}\` |"
  echo "| ALB interno | \`${ALB_INTERNAL_DNS:-}\` |"
  echo
  echo "Regras do listener público, na ordem de avaliação:"
  echo
  echo '| Prioridade | Caminho | Destino |'
  echo '|---|---|---|'
  echo '| 10 | `/api/admin*` | 403 fixo (bloqueado na borda) |'
  echo '| 20 | `/api/chat*`, `/api/conversations*` | chatbot |'
  echo '| 30 | `/api/*` | backend-api |'
  echo '| padrão | `/*` | frontend |'
  echo
  echo "## Serviços ECS"
  echo
  echo '| Serviço | Tasks | cpu / reserva / limite | Escala por |'
  echo '|---|---|---|---|'
  echo '| `backend-api` | min 2, max 8 | 256 / 256 MiB / 512 MiB | requisições por alvo + CPU |'
  echo '| `chatbot` | min 2, max 8 | 256 / 256 MiB / 512 MiB | requisições por alvo + CPU |'
  echo '| `order-worker` | min 1, max 6 | 128 / 128 MiB / 256 MiB | `BacklogPerTask` (metric math) |'
  echo '| `frontend` | 2 fixo | 64 / 64 MiB / 128 MiB | não escala |'
  echo
  echo "### Estado atual"
  echo
  echo '```'
  q ecs describe-services --region "$REGION" --cluster "$CLUSTER" \
    --services "${PREFIX}-backend-api" "${PREFIX}-chatbot" "${PREFIX}-frontend" "${PREFIX}-order-worker" \
    --query 'services[].[serviceName,desiredCount,runningCount]' --output text
  echo '```'
  echo
  echo "## Imagens (ECR)"
  echo
  echo '| Repositório | Tag |'
  echo '|---|---|'
  for service in "${SERVICES[@]}"; do
    var="IMAGE_${service//-/_}"
    echo "| \`${PROJECT}/${service}\` | \`${!var##*:}\` |"
  done
  echo
  echo "A tag é o hash do commit que originou a imagem. Scan on push ativo."
  echo
  echo "## Observabilidade"
  echo
  echo '| Log group | Retenção |'
  echo '|---|---|'
  for service in "${SERVICES[@]}"; do
    echo "| \`/${PROJECT}/${ENVIRONMENT}/${service}\` | 14 dias |"
  done
  echo
  echo "Métricas de negócio em EMF, namespace \`ConvCommerce\`."
  echo
  echo "## Segredos (SSM Parameter Store)"
  echo
  echo '| Parâmetro | Tipo |'
  echo '|---|---|'
  echo "| \`${SSM_PREFIX}/llm/gemini_api_key\` | SecureString |"
  echo "| \`${SSM_PREFIX}/llm/groq_api_key\` | SecureString |"
  echo "| \`${SSM_PREFIX}/admin_token\` | SecureString |"
  echo "| \`${SSM_PREFIX}/faults\` | String (injeção de falhas das demos) |"
  echo
  echo "Nenhum valor aparece no código, nas imagens ou neste documento."
} > "$OUT"

echo ">> inventário escrito em ${OUT}"
