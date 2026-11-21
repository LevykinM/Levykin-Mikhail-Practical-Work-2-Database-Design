-- FoodExpress full installation. Run in a database without the levykin_food schema.

-- The exts schema and uuid-ossp extension must already be available.

BEGIN;

create schema levykin_food;
create table levykin_food.client (
	client_id uuid primary key default exts.uuid_generate_v4(),
	login varchar(50) not null unique,
	phone_number char(12) not null unique,
	password char(32) not null
);

create table levykin_food.address (
	address_id uuid primary key default exts.uuid_generate_v4(),
	street varchar(100) not null,
	house_number varchar(12) not null,
	apartment_office varchar(20)
);

CREATE TABLE levykin_food.client_address (
    client_id uuid REFERENCES levykin_food.client(client_id),
    address_id uuid REFERENCES levykin_food.address(address_id),
    PRIMARY KEY (client_id, address_id)
);

CREATE TYPE levykin_food.restaurant_status AS ENUM (
    'активен',
    'неактивен'
);

CREATE TABLE levykin_food.restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(100) NOT NULL,
    address_id uuid NOT NULL UNIQUE REFERENCES levykin_food.address(address_id),
    description text NOT NULL,
    work_start time NOT NULL,
    work_end time NOT NULL,
    company_details text NOT NULL,
    rating numeric CHECK (rating BETWEEN 0 AND 5),
    status levykin_food.restaurant_status NOT NULL,
    CHECK (work_end > work_start)
);

CREATE TABLE levykin_food.product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(100) NOT NULL
);

CREATE TYPE levykin_food.product_status AS ENUM (
    'доступно',
    'нет_в_наличии',
    'архив'
);

CREATE TABLE levykin_food.product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(100) NOT NULL,
    product_category_id uuid NOT NULL
        REFERENCES levykin_food.product_category(product_category_id),
    restaurant_id uuid NOT NULL
        REFERENCES levykin_food.restaurant(restaurant_id),
    price numeric NOT NULL CHECK (price >= 0),
    description text NOT NULL,
    photo_url text,
    rating numeric CHECK (rating BETWEEN 0 AND 5),
    status levykin_food.product_status NOT NULL
);

CREATE TYPE levykin_food.courier_status AS ENUM (
    'свободен',
    'занят',
    'на_доставке',
    'уволен'
);

CREATE TABLE levykin_food.courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    fio varchar(150) NOT NULL,
    phone_number char(12) NOT NULL,
    status levykin_food.courier_status NOT NULL,
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric NOT NULL DEFAULT 0.1
        CHECK (coefficient BETWEEN 0.1 AND 0.5),
    CHECK ((status = 'уволен') = (dismissal_date IS NOT NULL))
);

CREATE TABLE levykin_food.courier_pay (
    year int NOT NULL,
    month int NOT NULL CHECK (month BETWEEN 1 AND 12),
    courier_id uuid NOT NULL REFERENCES levykin_food.courier(courier_id),
    amount numeric NOT NULL CHECK (amount >= 0),
    coefficient_used numeric NOT NULL
        CHECK (coefficient_used BETWEEN 0.1 AND 0.5),
    PRIMARY KEY (year, month, courier_id)
);

CREATE TYPE levykin_food.order_status AS ENUM (
    'создан',
    'готовится',
    'в_доставке',
    'доставлен',
    'отменён'
);

CREATE TYPE levykin_food.order_pay_status AS ENUM (
    'ожидает',
    'оплачен',
    'ошибка'
);

CREATE TABLE levykin_food."order" (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES levykin_food.courier(courier_id),
    client_id uuid NOT NULL REFERENCES levykin_food.client(client_id),
    address_id uuid NOT NULL REFERENCES levykin_food.address(address_id),
    restaurant_id uuid NOT NULL REFERENCES levykin_food.restaurant(restaurant_id),
    order_timestamp timestamp NOT NULL,
    delivery_timestamp timestamp,
    order_amount numeric NOT NULL,
    commission numeric NOT NULL,
    total_amount numeric NOT NULL CHECK (total_amount >= 1000),
    status levykin_food.order_status NOT NULL,
    pay_status levykin_food.order_pay_status NOT NULL,
    description text NOT NULL,
    FOREIGN KEY (client_id, address_id)
        REFERENCES levykin_food.client_address(client_id, address_id),
    CHECK (commission = order_amount * 0.10),
    CHECK (total_amount = order_amount + commission),
    CHECK (delivery_timestamp >= order_timestamp),
    CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL)
);

