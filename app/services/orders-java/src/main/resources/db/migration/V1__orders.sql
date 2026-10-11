-- Orders and their line items. Flyway runs this once per database and records
-- it in flyway_schema_history; later changes go in V2__..., V3__... files.
CREATE TABLE orders (
    id          VARCHAR(40)  PRIMARY KEY,
    user_id     VARCHAR(100) NOT NULL,
    total_cents BIGINT       NOT NULL CHECK (total_cents >= 0),
    currency    VARCHAR(3)   NOT NULL,
    status      VARCHAR(30)  NOT NULL,
    payment_id  VARCHAR(40),
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE INDEX orders_user_created_idx ON orders (user_id, created_at DESC);

CREATE TABLE order_items (
    order_id         VARCHAR(40)  NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    position         INTEGER      NOT NULL,
    product_id       VARCHAR(40)  NOT NULL,
    name             VARCHAR(200) NOT NULL,
    quantity         INTEGER      NOT NULL CHECK (quantity > 0),
    unit_price_cents BIGINT       NOT NULL,
    line_total_cents BIGINT       NOT NULL,
    PRIMARY KEY (order_id, position)
);
