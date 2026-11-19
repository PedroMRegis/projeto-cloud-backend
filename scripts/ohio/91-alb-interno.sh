#!/usr/bin/env bash
# ALB interno para a comunicação entre serviços (chatbot → backend-api).
#
# Por que um segundo load balancer:
#
# O ALB público é internet-facing, então seu DNS resolve para IPs públicos —
# inclusive quando consultado de dentro da VPC. Uma task em subnet privada que
# chamasse o backend por aquele endereço sairia pelo NAT, daria a volta pela
# internet e voltaria pela porta de entrada pública. Isso custa transferência
# no NAT, adiciona latência e, pior, tornaria impossível distinguir no security
# group o tráfego interno do externo: a regra teria de liberar a porta 80 para
# 0.0.0.0/0, abrindo a saída das instâncias para qualquer host da internet.
#
# O ALB interno resolve para IPs privados das subnets privadas. O tráfego entre
# serviços nunca deixa a VPC, e o security group pode continuar encadeado:
#
#   sg-ecs --(80)--> sg-alb-interno --(portas dinâmicas)--> sg-ecs
#
# O ALB público continua sendo a única porta de entrada externa, como o
# enunciado exige. Este aqui não é alcançável de fora: é `scheme internal`, em
# subnets sem rota para o IGW.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/91-alb-interno.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require VPC_ID PRIVATE_SUBNETS SG_ECS TG_BACKEND

ALB_NAME="${PREFIX}-internal"

# ------------------------------------------------- security group interno

if [[ -z "${SG_ALB_INTERNAL:-}" ]]; then
  SG_ALB_INTERNAL="$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${PREFIX}-alb-internal" \
    --description "ALB interno: so recebe das tasks" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PREFIX}-alb-internal},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}}]" \
    --query 'GroupId' --output text)"
  remember SG_ALB_INTERNAL "$SG_ALB_INTERNAL"

  # Entrada: só das instâncias ECS.
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ALB_INTERNAL" --protocol tcp --port 80 \
    --source-group "$SG_ECS" >/dev/null

  # Saída: só para as portas dinâmicas das tasks.
  aws ec2 revoke-security-group-egress --region "$REGION" \
    --group-id "$SG_ALB_INTERNAL" --protocol all --port -1 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-egress --region "$REGION" \
    --group-id "$SG_ALB_INTERNAL" --protocol tcp --port 32768-65535 \
    --source-group "$SG_ECS" >/dev/null
fi

# O outro lado da mesma conversa: sem esta regra o ALB interno alcança a
# instância, mas a instância recusa a conexão, e o health check do target
# group fica eternamente unhealthy.
if [[ -z "${SG_ECS_FROM_INTERNAL:-}" ]]; then
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ECS" --protocol tcp --port 32768-65535 \
    --source-group "$SG_ALB_INTERNAL" >/dev/null
  remember SG_ECS_FROM_INTERNAL "yes"
fi

# A saída das instâncias na porta 80 passa a apontar para o ALB interno, e não
# mais para o público: nenhuma task precisa de saída HTTP para a internet.
if [[ -z "${SG_ECS_INTERNAL_EGRESS:-}" ]]; then
  aws ec2 authorize-security-group-egress --region "$REGION" \
    --group-id "$SG_ECS" --protocol tcp --port 80 \
    --source-group "$SG_ALB_INTERNAL" >/dev/null
  # A regra antiga (porta 80 para o ALB público) deixa de ter uso.
  aws ec2 revoke-security-group-egress --region "$REGION" \
    --group-id "$SG_ECS" --protocol tcp --port 80 \
    --source-group "$SG_ALB" >/dev/null 2>&1 || true
  remember SG_ECS_INTERNAL_EGRESS "yes"
fi

# A entrada do ALB público vinda das tasks também deixa de ser necessária.
aws ec2 revoke-security-group-ingress --region "$REGION" \
  --group-id "$SG_ALB" --protocol tcp --port 80 \
  --source-group "$SG_ECS" >/dev/null 2>&1 || true

# ------------------------------------------------------------------- ALB

ALB_INTERNAL_ARN="$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || true)"

if [[ -z "$ALB_INTERNAL_ARN" || "$ALB_INTERNAL_ARN" == "None" ]]; then
  ALB_INTERNAL_ARN="$(aws elbv2 create-load-balancer --region "$REGION" \
    --name "$ALB_NAME" --type application --scheme internal \
    --subnets $PRIVATE_SUBNETS --security-groups "$SG_ALB_INTERNAL" \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  echo ">> ALB interno criado, aguardando ficar ativo"
  aws elbv2 wait load-balancer-available --region "$REGION" \
    --load-balancer-arns "$ALB_INTERNAL_ARN"
fi
remember ALB_INTERNAL_ARN "$ALB_INTERNAL_ARN"

ALB_INTERNAL_DNS="$(aws elbv2 describe-load-balancers --region "$REGION" \
  --load-balancer-arns "$ALB_INTERNAL_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)"
remember ALB_INTERNAL_DNS "$ALB_INTERNAL_DNS"

# Um target group próprio: um alvo não pode pertencer a dois load balancers.
# O health check é o mesmo `/health` do grupo público.
TG_BACKEND_INTERNAL="$(aws elbv2 describe-target-groups --region "$REGION" \
  --names "${PREFIX}-backend-int" --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || true)"

if [[ -z "$TG_BACKEND_INTERNAL" || "$TG_BACKEND_INTERNAL" == "None" ]]; then
  TG_BACKEND_INTERNAL="$(aws elbv2 create-target-group --region "$REGION" \
    --name "${PREFIX}-backend-int" --protocol HTTP --port 8000 --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP --health-check-path /health \
    --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  aws elbv2 modify-target-group-attributes --region "$REGION" \
    --target-group-arn "$TG_BACKEND_INTERNAL" \
    --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
fi
remember TG_BACKEND_INTERNAL "$TG_BACKEND_INTERNAL"

# Listener único: tudo que chega aqui é para o backend. O chatbot é o único
# cliente, e ele só chama rotas de catálogo, cotação e pedido.
if ! aws elbv2 describe-listeners --region "$REGION" \
     --load-balancer-arn "$ALB_INTERNAL_ARN" \
     --query 'Listeners[0].ListenerArn' --output text 2>/dev/null | grep -q arn; then
  aws elbv2 create-listener --region "$REGION" \
    --load-balancer-arn "$ALB_INTERNAL_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_BACKEND_INTERNAL}" >/dev/null
  echo ">> listener interno criado"
fi

echo ">> ALB interno pronto: http://${ALB_INTERNAL_DNS}"
echo ">> rode 95-services.sh de novo para o backend registrar no grupo interno"
echo ">> e o chatbot passar a usar BACKEND_URL interno"