CREATE TABLE levykin_food.order_structure (
    order_id uuid NOT NULL REFERENCES levykin_food."order"(order_id),
    product_id uuid NOT NULL REFERENCES levykin_food.product(product_id),
    quantity numeric NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, product_id)
);

CREATE TYPE levykin_food.payment_type AS ENUM (
    'карта', 'наличные', 'безнал'
);

CREATE TYPE levykin_food.payment_status AS ENUM (
    'успех', 'ошибка', 'в_обработке'
);

CREATE TABLE levykin_food.payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL REFERENCES levykin_food."order"(order_id),
    payment_type levykin_food.payment_type NOT NULL,
    amount numeric NOT NULL,
    transaction_id uuid NOT NULL UNIQUE,
    transaction_timestamp timestamp NOT NULL,
    status levykin_food.payment_status NOT NULL
);

CREATE UNIQUE INDEX payment_one_success_per_order
    ON levykin_food.payment (order_id)
    WHERE status = 'успех';

CREATE TYPE levykin_food.review_entity_type AS ENUM (
    'блюдо', 'ресторан', 'заказ'
);

CREATE TABLE levykin_food.review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    client_id uuid NOT NULL REFERENCES levykin_food.client(client_id),
    order_id uuid NOT NULL REFERENCES levykin_food."order"(order_id),
    review_timestamp timestamp NOT NULL,
    entity_id uuid NOT NULL,
    entity_type levykin_food.review_entity_type NOT NULL,
    description text NOT NULL,
    photo_url text,
    rating numeric NOT NULL CHECK (rating BETWEEN 1 AND 5),
    UNIQUE (order_id, entity_type, entity_id)
);

ALTER TABLE levykin_food."order"
    ADD CONSTRAINT order_id_total_amount_key
    UNIQUE (order_id, total_amount);

ALTER TABLE levykin_food.payment
    ADD CONSTRAINT payment_order_amount_fk
    FOREIGN KEY (order_id, amount)
    REFERENCES levykin_food."order"(order_id, total_amount);

CREATE FUNCTION levykin_food.check_order_product_restaurant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM levykin_food."order" o
        JOIN levykin_food.product p ON p.restaurant_id = o.restaurant_id
        WHERE o.order_id = NEW.order_id
          AND p.product_id = NEW.product_id
        FOR SHARE OF o, p
    ) THEN
        RAISE EXCEPTION 'Order and product must belong to the same restaurant'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_order_product_restaurant
BEFORE INSERT OR UPDATE OF order_id, product_id
ON levykin_food.order_structure
FOR EACH ROW
EXECUTE FUNCTION levykin_food.check_order_product_restaurant();

CREATE FUNCTION levykin_food.check_restaurant_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    has_positions boolean;
BEGIN
    IF TG_TABLE_NAME = 'order' THEN
        SELECT EXISTS (
            SELECT 1
            FROM levykin_food.order_structure
            WHERE order_id = OLD.order_id
        ) INTO has_positions;
    ELSE
        SELECT EXISTS (
            SELECT 1
            FROM levykin_food.order_structure
            WHERE product_id = OLD.product_id
        ) INTO has_positions;
    END IF;

    IF has_positions THEN
        RAISE EXCEPTION 'Cannot change restaurant while order positions exist'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_order_restaurant_change
AFTER UPDATE OF restaurant_id ON levykin_food."order"
FOR EACH ROW
WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION levykin_food.check_restaurant_change();

CREATE TRIGGER check_product_restaurant_change
AFTER UPDATE OF restaurant_id ON levykin_food.product
FOR EACH ROW
WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION levykin_food.check_restaurant_change();

