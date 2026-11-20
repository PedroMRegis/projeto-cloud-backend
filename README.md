# projeto-cloud-backend

Backend da **Cirro Livros**, a livraria conversacional do projeto semestral de
Computação em Nuvem (Insper). Dono do catálogo, do estoque, das cotações, dos
pedidos e das contas de cliente e de administrador.

Faz parte de quatro repositórios:

| Repositório | Serviço ECS | Responsabilidade |
|---|---|---|
| **projeto-cloud-backend** (este) | `backend-api`, `order-worker` | Catálogo, contas, cotação, pedido, confirmação assíncrona. Tem também os scripts da etapa manual em Ohio |
| [projeto-cloud-chatbot](https://github.com/PedroMRegis/projeto-cloud-chatbot) | `chatbot` | Vendedor conversacional (LLM + modo guiado) |
| [projeto-cloud-frontend](https://github.com/PedroMRegis/projeto-cloud-frontend) | `frontend` | Loja em React |
| [projeto-cloud-terraform](https://github.com/TheoRibeiroFranca/projeto-cloud-terraform) | — | Infraestrutura de São Paulo (`sa-east-1`) em Terraform |

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
| `users` | Conta: e-mail único, nome, hash da senha, papel (`customer` ou `admin`) |
| `stock_movements` | Livro-razão do estoque: toda mudança (carga, ajuste admin, pedido) com autor. Invariante `stock = Σ delta` |
| `quotes`, `quote_items` | Cotação com preço do servidor e desconto limitado pela política, TTL de 30 min |
| `orders`, `order_items`, `order_history` | Pedido (`order_id = quote_id`, no máximo um por cotação), a conta que o fez (`user_id`) e sua linha do tempo |
| `outbox` | Evento `OrderPlaced`, gravado na mesma transação do pedido |

As migrations são aplicadas pela própria API no start, sob `pg_advisory_lock`
(N tasks subindo juntas não disputam o schema).

### Busca

`GET /api/products?q=...` combina dois rankings com *Reciprocal Rank Fusion*:

- **por palavra-chave**: pontuação no próprio SQL, sem acento, com peso 4 em título e autor, 2 em categoria e 1 em chamada e sinopse. O termo casa por prefixo ou pelo radical em português ("aneis" acha "Anéis"), e termo sem resultado tenta a correção de digitação por distância de edição (`fuzzystrmatch`, "tolkein" acha Tolkien). Frases da conversa não zeram o resultado;
- **semântica**: pgvector com embeddings do Titan Text v2 no Bedrock (`amazon.titan-embed-text-v2:0`, 1024 dimensões), gerados a partir de título, autor, categoria, chamada e sinopse. Acha "um livro sobre vigilância" sem palavra em comum.

A busca semântica é opcional (`EMBEDDINGS_PROVIDER=bedrock`, com `bedrock:InvokeModel`
na task role). `python -m app.cli embed` gera os vetores que faltam. Com o Bedrock
fora (timeout de 4 s e circuit breaker), a busca segue só por palavra-chave.

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
| `GET /api/quotes/{id}` | Cotação já criada |
| `POST /api/orders` | Pedido a partir da cotação. **Exige login**, e o nome vem da conta. 201 = criado; 200 = já existia (idempotente) |
| `GET /api/orders/{id}?conversation_id=` | Status e histórico (nome mascarado). O dono logado vê o pedido de qualquer conversa |
| `POST /api/auth/register`, `POST /api/auth/login` | Cria a conta ou entra. Devolve o cookie de sessão. Limite de 10 por minuto por IP |
| `POST /api/auth/logout`, `GET /api/auth/me` | Sai / conta da sessão atual |
| `GET /api/me/orders` | Pedidos da conta logada |
| `GET /api/backoffice/stock`, `GET /api/backoffice/orders?status=` | Gestão, só para `role = admin`. Somente leitura |
| `POST /api/admin/products`, `PATCH /api/admin/products/{id}`, `POST /api/admin/products/{id}/stock`, `POST /api/admin/embeddings/backfill` | Manutenção do catálogo, com header `X-Admin-Token`. Bloqueado no ALB |

Documentação interativa em `/api/docs`.

### Contas e sessão

A sessão é um JWT assinado com `AUTH_JWT_SECRET`, válido por 12 h. O navegador o
recebe no cookie `cirro_session` (HttpOnly, SameSite=Lax), e o chatbot o repassa
ao backend em `Authorization: Bearer`. As senhas são guardadas só como hash argon2id. Os
middlewares ficam em `app/middlewares/` (autenticação, papel e rate limit), e
cada rota de conta segue o padrão `use_case` + `dto` + `index` em `app/use_cases/`.

As rotas de gestão ficam em `/api/backoffice`, e não em `/api/admin`, porque o
ALB bloqueia `/api/admin*` vindo da internet. Para promover uma conta a
administrador:

```bash
python -m app.cli set-role --email <email> --role admin
```

Os outros comandos do CLI são `migrate` (aplica as migrations) e `embed` (gera
os embeddings que faltam).

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

Para a plataforma inteira em local, suba também o compose do
[chatbot](https://github.com/PedroMRegis/projeto-cloud-chatbot) (porta 8002) e rode
o [frontend](https://github.com/PedroMRegis/projeto-cloud-frontend) com
`npm run dev`, cujo proxy faz o papel do ALB.

### Testes

Os testes usam um **Postgres de verdade** (o do compose), porque o que se testa
é SQL específico do Postgres: `FOR UPDATE`, `SKIP LOCKED`, savepoint, full-text e
pgvector. O SQS é simulado com moto.

```bash
python -m venv .venv && .venv/Scripts/pip install -r requirements-dev.txt   # Windows
docker compose up -d postgres
.venv/Scripts/python -m pytest      # 139 testes
.venv/Scripts/python -m ruff check .
```

## Configuração

| Variável | Padrão | Na AWS |
|---|---|---|
| `DATABASE_URL` ou `DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`/`DB_PASSWORD`/`DB_SSLMODE` | local | Host do RDS; usuário e senha vêm do segredo gerenciado pelo RDS no Secrets Manager (`secrets.valueFrom`); `DB_SSLMODE=require` |
| `DB_SECRET_ARN` | vazio | ARN do segredo do RDS. Com ele, a senha é relida sozinha depois da rotação automática, sem novo deploy (a task role precisa de `secretsmanager:GetSecretValue` nesse segredo) |
| `ORDERS_QUEUE_URL` | resolve por `ORDERS_QUEUE_NAME` | injetada |
| `AUTH_JWT_SECRET` | vazio | SecureString no Parameter Store |
| `AUTH_SESSION_HOURS` | `12` | Validade da sessão |
| `AUTH_COOKIE_SECURE` | `true` | `false` enquanto o site estiver só em HTTP |
| `EMBEDDINGS_PROVIDER` | `none` | `bedrock`, com a permissão na task role |
| `ADMIN_TOKEN` | vazio (admin desligado) | SecureString no Parameter Store |
| `FAULTS_PARAMETER` | vazio | `/convcommerce/<env>/faults` (injeção de falhas nas demos) |
| `MIGRATE_ON_START` | `true` | `true` na API, `false` no worker |

Nenhum segredo tem valor padrão, e nenhum vai para o código ou para a imagem. Em
São Paulo, o Terraform gera o `AUTH_JWT_SECRET` e o `ADMIN_TOKEN` como valores
efêmeros, gravados direto no Parameter Store, sem passar pelo state.

## Imagens

Uma imagem por serviço, a partir do mesmo `Dockerfile`:

```bash
docker build --target api    -t backend-api .
docker build --target worker -t order-worker .
```

As duas são multi-stage e rodam como usuário não-root, com health check.

## Ohio (etapa manual)

O ambiente de Ohio (`us-east-2`) foi criado à mão, com AWS CLI. Os scripts que o
criaram e o operam estão em [`scripts/ohio/`](scripts/ohio/README.md), e o
inventário dos recursos está em [`docs/recursos-ohio.md`](docs/recursos-ohio.md).
São Paulo (`sa-east-1`) é criado só pelo
[projeto-cloud-terraform](https://github.com/TheoRibeiroFranca/projeto-cloud-terraform),
que constrói as imagens a partir deste repositório.
