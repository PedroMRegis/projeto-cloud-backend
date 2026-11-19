#!/usr/bin/env bash
# VPC própria, 2 AZs, subnets públicas e privadas, IGW, NAT e gateway endpoints.
#
# Requisito do enunciado: "VPC própria distribuída em pelo menos duas zonas de
# disponibilidade, com sub-redes públicas e privadas, tabelas de rotas e
# security groups adequados".
#
#   source scripts/ohio/00-config.sh && scripts/ohio/10-network.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

# ----------------------------------------------------------------------- VPC

if [[ -z "${VPC_ID:-}" ]]; then
  VPC_ID="$(aws ec2 create-vpc \
    --region "$REGION" --cidr-block "$VPC_CIDR" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PREFIX}-vpc},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}}]" \
    --query 'Vpc.VpcId' --output text)"
  remember VPC_ID "$VPC_ID"

  # DNS interno: necessário para os endpoints de interface e para o ECS
  # resolver os serviços da AWS pelo nome.
  aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support
  aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames
fi

# ------------------------------------------------------------------------ AZs

# Lidas da API, nunca escritas no código: é o que garante que o mesmo
# procedimento funcione em São Paulo (rubrica 7/A).
#
# O `tr -d '\r'` não é decoração: no Git Bash a saída do aws.exe vem com CRLF,
# e um `\r` grudado no nome da AZ faz o CreateSubnet rejeitar o valor com uma
# mensagem que parece idêntica à correta.
mapfile -t AZS < <(aws ec2 describe-availability-zones \
  --region "$REGION" --filters "Name=state,Values=available" \
  --query "AvailabilityZones[0:${AZ_COUNT}].ZoneName" --output text \
  | tr -d '\r' | tr '\t' '\n')
echo ">> AZs: ${AZS[*]}"

# -------------------------------------------------------------------- subnets

create_subnet() {
  local cidr="$1" az="$2" name="$3"
  aws ec2 create-subnet \
    --region "$REGION" --vpc-id "$VPC_ID" \
    --cidr-block "$cidr" --availability-zone "$az" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}}]" \
    --query 'Subnet.SubnetId' --output text
}

for i in $(seq 0 $((AZ_COUNT - 1))); do
  az="${AZS[$i]}"
  var="PUBLIC_SUBNET_${i}"
  if [[ -z "${!var:-}" ]]; then
    remember "$var" "$(create_subnet "${PUBLIC_CIDRS[$i]}" "$az" "${PREFIX}-public-${az}")"
  fi
  var="PRIVATE_SUBNET_${i}"
  if [[ -z "${!var:-}" ]]; then
    remember "$var" "$(create_subnet "${PRIVATE_CIDRS[$i]}" "$az" "${PREFIX}-private-${az}")"
  fi
done

PUBLIC_SUBNETS="${PUBLIC_SUBNET_0} ${PUBLIC_SUBNET_1}"
PRIVATE_SUBNETS="${PRIVATE_SUBNET_0} ${PRIVATE_SUBNET_1}"
remember PUBLIC_SUBNETS "$PUBLIC_SUBNETS"
remember PRIVATE_SUBNETS "$PRIVATE_SUBNETS"

# O ALB precisa de IP público nas subnets públicas; as instâncias ECS ficam
# nas privadas e nunca recebem IP público.
for subnet in $PUBLIC_SUBNETS; do
  aws ec2 modify-subnet-attribute --region "$REGION" \
    --subnet-id "$subnet" --map-public-ip-on-launch
done

# ------------------------------------------------------- internet e saída NAT

if [[ -z "${IGW_ID:-}" ]]; then
  IGW_ID="$(aws ec2 create-internet-gateway --region "$REGION" \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PREFIX}-igw}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)"
  aws ec2 attach-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  remember IGW_ID "$IGW_ID"
fi

# Um NAT Gateway só (AZ-a). É um ponto único de saída, aceito conscientemente:
# ~US$ 0,045/h é o maior custo fixo do projeto, e a alternativa (um por AZ)
# dobra esse custo. O trade-off está documentado em docs/rede.md.
if [[ -z "${NAT_ID:-}" ]]; then
  EIP_ALLOC="$(aws ec2 allocate-address --region "$REGION" --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PREFIX}-nat-eip}]" \
    --query 'AllocationId' --output text)"
  remember EIP_ALLOC "$EIP_ALLOC"

  NAT_ID="$(aws ec2 create-nat-gateway --region "$REGION" \
    --subnet-id "$PUBLIC_SUBNET_0" --allocation-id "$EIP_ALLOC" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PREFIX}-nat}]" \
    --query 'NatGateway.NatGatewayId' --output text)"
  remember NAT_ID "$NAT_ID"

  echo ">> aguardando o NAT ficar disponível (leva ~2 min)"
  aws ec2 wait nat-gateway-available --region "$REGION" --nat-gateway-ids "$NAT_ID"
fi

# -------------------------------------------------------------- route tables

if [[ -z "${PUBLIC_RT:-}" ]]; then
  PUBLIC_RT="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-public-rt}]" \
    --query 'RouteTable.RouteTableId' --output text)"
  aws ec2 create-route --region "$REGION" --route-table-id "$PUBLIC_RT" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  remember PUBLIC_RT "$PUBLIC_RT"
fi

if [[ -z "${PRIVATE_RT:-}" ]]; then
  PRIVATE_RT="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-private-rt}]" \
    --query 'RouteTable.RouteTableId' --output text)"
  aws ec2 create-route --region "$REGION" --route-table-id "$PRIVATE_RT" \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null
  remember PRIVATE_RT "$PRIVATE_RT"
fi

# A associação fica fora do bloco de criação: a route table pode já existir de
# uma execução anterior e a subnet, não. Sem subnet associada à RT privada, a
# task não teria rota de saída — e o sintoma seria um timeout no pull da imagem.
associate() {
  local rt="$1" subnet="$2"
  local current
  current="$(aws ec2 describe-route-tables --region "$REGION" --route-table-id "$rt" \
    --query "RouteTables[0].Associations[?SubnetId=='${subnet}'].RouteTableAssociationId" \
    --output text)"
  [[ -n "$current" ]] && return
  aws ec2 associate-route-table --region "$REGION" \
    --route-table-id "$rt" --subnet-id "$subnet" >/dev/null
  echo ">> ${subnet} associada a ${rt}"
}

for subnet in $PUBLIC_SUBNETS; do associate "$PUBLIC_RT" "$subnet"; done
for subnet in $PRIVATE_SUBNETS; do associate "$PRIVATE_RT" "$subnet"; done

# ------------------------------------------------------------ VPC endpoints

# Gateway endpoints são gratuitos e tiram o tráfego de DynamoDB e S3 do NAT
# (que cobra por GB). O S3 importa porque as camadas das imagens do ECR vêm
# de lá: sem o endpoint, todo pull de imagem passaria pelo NAT.
for service in dynamodb s3; do
  var="ENDPOINT_${service^^}"
  if [[ -z "${!var:-}" ]]; then
    remember "$var" "$(aws ec2 create-vpc-endpoint --region "$REGION" \
      --vpc-id "$VPC_ID" --vpc-endpoint-type Gateway \
      --service-name "com.amazonaws.${REGION}.${service}" \
      --route-table-ids "$PRIVATE_RT" \
      --query 'VpcEndpoint.VpcEndpointId' --output text)"
  fi
done

echo ">> rede pronta"