CREATE FUNCTION levykin_food.check_review_target()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM levykin_food."order" o
        WHERE o.order_id = NEW.order_id
          AND o.client_id = NEW.client_id
          AND CASE NEW.entity_type
              WHEN 'заказ' THEN NEW.entity_id = o.order_id
              WHEN 'ресторан' THEN NEW.entity_id = o.restaurant_id
              WHEN 'блюдо' THEN EXISTS (
                  SELECT 1
                  FROM levykin_food.order_structure os
                  WHERE os.order_id = o.order_id
                    AND os.product_id = NEW.entity_id
              )
              ELSE false
          END
        FOR SHARE OF o
    ) THEN
        RAISE EXCEPTION 'Review author or target does not match the order'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_review_target
BEFORE INSERT OR UPDATE OF client_id, order_id, entity_type, entity_id
ON levykin_food.review
FOR EACH ROW
EXECUTE FUNCTION levykin_food.check_review_target();

CREATE FUNCTION levykin_food.rating_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    target record;
BEGIN
    FOR target IN
        SELECT OLD.entity_type AS entity_type, OLD.entity_id AS entity_id
        WHERE TG_OP <> 'INSERT'
        UNION
        SELECT NEW.entity_type, NEW.entity_id
        WHERE TG_OP <> 'DELETE'
        ORDER BY entity_type, entity_id
    LOOP
        IF target.entity_type = 'блюдо' THEN
            PERFORM 1 FROM levykin_food.product
            WHERE product_id = target.entity_id FOR NO KEY UPDATE;

            UPDATE levykin_food.product
            SET rating = (
                SELECT AVG(r.rating)
                FROM levykin_food.review r
                WHERE r.entity_type = target.entity_type
                  AND r.entity_id = target.entity_id
            )
            WHERE product_id = target.entity_id;

        ELSIF target.entity_type = 'ресторан' THEN
            PERFORM 1 FROM levykin_food.restaurant
            WHERE restaurant_id = target.entity_id FOR NO KEY UPDATE;

            UPDATE levykin_food.restaurant
            SET rating = (
                SELECT AVG(r.rating)
                FROM levykin_food.review r
                WHERE r.entity_type = target.entity_type
                  AND r.entity_id = target.entity_id
            )
            WHERE restaurant_id = target.entity_id;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

CREATE TRIGGER rating_change
AFTER INSERT OR UPDATE OR DELETE ON levykin_food.review
FOR EACH ROW
EXECUTE FUNCTION levykin_food.rating_change();

ALTER TABLE levykin_food.courier
    ADD CONSTRAINT courier_dismissal_not_before_hire
    CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date);

CREATE FUNCTION levykin_food.check_order_has_items() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    checked_order_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'order' THEN
        checked_order_id := NEW.order_id;
    ELSE
        checked_order_id := OLD.order_id;
        UPDATE levykin_food."order" o SET description = o.description WHERE o.order_id = checked_order_id;
    END IF;
    IF EXISTS (SELECT 1 FROM levykin_food."order" WHERE order_id = checked_order_id)
        AND NOT EXISTS (SELECT 1 FROM levykin_food.order_structure WHERE order_id = checked_order_id) THEN
        RAISE EXCEPTION 'Order % must contain at least one item', checked_order_id USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_new_order_has_items
AFTER INSERT OR UPDATE OF order_id ON levykin_food."order"
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
EXECUTE FUNCTION levykin_food.check_order_has_items();

CREATE CONSTRAINT TRIGGER check_order_has_items_after_item_removal
AFTER DELETE OR UPDATE OF order_id ON levykin_food.order_structure
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
EXECUTE FUNCTION levykin_food.check_order_has_items();

CREATE FUNCTION levykin_food.sync_order_pay_status() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE affected_order_ids uuid[];
BEGIN
    affected_order_ids := CASE TG_OP
        WHEN 'INSERT' THEN ARRAY[NEW.order_id]
        WHEN 'DELETE' THEN ARRAY[OLD.order_id]
        ELSE ARRAY[OLD.order_id, NEW.order_id] END;
    PERFORM 1 FROM levykin_food."order" o WHERE o.order_id = ANY(affected_order_ids)
    ORDER BY o.order_id FOR NO KEY UPDATE;
    UPDATE levykin_food."order" o SET pay_status = (
        SELECT (CASE WHEN bool_or(p.status='успех') THEN 'оплачен'
                     WHEN bool_or(p.status='в_обработке') THEN 'ожидает'
                     WHEN bool_or(p.status='ошибка') THEN 'ошибка'
                     ELSE 'ожидает' END)::levykin_food.order_pay_status
        FROM levykin_food.payment p WHERE p.order_id = o.order_id)
    WHERE o.order_id = ANY(affected_order_ids);
    RETURN NULL;
