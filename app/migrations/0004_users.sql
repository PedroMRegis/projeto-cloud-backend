-- Contas de cliente e de administrador. Pedidos novos exigem login (regra da API);
-- `orders.user_id` é NULL só nos pedidos anteriores às contas.

CREATE TABLE users (
    user_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email         text NOT NULL,
    name          text NOT NULL,
    password_hash text NOT NULL,
    role          text NOT NULL DEFAULT 'customer' CHECK (role IN ('customer', 'admin')),
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX users_email_uq ON users (lower(email));

ALTER TABLE orders ADD COLUMN user_id uuid REFERENCES users (user_id);

CREATE INDEX orders_user_idx ON orders (user_id, created_at DESC) WHERE user_id IS NOT NULL;
CREATE INDEX orders_created_idx ON orders (created_at DESC);
