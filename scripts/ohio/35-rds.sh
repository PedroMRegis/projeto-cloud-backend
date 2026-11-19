#!/usr/bin/env bash
# RDS Postgres: catálogo, estoque, pedidos, contas e os vetores da busca.
#
# Por que Postgres e não DynamoDB para a loja: pedido e estoque precisam de
# transação. O estoque é a soma dos movimentos do livro-razão, e o pedido só é
# confirmado se o débito acontecer; o evento do outbox é gravado na mesma
# transação do pedido. O pgvector guarda os embeddings da busca por significado.
#
# Decisões de custo, justificadas em docs/recursos-ohio.md e no documento de
# arquitetura: instância única (sem Multi-AZ) e db.t4g.micro.
#
# A senha é administrada pela AWS no Secrets Manager (--manage-master-user-password)
# e trocada a cada 7 dias. A aplicação lê o segredo ao subir e de novo quando o
# Postgres recusa a senha (app/adapters/db_credentials.py).
#
#   source scripts/ohio/00-config.sh && scripts/ohio/35-rds.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require VPC_ID PRIVATE_SUBNETS SG_ECS

# ------------------------------------------------------------ security group

# O banco só aceita 5432 vindo das instâncias do cluster, e as instâncias só
# saem para 5432 em direção ao banco.
if [[ -z "${SG_RDS:-}" ]]; then
  SG_RDS="$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
    --group-name "${PREFIX}-rds" --description "Postgres so a partir do ECS" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PREFIX}-rds},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}}]" \
    --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_RDS" \
    --protocol tcp --port 5432 --source-group "$SG_ECS" >/dev/null
  aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$SG_ECS" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${SG_RDS}}]" \
    >/dev/null 2>&1 || true
  remember SG_RDS "$SG_RDS"
fi

# --------------------------------------------------------------- subnet group

# Subnets privadas das duas zonas: o RDS exige duas zonas no subnet group mesmo
# sem Multi-AZ, e isso permite ligar o Multi-AZ depois sem mudar a rede.
if ! aws rds describe-db-subnet-groups --region "$REGION" \
     --db-subnet-group-name "$PREFIX" >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  aws rds create-db-subnet-group --region "$REGION" \
    --db-subnet-group-name "$PREFIX" \
    --db-subnet-group-description "Subnets privadas do projeto" \
    --subnet-ids $PRIVATE_SUBNETS \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null
  echo ">> subnet group ${PREFIX} criado"
fi

# ------------------------------------------------------------------ instância

if aws rds describe-db-instances --region "$REGION" \
     --db-instance-identifier "$DB_INSTANCE" >/dev/null 2>&1; then
  echo ">> banco ${DB_INSTANCE} já existe"
else
  # Backup de 7 dias e proteção contra exclusão não mudam a fatura (o backup é
  # gratuito até o tamanho do banco). Em Ohio o banco nasceu com 1 dia e sem
  # proteção, e foi ajustado em 19/11 com modify-db-instance.
  aws rds create-db-instance --region "$REGION" \
    --db-instance-identifier "$DB_INSTANCE" \
    --engine postgres --engine-version 16 \
    --db-instance-class db.t4g.micro \
    --allocated-storage 20 --storage-type gp3 --storage-encrypted \
    --db-name "$DB_NAME" --master-username "$DB_NAME" \
    --manage-master-user-password \
    --db-subnet-group-name "$PREFIX" \
    --vpc-security-group-ids "$SG_RDS" \
    --no-publicly-accessible --no-multi-az \
    --backup-retention-period 7 --deletion-protection \
    --auto-minor-version-upgrade \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null
  echo ">> banco ${DB_INSTANCE} em criação (leva ~10 min)"
fi

aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$DB_INSTANCE"

DB_HOST="$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
DB_SECRET_ARN="$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)"
remember DB_HOST "$DB_HOST"
remember DB_SECRET_ARN "$DB_SECRET_ARN"

# As tabelas e o catálogo nascem das migrations, aplicadas pelo backend-api ao
# subir (MIGRATE_ON_START=true). Os embeddings são gerados depois, por task
# avulsa: python -m app.cli embed.
echo ">> banco pronto em ${DB_HOST}"
echo ">> em seguida: scripts/ohio/40-iam.sh"
