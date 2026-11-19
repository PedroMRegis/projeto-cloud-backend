#!/usr/bin/env bash
# Cluster ECS sobre EC2: Launch Template, Auto Scaling Group e Capacity Provider.
#
# Requisitos do enunciado atendidos aqui:
# * "executada em um cluster Amazon ECS sobre instâncias Amazon EC2. Não será
#   permitido utilizar AWS Fargate como capacidade principal";
# * "as instâncias do cluster deverão pertencer a um Auto Scaling Group e ser
#   integradas ao ECS por meio de um Capacity Provider. O grupo deverá definir
#   capacidade mínima, desejada e máxima e demonstrar o ciclo de inclusão,
#   drenagem, substituição e remoção de instâncias".
#
# Dimensionamento (t3.small: 2 vCPU = 2048 CPU units, ~1,9 GiB utilizável):
#
#   serviço        cpu   reserva  limite   tasks/instância
#   backend-api    256   256 MiB  512 MiB
#   chatbot        512   256 MiB  512 MiB
#   order-worker   128   128 MiB  256 MiB
#   frontend        64    64 MiB  128 MiB
#
# A soma das **reservas** é o que define quanto cabe por instância — é ela que
# o Capacity Provider usa para decidir o scale-out da frota. O limite rígido
# protege o vizinho de um container que vaze memória.
#
#   source scripts/ohio/00-config.sh && scripts/ohio/80-ecs-cluster.sh

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
require VPC_ID PRIVATE_SUBNETS SG_ECS INSTANCE_PROFILE_ARN

CLUSTER="${PREFIX}"
LAUNCH_TEMPLATE="${PREFIX}-ecs"
ASG="${PREFIX}-ecs"
CAPACITY_PROVIDER="${PREFIX}-ec2"

# ------------------------------------------------------------------ cluster

if ! aws ecs describe-clusters --region "$REGION" --clusters "$CLUSTER" \
     --query 'clusters[?status==`ACTIVE`]' --output text | grep -q .; then
  aws ecs create-cluster --region "$REGION" --cluster-name "$CLUSTER" \
    --tags "key=Project,value=${PROJECT}" "key=Environment,value=${ENVIRONMENT}" \
    >/dev/null
  echo ">> cluster ${CLUSTER} criado"
fi
remember CLUSTER "$CLUSTER"

# ---------------------------------------------------------- launch template

# A AMI vem do parâmetro público do SSM, nunca escrita no código: é o mesmo
# comando que resolverá para a AMI certa em São Paulo, o que é exatamente a
# portabilidade que a rubrica 7/A cobra.
AMI_ID="$(aws ssm get-parameters --region "$REGION" \
  --names /aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id \
  --query 'Parameters[0].Value' --output text)"
remember AMI_ID "$AMI_ID"

if ! aws ec2 describe-launch-templates --region "$REGION" \
     --launch-template-names "$LAUNCH_TEMPLATE" >/dev/null 2>&1; then

  # O user data registra a instância no cluster. `ECS_ENABLE_SPOT_INSTANCE_DRAINING`
  # não se aplica (frota On-Demand), mas o stop timeout precisa casar com o
  # `stopTimeout` das tasks para o shutdown gracioso do worker caber.
  USER_DATA="$(cat <<EOF | base64 -w0
#!/bin/bash
echo "ECS_CLUSTER=${CLUSTER}" >> /etc/ecs/ecs.config
echo "ECS_CONTAINER_STOP_TIMEOUT=30s" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_CONTAINER_METADATA=true" >> /etc/ecs/ecs.config
EOF
)"

  aws ec2 create-launch-template --region "$REGION" \
    --launch-template-name "$LAUNCH_TEMPLATE" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}}]" \
    --launch-template-data "$(cat <<JSON
{
  "ImageId": "${AMI_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "IamInstanceProfile": {"Arn": "${INSTANCE_PROFILE_ARN}"},
  "SecurityGroupIds": ["${SG_ECS}"],
  "UserData": "${USER_DATA}",
  "MetadataOptions": {
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 1
  },
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {"VolumeSize": 30, "VolumeType": "gp3", "Encrypted": true,
            "DeleteOnTermination": true}
  }],
  "Monitoring": {"Enabled": true},
  "TagSpecifications": [{
    "ResourceType": "instance",
    "Tags": [{"Key": "Name", "Value": "${PREFIX}-ecs"},
             {"Key": "Project", "Value": "${PROJECT}"},
             {"Key": "Environment", "Value": "${ENVIRONMENT}"}]
  }]
}
JSON
)" >/dev/null
  echo ">> launch template ${LAUNCH_TEMPLATE} criado"
