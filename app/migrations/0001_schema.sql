-- Schema relacional do backend (ADR 0002: Postgres + pgvector para catálogo,
-- estoque e pedidos; conversas ficam no DynamoDB, com o chatbot).

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- unaccent() não é IMMUTABLE, então não pode entrar em coluna gerada nem em
-- índice. O wrapper fixa o dicionário e pode ser declarado IMMUTABLE.
CREATE OR REPLACE FUNCTION f_unaccent(text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS
$$ SELECT public.unaccent('public.unaccent'::regdictionary, $1) $$;

-- ------------------------------------------------------------------ catálogo

CREATE TABLE products (
    product_id      text PRIMARY KEY,
    title           text NOT NULL,
    author          text NOT NULL,
    category        text NOT NULL,
    tagline         text NOT NULL DEFAULT '',
    description     text NOT NULL DEFAULT '',
    original_year   integer,
    price_cents     integer NOT NULL CHECK (price_cents >= 0),
    -- O CHECK é a última barreira contra estoque negativo; a primeira é o
    -- `UPDATE ... WHERE stock >= q` do worker.
    stock           integer NOT NULL CHECK (stock >= 0),
    version         integer NOT NULL DEFAULT 1,
    -- Busca semântica (pgvector). NULL até o embedding ser gerado.
    embedding       vector(768),
    embedding_model text,
    -- Busca textual em português, sem acento, com peso maior para título e autor.
    search_tsv      tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('portuguese', f_unaccent(title)), 'A') ||
        setweight(to_tsvector('portuguese', f_unaccent(author)), 'A') ||
        setweight(to_tsvector('portuguese', f_unaccent(category)), 'B') ||
        setweight(to_tsvector('portuguese', f_unaccent(tagline || ' ' || description)), 'C')
    ) STORED,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX products_search_idx ON products USING gin (search_tsv);
CREATE INDEX products_category_idx ON products (category);
CREATE INDEX products_embedding_idx ON products USING hnsw (embedding vector_cosine_ops);

-- Livro-razão do estoque: toda alteração vira um movimento. Serve de
-- auditoria e sustenta a invariante `stock = Σ delta` (scripts/check_consistency.py).
CREATE TABLE stock_movements (
    id          bigserial PRIMARY KEY,
    product_id  text NOT NULL REFERENCES products (product_id),
    delta       integer NOT NULL,
    reason      text NOT NULL CHECK (reason IN ('seed', 'admin_adjust', 'order')),
    ref         text NOT NULL,
    actor       text NOT NULL DEFAULT 'system',
    at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX stock_movements_product_idx ON stock_movements (product_id, id);
-- Um pedido nunca debita o mesmo produto duas vezes, mesmo se um bug
-- reprocessar a mensagem: a segunda inserção viola o índice e a transação cai.
CREATE UNIQUE INDEX stock_movements_order_uq
    ON stock_movements (product_id, ref) WHERE reason = 'order';

-- ------------------------------------------------------------------ cotações

CREATE TABLE quotes (
    quote_id               uuid PRIMARY KEY,
    conversation_id        text NOT NULL,
    subtotal_cents         integer NOT NULL,
    requested_discount_pct integer NOT NULL DEFAULT 0,
    discount_pct           integer NOT NULL,
    discount_cents         integer NOT NULL,
    total_cents            integer NOT NULL,
    max_discount_pct       integer NOT NULL,
    expires_at             timestamptz NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX quotes_conversation_idx ON quotes (conversation_id, created_at DESC);

CREATE TABLE quote_items (
    quote_id         uuid NOT NULL REFERENCES quotes (quote_id) ON DELETE CASCADE,
    product_id       text NOT NULL REFERENCES products (product_id),
    quantity         integer NOT NULL CHECK (quantity BETWEEN 1 AND 10),
    unit_price_cents integer NOT NULL CHECK (unit_price_cents >= 0),
    PRIMARY KEY (quote_id, product_id)
);

-- ------------------------------------------------------------------- pedidos

-- order_id = quote_id: a chave primária garante no máximo um pedido por cotação.
CREATE TABLE orders (
    order_id        uuid PRIMARY KEY REFERENCES quotes (quote_id),
    conversation_id text NOT NULL,
    customer_name   text NOT NULL,
    status          text NOT NULL CHECK (status IN ('PENDING', 'CONFIRMED', 'REJECTED')),
    reason          text,
    subtotal_cents  integer NOT NULL,
    discount_pct    integer NOT NULL,
    total_cents     integer NOT NULL,
    correlation_id  text,
    traceparent     text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Índice parcial: só os PENDING, que é o que o sweeper procura.
CREATE INDEX orders_pending_idx ON orders (created_at) WHERE status = 'PENDING';
CREATE INDEX orders_conversation_idx ON orders (conversation_id, created_at DESC);

CREATE TABLE order_items (
    order_id         uuid NOT NULL REFERENCES orders (order_id) ON DELETE CASCADE,
    product_id       text NOT NULL REFERENCES products (product_id),
    quantity         integer NOT NULL CHECK (quantity BETWEEN 1 AND 10),
    unit_price_cents integer NOT NULL,
    PRIMARY KEY (order_id, product_id)
);

CREATE TABLE order_history (
    id       bigserial PRIMARY KEY,
    order_id uuid NOT NULL REFERENCES orders (order_id) ON DELETE CASCADE,
    status   text NOT NULL,
    reason   text,
    actor    text NOT NULL,
    at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX order_history_order_idx ON order_history (order_id, id);

-- -------------------------------------------------------------------- outbox

-- Transactional outbox: o evento é gravado na MESMA transação do pedido, então
-- não existe pedido sem evento nem evento sem pedido. A publicação no SQS é
-- feita depois (imediata pela API, com o relay do worker de rede de segurança).
CREATE TABLE outbox (
    id           bigserial PRIMARY KEY,
    aggregate_id text NOT NULL,
    event_type   text NOT NULL,
    payload      jsonb NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    attempts     integer NOT NULL DEFAULT 0,
    last_error   text
);

CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;
