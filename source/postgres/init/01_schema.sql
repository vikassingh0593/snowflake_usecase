-- Quick-commerce OLTP source. Money is INTEGER PAISE everywhere: never float,
-- never NUMERIC. It survives JSON, Kafka, VARIANT and Snowpark without a
-- rounding argument.

CREATE SCHEMA IF NOT EXISTS qc;
SET search_path = qc, public;

CREATE TABLE dark_stores (
  store_id      INT PRIMARY KEY,
  store_code    TEXT NOT NULL,
  city          TEXT NOT NULL,
  pincode       TEXT NOT NULL,
  lat           DOUBLE PRECISION NOT NULL,
  lon           DOUBLE PRECISION NOT NULL,
  opened_on     DATE NOT NULL,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE customers (
  customer_id   INT PRIMARY KEY,
  full_name     TEXT NOT NULL,
  email         TEXT NOT NULL,          -- the PII column the policies target
  phone         TEXT NOT NULL,
  segment       TEXT NOT NULL,          -- SCD2 attribute
  home_pincode  TEXT NOT NULL,          -- SCD2 attribute
  home_lat      DOUBLE PRECISION NOT NULL,
  home_lon      DOUBLE PRECISION NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL
);

CREATE TABLE products (
  product_id    INT PRIMARY KEY,
  sku           TEXT NOT NULL,
  name          TEXT NOT NULL,
  category_l1   TEXT NOT NULL,          -- feeds the recursive-CTE category tree
  category_l2   TEXT NOT NULL,
  category_l3   TEXT NOT NULL,
  price_paise   BIGINT NOT NULL,        -- SCD2 attribute
  is_active     BOOLEAN NOT NULL,       -- SCD2 attribute
  updated_at    TIMESTAMPTZ NOT NULL
);

CREATE TABLE riders (
  rider_id      INT PRIMARY KEY,
  full_name     TEXT NOT NULL,
  phone         TEXT NOT NULL,
  vehicle_type  TEXT NOT NULL,
  store_id      INT NOT NULL REFERENCES dark_stores(store_id),
  shift         TEXT NOT NULL,          -- SCD2 attribute
  is_active     BOOLEAN NOT NULL,
  joined_on     DATE NOT NULL
);

-- Store x product x day. Becomes FCT_INVENTORY_DAILY, the periodic snapshot.
CREATE TABLE inventory (
  snapshot_date DATE NOT NULL,
  store_id      INT  NOT NULL REFERENCES dark_stores(store_id),
  product_id    INT  NOT NULL REFERENCES products(product_id),
  on_hand_qty   INT  NOT NULL,
  reorder_level INT  NOT NULL,
  PRIMARY KEY (snapshot_date, store_id, product_id)
);

-- Becomes FCT_ORDER, the accumulating snapshot: milestones as columns.
CREATE TABLE orders (
  order_id           BIGINT PRIMARY KEY,
  customer_id        INT NOT NULL REFERENCES customers(customer_id),
  store_id           INT NOT NULL REFERENCES dark_stores(store_id),
  rider_id           INT REFERENCES riders(rider_id),
  placed_ts          TIMESTAMPTZ NOT NULL,
  promised_ts        TIMESTAMPTZ NOT NULL,
  packed_ts          TIMESTAMPTZ,
  picked_up_ts       TIMESTAMPTZ,
  delivered_ts       TIMESTAMPTZ,
  status             TEXT NOT NULL,
  payment_method     TEXT NOT NULL,
  coupon_code        TEXT,
  item_count         INT NOT NULL,
  gross_paise        BIGINT NOT NULL,
  discount_paise     BIGINT NOT NULL,
  delivery_fee_paise BIGINT NOT NULL,
  order_total_paise  BIGINT NOT NULL
);

CREATE TABLE order_items (
  order_item_id    BIGINT PRIMARY KEY,
  order_id         BIGINT NOT NULL REFERENCES orders(order_id),
  product_id       INT    NOT NULL REFERENCES products(product_id),
  qty              INT    NOT NULL,
  unit_price_paise BIGINT NOT NULL,
  line_total_paise BIGINT NOT NULL
);

CREATE INDEX ix_orders_placed  ON orders(placed_ts);
CREATE INDEX ix_orders_store   ON orders(store_id, placed_ts);
CREATE INDEX ix_items_order    ON order_items(order_id);

-- REPLICA IDENTITY FULL on every replicated table. Without it the WAL carries
-- no pre-image and SCD2 cannot tell which attribute changed. Set at creation,
-- not later -- you find out you forgot at the dbt snapshot stage.
ALTER TABLE dark_stores REPLICA IDENTITY FULL;
ALTER TABLE customers   REPLICA IDENTITY FULL;
ALTER TABLE products    REPLICA IDENTITY FULL;
ALTER TABLE riders      REPLICA IDENTITY FULL;
ALTER TABLE inventory   REPLICA IDENTITY FULL;
ALTER TABLE orders      REPLICA IDENTITY FULL;
ALTER TABLE order_items REPLICA IDENTITY FULL;

CREATE PUBLICATION qc_pub FOR TABLE
  dark_stores, customers, products, riders, inventory, orders, order_items;
