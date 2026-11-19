#!/usr/bin/env bash
# Parâmetros no SSM Parameter Store.
#
# Requisito do enunciado: "segredos e credenciais deverão permanecer no AWS
# Secrets Manager ou Systems Manager Parameter Store. Não será permitido
# armazená-los no código, nas imagens ou nos arquivos Terraform".
#
# Parameter Store (e não Secrets Manager) porque o tier Standard é gratuito,
# enquanto o Secrets Manager cobra por segredo/mês. As chaves são gravadas
# **por este script**, a partir do ambiente local — nunca pelo Terraform, que
# gravaria o valor no state. O Terraform só monta o ARN por nome.
#
#   export GEMINI_API_KEY=...   # opcional
#   export GROQ_API_KEY=...     # opcional
#   source scripts/ohio/00-config.sh && scripts/ohio/60-ssm.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

put_secure() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    if aws ssm get-parameter --region "$REGION" --name "$name" >/dev/null 2>&1; then
      echo ">> ${name} já existe, preservado"
    else
      # O chatbot trata chave vazia como provedor indisponível e cai no modo
      # guiado, então o parâmetro precisa existir mesmo sem valor: a task
      # execution role falha ao subir o container se o parâmetro não existir.
      aws ssm put-parameter --region "$REGION" --name "$name" \
        --type SecureString --value "sem-chave" --overwrite >/dev/null
      echo ">> ${name} criado vazio (modo guiado/mock)"
    fi
    return
  fi
  aws ssm put-parameter --region "$REGION" --name "$name" \
    --type SecureString --value "$value" --overwrite >/dev/null
  echo ">> ${name} gravado"
}

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

put_secure "${SSM_PREFIX}/llm/gemini_api_key" "${GEMINI_API_KEY:-}"
put_secure "${SSM_PREFIX}/llm/groq_api_key" "${GROQ_API_KEY:-}"

# Token do admin do catálogo: gerado aqui, nunca escrito no repositório.
if ! aws ssm get-parameter --region "$REGION" --name "${SSM_PREFIX}/admin_token" >/dev/null 2>&1; then
  aws ssm put-parameter --region "$REGION" --name "${SSM_PREFIX}/admin_token" \
    --type SecureString --value "$(openssl rand -hex 24)" --overwrite >/dev/null
  echo ">> ${SSM_PREFIX}/admin_token gerado"
else
  echo ">> ${SSM_PREFIX}/admin_token já existe, preservado"
fi

# Injeção de falhas: começa desligada. É alterada nas demos com um
# `put-parameter --overwrite`, sem redeploy, e as apps releem a cada 15 s.
put_plain "${SSM_PREFIX}/faults" \
  '{"llm_error_rate":0,"llm_delay_ms":0,"worker_error_rate":0,"worker_delay_ms":0,"db_error_rate":0}'

echo ">> parâmetros prontos"
