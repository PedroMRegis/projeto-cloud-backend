# projeto-cloud-backend

Backend da **Cirro Livros**, a livraria conversacional do projeto semestral de
Computação em Nuvem (Insper). Dono do catálogo, do estoque, das cotações e dos
pedidos.

Faz parte de três repositórios:

| Repositório | Serviço ECS | Responsabilidade |
|---|---|---|
| **projeto-cloud-backend** (este) | `backend-api`, `order-worker` | Catálogo, cotação, pedido, confirmação assíncrona |
| [projeto-cloud-chatbot](https://github.com/PedroMRegis/projeto-cloud-chatbot) | `chatbot` | Vendedor conversacional (LLM + modo guiado) |
| [projeto-cloud-frontend](https://github.com/PedroMRegis/projeto-cloud-frontend) | `frontend` | Loja em React |
| [projeto-cloud-insper](https://github.com/joselsm3/projeto-cloud-insper) | — | Plano, infraestrutura, docs e o compose da plataforma inteira |

## Arquitetura

```
           ALB  /api/*  ─────────────► backend-api (FastAPI) ──┐
 chatbot ── HTTP (Service Connect) ──►      │                  │ mesma transação:
                                            ▼                  │ pedido + itens +
                                  RDS PostgreSQL + pgvector ◄──┘ histórico + outbox
                                            │
                     relay do outbox ───────┤ publicação imediata (best-effort)
                                            ▼
                                     SQS orders-queue ──(3 falhas)──► orders-dlq
                                            │
                                            ▼
                                     order-worker ── UPDATE estoque WHERE stock >= q
                                                     + PENDING → CONFIRMED/REJECTED
```

**Por que dois serviços:** a `backend-api` é síncrona e escala por requisições;
o `order-worker` é assíncrono, escala por backlog da fila e pode cair sem que a
loja pare de vender (os pedidos esperam na fila).

## Dados (PostgreSQL + pgvector)

O catálogo vive **no banco**. Ele nasce de uma migration de carga inicial
(`app/migrations/0002_seed_catalog.sql`), que roda uma única vez em banco vazio, e
depois só muda pela API admin. A aplicação nunca lê arquivo de dados.

| Tabela | Para quê |
|---|---|
| `products` | Livro: título, autor, categoria, chamada, **sinopse**, ano, preço, estoque, `embedding vector(1024)`, `search_tsv` (full-text em português) |
| `stock_movements` | Livro-razão do estoque: toda mudança (carga, ajuste admin, pedido) com autor. Invariante `stock = Σ delta` |
| `quotes`, `quote_items` | Cotação com preço do servidor e desconto limitado pela política, TTL de 30 min |
| `orders`, `order_items`, `order_history` | Pedido (`order_id = quote_id`, no máximo um por cotação) e sua linha do tempo |
| `outbox` | Evento `OrderPlaced`, gravado na mesma transação do pedido |

As migrations são aplicadas pela própria API no start, sob `pg_advisory_lock`
(N tasks subindo juntas não disputam o schema).

### Busca

`GET /api/products?q=...` combina dois rankings com *Reciprocal Rank Fusion*:

- **textual**: full-text em português, sem acento, com peso maior em título e autor e OR entre os termos (frases da conversa não zeram o resultado);
- **semântica**: pgvector com embeddings do Titan Text v2 no Bedrock (`amazon.titan-embed-text-v2:0`, 1024 dimensões), gerados a partir de título, autor, categoria, chamada e sinopse. Acha "um livro sobre vigilância" sem palavra em comum.

A busca semântica é opcional (`EMBEDDINGS_PROVIDER=bedrock`, com `bedrock:InvokeModel`
na task role). `python -m app.cli embed` gera os vetores que faltam. Com o Bedrock
fora (timeout de 4 s e circuit breaker), a busca segue só textual.

## API

| Rota | O que faz |
|---|---|
| `GET /health` | Vivo? Sem I/O (usado pelo ALB) |
| `GET /ready` | Banco acessível? (diagnóstico, cache de 10 s) |
| `GET /api/products?q=&category=&sort=&limit=&offset=` | Busca híbrida (com `q`) ou listagem paginada |
| `GET /api/products/{id}?related=4` | Livro com sinopse e relacionados |
| `GET /api/products/{id}/availability?quantity=` | Estoque atual |
| `GET /api/categories` | Categorias com contagem |
| `POST /api/quotes` | Cotação. **O preço vem do banco**; o cliente só pede desconto |
| `POST /api/orders` | Pedido a partir da cotação. 201 = criado; 200 = já existia (idempotente) |
| `GET /api/orders/{id}?conversation_id=` | Status e histórico (nome mascarado) |
| `POST /api/admin/products`, `PATCH /api/admin/products/{id}`, `POST /api/admin/products/{id}/stock`, `POST /api/admin/embeddings/backfill` | Manutenção do catálogo, com header `X-Admin-Token`. Bloqueado no ALB |

Documentação interativa em `/api/docs`.

## Garantias do processamento de pedidos

- **Sem pedido sem evento:** pedido e evento do outbox são gravados na mesma transação. Se o SQS estiver fora, o relay do worker publica depois.
- **Sem débito duplo:** o worker trava o pedido com `SELECT ... FOR UPDATE`. Uma mensagem repetida encontra o pedido fora de PENDING e é descartada como duplicata. O índice único em `stock_movements` é a segunda barreira.
- **Tudo ou nada:** se faltar estoque de qualquer item, um SAVEPOINT desfaz os débitos já feitos e o pedido vira `REJECTED`.
- **Sem deadlock:** os itens são debitados sempre na ordem do `product_id`.
- **Falha transitória não perde mensagem:** ela volta à fila e, no 3º recebimento, vai para a DLQ. Mensagem malformada também vai para a DLQ.
- **Pedido preso:** o sweeper (um worker por vez, via advisory lock) reenfileira pedidos PENDING antigos.

`scripts/check_consistency.py` verifica essas invariantes num banco real (evidência para a rubrica 1/A).

## Rodando

```bash
docker compose up -d --build        # Postgres + ElasticMQ + API + worker
# API em http://localhost:8001/api/docs
```

Para a plataforma inteira (frontend + chatbot + backend), use o compose do
repositório `projeto-cloud-insper`.

### Testes

Os testes usam um **Postgres de verdade** (o do compose), porque o que se testa
é SQL específico do Postgres: `FOR UPDATE`, `SKIP LOCKED`, savepoint, full-text e
pgvector. O SQS é simulado com moto.

```bash
python -m venv .venv && .venv/Scripts/pip install -r requirements-dev.txt   # Windows
docker compose up -d postgres
.venv/Scripts/python -m pytest      # 89 testes
.venv/Scripts/python -m ruff check .
```

## Configuração

| Variável | Padrão | Na AWS |
|---|---|---|
| `DATABASE_URL` ou `DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`/`DB_PASSWORD`/`DB_SSLMODE` | local | Host do RDS; usuário e senha vêm do segredo gerenciado pelo RDS no Secrets Manager (`secrets.valueFrom`); `DB_SSLMODE=require` |
| `ORDERS_QUEUE_URL` | resolve por `ORDERS_QUEUE_NAME` | injetada |
| `EMBEDDINGS_PROVIDER` | `none` | `bedrock`, com a permissão na task role |
| `ADMIN_TOKEN` | vazio (admin desligado) | SecureString no Parameter Store |
| `FAULTS_PARAMETER` | vazio | `/convcommerce/<env>/faults` (injeção de falhas nas demos) |
| `MIGRATE_ON_START` | `true` | `true` na API, `false` no worker |

Nenhum segredo tem valor padrão, e nenhum vai para o código, para a imagem ou para o Terraform.

## Imagens

Uma imagem por serviço, a partir do mesmo `Dockerfile`:

```bash
docker build --target api    -t backend-api .
docker build --target worker -t order-worker .
```

As duas são multi-stage e rodam como usuário não-root, com health check.