END;
$$;
CREATE TRIGGER sync_order_pay_status AFTER INSERT OR UPDATE OF status,order_id OR DELETE
ON levykin_food.payment FOR EACH ROW EXECUTE FUNCTION levykin_food.sync_order_pay_status();

CREATE OR REPLACE PROCEDURE levykin_food.insert_test_data(value int)
LANGUAGE plpgsql
AS $$
DECLARE
    client_key uuid;
    courier_key uuid;
    category_key uuid;
    restaurant_key uuid;
    address_key uuid;
    client_addresses uuid[];
    product_key uuid;
    order_key uuid;
    product_price numeric;
    item_quantity numeric;
    subtotal numeric;
    fee numeric;
    order_time timestamp;
    delivery_time timestamp;
    current_month timestamp := date_trunc('month', localtimestamp);
    first_month timestamp := current_month - interval '5 months';
    restaurant_states levykin_food.restaurant_status[] :=
        enum_range(NULL::levykin_food.restaurant_status);
    product_states levykin_food.product_status[] :=
        enum_range(NULL::levykin_food.product_status);
    courier_states levykin_food.courier_status[] :=
        enum_range(NULL::levykin_food.courier_status);
    order_states levykin_food.order_status[] :=
        enum_range(NULL::levykin_food.order_status);
    order_pay_states levykin_food.order_pay_status[] :=
        enum_range(NULL::levykin_food.order_pay_status);
    payment_methods levykin_food.payment_type[] :=
        enum_range(NULL::levykin_food.payment_type);
    payment_states levykin_food.payment_status[] :=
        enum_range(NULL::levykin_food.payment_status);
    review_types levykin_food.review_entity_type[] :=
        enum_range(NULL::levykin_food.review_entity_type);
    courier_state levykin_food.courier_status;
    review_type levykin_food.review_entity_type;
    review_target uuid;
    coefficient_for_month numeric;
    pay_period record;
