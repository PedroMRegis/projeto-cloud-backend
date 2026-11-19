#!/usr/bin/env bash
# Prova de ausência de dependências ocultas de Ohio (PLANO §9.2, demo 14).
#
# A rubrica 7/A+ pede "comprovar a ausência de dependências de Ohio". Este
# script falha se encontrar no código do Terraform qualquer identificador que
# só existe em uma região ou conta: região literal, AMI, IDs de VPC/subnet/SG,
# nomes de AZ e números de conta.
#
# Uso:  scripts/portability-check.sh [diretório]
# Saída esperada: salvar em docs/evidencias/portability-check.txt
set -uo pipefail

TARGET="${1:-infra}"
RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'

if [[ ! -d "$TARGET" ]]; then
  echo "${RED}diretório '$TARGET' não existe${RESET}" >&2
  exit 2
fi

# Padrões proibidos. Cada entrada é "rótulo|regex estendida".
PATTERNS=(
  "região de Ohio literal|us-east-2"
  "outras regiões literais|(us-east-1|us-west-[12]|eu-west-[123])"
  "ID de AMI fixo|ami-[0-9a-f]{8,}"
  "ID de subnet fixo|subnet-[0-9a-f]{8,}"
  "ID de VPC fixo|vpc-[0-9a-f]{8,}"
  "ID de security group fixo|sg-[0-9a-f]{8,}"
  "ID de instância fixo|i-[0-9a-f]{17}"
  "nome de AZ literal|\"(us|sa|eu|ap)-[a-z]+-[0-9][a-z]\""
  "número de conta AWS|[^0-9a-zA-Z_.-][0-9]{12}[^0-9a-zA-Z_.-]"
)

# A região de destino aparece legitimamente nos arquivos de ambiente (é o valor
# de uma variável, não um identificador embutido no código dos módulos).
EXCLUDES=(
  --include='*.tf'
  --include='*.tfvars'
  --exclude-dir='.terraform'
)

echo "Verificação de portabilidade — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Diretório: ${TARGET}"
echo

violacoes=0
for entry in "${PATTERNS[@]}"; do
  rotulo="${entry%%|*}"
  regex="${entry#*|}"

  # grep -n para citar a linha; o módulo `envs/` é verificado junto, porque nem
  # lá se aceita um ID de recurso fixo.
  if achados=$(grep -rnE "${EXCLUDES[@]}" -- "$regex" "$TARGET" 2>/dev/null \
                | grep -v '^\s*#' | grep -vE '^[^:]+:[0-9]+:\s*#'); then
    echo "${RED}FALHA${RESET} — ${rotulo}"
    while IFS= read -r linha; do
      echo "  ${DIM}${linha}${RESET}"
      violacoes=$((violacoes + 1))
    done <<< "$achados"
    echo
  else
    echo "${GREEN}OK${RESET}    — nenhum ${rotulo}"
  fi
done

echo
if (( violacoes > 0 )); then
  echo "${RED}${violacoes} violação(ões) de portabilidade encontradas.${RESET}"
  echo "Use data sources: aws_availability_zones, aws_region, aws_caller_identity,"
  echo "aws_ssm_parameter (AMI do ECS), aws_ec2_managed_prefix_list,"
  echo "aws_elb_service_account."
  exit 1
fi

echo "${GREEN}Nenhuma dependência regional embutida no código.${RESET}"
