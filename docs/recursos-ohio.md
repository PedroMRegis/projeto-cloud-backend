# Recursos criados em Ohio (us-east-2) — etapa manual

Gerado por `scripts/ohio/99-inventario.sh` em 2026-10-29 17:18 UTC.
Conta `108791993403`, região `us-east-2`, ambiente `prod`.

Todos os recursos levam o prefixo `convcommerce-prod` e as tags
`Project=convcommerce` e `Environment=prod`.

## Rede

| Recurso | ID | Detalhe |
|---|---|---|
| VPC | `vpc-06bad157abe7820ca` | 10.10.0.0/16 |
| Subnet convcommerce-prod-public-us-east-2b | `subnet-060ef2ad77bd97088` | 10.10.1.0/24� us-east-2b |
| Subnet convcommerce-prod-private-us-east-2b | `subnet-0ff3a1528a53a1cae` | 10.10.11.0/24� us-east-2b |
| Subnet convcommerce-prod-private-us-east-2a | `subnet-0018a76ddb9fdfbfa` | 10.10.10.0/24� us-east-2a |
| Subnet convcommerce-prod-public-us-east-2a | `subnet-012fd379744aba68c` | 10.10.0.0/24� us-east-2a |
| Internet Gateway | `igw-0a2412bcbe7ec830e` | rota 0.0.0.0/0 da RT pública |
| NAT Gateway | `nat-0668bfcc8671a0945` | saída das subnets privadas (AZ-a) |
| Route table pública | `rtb-03c7b8860b89cd951` | → IGW |
| Route table privada | `rtb-02b01397a692026f8` | → NAT |
| VPC Endpoint DynamoDB | `vpce-0cdb59b5de1a5613d` | gateway, gratuito |
| VPC Endpoint S3 | `vpce-03c14a6611170f993` | gateway (camadas do ECR) |

## Security groups

| Grupo | ID | Entrada | Saída |
|---|---|---|---|
| `convcommerce-prod-alb` | `sg-0dec18aefb956c2b7` | 80 de 0.0.0.0/0 | 32768-65535 para sg-ecs |
| `convcommerce-prod-alb-internal` | `sg-0ee7a9cc6fbfb5ea7` | 80 de sg-ecs | 32768-65535 para sg-ecs |
| `convcommerce-prod-ecs` | `sg-08c2685f302f03667` | 32768-65535 dos dois ALBs | 443 para 0.0.0.0/0; 80 para o ALB interno |

Sem porta 22 em nenhum grupo: o acesso administrativo é por SSM Session Manager.

## Dados (DynamoDB, on-demand)

| Tabela | Chaves | Extras |
|---|---|---|
| `convcommerce-prod-products` | PK product_id | GSI `gsi_category`, PITR |
| `convcommerce-prod-stock_movements` | PK product_id, SK sk | livro-razão, PITR |
| `convcommerce-prod-quotes` | PK quote_id | TTL em `ttl` |
| `convcommerce-prod-orders` | PK order_id | Stream NEW_IMAGE, GSI esparso `gsi_pending`, PITR |
| `convcommerce-prod-conversations` | PK conversation_id, SK sk | TTL em `expires_at` |

## Mensageria

| Recurso | Nome | Configuração |
|---|---|---|
| Fila | `convcommerce-prod-orders-queue` | visibility 60 s, long polling 20 s, redrive em 3 tentativas |
| DLQ | `convcommerce-prod-orders-dlq` | retenção de 14 dias |
| DLQ do Pipe | `convcommerce-prod-pipe-dlq` | retenção de 14 dias |
| EventBridge Pipe | `convcommerce-prod-orders-outbox` | stream de orders → fila; filtro INSERT + PENDING |

## IAM (uma role por responsabilidade)

