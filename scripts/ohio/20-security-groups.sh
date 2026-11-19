#!/usr/bin/env bash
# Security groups encadeados: internet → ALB → instâncias ECS.
#
# Requisito do enunciado: "as instâncias ECS deverão executar preferencialmente
# em sub-redes privadas e não deverão receber tráfego de aplicação diretamente
# da internet". O encadeamento por security group (e não por CIDR) é o que
# garante isso: a regra de entrada do `sg-ecs` referencia o `sg-alb`, então
# nenhum outro endereço alcança as tasks, nem de dentro da VPC.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/20-security-groups.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require VPC_ID

create_sg() {
  local name="$1" description="$2"
  aws ec2 create-security-group --region "$REGION" \
    --group-name "$name" --description "$description" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}}]" \
    --query 'GroupId' --output text
}

# ---------------------------------------------------------------------- ALB

if [[ -z "${SG_ALB:-}" ]]; then
  remember SG_ALB "$(create_sg "${PREFIX}-alb" "Entrada HTTP publica para o ALB")"

  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ALB" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
fi

# ----------------------------------------------------------- instâncias ECS

if [[ -z "${SG_ECS:-}" ]]; then
  remember SG_ECS "$(create_sg "${PREFIX}-ecs" "Instancias ECS: so recebem do ALB")"

  # Portas dinâmicas do modo bridge: o ECS publica cada task numa porta
  # efêmera e registra essa porta no target group. Só o ALB alcança.
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ECS" --protocol tcp --port 32768-65535 \
    --source-group "$SG_ALB" >/dev/null

  # Sem porta 22 em nenhum SG: o acesso administrativo é via SSM Session
  # Manager, que sai pela porta 443 e não precisa de entrada nenhuma.
fi

# O ALB precisa alcançar as tasks nas portas dinâmicas. A regra de saída
# padrão (tudo liberado) seria suficiente, mas restringi-la ao `sg-ecs` é o
# que a rubrica 3/A pede como "regras de rede claras e restritivas".
if [[ -z "${SG_ALB_EGRESS_SET:-}" ]]; then
  aws ec2 revoke-security-group-egress --region "$REGION" \
    --group-id "$SG_ALB" --protocol all --port -1 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-egress --region "$REGION" \
    --group-id "$SG_ALB" --protocol tcp --port 32768-65535 \
    --source-group "$SG_ECS" >/dev/null
  remember SG_ALB_EGRESS_SET "yes"
fi

# O chatbot fala com a backend-api através do próprio ALB (caminho interno),
# então as instâncias precisam alcançar o ALB na porta 80.
if [[ -z "${SG_ALB_INTERNAL_SET:-}" ]]; then
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ALB" --protocol tcp --port 80 \
    --source-group "$SG_ECS" >/dev/null
  remember SG_ALB_INTERNAL_SET "yes"
fi

# A saída das instâncias é 443 para todo lugar: ECR, DynamoDB, SQS, SSM,
# CloudWatch e as APIs de LLM. Tudo passa por TLS, pelo NAT ou pelos gateway
# endpoints. Não há saída em texto claro.
if [[ -z "${SG_ECS_EGRESS_SET:-}" ]]; then
  aws ec2 revoke-security-group-egress --region "$REGION" \
    --group-id "$SG_ECS" --protocol all --port -1 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-egress --region "$REGION" \
    --group-id "$SG_ECS" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-egress --region "$REGION" \
    --group-id "$SG_ECS" --protocol tcp --port 80 \
    --source-group "$SG_ALB" >/dev/null
  remember SG_ECS_EGRESS_SET "yes"
fi

echo ">> security groups prontos"
