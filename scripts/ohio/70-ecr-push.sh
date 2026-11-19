#!/usr/bin/env bash
# Repositórios ECR e publicação das imagens dos quatro serviços.
#
# Requisito do enunciado: "as imagens deverão ser armazenadas no Amazon ECR da
# respectiva região. A solução em São Paulo não poderá depender da execução de
# imagens diretamente a partir do ECR de Ohio. O grupo deverá definir como as
# imagens serão publicadas ou replicadas entre as regiões."
#
# Decisão: **build a partir do código-fonte em cada região**, sem replicação
# cross-region. Replicar a partir de Ohio faria São Paulo depender de Ohio, que
# é exatamente o que a rubrica 7/B proíbe. Com build a partir da fonte, as duas
# regiões são independentes e o mesmo script serve às duas.
#
# A tag é o hash do commit de cada repositório: a imagem é rastreável até o
# código que a gerou, e republicar sem mudança é barato (a tag já existe).
#
#   source scripts/ohio/00-config.sh && scripts/ohio/70-ecr-push.sh [serviço...]

source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

REPOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../repos" && pwd)"

# serviço → repositório git + target do Dockerfile
declare -A SOURCE_REPO=(
  [backend-api]=projeto-cloud-backend
  [order-worker]=projeto-cloud-backend
  [chatbot]=projeto-cloud-chatbot
  [frontend]=projeto-cloud-frontend
)
declare -A BUILD_TARGET=(
  [backend-api]=api
  [order-worker]=worker
  [chatbot]=""
  [frontend]=""
)

WANTED=("$@")
(( ${#WANTED[@]} )) || WANTED=("${SERVICES[@]}")

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
echo ">> autenticado no ECR ${REGISTRY}"

for service in "${WANTED[@]}"; do
  repository="${PROJECT}/${service}"
  source_dir="${REPOS_DIR}/${SOURCE_REPO[$service]}"

  if [[ ! -d "$source_dir" ]]; then
    echo "!! ${source_dir} não existe — clone os repositórios em repos/" >&2
    exit 1
  fi

  # Scan on push é gratuito no nível básico e dá a varredura de CVE das
  # imagens sem nenhuma infraestrutura extra.
  aws ecr describe-repositories --region "$REGION" --repository-names "$repository" \
    >/dev/null 2>&1 || \
  aws ecr create-repository --region "$REGION" --repository-name "$repository" \
    --image-scanning-configuration scanOnPush=true \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" \
    >/dev/null

  tag="$(git -C "$source_dir" rev-parse --short=12 HEAD)"
  # Árvore suja gera uma tag distinta: uma imagem publicada nunca corresponde
  # a um commit que não existe.
  git -C "$source_dir" diff --quiet HEAD 2>/dev/null || tag="${tag}-dirty-$(date +%H%M%S)"
  image="${REGISTRY}/${repository}:${tag}"

  if aws ecr describe-images --region "$REGION" --repository-name "$repository" \
       --image-ids "imageTag=${tag}" >/dev/null 2>&1; then
    echo ">> ${repository}:${tag} já publicada"
  else
    echo ">> build ${repository}:${tag}"
    build_args=(--platform linux/amd64 -t "$image")
    [[ -n "${BUILD_TARGET[$service]}" ]] && build_args+=(--target "${BUILD_TARGET[$service]}")
    docker build "${build_args[@]}" "$source_dir"
    docker push "$image"
  fi

  remember "IMAGE_${service//-/_}" "$image"
done

echo ">> imagens publicadas"