BEGIN
    IF value IS NULL OR value < 0 THEN
        RAISE EXCEPTION 'value must be a nonnegative integer'
            USING ERRCODE = '22023';
    END IF;

    FOR i IN 1..value LOOP
        -- Create one connected batch of customers, staff and catalog data.
        LOOP
            INSERT INTO levykin_food.client (login, phone_number, password)
            VALUES (
                'client_' || exts.uuid_generate_v4()::text,
                '+7' || lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
                md5(random()::text)
            )
            ON CONFLICT (phone_number) DO NOTHING
            RETURNING client_id INTO client_key;
            EXIT WHEN FOUND;
        END LOOP;

        courier_state := courier_states[1 + (i - 1) % cardinality(courier_states)];

        LOOP
            INSERT INTO levykin_food.courier
                (fio, phone_number, status, hire_date, dismissal_date)
            VALUES (
                'Test Courier ' || left(client_key::text, 8),
                '+7' || lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
                courier_state,
                greatest(first_month::date, current_date - 180),
                CASE WHEN courier_state = 'уволен' THEN current_date END
            )
            ON CONFLICT DO NOTHING
            RETURNING courier_id INTO courier_key;
            EXIT WHEN FOUND;
        END LOOP;

        INSERT INTO levykin_food.product_category (product_category_name)
        VALUES ('Category ' || client_key::text)
        RETURNING product_category_id INTO category_key;

        INSERT INTO levykin_food.address (street, house_number)
        VALUES ('Test Street ' || client_key::text, '1')
        RETURNING address_id INTO address_key;

        INSERT INTO levykin_food.restaurant
            (restaurant_name, address_id, description, work_start, work_end, company_details, status)
        VALUES (
            'Restaurant ' || client_key::text, address_key, 'Test restaurant',
            time '09:00', time '22:00', 'Test company', restaurant_states[1]
        )
        RETURNING restaurant_id INTO restaurant_key;

        client_addresses := ARRAY[]::uuid[];
        FOR j IN 1..4 LOOP
            INSERT INTO levykin_food.address (street, house_number)
            VALUES ('Test Street ' || client_key::text, (j + 1)::text)
            RETURNING address_id INTO address_key;

            INSERT INTO levykin_food.client_address (client_id, address_id)
            VALUES (client_key, address_key);

            client_addresses := array_append(client_addresses, address_key);
        END LOOP;

        -- Each batch adds five products, orders, payment attempts and reviews.
        FOR j IN 1..5 LOOP
            product_price := 1000 + (i % 50) * 10 + j * 25;
            item_quantity := 1 + (j % 3) * 0.5;
            subtotal := product_price * item_quantity;
            fee := subtotal * 0.10;
            order_time := least(
                current_month + (j - 5) * interval '1 month' + interval '2 days 12 hours',
                greatest(current_month, localtimestamp - interval '1 hour')
            );
            delivery_time := least(order_time + interval '1 hour', localtimestamp);

            INSERT INTO levykin_food.product
                (product_name, product_category_id, restaurant_id, price, description, status)
            VALUES ('Dish ' || j, category_key, restaurant_key,
                    product_price, 'Test dish', product_states[1])
            RETURNING product_id INTO product_key;

            INSERT INTO levykin_food."order" (
                courier_id, client_id, address_id, restaurant_id, order_timestamp,
                delivery_timestamp, order_amount, commission, total_amount,
                status, pay_status, description
            )
            VALUES (
                courier_key, client_key, client_addresses[1 + (j - 1) % 4],
                restaurant_key, order_time, delivery_time, subtotal, fee, subtotal + fee,
                order_states[4], order_pay_states[2], 'Test order'
            )
            RETURNING order_id INTO order_key;

            INSERT INTO levykin_food.order_structure (order_id, product_id, quantity)
            VALUES (order_key, product_key, item_quantity);

            INSERT INTO levykin_food.payment (
                order_id, payment_type, amount, transaction_id, transaction_timestamp, status
            )
            VALUES (
                order_key, payment_methods[1 + (j - 1) % cardinality(payment_methods)],
                subtotal + fee, exts.uuid_generate_v4(), order_time, payment_states[1]
            );

            review_type := review_types[1 + (j - 1) % cardinality(review_types)];
            review_target := CASE review_type
                WHEN 'блюдо' THEN product_key
                WHEN 'ресторан' THEN restaurant_key
                WHEN 'заказ' THEN order_key
            END;

            INSERT INTO levykin_food.review (
                client_id, order_id, review_timestamp, entity_id,
                entity_type, description, rating
            )
            VALUES (
                client_key, order_key, delivery_time, review_target,
                review_type, 'Test review', 3 + (i + j) % 3
            );
        END LOOP;

        -- Apply each month's coefficient before calculating the next one.
        coefficient_for_month := 0.1;
        FOR pay_period IN
            SELECT m.month_start,
                   coalesce(d.delivery_count, 0) AS delivery_count,
                   coalesce(d.commission_sum, 0) AS commission_sum
            FROM generate_series(first_month, current_month, interval '1 month') m(month_start)
            LEFT JOIN (
                SELECT date_trunc('month', delivery_timestamp) AS month_start,
                       count(*) AS delivery_count,
                       sum(commission) AS commission_sum
                FROM levykin_food."order"
                WHERE courier_id = courier_key
                  AND status = order_states[4]
                GROUP BY date_trunc('month', delivery_timestamp)
            ) d USING (month_start)
            ORDER BY m.month_start
        LOOP
            INSERT INTO levykin_food.courier_pay
                (year, month, courier_id, amount, coefficient_used)
            VALUES (
                extract(year FROM pay_period.month_start)::int,
                extract(month FROM pay_period.month_start)::int,
                courier_key,
                round(coefficient_for_month * pay_period.commission_sum, 2),
                coefficient_for_month
            );

            coefficient_for_month := CASE
                WHEN pay_period.delivery_count <= 150 THEN 0.1
                WHEN pay_period.delivery_count <= 250 THEN 0.2
                WHEN pay_period.delivery_count <= 500 THEN 0.3
                ELSE 0.5
            END;
        END LOOP;

        IF courier_state <> 'уволен' THEN
            UPDATE levykin_food.courier
            SET coefficient = coefficient_for_month
            WHERE courier_id = courier_key;
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE levykin_food.erase_test_data()
LANGUAGE sql
AS $$
    TRUNCATE TABLE
        levykin_food.review,
        levykin_food.payment,
        levykin_food.order_structure,
        levykin_food."order",
        levykin_food.client_address,
        levykin_food.courier_pay,
        levykin_food.product,
        levykin_food.restaurant,
        levykin_food.product_category,
        levykin_food.address,
        levykin_food.client,
        levykin_food.courier;