| Role | Para quê | Permissões principais |
|---|---|---|
| `convcommerce-prod-ecs-instance` | registrar a instância no cluster | ECS agent + SSM Session Manager |
| `convcommerce-prod-task-execution` | ECS puxar imagem e resolver segredos | ECR, logs, `ssm:GetParameters` em /convcommerce/prod/* |
| `convcommerce-prod-backend-api` | aplicação | lê catálogo, grava cotação, **cria** pedido |
| `convcommerce-prod-order-worker` | aplicação | consome a fila, debita estoque, **confirma** pedido |
| `convcommerce-prod-chatbot` | aplicação | só a tabela `conversations` |
| `convcommerce-prod-frontend` | aplicação | só logs |
| `convcommerce-prod-pipe` | EventBridge Pipe | lê o stream, publica na fila |

A fronteira entre `backend-api` e `order-worker` é deliberada: o caminho
síncrono **não tem** permissão para debitar estoque nem confirmar pedido.

## Computação

| Recurso | Nome/ID | Configuração |
|---|---|---|
| Cluster ECS | `convcommerce-prod` | Container Insights ligado |
| Launch Template | `convcommerce-prod-ecs` | t3.small, AMI `ami-0467722b0cf22c8f8` (via SSM), IMDSv2 hop 1, EBS gp3 cifrado |
| Auto Scaling Group | `convcommerce-prod-ecs` | min 2 · desired 2 · max 4, 2 AZs |
| Capacity Provider | `convcommerce-prod-ec2` | managed scaling (alvo 90%), termination protection e draining |

### Instâncias agora

```
i-0988824d0fae6f5fa	t3.small	us-east-2b	10.10.11.128
i-06a168b811786ccdc	t3.small	us-east-2b	10.10.11.120
i-088c037282eeedf92	t3.small	us-east-2a	10.10.10.99
```

## Balanceamento

| Recurso | Endereço |
|---|---|
| ALB público | `convcommerce-prod-alb-516489552.us-east-2.elb.amazonaws.com` |
| ALB interno | `internal-convcommerce-prod-internal-536102756.us-east-2.elb.amazonaws.com` |

Regras do listener público, na ordem de avaliação:

| Prioridade | Caminho | Destino |
|---|---|---|
| 10 | `/api/admin*` | 403 fixo (bloqueado na borda) |
| 20 | `/api/chat*`, `/api/conversations*` | chatbot |
| 30 | `/api/*` | backend-api |
| padrão | `/*` | frontend |

## Serviços ECS

| Serviço | Tasks | cpu / reserva / limite | Escala por |
|---|---|---|---|
| `backend-api` | min 2, max 8 | 256 / 256 MiB / 512 MiB | requisições por alvo + CPU |
| `chatbot` | min 2, max 8 | 256 / 256 MiB / 512 MiB | requisições por alvo + CPU |
| `order-worker` | min 1, max 6 | 128 / 128 MiB / 256 MiB | `BacklogPerTask` (metric math) |
| `frontend` | 2 fixo | 64 / 64 MiB / 128 MiB | não escala |

### Estado atual

```
convcommerce-prod-backend-api	2	2
convcommerce-prod-chatbot	2	2
convcommerce-prod-frontend	2	2
convcommerce-prod-order-worker	1	1
```

## Imagens (ECR)

| Repositório | Tag |
|---|---|
| `convcommerce/backend-api` | `0cdf207dcfc5` |
| `convcommerce/order-worker` | `0cdf207dcfc5` |
| `convcommerce/chatbot` | `e4ea3f3fb100` |
| `convcommerce/frontend` | `bfabf850aa02` |

A tag é o hash do commit que originou a imagem. Scan on push ativo.

## Observabilidade

| Log group | Retenção |
|---|---|
| `/convcommerce/prod/backend-api` | 14 dias |
| `/convcommerce/prod/order-worker` | 14 dias |
| `/convcommerce/prod/chatbot` | 14 dias |
| `/convcommerce/prod/frontend` | 14 dias |

Métricas de negócio em EMF, namespace `ConvCommerce`.

## Segredos (SSM Parameter Store)

| Parâmetro | Tipo |
|---|---|
| `/convcommerce/prod/llm/gemini_api_key` | SecureString |
| `/convcommerce/prod/llm/groq_api_key` | SecureString |
| `/convcommerce/prod/admin_token` | SecureString |
| `/convcommerce/prod/faults` | String (injeção de falhas das demos) |

Nenhum valor aparece no código, nas imagens ou neste documento.
