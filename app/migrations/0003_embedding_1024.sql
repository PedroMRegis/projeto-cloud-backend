-- Embeddings do Titan Text v2, que aceita 256, 512 ou 1024 dimensões (e não 768).
-- Os vetores antigos não servem para o modelo novo, então voltam a NULL e são
-- gerados de novo por `python -m app.cli embed`.

DROP INDEX products_embedding_idx;

UPDATE products SET embedding = NULL, embedding_model = NULL;

ALTER TABLE products ALTER COLUMN embedding TYPE vector(1024);

CREATE INDEX products_embedding_idx ON products USING hnsw (embedding vector_cosine_ops);
