#!/usr/bin/env bash
# Grava as chaves de LLM no SSM Parameter Store como SecureString.
#
# Por que isso é um script e não Terraform (PLANO §9.4): se o Terraform criasse
# o parâmetro, o **valor da chave entraria no state**. O Terraform apenas monta
# o ARN do parâmetro por nome e concede permissão de leitura à task execution
# role — ele nunca vê o segredo. Pelo mesmo motivo, `data "aws_ssm_parameter"`
# é proibido no código.
#
# Uso:
#   export GEMINI_API_KEY=...
#   export GROQ_API_KEY=...
#   scripts/set-secrets.sh sa-east-1 [env]
set -euo pipefail

REGION="${1:?uso: set-secrets.sh <região> [env]}"
ENVIRONMENT="${2:-prod}"
PREFIX="/convcommerce/${ENVIRONMENT}"

put_secure() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "!! ${name}: variável vazia, pulando" >&2
    return
  fi
  aws ssm put-parameter \
    --region "$REGION" \
    --name "$name" \
    --type SecureString \
    --value "$value" \
    --overwrite \
    --no-cli-pager >/dev/null
  echo ">> ${name} gravado"
}

put_plain() {
  local name="$1" value="$2"
  aws ssm put-parameter \
    --region "$REGION" \
    --name "$name" \
    --type String \
    --value "$value" \
    --overwrite \
    --no-cli-pager >/dev/null
  echo ">> ${name} gravado"
}

echo ">> região=${REGION} env=${ENVIRONMENT}"

put_secure "${PREFIX}/llm/gemini_api_key" "${GEMINI_API_KEY:-}"
put_secure "${PREFIX}/llm/groq_api_key" "${GROQ_API_KEY:-}"

# Injeção de falhas: começa desligada. É alterada nas demos 10 e 11 com
# `aws ssm put-parameter --overwrite`, sem redeploy.
if ! aws ssm get-parameter --region "$REGION" --name "${PREFIX}/faults" >/dev/null 2>&1; then
  put_plain "${PREFIX}/faults" \
    '{"llm_error_rate":0,"llm_delay_ms":0,"worker_error_rate":0,"worker_delay_ms":0,"dynamo_error_rate":0}'
else
  echo ">> ${PREFIX}/faults já existe, preservado"
fi

echo ">> concluído"
