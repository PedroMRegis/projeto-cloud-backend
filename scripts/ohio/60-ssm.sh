#!/usr/bin/env bash
# Parâmetros no SSM Parameter Store.
#
# Requisito do enunciado: "segredos e credenciais deverão permanecer no AWS
# Secrets Manager ou Systems Manager Parameter Store. Não será permitido
# armazená-los no código, nas imagens ou nos arquivos Terraform".
#
# Parameter Store (e não Secrets Manager) porque o tier Standard é gratuito,
# enquanto o Secrets Manager cobra por segredo/mês. A exceção é a senha do RDS,
# que fica no Secrets Manager porque a AWS a troca sozinha (35-rds.sh).
#
# Os valores são gerados aqui, com openssl, e nunca passam pelo repositório nem
# pela linha de comando de quem roda o script. O modelo de IA é o Bedrock, que
# usa a role da task: não há chave de API de LLM para guardar.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/60-ssm.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

put_plain() {
  local name="$1" value="$2"
  if aws ssm get-parameter --region "$REGION" --name "$name" >/dev/null 2>&1; then
    echo ">> ${name} já existe, preservado"
    return
  fi
  aws ssm put-parameter --region "$REGION" --name "$name" \
    --type String --value "$value" --overwrite >/dev/null
  echo ">> ${name} gravado"
}

put_generated() {
  # Gera o valor só na primeira vez: trocar o segredo de sessão desloga todo
  # mundo, e trocar o token de admin quebra quem o usa.
  local name="$1" bytes="$2"
  if aws ssm get-parameter --region "$REGION" --name "$name" >/dev/null 2>&1; then
    echo ">> ${name} já existe, preservado"
    return
  fi
  aws ssm put-parameter --region "$REGION" --name "$name" \
    --type SecureString --value "$(openssl rand -hex "$bytes")" >/dev/null
  echo ">> ${name} gerado"
}

# Token do admin do catálogo e segredo que assina o JWT da sessão de login
# (backend e chatbot usam o mesmo, para validar o cookie nos dois).
put_generated "${SSM_PREFIX}/admin_token" 24
put_generated "${SSM_PREFIX}/auth_jwt_secret" 32

# Injeção de falhas: começa desligada. É alterada nas demos com um
# `put-parameter --overwrite`, sem redeploy, e as apps releem a cada 15 s.
put_plain "${SSM_PREFIX}/faults" \
  '{"llm_error_rate":0,"llm_delay_ms":0,"worker_error_rate":0,"worker_delay_ms":0,"db_error_rate":0}'

echo ">> parâmetros prontos"
