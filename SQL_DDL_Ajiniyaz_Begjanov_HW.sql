/*
===============================================================================
 SQL DDL HW - physical database "E-commerce Marketplace"
 Author   : Ajiniyaz Begjanov
 DBMS     : PostgreSQL
 Database : ecommerce_marketplace
 Schema   : marketplace
===============================================================================
*/


/*------------------------------------------------------------------------------
 SECTION 0. Physical database (run once, connected to another database, in my case: "postgres")
------------------------------------------------------------------------------*/
CREATE DATABASE ecommerce_marketplace;

-- >>> Switch the connection to ecommerce_marketplace. Everything below is rerunnable. <<<


/*------------------------------------------------------------------------------
 SECTION 1. Schema and extension
------------------------------------------------------------------------------*/
CREATE SCHEMA IF NOT EXISTS marketplace;

-- Needed for the exclusion constraint on product_price_history (equality on an integer
-- column together with the range overlap operator in one GiST index).
CREATE EXTENSION IF NOT EXISTS btree_gist;


/*------------------------------------------------------------------------------
 SECTION 2. Tables (parents first, children after - see "DDL ORDER" above)
------------------------------------------------------------------------------*/

-- ===== Level 1: tables without foreign keys ==================================

CREATE TABLE IF NOT EXISTS marketplace.seller (
    seller_id     integer       GENERATED ALWAYS AS IDENTITY,
    seller_name   varchar(150)  NOT NULL,
    email         varchar(255)  NOT NULL,
    phone         varchar(20),
    registered_at timestamptz   NOT NULL DEFAULT now(),
    is_active     boolean       NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_seller PRIMARY KEY (seller_id),
    CONSTRAINT uq_seller_email UNIQUE (email),
    CONSTRAINT chk_seller_registered_at CHECK (registered_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

CREATE TABLE IF NOT EXISTS marketplace.buyer (
    buyer_id      integer       GENERATED ALWAYS AS IDENTITY,
    first_name    varchar(80)   NOT NULL,
    last_name     varchar(80)   NOT NULL,
    email         varchar(255)  NOT NULL,
    phone         varchar(20),
    registered_at timestamptz   NOT NULL DEFAULT now(),
    is_active     boolean       NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_buyer PRIMARY KEY (buyer_id),
    CONSTRAINT uq_buyer_email UNIQUE (email),
    CONSTRAINT chk_buyer_registered_at CHECK (registered_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

CREATE TABLE IF NOT EXISTS marketplace.category (
    category_id        integer       GENERATED ALWAYS AS IDENTITY,
    parent_category_id integer,
    category_name      varchar(100)  NOT NULL,
    description        text,
    CONSTRAINT pk_category PRIMARY KEY (category_id),
    CONSTRAINT fk_category_parent FOREIGN KEY (parent_category_id)
        REFERENCES marketplace.category (category_id) ON DELETE RESTRICT,
    CONSTRAINT uq_category_parent_name UNIQUE (parent_category_id, category_name),
    CONSTRAINT chk_category_not_own_parent CHECK (parent_category_id <> category_id)
);

CREATE TABLE IF NOT EXISTS marketplace.promotion (
    promotion_id   integer        GENERATED ALWAYS AS IDENTITY,
    promotion_name varchar(150)   NOT NULL,
    discount_type  varchar(10)    NOT NULL,
    discount_value numeric(10, 2) NOT NULL,
    start_at       timestamptz    NOT NULL,
    end_at         timestamptz    NOT NULL,
    CONSTRAINT pk_promotion PRIMARY KEY (promotion_id),
    CONSTRAINT chk_promotion_discount_type CHECK (discount_type IN ('PERCENT', 'FIXED')),
    CONSTRAINT chk_promotion_discount_value CHECK (discount_value > 0
                                                   AND (discount_type <> 'PERCENT' OR discount_value <= 100)),
    CONSTRAINT chk_promotion_period CHECK (end_at > start_at),
    CONSTRAINT chk_promotion_start_at CHECK (start_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

CREATE TABLE IF NOT EXISTS marketplace.order_status (
    status_id   smallint     GENERATED ALWAYS AS IDENTITY,
    status_code varchar(30)  NOT NULL,
    description varchar(255),
    CONSTRAINT pk_order_status PRIMARY KEY (status_id),
    CONSTRAINT uq_order_status_code UNIQUE (status_code)
);

-- ===== Level 2 ================================================================

CREATE TABLE IF NOT EXISTS marketplace.product (
    product_id   integer       GENERATED ALWAYS AS IDENTITY,
    seller_id    integer       NOT NULL,
    category_id  integer       NOT NULL,
    sku          varchar(50)   NOT NULL,
    product_name varchar(200)  NOT NULL,
    description  text,
    created_at   timestamptz   NOT NULL DEFAULT now(),
    is_active    boolean       NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_product PRIMARY KEY (product_id),
    CONSTRAINT fk_product_seller FOREIGN KEY (seller_id)
        REFERENCES marketplace.seller (seller_id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_category FOREIGN KEY (category_id)
        REFERENCES marketplace.category (category_id) ON DELETE RESTRICT,
    CONSTRAINT uq_product_seller_sku UNIQUE (seller_id, sku),
    CONSTRAINT chk_product_created_at CHECK (created_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

-- ===== Level 3 ================================================================

-- history table: append-only (rows are inserted, never updated)
CREATE TABLE IF NOT EXISTS marketplace.product_price_history (
    price_id      bigint         GENERATED ALWAYS AS IDENTITY,
    product_id    integer        NOT NULL,
    price         numeric(12, 2) NOT NULL,
    currency_code char(3)        NOT NULL DEFAULT 'USD',
    valid_from    timestamptz    NOT NULL DEFAULT now(),
    valid_to      timestamptz,
    CONSTRAINT pk_product_price_history PRIMARY KEY (price_id),
    CONSTRAINT fk_product_price_history_product FOREIGN KEY (product_id)
        REFERENCES marketplace.product (product_id) ON DELETE RESTRICT,
    CONSTRAINT uq_product_price_history_period UNIQUE (product_id, valid_from),
    CONSTRAINT chk_product_price_history_price CHECK (price > 0),
    CONSTRAINT chk_product_price_history_period CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- no two price periods of one product may overlap (half-open ranges: [valid_from, valid_to) )
    CONSTRAINT excl_product_price_history_overlap
        EXCLUDE USING gist (product_id WITH =, tstzrange(valid_from, valid_to) WITH &&)
);

-- history table: append-only
CREATE TABLE IF NOT EXISTS marketplace.inventory_movement (
    movement_id    bigint       GENERATED ALWAYS AS IDENTITY,
    product_id     integer      NOT NULL,
    movement_type  varchar(20)  NOT NULL,
    quantity_delta integer      NOT NULL,
    moved_at       timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_inventory_movement PRIMARY KEY (movement_id),
    CONSTRAINT fk_inventory_movement_product FOREIGN KEY (product_id)
        REFERENCES marketplace.product (product_id) ON DELETE RESTRICT,
    CONSTRAINT chk_inventory_movement_type
        CHECK (movement_type IN ('RESTOCK', 'SALE', 'RETURN', 'ADJUSTMENT')),
    CONSTRAINT chk_inventory_movement_nonzero CHECK (quantity_delta <> 0),
    -- sign by type: stock grows on RESTOCK / RETURN, shrinks on SALE, ADJUSTMENT may go both ways
    CONSTRAINT chk_inventory_movement_sign
        CHECK ((movement_type IN ('RESTOCK', 'RETURN') AND quantity_delta > 0)
               OR (movement_type = 'SALE' AND quantity_delta < 0)
               OR movement_type = 'ADJUSTMENT')
);

-- link table: many-to-many between product and promotion
CREATE TABLE IF NOT EXISTS marketplace.product_promotion (
    product_id   integer      NOT NULL,
    promotion_id integer      NOT NULL,
    added_at     timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_product_promotion PRIMARY KEY (product_id, promotion_id),
    CONSTRAINT fk_product_promotion_product FOREIGN KEY (product_id)
        REFERENCES marketplace.product (product_id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_promotion_promotion FOREIGN KEY (promotion_id)
        REFERENCES marketplace.promotion (promotion_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS marketplace.customer_order (
    order_id     bigint       GENERATED ALWAYS AS IDENTITY,
    order_number varchar(30)  NOT NULL,
    buyer_id     integer      NOT NULL,
    ordered_at   timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_customer_order PRIMARY KEY (order_id),
    CONSTRAINT uq_customer_order_number UNIQUE (order_number),
    CONSTRAINT fk_customer_order_buyer FOREIGN KEY (buyer_id)
        REFERENCES marketplace.buyer (buyer_id) ON DELETE RESTRICT,
    CONSTRAINT chk_customer_order_ordered_at CHECK (ordered_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

-- ===== Level 4 ================================================================

CREATE TABLE IF NOT EXISTS marketplace.order_item (
    order_item_id bigint         GENERATED ALWAYS AS IDENTITY,
    order_id      bigint         NOT NULL,
    product_id    integer        NOT NULL,
    promotion_id  integer,
    quantity      integer        NOT NULL,
    unit_price    numeric(12, 2) NOT NULL,
    CONSTRAINT pk_order_item PRIMARY KEY (order_item_id),
    CONSTRAINT uq_order_item_order_product UNIQUE (order_id, product_id),
    CONSTRAINT fk_order_item_order FOREIGN KEY (order_id)
        REFERENCES marketplace.customer_order (order_id) ON DELETE RESTRICT,
    CONSTRAINT fk_order_item_product FOREIGN KEY (product_id)
        REFERENCES marketplace.product (product_id) ON DELETE RESTRICT,
    -- composite FK: a promotion can be applied only to a product that is linked to it.
    -- When promotion_id is NULL (no promotion) the check is skipped (MATCH SIMPLE).
    CONSTRAINT fk_order_item_product_promotion FOREIGN KEY (product_id, promotion_id)
        REFERENCES marketplace.product_promotion (product_id, promotion_id) ON DELETE RESTRICT,
    CONSTRAINT chk_order_item_quantity CHECK (quantity > 0),
    CONSTRAINT chk_order_item_unit_price CHECK (unit_price >= 0)
);

CREATE TABLE IF NOT EXISTS marketplace.delivery (
    delivery_id     bigint         GENERATED ALWAYS AS IDENTITY,
    order_id        bigint         NOT NULL,
    recipient_name  varchar(160)   NOT NULL,
    country         varchar(80)    NOT NULL,
    city            varchar(100)   NOT NULL,
    street_address  varchar(255)   NOT NULL,
    postal_code     varchar(20),
    carrier_name    varchar(100),
    tracking_number varchar(60),
    delivery_fee    numeric(10, 2) NOT NULL DEFAULT 0,
    shipped_at      timestamptz,
    delivered_at    timestamptz,
    CONSTRAINT pk_delivery PRIMARY KEY (delivery_id),
    CONSTRAINT uq_delivery_order UNIQUE (order_id),
    CONSTRAINT uq_delivery_tracking_number UNIQUE (tracking_number),
    CONSTRAINT fk_delivery_order FOREIGN KEY (order_id)
        REFERENCES marketplace.customer_order (order_id) ON DELETE RESTRICT,
    CONSTRAINT chk_delivery_fee CHECK (delivery_fee >= 0),
    CONSTRAINT chk_delivery_dates CHECK (delivered_at >= shipped_at)
);

-- history table: append-only
CREATE TABLE IF NOT EXISTS marketplace.order_status_history (
    history_id    bigint       GENERATED ALWAYS AS IDENTITY,
    order_id      bigint       NOT NULL,
    status_id     smallint     NOT NULL,
    changed_at    timestamptz  NOT NULL DEFAULT now(),
    change_reason varchar(255),
    CONSTRAINT pk_order_status_history PRIMARY KEY (history_id),
    CONSTRAINT uq_order_status_history_order_changed UNIQUE (order_id, changed_at),
    CONSTRAINT fk_order_status_history_order FOREIGN KEY (order_id)
        REFERENCES marketplace.customer_order (order_id) ON DELETE RESTRICT,
    CONSTRAINT fk_order_status_history_status FOREIGN KEY (status_id)
        REFERENCES marketplace.order_status (status_id) ON DELETE RESTRICT
);

-- history table: append-only
CREATE TABLE IF NOT EXISTS marketplace.payment (
    payment_id       bigint         GENERATED ALWAYS AS IDENTITY,
    order_id         bigint         NOT NULL,
    payment_method   varchar(20)    NOT NULL,
    transaction_type varchar(10)    NOT NULL DEFAULT 'CHARGE',
    payment_result   varchar(10)    NOT NULL,
    amount           numeric(12, 2) NOT NULL,
    currency_code    char(3)        NOT NULL DEFAULT 'USD',
    external_ref     varchar(100),
    paid_at          timestamptz    NOT NULL DEFAULT now(),
    CONSTRAINT pk_payment PRIMARY KEY (payment_id),
    CONSTRAINT uq_payment_external_ref UNIQUE (external_ref),
    CONSTRAINT fk_payment_order FOREIGN KEY (order_id)
        REFERENCES marketplace.customer_order (order_id) ON DELETE RESTRICT,
    CONSTRAINT chk_payment_amount CHECK (amount > 0),
    CONSTRAINT chk_payment_method CHECK (payment_method IN ('CARD', 'BANK_TRANSFER', 'WALLET', 'CASH')),
    CONSTRAINT chk_payment_transaction_type CHECK (transaction_type IN ('CHARGE', 'REFUND')),
    CONSTRAINT chk_payment_result CHECK (payment_result IN ('SUCCESS', 'FAILED')),
    CONSTRAINT chk_payment_paid_at CHECK (paid_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

-- ===== Level 5 ================================================================

CREATE TABLE IF NOT EXISTS marketplace.review (
    review_id     bigint       GENERATED ALWAYS AS IDENTITY,
    order_item_id bigint       NOT NULL,
    rating        smallint     NOT NULL,
    review_text   text,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_review PRIMARY KEY (review_id),
    CONSTRAINT uq_review_order_item UNIQUE (order_item_id),
    CONSTRAINT fk_review_order_item FOREIGN KEY (order_item_id)
        REFERENCES marketplace.order_item (order_item_id) ON DELETE RESTRICT,
    CONSTRAINT chk_review_rating CHECK (rating BETWEEN 1 AND 5)
);


/*------------------------------------------------------------------------------
 SECTION 3. Indexes on foreign key columns that are not already covered by a
 primary key / unique constraint (PostgreSQL does not index FK columns automatically;
 without these indexes joins and parent-row deletes would scan the whole child table).
------------------------------------------------------------------------------*/
CREATE INDEX IF NOT EXISTS idx_product_category_id            ON marketplace.product (category_id);
CREATE INDEX IF NOT EXISTS idx_inventory_movement_product_id  ON marketplace.inventory_movement (product_id, moved_at);
CREATE INDEX IF NOT EXISTS idx_product_promotion_promotion_id ON marketplace.product_promotion (promotion_id);
CREATE INDEX IF NOT EXISTS idx_customer_order_buyer_id        ON marketplace.customer_order (buyer_id);
CREATE INDEX IF NOT EXISTS idx_order_item_product_promotion   ON marketplace.order_item (product_id, promotion_id);
CREATE INDEX IF NOT EXISTS idx_order_status_history_status_id ON marketplace.order_status_history (status_id);
CREATE INDEX IF NOT EXISTS idx_payment_order_id               ON marketplace.payment (order_id);


/*------------------------------------------------------------------------------
 SECTION 4. Sample data (parents first, every foreign key is found by JOIN on a natural key)
 Duplicates are avoided with ON CONFLICT DO NOTHING / WHERE NOT EXISTS, so every statement
 inserts 0 rows on a second run. (WHERE TRUE after a join is needed only to keep the
 parser from reading "ON CONFLICT" as part of the join condition.)
------------------------------------------------------------------------------*/

-- 4.1 seller (3 rows); conflict target: unique e-mail
INSERT INTO marketplace.seller (seller_name, email, phone, registered_at)
SELECT v.seller_name, v.email, v.phone, v.registered_at
FROM (VALUES
        ('TechWorld LLC',   'contact@techworld.example.com', '+998901112233', TIMESTAMPTZ '2024-03-10 09:00:00+00'),
        ('HomeStyle Store', 'sales@homestyle.example.com',   '+998902223344', TIMESTAMPTZ '2024-05-21 11:30:00+00'),
        ('BookNest',        'hello@booknest.example.com',    '+998903334455', TIMESTAMPTZ '2024-07-02 08:15:00+00')
     ) AS v (seller_name, email, phone, registered_at)
WHERE TRUE
ON CONFLICT (email) DO NOTHING;

-- 4.2 buyer (4 rows); conflict target: unique e-mail
INSERT INTO marketplace.buyer (first_name, last_name, email, phone, registered_at)
SELECT v.first_name, v.last_name, v.email, v.phone, v.registered_at
FROM (VALUES
        ('Aziz',    'Karimov',  'aziz.karimov@example.com',     '+998911000001', TIMESTAMPTZ '2025-01-12 10:00:00+00'),
        ('Dilnoza', 'Yusupova', 'dilnoza.yusupova@example.com', '+998911000002', TIMESTAMPTZ '2025-02-03 12:20:00+00'),
        ('John',    'Miller',   'john.miller@example.com',      '+14155550123',  TIMESTAMPTZ '2025-03-18 16:45:00+00'),
        ('Maria',   'Garcia',   'maria.garcia@example.com',     '+34600111222',  TIMESTAMPTZ '2025-04-25 09:10:00+00')
     ) AS v (first_name, last_name, email, phone, registered_at)
WHERE TRUE
ON CONFLICT (email) DO NOTHING;

-- 4.3 category: root categories first (parent_category_id is NULL), then their children.
-- UNIQUE (parent_category_id, category_name) does not stop duplicate roots (NULLs are
-- never equal to each other in a unique constraint), so roots use WHERE NOT EXISTS.
INSERT INTO marketplace.category (category_name, description)
SELECT v.category_name, v.description
FROM (VALUES
        ('Electronics',    'Phones, computers and accessories'),
        ('Home & Kitchen', 'Appliances and goods for the home'),
        ('Books',          'Printed and digital books')
     ) AS v (category_name, description)
WHERE NOT EXISTS (SELECT 1
                  FROM marketplace.category AS c
                  WHERE c.parent_category_id IS NULL
                    AND c.category_name = v.category_name);

INSERT INTO marketplace.category (parent_category_id, category_name, description)
SELECT p.category_id, v.category_name, v.description
FROM (VALUES
        ('Electronics',    'Smartphones',        'Mobile phones'),
        ('Electronics',    'Laptops',            'Portable computers'),
        ('Home & Kitchen', 'Kitchen Appliances', 'Small kitchen appliances')
     ) AS v (parent_name, category_name, description)
INNER JOIN marketplace.category AS p            -- INNER JOIN: a child is inserted only if its parent exists
        ON p.category_name = v.parent_name
       AND p.parent_category_id IS NULL
WHERE TRUE
ON CONFLICT (parent_category_id, category_name) DO NOTHING;

-- 4.4 product (6 rows); seller and category found by name; conflict target (seller_id, sku)
INSERT INTO marketplace.product (seller_id, category_id, sku, product_name, description, created_at)
SELECT s.seller_id, c.category_id, v.sku, v.product_name, v.description, v.created_at
FROM (VALUES
        ('TechWorld LLC',   'Smartphones',        'TW-PH-001', 'Galaxy Phone X',        '6.5-inch smartphone, 128 GB',          TIMESTAMPTZ '2024-12-15 10:00:00+00'),
        ('TechWorld LLC',   'Laptops',            'TW-LT-001', 'UltraBook 14',          '14-inch lightweight laptop',           TIMESTAMPTZ '2024-12-15 10:05:00+00'),
        ('HomeStyle Store', 'Kitchen Appliances', 'HS-KA-001', 'Air Fryer 5L',          'Oil-free air fryer, 5 litres',         TIMESTAMPTZ '2024-12-16 09:00:00+00'),
        ('HomeStyle Store', 'Kitchen Appliances', 'HS-KA-002', 'Blender Pro',           'Countertop blender, 1000 W',           TIMESTAMPTZ '2024-12-16 09:10:00+00'),
        ('BookNest',        'Books',              'BN-BK-001', 'SQL for Beginners',     'Introductory book about SQL',          TIMESTAMPTZ '2024-12-17 08:00:00+00'),
        ('BookNest',        'Books',              'BN-BK-002', 'Data Modeling Handbook','Entity-relationship modeling guide',   TIMESTAMPTZ '2024-12-17 08:10:00+00')
     ) AS v (seller_name, category_name, sku, product_name, description, created_at)
INNER JOIN marketplace.seller AS s              -- INNER JOIN: a product needs an existing seller
        ON s.seller_name = v.seller_name
INNER JOIN marketplace.category AS c            -- INNER JOIN: a product needs an existing category
        ON c.category_name = v.category_name
WHERE TRUE
ON CONFLICT (seller_id, sku) DO NOTHING;

-- 4.5 promotion (3 rows); the model has no unique key here, so WHERE NOT EXISTS on the name
INSERT INTO marketplace.promotion (promotion_name, discount_type, discount_value, start_at, end_at)
SELECT v.promotion_name, v.discount_type, v.discount_value, v.start_at, v.end_at
FROM (VALUES
        ('Autumn Sale 10%',      'PERCENT', 10.00, TIMESTAMPTZ '2025-09-01 00:00:00+00', TIMESTAMPTZ '2025-11-30 23:59:59+00'),
        ('Kitchen 20 Off',       'FIXED',   20.00, TIMESTAMPTZ '2025-10-01 00:00:00+00', TIMESTAMPTZ '2025-12-31 23:59:59+00'),
        ('Book Week 15%',        'PERCENT', 15.00, TIMESTAMPTZ '2025-11-01 00:00:00+00', TIMESTAMPTZ '2025-11-15 23:59:59+00')
     ) AS v (promotion_name, discount_type, discount_value, start_at, end_at)
WHERE NOT EXISTS (SELECT 1
                  FROM marketplace.promotion AS p
                  WHERE p.promotion_name = v.promotion_name);

-- 4.6 product_promotion (4 rows); which promotion covers which product
INSERT INTO marketplace.product_promotion (product_id, promotion_id, added_at)
SELECT p.product_id, pr.promotion_id, v.added_at
FROM (VALUES
        ('TW-PH-001', 'Autumn Sale 10%', TIMESTAMPTZ '2025-08-25 09:00:00+00'),
        ('TW-LT-001', 'Autumn Sale 10%', TIMESTAMPTZ '2025-08-25 09:00:00+00'),
        ('HS-KA-001', 'Kitchen 20 Off',  TIMESTAMPTZ '2025-09-25 09:00:00+00'),
        ('BN-BK-001', 'Book Week 15%',   TIMESTAMPTZ '2025-10-25 09:00:00+00')
     ) AS v (sku, promotion_name, added_at)
INNER JOIN marketplace.product AS p             -- INNER JOIN: only existing products
        ON p.sku = v.sku
INNER JOIN marketplace.promotion AS pr          -- INNER JOIN: only existing promotions
        ON pr.promotion_name = v.promotion_name
WHERE TRUE
ON CONFLICT (product_id, promotion_id) DO NOTHING;

-- 4.7 product_price_history (7 rows); Galaxy Phone X has two consecutive periods
INSERT INTO marketplace.product_price_history (product_id, price, valid_from, valid_to)
SELECT p.product_id, v.price, v.valid_from, v.valid_to
FROM (VALUES
        ('TW-PH-001', 699.00, TIMESTAMPTZ '2025-01-01 00:00:00+00', TIMESTAMPTZ '2025-09-01 00:00:00+00'),
        ('TW-PH-001', 649.00, TIMESTAMPTZ '2025-09-01 00:00:00+00', NULL),
        ('TW-LT-001', 1199.00, TIMESTAMPTZ '2025-01-01 00:00:00+00', NULL),
        ('HS-KA-001',   89.90, TIMESTAMPTZ '2025-01-01 00:00:00+00', NULL),
        ('HS-KA-002',   59.90, TIMESTAMPTZ '2025-01-01 00:00:00+00', NULL),
        ('BN-BK-001',   29.90, TIMESTAMPTZ '2025-01-01 00:00:00+00', NULL),
        ('BN-BK-002',   39.90, TIMESTAMPTZ '2025-01-01 00:00:00+00', NULL)
     ) AS v (sku, price, valid_from, valid_to)
INNER JOIN marketplace.product AS p             -- INNER JOIN: a price needs an existing product
        ON p.sku = v.sku
WHERE TRUE
ON CONFLICT DO NOTHING;                          -- no target: also covers the exclusion constraint

-- 4.8 order_status (5 rows); conflict target: unique status_code
INSERT INTO marketplace.order_status (status_code, description)
SELECT v.status_code, v.description
FROM (VALUES
        ('PENDING',   'Order created, waiting for payment'),
        ('PAID',      'Payment received'),
        ('SHIPPED',   'Handed over to the carrier'),
        ('DELIVERED', 'Delivered to the recipient'),
        ('CANCELLED', 'Order cancelled')
     ) AS v (status_code, description)
WHERE TRUE
ON CONFLICT (status_code) DO NOTHING;

-- 4.9 customer_order (4 rows); buyer found by e-mail; conflict target: unique order_number
INSERT INTO marketplace.customer_order (order_number, buyer_id, ordered_at)
SELECT v.order_number, b.buyer_id, v.ordered_at
FROM (VALUES
        ('ORD-2025-0001', 'aziz.karimov@example.com',     TIMESTAMPTZ '2025-10-05 10:15:00+00'),
        ('ORD-2025-0002', 'dilnoza.yusupova@example.com', TIMESTAMPTZ '2025-10-12 14:30:00+00'),
        ('ORD-2025-0003', 'john.miller@example.com',      TIMESTAMPTZ '2025-11-02 09:05:00+00'),
        ('ORD-2025-0004', 'maria.garcia@example.com',     TIMESTAMPTZ '2025-11-08 18:45:00+00')
     ) AS v (order_number, buyer_email, ordered_at)
INNER JOIN marketplace.buyer AS b               -- INNER JOIN: an order needs an existing buyer
        ON b.email = v.buyer_email
WHERE TRUE
ON CONFLICT (order_number) DO NOTHING;

-- 4.10 order_item (6 rows). unit_price is NOT typed: it is the price valid at the order time.
-- LEFT JOIN promotion: items without a promotion stay (promotion_id = NULL).
-- The composite FK guarantees that the promotion really covers the product.
INSERT INTO marketplace.order_item (order_id, product_id, promotion_id, quantity, unit_price)
SELECT o.order_id,
       p.product_id,
       pr.promotion_id,
       v.quantity,
       (SELECT h.price
        FROM marketplace.product_price_history AS h
        WHERE h.product_id = p.product_id
          AND h.valid_from <= o.ordered_at
          AND (h.valid_to IS NULL OR h.valid_to > o.ordered_at))
FROM (VALUES
        ('ORD-2025-0001', 'TW-PH-001', 'Autumn Sale 10%', 1),
        ('ORD-2025-0001', 'BN-BK-002', NULL,              2),
        ('ORD-2025-0002', 'HS-KA-001', 'Kitchen 20 Off',  1),
        ('ORD-2025-0002', 'HS-KA-002', NULL,              1),
        ('ORD-2025-0003', 'TW-LT-001', 'Autumn Sale 10%', 1),
        ('ORD-2025-0004', 'BN-BK-001', 'Book Week 15%',   3)
     ) AS v (order_number, sku, promotion_name, quantity)
INNER JOIN marketplace.customer_order AS o      -- INNER JOIN: an item needs an existing order
        ON o.order_number = v.order_number
INNER JOIN marketplace.product AS p             -- INNER JOIN: an item needs an existing product
        ON p.sku = v.sku
LEFT JOIN marketplace.promotion AS pr           -- LEFT JOIN: the promotion is optional
       ON pr.promotion_name = v.promotion_name
WHERE TRUE
ON CONFLICT (order_id, product_id) DO NOTHING;

-- 4.11 delivery (3 rows; order 4 is not shipped yet, order 3 is shipped but not delivered).
-- Dates are derived from ordered_at (shipped after 1 day, delivered after 4 days).
INSERT INTO marketplace.delivery (order_id, recipient_name, country, city, street_address, postal_code,
                                  carrier_name, tracking_number, delivery_fee, shipped_at, delivered_at)
SELECT o.order_id,
       v.recipient_name,
       v.country,
       v.city,
       v.street_address,
       v.postal_code,
       v.carrier_name,
       v.tracking_number,
       v.delivery_fee,
       o.ordered_at + v.shipped_after_days   * INTERVAL '1 day',
       o.ordered_at + v.delivered_after_days * INTERVAL '1 day'
FROM (VALUES
        ('ORD-2025-0001', 'Aziz Karimov',     'Uzbekistan',    'Tashkent',  'Amir Temur Ave 15',   '100000', 'FastShip', 'FS-100001',  5.50, 1, 4),
        ('ORD-2025-0002', 'Dilnoza Yusupova', 'Uzbekistan',    'Samarkand', 'Registan St 8',       '140100', 'UzPost',   'UZ-200002',  0.00, 1, 4),
        ('ORD-2025-0003', 'John Miller',      'United States', 'Austin',    '500 Congress Ave',    '78701',  'FastShip', 'FS-300003', 24.00, 1, NULL)
     ) AS v (order_number, recipient_name, country, city, street_address, postal_code,
             carrier_name, tracking_number, delivery_fee, shipped_after_days, delivered_after_days)
INNER JOIN marketplace.customer_order AS o      -- INNER JOIN: a delivery needs an existing order
        ON o.order_number = v.order_number
WHERE TRUE
ON CONFLICT (order_id) DO NOTHING;

-- 4.12 order_status_history (13 rows); status found by code, times derived from ordered_at
INSERT INTO marketplace.order_status_history (order_id, status_id, changed_at, change_reason)
SELECT o.order_id,
       s.status_id,
       o.ordered_at + v.hours_after_order * INTERVAL '1 hour',
       v.change_reason
FROM (VALUES
        ('ORD-2025-0001', 'PENDING',    0, 'Order placed'),
        ('ORD-2025-0001', 'PAID',       1, 'Payment received'),
        ('ORD-2025-0001', 'SHIPPED',   24, 'Handed over to the carrier'),
        ('ORD-2025-0001', 'DELIVERED', 96, 'Delivered to the recipient'),
        ('ORD-2025-0002', 'PENDING',    0, 'Order placed'),
        ('ORD-2025-0002', 'PAID',       1, 'Payment received'),
        ('ORD-2025-0002', 'SHIPPED',   24, 'Handed over to the carrier'),
        ('ORD-2025-0002', 'DELIVERED', 96, 'Delivered to the recipient'),
        ('ORD-2025-0003', 'PENDING',    0, 'Order placed'),
        ('ORD-2025-0003', 'PAID',       1, 'Payment received'),
        ('ORD-2025-0003', 'SHIPPED',   24, 'Handed over to the carrier'),
        ('ORD-2025-0004', 'PENDING',    0, 'Order placed'),
        ('ORD-2025-0004', 'PAID',       2, 'Payment received after one failed attempt')
     ) AS v (order_number, status_code, hours_after_order, change_reason)
INNER JOIN marketplace.customer_order AS o      -- INNER JOIN: history needs an existing order
        ON o.order_number = v.order_number
INNER JOIN marketplace.order_status AS s        -- INNER JOIN: history needs an existing status
        ON s.status_code = v.status_code
WHERE TRUE
ON CONFLICT (order_id, changed_at) DO NOTHING;

-- 4.13 payment (5 rows). amount is calculated: sum of the order items + delivery fee.
-- transaction_type and currency_code are not listed: their DEFAULT values (CHARGE, USD) apply.
-- Order 4 has a failed attempt and then a successful one.
WITH order_totals AS (
    SELECT o.order_id,
           o.order_number,
           o.ordered_at,
           SUM(oi.quantity * oi.unit_price) + COALESCE(MAX(d.delivery_fee), 0) AS total_amount
    FROM marketplace.customer_order AS o
    INNER JOIN marketplace.order_item AS oi
            ON oi.order_id = o.order_id
    LEFT JOIN marketplace.delivery AS d         -- LEFT JOIN: an order without delivery has fee 0
           ON d.order_id = o.order_id
    GROUP BY o.order_id, o.order_number, o.ordered_at
)
INSERT INTO marketplace.payment (order_id, payment_method, payment_result, amount, external_ref, paid_at)
SELECT t.order_id,
       v.payment_method,
       v.payment_result,
       t.total_amount,
       'PAY-' || t.order_number || '-' || v.attempt_no,
       t.ordered_at + v.minutes_after_order * INTERVAL '1 minute'
FROM (VALUES
        ('ORD-2025-0001', 1, 'CARD',          'SUCCESS', 10),
        ('ORD-2025-0002', 1, 'WALLET',        'SUCCESS', 15),
        ('ORD-2025-0003', 1, 'BANK_TRANSFER', 'SUCCESS', 30),
        ('ORD-2025-0004', 1, 'CARD',          'FAILED',   5),
        ('ORD-2025-0004', 2, 'CARD',          'SUCCESS', 90)
     ) AS v (order_number, attempt_no, payment_method, payment_result, minutes_after_order)
INNER JOIN order_totals AS t                    -- INNER JOIN: a payment needs an existing order with items
        ON t.order_number = v.order_number
WHERE TRUE
ON CONFLICT (external_ref) DO NOTHING;

-- 4.14 review (3 rows) for delivered items; conflict target: one review per order item
INSERT INTO marketplace.review (order_item_id, rating, review_text, created_at)
SELECT oi.order_item_id,
       v.rating,
       v.review_text,
       o.ordered_at + INTERVAL '10 days'
FROM (VALUES
        ('ORD-2025-0001', 'TW-PH-001', 5, 'Great phone, fast delivery.'),
        ('ORD-2025-0001', 'BN-BK-002', 4, 'Clear explanations, useful examples.'),
        ('ORD-2025-0002', 'HS-KA-001', 5, 'Cooks evenly and is easy to clean.')
     ) AS v (order_number, sku, rating, review_text)
INNER JOIN marketplace.customer_order AS o      -- INNER JOIN chain: review -> order item -> order and product
        ON o.order_number = v.order_number
INNER JOIN marketplace.product AS p
        ON p.sku = v.sku
INNER JOIN marketplace.order_item AS oi
        ON oi.order_id = o.order_id
       AND oi.product_id = p.product_id
WHERE TRUE
ON CONFLICT (order_item_id) DO NOTHING;

-- 4.15 inventory_movement (12 rows). The model has no unique key here, so WHERE NOT EXISTS.
-- (a) initial RESTOCK of every product
INSERT INTO marketplace.inventory_movement (product_id, movement_type, quantity_delta, moved_at)
SELECT p.product_id,
       'RESTOCK',
       100,
       TIMESTAMPTZ '2025-09-15 08:00:00+00'
FROM marketplace.product AS p
WHERE NOT EXISTS (SELECT 1
                  FROM marketplace.inventory_movement AS m
                  WHERE m.product_id = p.product_id
                    AND m.movement_type = 'RESTOCK'
                    AND m.moved_at = TIMESTAMPTZ '2025-09-15 08:00:00+00');

-- (b) one SALE per order item: the quantity and the time come from the order itself
INSERT INTO marketplace.inventory_movement (product_id, movement_type, quantity_delta, moved_at)
SELECT oi.product_id,
       'SALE',
       -oi.quantity,
       o.ordered_at
FROM marketplace.order_item AS oi
INNER JOIN marketplace.customer_order AS o      -- INNER JOIN: the sale time is the order time
        ON o.order_id = oi.order_id
WHERE NOT EXISTS (SELECT 1
                  FROM marketplace.inventory_movement AS m
                  WHERE m.product_id = oi.product_id
                    AND m.movement_type = 'SALE'
                    AND m.moved_at = o.ordered_at);


/*------------------------------------------------------------------------------
 SECTION 5. record_ts column for every table (ALTER TABLE)
 NOT NULL with DEFAULT current_date: PostgreSQL fills the value for all EXISTING rows at the
 moment the column is added, and for every new row it is set automatically.
 IF NOT EXISTS makes the statements rerunnable.
------------------------------------------------------------------------------*/
ALTER TABLE marketplace.seller                ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.buyer                 ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.category              ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.promotion             ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.order_status          ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.product               ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.product_price_history ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.inventory_movement    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.product_promotion     ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.customer_order        ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.order_item            ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.delivery              ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.order_status_history  ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.payment               ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE marketplace.review                ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;


/*------------------------------------------------------------------------------
 SECTION 6. Checks
------------------------------------------------------------------------------*/

-- 6.1 record_ts is set for ALL existing rows: rows_without_record_ts must be 0 everywhere
SELECT 'seller' AS table_name, COUNT(*) AS total_rows, COUNT(*) - COUNT(record_ts) AS rows_without_record_ts FROM marketplace.seller
UNION ALL SELECT 'buyer',                 COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.buyer
UNION ALL SELECT 'category',              COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.category
UNION ALL SELECT 'promotion',             COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.promotion
UNION ALL SELECT 'order_status',          COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.order_status
UNION ALL SELECT 'product',               COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.product
UNION ALL SELECT 'product_price_history', COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.product_price_history
UNION ALL SELECT 'inventory_movement',    COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.inventory_movement
UNION ALL SELECT 'product_promotion',     COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.product_promotion
UNION ALL SELECT 'customer_order',        COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.customer_order
UNION ALL SELECT 'order_item',            COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.order_item
UNION ALL SELECT 'delivery',              COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.delivery
UNION ALL SELECT 'order_status_history',  COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.order_status_history
UNION ALL SELECT 'payment',               COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.payment
UNION ALL SELECT 'review',                COUNT(*), COUNT(*) - COUNT(record_ts) FROM marketplace.review
ORDER BY table_name;

-- 6.2 the data really matches itself: an order total equals the sum of its payments with
-- result SUCCESS (the failed attempt of order 4 is not counted); mismatches must be 0 rows
SELECT o.order_number,
       SUM(oi.quantity * oi.unit_price) + COALESCE(MAX(d.delivery_fee), 0) AS order_total,
       (SELECT SUM(p.amount)
        FROM marketplace.payment AS p
        WHERE p.order_id = o.order_id
          AND p.payment_result = 'SUCCESS') AS paid_total
FROM marketplace.customer_order AS o
INNER JOIN marketplace.order_item AS oi
        ON oi.order_id = o.order_id
LEFT JOIN marketplace.delivery AS d
       ON d.order_id = o.order_id
GROUP BY o.order_id, o.order_number
HAVING SUM(oi.quantity * oi.unit_price) + COALESCE(MAX(d.delivery_fee), 0)
       IS DISTINCT FROM (SELECT SUM(p.amount)
                         FROM marketplace.payment AS p
                         WHERE p.order_id = o.order_id
                           AND p.payment_result = 'SUCCESS');
