#!/usr/bin/env bash
# Configuração compartilhada pelos scripts da etapa manual (Ohio).
#
# Etapa 1 do enunciado: tudo é criado manualmente, só com console e AWS CLI.
# Scripts de AWS CLI são permitidos — não são ferramenta de infraestrutura como
# código: cada comando é a mesma chamada que o console faria, e nenhum deles
# mantém estado, plano ou reconciliação. Eles existem para que cada recurso
# criado fique registrado e auditável em `docs/recursos-ohio.md`.
#
# Carregue com `source scripts/ohio/00-config.sh` antes dos demais.

set -euo pipefail

export AWS_PAGER=""

# No Git Bash, o MSYS reescreve argumentos que parecem caminho POSIX antes de
# entregá-los a um .exe nativo: um nome de parâmetro SSM como
# `/convcommerce/prod/faults` chegaria no aws.exe como `C:/Program Files/Git/...`.
#
# A desativação é **só** para o aws: ligá-la globalmente quebraria o git, que
# depende da conversão para receber caminhos do working tree. Em Linux e macOS
# a variável não tem efeito e a função é um passa-adiante.
aws() {
  MSYS_NO_PATHCONV=1 command aws "$@"
}
export -f aws

# ------------------------------------------------------------------ identidade

export REGION="${REGION:-us-east-2}"
export ENVIRONMENT="${ENVIRONMENT:-prod}"
export PROJECT="convcommerce"
# Prefixo de todo recurso nomeável: facilita achar e apagar tudo depois.
export PREFIX="${PROJECT}-${ENVIRONMENT}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ACCOUNT_ID
export REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ---------------------------------------------------------------------- rede

# Mesma faixa usada em São Paulo pelo Terraform: as duas regiões são
# ambientes independentes, sem peering entre elas.
export VPC_CIDR="10.10.0.0/16"
export PUBLIC_CIDRS=("10.10.0.0/24" "10.10.1.0/24")
export PRIVATE_CIDRS=("10.10.10.0/24" "10.10.11.0/24")
# Uma subnet pública e uma privada por AZ, em 2 AZs (exigência do enunciado).
export AZ_COUNT=2

# ------------------------------------------------------------------ capacidade

export INSTANCE_TYPE="t3.small"   # 2 vCPU, 2 GiB: comporta agente + ~6 tasks
export ASG_MIN=2                  # uma instância por AZ
export ASG_MAX=6                  # pico de ~7.200 unidades de CPU com o chatbot em 512
export ASG_DESIRED=3
export TARGET_CAPACITY=90         # ~10% de folga para absorver picos

# ---------------------------------------------------------------------- dados

# Catálogo, estoque, pedidos e contas ficam no RDS Postgres (35-rds.sh). No
# DynamoDB sobra só a tabela de conversas do chatbot.
export TABLE_PREFIX="${PREFIX}-"
export TABLES=(conversations)
export DB_INSTANCE="${PREFIX}"
export DB_NAME="convcommerce"
export ORDERS_QUEUE="${PREFIX}-orders-queue"
export ORDERS_DLQ="${PREFIX}-orders-dlq"

# ------------------------------------------------------------------- serviços

# Os quatro serviços ECS e os repositórios ECR correspondentes.
export SERVICES=(backend-api order-worker chatbot frontend)

# ------------------------------------------------------------------- segredos

export SSM_PREFIX="/${PROJECT}/${ENVIRONMENT}"

# ---------------------------------------------------------------- utilidades

# Guarda e lê os IDs dos recursos criados, para os scripts seguintes.
export STATE_FILE="${STATE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docs/evidencias/ohio/recursos.env}"
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

# shellcheck disable=SC1090
source "$STATE_FILE"

remember() {
  # remember NOME valor — grava no state e exporta na sessão atual.
  # O `\r` é removido porque no Git Bash a saída do aws.exe pode vir com CRLF,
  # e um ID com carriage return falha depois de um jeito difícil de enxergar.
  local name="$1" value="${2//$'\r'/}"
  sed -i.bak "/^export ${name}=/d" "$STATE_FILE" 2>/dev/null || true
  rm -f "${STATE_FILE}.bak"
  echo "export ${name}=\"${value}\"" >> "$STATE_FILE"
  export "${name}=${value}"
  echo ">> ${name}=${value}"
}

require() {
  # require NOME... — falha cedo se um script anterior não rodou.
  local missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  if (( ${#missing[@]} )); then
    echo "!! faltam recursos de etapas anteriores: ${missing[*]}" >&2
    echo "!! rode os scripts na ordem numérica" >&2
    return 1
  fi
}

tags() {
  # Tags padrão em todo recurso: o mesmo conjunto que o Terraform usará em
  # São Paulo, o que torna as duas regiões comparáveis.
  echo "Key=Project,Value=${PROJECT} Key=Environment,Value=${ENVIRONMENT} Key=ManagedBy,Value=aws-cli"
}

echo ">> conta=${ACCOUNT_ID} região=${REGION} env=${ENVIRONMENT}"
echo ">> state=${STATE_FILE}"