$$;

CREATE OR REPLACE PROCEDURE levykin_food.add_product(
    p_restaurant_id uuid,
    p_product_category_id uuid,
    p_name varchar,
    p_price numeric,
    p_rating numeric,
    p_status levykin_food.product_status,
    p_description text,
    p_photo_url text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_rating NOT BETWEEN 0 AND 5 THEN
        RAISE EXCEPTION 'Product rating must be between 0 and 5'
            USING ERRCODE = '23514';
    END IF;

    -- A new product has no reviews, so its aggregate rating starts as NULL.
    INSERT INTO levykin_food.product (
        restaurant_id, product_category_id, product_name, price,
        status, description, photo_url
    )
    VALUES (
        p_restaurant_id, p_product_category_id, p_name, p_price,
        p_status, p_description, p_photo_url
    );
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Restaurant or product category does not exist'
            USING ERRCODE = '23503', DETAIL = SQLERRM;
    WHEN check_violation THEN
        RAISE EXCEPTION 'Product price must be nonnegative and rating must be between 0 and 5'
            USING ERRCODE = '23514', DETAIL = SQLERRM;
END;
$$;

-- FOOD-106. Restaurant statistics.

CREATE FUNCTION levykin_food.get_statistic()
RETURNS TABLE (
    restaurant_name text,
    best_product_name text,
    total_amount numeric,
    avg_amount numeric,
    best_user text
)
LANGUAGE sql
AS $$
    WITH delivered AS MATERIALIZED (
        SELECT o.order_id, o.restaurant_id, o.client_id, o.total_amount
        FROM levykin_food."order" o
        WHERE o.status = 'доставлен'
    ),
    restaurant_totals AS (
        SELECT
            d.restaurant_id,
            SUM(d.total_amount) AS total_amount,
            AVG(d.total_amount) AS avg_amount
        FROM delivered d
        GROUP BY d.restaurant_id
    ),
    best_products AS (
        SELECT DISTINCT ON (d.restaurant_id)
            d.restaurant_id,
            s.product_id
        FROM delivered d
        JOIN levykin_food.order_structure s ON s.order_id = d.order_id
        GROUP BY d.restaurant_id, s.product_id
        ORDER BY d.restaurant_id, SUM(s.quantity) DESC, random()
    ),
    best_clients AS (
        SELECT DISTINCT ON (d.restaurant_id)
            d.restaurant_id,
            d.client_id
        FROM delivered d
        GROUP BY d.restaurant_id, d.client_id
        ORDER BY d.restaurant_id, COUNT(*) DESC, random()
    )
    SELECT
        r.restaurant_name::text,
        p.product_name::text,
        COALESCE(t.total_amount, 0::numeric),
        t.avg_amount,
        c.login::text
    FROM levykin_food.restaurant r
    LEFT JOIN restaurant_totals t ON t.restaurant_id = r.restaurant_id
    LEFT JOIN best_products bp ON bp.restaurant_id = r.restaurant_id
    LEFT JOIN levykin_food.product p ON p.product_id = bp.product_id
    LEFT JOIN best_clients bc ON bc.restaurant_id = r.restaurant_id
    LEFT JOIN levykin_food.client c ON c.client_id = bc.client_id;
$$;

-- FOOD-107. Keep the coefficient originally applied when recomputing a payout.
CREATE OR REPLACE PROCEDURE levykin_food.courier_salary()
LANGUAGE plpgsql
AS $$
DECLARE
    period_start timestamp := date_trunc('month', localtimestamp);
    period_end timestamp := period_start + INTERVAL '1 month';
    period_year integer := EXTRACT(YEAR FROM period_start);
    period_month integer := EXTRACT(MONTH FROM period_start);
BEGIN
    PERFORM 1
    FROM levykin_food.courier
    ORDER BY courier_id
    FOR NO KEY UPDATE;

    WITH deliveries AS MATERIALIZED (
        SELECT
            o.courier_id,
            COUNT(*) AS delivery_count,
            SUM(o.commission) AS commission_sum
        FROM levykin_food."order" o
        WHERE o.status = 'доставлен'
            AND o.delivery_timestamp >= period_start
            AND o.delivery_timestamp < period_end
        GROUP BY o.courier_id
    ),
    payout_inputs AS (
        SELECT
            c.courier_id,
            COALESCE(prior.coefficient_used, c.coefficient) AS coefficient_used,
            COALESCE(d.commission_sum, 0) AS commission_sum
        FROM levykin_food.courier c
        LEFT JOIN deliveries d ON d.courier_id = c.courier_id
        LEFT JOIN levykin_food.courier_pay prior
            ON prior.courier_id = c.courier_id
            AND prior.year = period_year
            AND prior.month = period_month
    ),
    saved_payouts AS (
        INSERT INTO levykin_food.courier_pay
            (year, month, courier_id, amount, coefficient_used)
        SELECT
            period_year,
            period_month,
            courier_id,
            ROUND(coefficient_used * commission_sum, 2),
            coefficient_used
        FROM payout_inputs
        ON CONFLICT (year, month, courier_id) DO UPDATE
        SET amount = EXCLUDED.amount
        RETURNING courier_id
    )
    UPDATE levykin_food.courier c
    SET coefficient = CASE
        WHEN COALESCE(d.delivery_count, 0) <= 150 THEN 0.1
        WHEN d.delivery_count <= 250 THEN 0.2
        WHEN d.delivery_count <= 500 THEN 0.3
        ELSE 0.5
    END
    FROM saved_payouts p
    LEFT JOIN deliveries d ON d.courier_id = p.courier_id
    WHERE c.courier_id = p.courier_id
        AND c.status <> 'уволен';
END;
$$;

-- FOOD-108. Keep missing months and compare commissions to the previous calendar month.
CREATE OR REPLACE VIEW levykin_food.how_much_money AS
WITH RECURSIVE delivered_totals AS (
    SELECT
        date_trunc('month', o.delivery_timestamp)::date AS month_start,
        SUM(o.order_amount) AS sum_no_commission,
        SUM(o.total_amount) AS sum_with_commission
    FROM levykin_food."order" o
    WHERE o.status = 'доставлен'
    GROUP BY 1
),
bounds AS (
    SELECT MIN(month_start) AS first_month, MAX(month_start) AS last_month
    FROM delivered_totals
),
months (month_start, last_month) AS (
    SELECT first_month, last_month
    FROM bounds
    WHERE first_month IS NOT NULL

    UNION ALL

    SELECT (m.month_start + INTERVAL '1 month')::date, m.last_month
    FROM months m
    WHERE m.month_start < m.last_month
),
payout_totals AS (
    SELECT make_date(year, month, 1) AS month_start, SUM(amount) AS courier_pay
    FROM levykin_food.courier_pay
    GROUP BY 1
),
amounts AS (
    SELECT
        m.month_start,
        COALESCE(d.sum_no_commission, 0::numeric) AS sum_no_commission,
        COALESCE(d.sum_with_commission, 0::numeric) AS sum_with_commission,
        COALESCE(d.sum_with_commission - d.sum_no_commission, 0::numeric) AS commission,
        COALESCE(p.courier_pay, 0::numeric) AS courier_pay
    FROM months m
    LEFT JOIN delivered_totals d ON d.month_start = m.month_start
    LEFT JOIN payout_totals p ON p.month_start = m.month_start
),
with_previous AS (
    SELECT amounts.*, LAG(commission) OVER (ORDER BY month_start) AS prev_commission
    FROM amounts
)
SELECT
    to_char(month_start, 'YYYY-MM') AS year_month,
    sum_no_commission,
    sum_with_commission,
    commission,
    prev_commission,
    commission - prev_commission AS commission_diff,
    courier_pay,
    commission - courier_pay AS net_profit
FROM with_previous
ORDER BY month_start;

COMMIT;
