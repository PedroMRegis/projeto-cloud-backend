#!/usr/bin/env bash
# Application Load Balancer, target groups e regras de roteamento.
#
# Requisito do enunciado: "o acesso externo deverá ocorrer por meio de um
# Application Load Balancer. As instâncias ECS deverão executar
# preferencialmente em sub-redes privadas e não deverão receber tráfego de
# aplicação diretamente da internet".
#
# Roteamento (a ordem das regras importa — a mais específica primeiro):
#
#   /api/chat*, /api/conversations*  → chatbot      (conversa)
#   /api/admin*                      → 403          (bloqueado na borda)
#   /api/*                           → backend-api  (catálogo, cotação, pedido)
#   /*                               → frontend     (a loja, regra padrão)
#
# O `order-worker` não aparece aqui de propósito: ele não tem porta HTTP e seu
# trabalho chega pela fila. É a diferença de perfil que justifica a separação
# dos dois serviços ECS.
#
# Os target groups são do tipo `instance` porque as tasks rodam em modo bridge
# com porta dinâmica: o ECS registra a porta efêmera de cada task no grupo.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/90-alb.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require VPC_ID PUBLIC_SUBNETS SG_ALB

ALB_NAME="${PREFIX}-alb"

# --------------------------------------------------------------------- ALB

ALB_ARN="$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || true)"

if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
  ALB_ARN="$(aws elbv2 create-load-balancer --region "$REGION" \
    --name "$ALB_NAME" --type application --scheme internet-facing \
    --subnets $PUBLIC_SUBNETS --security-groups "$SG_ALB" \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  echo ">> ALB criado, aguardando ficar ativo"
  aws elbv2 wait load-balancer-available --region "$REGION" --load-balancer-arns "$ALB_ARN"
fi
remember ALB_ARN "$ALB_ARN"

ALB_DNS="$(aws elbv2 describe-load-balancers --region "$REGION" \
  --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"
remember ALB_DNS "$ALB_DNS"

# Deregistration delay de 30 s: tempo para a requisição em voo terminar antes
# de a task sair do grupo. É o que torna a troca de task invisível ao cliente.
create_tg() {
  local name="$1" port="$2" health_path="$3"
  local arn
  arn="$(aws elbv2 describe-target-groups --region "$REGION" --names "$name" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
  if [[ -n "$arn" && "$arn" != "None" ]]; then
    echo "$arn"
    return
  fi
  arn="$(aws elbv2 create-target-group --region "$REGION" \
    --name "$name" --protocol HTTP --port "$port" --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP --health-check-path "$health_path" \
    --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  aws elbv2 modify-target-group-attributes --region "$REGION" \
    --target-group-arn "$arn" \
    --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
  echo "$arn"
}

# `/health` não checa dependências de propósito: se checasse, uma instabilidade
# do DynamoDB marcaria todas as tasks como unhealthy ao mesmo tempo e o ALB
# tiraria o serviço inteiro do ar. O diagnóstico fica em `/ready`.
remember TG_BACKEND  "$(create_tg "${PREFIX}-backend"  8000 /health)"
remember TG_CHATBOT  "$(create_tg "${PREFIX}-chatbot"  8000 /health)"
remember TG_FRONTEND "$(create_tg "${PREFIX}-frontend" 8080 /health)"

# ----------------------------------------------------------------- listener

LISTENER_ARN="$(aws elbv2 describe-listeners --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" --query 'Listeners[0].ListenerArn' \
  --output text 2>/dev/null || true)"

if [[ -z "$LISTENER_ARN" || "$LISTENER_ARN" == "None" ]]; then
  LISTENER_ARN="$(aws elbv2 create-listener --region "$REGION" \
    --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_FRONTEND}" \
    --query 'Listeners[0].ListenerArn' --output text)"
  echo ">> listener HTTP:80 criado"
fi
remember LISTENER_ARN "$LISTENER_ARN"

# ------------------------------------------------------------------ regras

rule_exists() {
  aws elbv2 describe-rules --region "$REGION" --listener-arn "$LISTENER_ARN" \
    --query "Rules[?Priority=='$1'].RuleArn" --output text | grep -q .
}

add_rule() {
  local priority="$1" conditions="$2" actions="$3"
  if rule_exists "$priority"; then
    echo ">> regra ${priority} já existe"
    return
  fi
  aws elbv2 create-rule --region "$REGION" --listener-arn "$LISTENER_ARN" \
    --priority "$priority" --conditions "$conditions" --actions "$actions" >/dev/null
  echo ">> regra ${priority} criada"
}

# O admin do catálogo é bloqueado na borda: mesmo com o token, ninguém de fora
# alcança `/api/admin/*`. Manutenção se faz de dentro da VPC.
add_rule 10 \
  '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/api/admin*"]}}]' \
  '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"403","ContentType":"application/json","MessageBody":"{\"detail\":\"admin indisponivel publicamente\"}"}}]'

add_rule 20 \
  '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/api/chat*","/api/conversations*"]}}]' \
  "[{\"Type\":\"forward\",\"TargetGroupArn\":\"${TG_CHATBOT}\"}]"

add_rule 30 \
  '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/api/*"]}}]' \
  "[{\"Type\":\"forward\",\"TargetGroupArn\":\"${TG_BACKEND}\"}]"

echo ">> ALB pronto: http://${ALB_DNS}"