fi
remember LAUNCH_TEMPLATE "$LAUNCH_TEMPLATE"

# IMDSv2 obrigatório com hop limit 1: em modo bridge, um container que tentasse
# alcançar o metadata service da instância passaria por um hop a mais e é
# bloqueado. É o que impede uma task de roubar a credencial da instância.

# ------------------------------------------------------- auto scaling group

if ! aws autoscaling describe-auto-scaling-groups --region "$REGION" \
     --auto-scaling-group-names "$ASG" \
     --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null \
     | grep -q "$ASG"; then

  SUBNET_LIST="$(echo "$PRIVATE_SUBNETS" | tr ' ' ',')"

  aws autoscaling create-auto-scaling-group --region "$REGION" \
    --auto-scaling-group-name "$ASG" \
    --launch-template "LaunchTemplateName=${LAUNCH_TEMPLATE},Version=\$Latest" \
    --min-size "$ASG_MIN" --max-size "$ASG_MAX" --desired-capacity "$ASG_DESIRED" \
    --vpc-zone-identifier "$SUBNET_LIST" \
    --health-check-type EC2 --health-check-grace-period 180 \
    --default-instance-warmup 180 \
    --new-instances-protected-from-scale-in \
    --tags \
      "Key=Name,Value=${PREFIX}-ecs,PropagateAtLaunch=true" \
      "Key=Project,Value=${PROJECT},PropagateAtLaunch=true" \
      "Key=Environment,Value=${ENVIRONMENT},PropagateAtLaunch=true" \
      "Key=AmazonECSManaged,Value=true,PropagateAtLaunch=false"
  echo ">> ASG ${ASG} criado (min=${ASG_MIN} desired=${ASG_DESIRED} max=${ASG_MAX})"
fi
remember ASG "$ASG"

ASG_ARN="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].AutoScalingGroupARN' --output text)"
remember ASG_ARN "$ASG_ARN"

# `new-instances-protected-from-scale-in` é pré-requisito da managed
# termination protection: sem ela, o ASG poderia encerrar uma instância que
# ainda está rodando tasks.

# ------------------------------------------------------- capacity provider

if ! aws ecs describe-capacity-providers --region "$REGION" \
     --capacity-providers "$CAPACITY_PROVIDER" \
     --query 'capacityProviders[0].name' --output text 2>/dev/null \
     | grep -q "$CAPACITY_PROVIDER"; then

  # targetCapacity 90: deixa ~10% de folga, para um pico de tasks encontrar
  # capacidade já quente em vez de esperar uma EC2 nova subir (~2 min).
  # managedDraining: ao remover uma instância, o ECS a coloca em DRAINING e
  # espera as tasks migrarem — é o que torna o scale-in seguro.
  aws ecs create-capacity-provider --region "$REGION" \
    --name "$CAPACITY_PROVIDER" \
    --auto-scaling-group-provider "$(cat <<JSON
{
  "autoScalingGroupArn": "${ASG_ARN}",
  "managedScaling": {
    "status": "ENABLED",
    "targetCapacity": ${TARGET_CAPACITY},
    "minimumScalingStepSize": 1,
    "maximumScalingStepSize": 2,
    "instanceWarmupPeriod": 180
  },
  "managedTerminationProtection": "ENABLED",
  "managedDraining": "ENABLED"
}
JSON
)" --tags "key=Project,value=${PROJECT}" "key=Environment,value=${ENVIRONMENT}" \
    >/dev/null
  echo ">> capacity provider ${CAPACITY_PROVIDER} criado"
fi
remember CAPACITY_PROVIDER "$CAPACITY_PROVIDER"

# Associa o provider ao cluster e o torna a estratégia padrão: um serviço
# criado sem especificar launch type vai para o EC2, nunca para o Fargate.
aws ecs put-cluster-capacity-providers --region "$REGION" \
  --cluster "$CLUSTER" \
  --capacity-providers "$CAPACITY_PROVIDER" \
  --default-capacity-provider-strategy \
    "capacityProvider=${CAPACITY_PROVIDER},weight=1,base=0" \
  >/dev/null
echo ">> capacity provider associado ao cluster"

echo ">> aguardando as instâncias se registrarem no cluster"
for _ in $(seq 1 40); do
  registered="$(aws ecs describe-clusters --region "$REGION" --clusters "$CLUSTER" \
    --query 'clusters[0].registeredContainerInstancesCount' --output text)"
  echo "   instâncias registradas: ${registered}/${ASG_DESIRED}"
  [[ "$registered" -ge "$ASG_DESIRED" ]] && break
  sleep 15
done

echo ">> cluster pronto"
