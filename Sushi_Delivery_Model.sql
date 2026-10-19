-- Sushi Delivery Logical Data Model
-- Target DBMS: PostgreSQL
-- Designed in 3NF; execute in an empty database/schema.

CREATE TABLE customers (
    customer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100),
    phone VARCHAR(20) NOT NULL UNIQUE,
    email VARCHAR(255) UNIQUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_customer_phone_nonempty CHECK (LENGTH(TRIM(phone)) > 0)
);

CREATE TABLE customer_addresses (
    address_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
    address_label VARCHAR(50),
    city VARCHAR(100) NOT NULL,
    district VARCHAR(100) NOT NULL,
    street VARCHAR(150) NOT NULL,
    building VARCHAR(30) NOT NULL,
    apartment VARCHAR(30),
    delivery_instructions TEXT,
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_customer_addresses_customer ON customer_addresses(customer_id);

CREATE TABLE menu_categories (
    category_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE menu_items (
    menu_item_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id BIGINT NOT NULL REFERENCES menu_categories(category_id),
    item_name VARCHAR(150) NOT NULL UNIQUE,
    description TEXT,
    current_price NUMERIC(12,2) NOT NULL CHECK (current_price >= 0),
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    preparation_time_minutes SMALLINT NOT NULL CHECK (preparation_time_minutes > 0)
);

CREATE TABLE ingredients (
    ingredient_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingredient_name VARCHAR(120) NOT NULL UNIQUE,
    unit_of_measure VARCHAR(20) NOT NULL,
    is_allergen BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE menu_item_ingredients (
    menu_item_id BIGINT NOT NULL REFERENCES menu_items(menu_item_id) ON DELETE CASCADE,
    ingredient_id BIGINT NOT NULL REFERENCES ingredients(ingredient_id),
    quantity_required NUMERIC(10,3) NOT NULL CHECK (quantity_required > 0),
    PRIMARY KEY (menu_item_id, ingredient_id)
);

CREATE TABLE payment_methods (
    payment_method_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    method_name VARCHAR(40) NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE orders (
    order_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
    delivery_address_id BIGINT NOT NULL REFERENCES customer_addresses(address_id),
    accepted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    order_channel VARCHAR(20) NOT NULL CHECK (order_channel IN ('PHONE', 'WEBSITE', 'MOBILE_APP', 'IN_PERSON')),
    currency CHAR(3) NOT NULL DEFAULT 'UZS',
    subtotal_amount NUMERIC(12,2) NOT NULL CHECK (subtotal_amount >= 0),
    delivery_fee NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
    discount_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0),
    customer_note TEXT,
    CONSTRAINT chk_order_total CHECK (total_amount = subtotal_amount + delivery_fee - discount_amount),
    CONSTRAINT chk_discount_not_over_subtotal CHECK (discount_amount <= subtotal_amount)
);
CREATE INDEX idx_orders_customer_accepted ON orders(customer_id, accepted_at);

CREATE TABLE order_items (
    order_item_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    menu_item_id BIGINT NOT NULL REFERENCES menu_items(menu_item_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
    line_total NUMERIC(12,2) NOT NULL CHECK (line_total = quantity * unit_price),
    item_note TEXT,
    CONSTRAINT uq_order_item UNIQUE (order_id, menu_item_id, item_note)
);
CREATE INDEX idx_order_items_order ON order_items(order_id);

CREATE TABLE order_status_history (
    order_status_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    status_code VARCHAR(30) NOT NULL CHECK (status_code IN ('ACCEPTED', 'CONFIRMED', 'PREPARING', 'READY', 'OUT_FOR_DELIVERY', 'DELIVERED', 'CANCELLED')),
    status_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed_by VARCHAR(100),
    comment TEXT
);
CREATE INDEX idx_order_status_history_order_time ON order_status_history(order_id, status_at);

CREATE TABLE couriers (
    courier_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100),
    phone VARCHAR(20) NOT NULL UNIQUE,
    hired_at DATE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE deliveries (
    delivery_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id BIGINT NOT NULL UNIQUE REFERENCES orders(order_id) ON DELETE CASCADE,
    courier_id BIGINT REFERENCES couriers(courier_id),
    address_id BIGINT NOT NULL REFERENCES customer_addresses(address_id),
    assigned_at TIMESTAMP,
    picked_up_at TIMESTAMP,
    delivered_at TIMESTAMP,
    delivery_fee NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
    delivery_note TEXT,
    CONSTRAINT chk_delivery_time_order CHECK (
        delivered_at IS NULL OR picked_up_at IS NULL OR delivered_at >= picked_up_at
    )
);
CREATE INDEX idx_deliveries_courier_assigned ON deliveries(courier_id, assigned_at);

CREATE TABLE delivery_status_history (
    delivery_status_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    delivery_id BIGINT NOT NULL REFERENCES deliveries(delivery_id) ON DELETE CASCADE,
    status_code VARCHAR(30) NOT NULL CHECK (status_code IN ('WAITING_FOR_COURIER', 'ASSIGNED', 'PICKED_UP', 'ON_THE_WAY', 'DELIVERED', 'FAILED', 'RETURNED')),
    status_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    comment TEXT
);
CREATE INDEX idx_delivery_status_history_delivery_time ON delivery_status_history(delivery_id, status_at);

CREATE TABLE preparation_tasks (
    preparation_task_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_item_id BIGINT NOT NULL UNIQUE REFERENCES order_items(order_item_id) ON DELETE CASCADE,
    assigned_to VARCHAR(100),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    task_status VARCHAR(20) NOT NULL DEFAULT 'QUEUED'
        CHECK (task_status IN ('QUEUED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
    CONSTRAINT chk_preparation_time CHECK (
        completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at
    )
);

CREATE TABLE payments (
    payment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(order_id),
    payment_method_id SMALLINT NOT NULL REFERENCES payment_methods(payment_method_id),
    payment_amount NUMERIC(12,2) NOT NULL CHECK (payment_amount > 0),
    payment_status VARCHAR(20) NOT NULL CHECK (payment_status IN ('PENDING', 'SUCCEEDED', 'FAILED', 'REFUNDED')),
    transaction_reference VARCHAR(100) UNIQUE,
    paid_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_payments_order ON payments(order_id);
