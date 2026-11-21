--
-- PostgreSQL database dump
--

-- Dumped from database version 17.2
-- Dumped by pg_dump version 17.2

-- Started on 2026-11-21 19:43:40

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 5 (class 2615 OID 17128)
-- Name: levykin_food; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA levykin_food;


--
-- TOC entry 911 (class 1247 OID 17232)
-- Name: courier_status; Type: TYPE; Schema: levykin_food; Owner: -
--

CREATE TYPE levykin_food.courier_status AS ENUM (
    'свободен',
    'занят',
    'на_доставке',
    'уволен'
);


--
-- TOC entry 923 (class 1247 OID 17280)
-- Name: order_pay_status; Type: TYPE; Schema: levykin_food; Owner: -
--

CREATE TYPE levykin_food.order_pay_status AS ENUM (
    'ожидает',
    'оплачен',
    'ошибка'
);


--
-- TOC entry 920 (class 1247 OID 17268)
-- Name: order_status; Type: TYPE; Schema: levykin_food; Owner: -
--

CREATE TYPE levykin_food.order_status AS ENUM (
    'создан',
    'готовится',
    'в_доставке',
    'доставлен',
    'отменён'
);


--
-- TOC entry 935 (class 1247 OID 17352)
-- Name: payment_status; Type: TYPE; Schema: levykin_food; Owner: -
--

CREATE TYPE levykin_food.payment_status AS ENUM (
    'успех',
    'ошибка',
    'в_обработке'
);


--
-- TOC entry 932 (class 1247 OID 17344)
-- Name: payment_type; Type: TYPE; Schema: levykin_food; Owner: -
--

CREATE TYPE levykin_food.payment_type AS ENUM (
    'карта',
    'наличные',
    'безнал'
);


--
-- TOC entry 905 (class 1247 OID 17205)
-- Name: product_status; Type: TYPE; Schema: levykin_food; Owner: -
--

CREATE TYPE levykin_food.product_status AS ENUM (
    'доступно',
    'нет_в_наличии',
    'архив'
);


--
-- TOC entry 896 (class 1247 OID 17177)
-- Name: restaurant_status; Type: TYPE; Schema: levykin_food; Owner: -
--

CREATE TYPE levykin_food.restaurant_status AS ENUM (
    'активен',
    'неактивен'
);


--
-- TOC entry 941 (class 1247 OID 17376)
-- Name: review_entity_type; Type: TYPE; Schema: levykin_food; Owner: -
--

CREATE TYPE levykin_food.review_entity_type AS ENUM (
    'блюдо',
    'ресторан',
    'заказ'
);


--
-- TOC entry 262 (class 1255 OID 17423)
-- Name: add_product(uuid, uuid, character varying, numeric, numeric, levykin_food.product_status, text, text); Type: PROCEDURE; Schema: levykin_food; Owner: -
--

CREATE PROCEDURE levykin_food.add_product(IN p_restaurant_id uuid, IN p_product_category_id uuid, IN p_name character varying, IN p_price numeric, IN p_rating numeric, IN p_status levykin_food.product_status, IN p_description text, IN p_photo_url text DEFAULT NULL::text)
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


--
-- TOC entry 260 (class 1255 OID 17428)
-- Name: check_order_has_items(); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.check_order_has_items() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    checked_order_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'order' THEN
        checked_order_id := NEW.order_id;
    ELSE
        checked_order_id := OLD.order_id;

        -- Serialize concurrent removals from the same order.
        UPDATE levykin_food."order" o
        SET description = o.description
        WHERE o.order_id = checked_order_id;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM levykin_food."order"
        WHERE order_id = checked_order_id
    ) AND NOT EXISTS (
        SELECT 1
        FROM levykin_food.order_structure
        WHERE order_id = checked_order_id
    ) THEN
        RAISE EXCEPTION 'Order % must contain at least one item', checked_order_id
            USING ERRCODE = '23514';
    END IF;

    RETURN NULL;
END;
$$;


--
-- TOC entry 257 (class 1255 OID 17411)
-- Name: check_order_product_restaurant(); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.check_order_product_restaurant() RETURNS trigger
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


--
-- TOC entry 258 (class 1255 OID 17413)
-- Name: check_restaurant_change(); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.check_restaurant_change() RETURNS trigger
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


--
-- TOC entry 259 (class 1255 OID 17416)
-- Name: check_review_target(); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.check_review_target() RETURNS trigger
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


--
-- TOC entry 263 (class 1255 OID 17436)
-- Name: courier_salary(); Type: PROCEDURE; Schema: levykin_food; Owner: -
--

CREATE PROCEDURE levykin_food.courier_salary()
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
            AND o.order_timestamp >= period_start
            AND o.order_timestamp < period_end
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


--
-- TOC entry 261 (class 1255 OID 17422)
-- Name: erase_test_data(); Type: PROCEDURE; Schema: levykin_food; Owner: -
--

CREATE PROCEDURE levykin_food.erase_test_data()
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


--
-- TOC entry 264 (class 1255 OID 17450)
-- Name: expected_order_pay_status(uuid); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.expected_order_pay_status(p_order_id uuid) RETURNS levykin_food.order_pay_status
    LANGUAGE sql
    AS $$
    SELECT (
        CASE
            WHEN bool_or(p.status = 'успех') THEN 'оплачен'
            WHEN bool_or(p.status = 'в_обработке') THEN 'ожидает'
            WHEN bool_or(p.status = 'ошибка') THEN 'ошибка'
            ELSE 'ожидает'
        END
    )::levykin_food.order_pay_status
    FROM levykin_food.payment p
    WHERE p.order_id = p_order_id;
$$;


--
-- TOC entry 267 (class 1255 OID 17446)
-- Name: get_statistic(); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.get_statistic() RETURNS TABLE(restaurant_name text, best_product_name text, total_amount numeric, avg_amount numeric, best_user text)
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


--
-- TOC entry 244 (class 1255 OID 17451)
-- Name: guard_order_pay_status(); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.guard_order_pay_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
        IF TG_OP = 'INSERT' THEN
            NEW.pay_status := 'ожидает';
        ELSIF NEW.pay_status IS DISTINCT FROM
            levykin_food.expected_order_pay_status(NEW.order_id) THEN
            RAISE EXCEPTION 'Order payment status does not match payment attempts'
                USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
    END;
    $$;


--
-- TOC entry 256 (class 1255 OID 17420)
-- Name: insert_test_data(integer); Type: PROCEDURE; Schema: levykin_food; Owner: -
--

CREATE PROCEDURE levykin_food.insert_test_data(IN value integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
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
    review_rating numeric;
    coefficient_for_month numeric;
    pay_period record;
BEGIN
    IF value IS NULL OR value < 0 THEN
        RAISE EXCEPTION 'value must be a nonnegative integer'
            USING ERRCODE = '22023';
    END IF;

    IF value = 0 THEN
        RETURN;
    END IF;

    -- Keep the review checks active while the generator sets ratings itself.
    ALTER TABLE levykin_food.review DISABLE TRIGGER rating_change;

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
            review_rating := 3 + (i + j) % 3;

            INSERT INTO levykin_food.review (
                client_id, order_id, review_timestamp, entity_id,
                entity_type, description, rating
            )
            VALUES (
                client_key, order_key, delivery_time, review_target,
                review_type, 'Test review', review_rating
            );

            -- Each generated product is new and has at most one review.
            IF review_type = 'блюдо' THEN
                UPDATE levykin_food.product
                SET rating = review_rating
                WHERE product_id = product_key;
            END IF;
        END LOOP;

        UPDATE levykin_food.restaurant
        SET rating = (
            SELECT AVG(r.rating)
            FROM levykin_food.review AS r
            WHERE r.entity_type = 'ресторан' AND r.entity_id = restaurant_key
        )
        WHERE restaurant_id = restaurant_key;

        -- Apply each month's coefficient before calculating the next one.
        coefficient_for_month := 0.1;
        FOR pay_period IN
            SELECT m.month_start,
                   coalesce(d.delivery_count, 0) AS delivery_count,
                   coalesce(d.commission_sum, 0) AS commission_sum
            FROM generate_series(first_month, current_month, interval '1 month') m(month_start)
            LEFT JOIN (
                SELECT date_trunc('month', order_timestamp) AS month_start,
                       count(*) AS delivery_count,
                       sum(commission) AS commission_sum
                FROM levykin_food."order"
                WHERE courier_id = courier_key
                  AND status = order_states[4]
                GROUP BY date_trunc('month', order_timestamp)
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

    ALTER TABLE levykin_food.review ENABLE TRIGGER rating_change;
END;
$$;

REVOKE EXECUTE ON PROCEDURE levykin_food.insert_test_data(integer) FROM PUBLIC;

--
-- TOC entry 266 (class 1255 OID 17418)
-- Name: rating_change(); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.rating_change() RETURNS trigger
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
            PERFORM 1
            FROM levykin_food.product
            WHERE product_id = target.entity_id
            FOR NO KEY UPDATE;

            UPDATE levykin_food.product
            SET rating = (
                SELECT AVG(r.rating)
                FROM levykin_food.review r
                WHERE r.entity_type = target.entity_type
                    AND r.entity_id = target.entity_id
            )
            WHERE product_id = target.entity_id;
        ELSIF target.entity_type = 'ресторан' THEN
            PERFORM 1
            FROM levykin_food.restaurant
            WHERE restaurant_id = target.entity_id
            FOR NO KEY UPDATE;

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


--
-- TOC entry 265 (class 1255 OID 17425)
-- Name: sync_order_pay_status(); Type: FUNCTION; Schema: levykin_food; Owner: -
--

CREATE FUNCTION levykin_food.sync_order_pay_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
        affected_order_ids uuid[];
    BEGIN
        affected_order_ids := CASE TG_OP
            WHEN 'INSERT' THEN ARRAY[NEW.order_id]
            WHEN 'DELETE' THEN ARRAY[OLD.order_id]
            ELSE ARRAY[OLD.order_id, NEW.order_id]
        END;

        PERFORM 1
        FROM levykin_food."order" o
        WHERE o.order_id = ANY(affected_order_ids)
        ORDER BY o.order_id
        FOR NO KEY UPDATE;

        UPDATE levykin_food."order" o
        SET pay_status = levykin_food.expected_order_pay_status(o.order_id)
        WHERE o.order_id = ANY(affected_order_ids);

        RETURN NULL;
    END;
    $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 222 (class 1259 OID 17151)
-- Name: address; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.address (
    address_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    street character varying(100) NOT NULL,
    house_number character varying(12) NOT NULL,
    apartment_office character varying(20)
);


--
-- TOC entry 221 (class 1259 OID 17141)
-- Name: client; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.client (
    client_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    login character varying(50) NOT NULL,
    phone_number character(12) NOT NULL,
    password character(32) NOT NULL
);


--
-- TOC entry 223 (class 1259 OID 17161)
-- Name: client_address; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.client_address (
    client_id uuid NOT NULL,
    address_id uuid NOT NULL
);


--
-- TOC entry 227 (class 1259 OID 17241)
-- Name: courier; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.courier (
    courier_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    fio character varying(150) NOT NULL,
    phone_number character(12) NOT NULL,
    status levykin_food.courier_status NOT NULL,
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric DEFAULT 0.1 NOT NULL,
    CONSTRAINT courier_check CHECK (((status = 'уволен'::levykin_food.courier_status) = (dismissal_date IS NOT NULL))),
    CONSTRAINT courier_coefficient_check CHECK (((coefficient >= 0.1) AND (coefficient <= 0.5))),
    CONSTRAINT courier_dismissal_not_before_hire CHECK (((dismissal_date IS NULL) OR (dismissal_date >= hire_date)))
);


--
-- TOC entry 228 (class 1259 OID 17252)
-- Name: courier_pay; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.courier_pay (
    year integer NOT NULL,
    month integer NOT NULL,
    courier_id uuid NOT NULL,
    amount numeric NOT NULL,
    coefficient_used numeric NOT NULL,
    CONSTRAINT courier_pay_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT courier_pay_coefficient_used_check CHECK (((coefficient_used >= 0.1) AND (coefficient_used <= 0.5))),
    CONSTRAINT courier_pay_month_check CHECK (((month >= 1) AND (month <= 12)))
);


--
-- TOC entry 229 (class 1259 OID 17287)
-- Name: order; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food."order" (
    order_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    courier_id uuid NOT NULL,
    client_id uuid NOT NULL,
    address_id uuid NOT NULL,
    restaurant_id uuid NOT NULL,
    order_timestamp timestamp without time zone NOT NULL,
    delivery_timestamp timestamp without time zone,
    order_amount numeric NOT NULL,
    commission numeric NOT NULL,
    total_amount numeric NOT NULL,
    status levykin_food.order_status NOT NULL,
    pay_status levykin_food.order_pay_status NOT NULL,
    description text NOT NULL,
    CONSTRAINT order_check CHECK ((commission = (order_amount * 0.10))),
    CONSTRAINT order_check1 CHECK ((total_amount = (order_amount + commission))),
    CONSTRAINT order_check2 CHECK ((delivery_timestamp >= order_timestamp)),
    CONSTRAINT order_check3 CHECK (((status <> 'доставлен'::levykin_food.order_status) OR (delivery_timestamp IS NOT NULL))),
    CONSTRAINT order_total_amount_check CHECK ((total_amount >= (1000)::numeric))
);


--
-- TOC entry 233 (class 1259 OID 17437)
-- Name: how_much_money; Type: VIEW; Schema: levykin_food; Owner: -
--

CREATE VIEW levykin_food.how_much_money AS
 WITH RECURSIVE delivered_totals AS (
         SELECT (date_trunc('month'::text, o.order_timestamp))::date AS month_start,
            sum(o.order_amount) AS sum_no_commission,
            sum(o.total_amount) AS sum_with_commission
           FROM levykin_food."order" o
          WHERE (o.status = 'доставлен'::levykin_food.order_status)
          GROUP BY ((date_trunc('month'::text, o.order_timestamp))::date)
        ), bounds AS (
         SELECT min(delivered_totals.month_start) AS first_month,
            max(delivered_totals.month_start) AS last_month
           FROM delivered_totals
        ), months(month_start, last_month) AS (
         SELECT bounds.first_month,
            bounds.last_month
           FROM bounds
          WHERE (bounds.first_month IS NOT NULL)
        UNION ALL
         SELECT ((m.month_start + '1 mon'::interval))::date AS date,
            m.last_month
           FROM months m
          WHERE (m.month_start < m.last_month)
        ), payout_totals AS (
         SELECT make_date(courier_pay.year, courier_pay.month, 1) AS month_start,
            sum(courier_pay.amount) AS courier_pay
           FROM levykin_food.courier_pay
          GROUP BY (make_date(courier_pay.year, courier_pay.month, 1))
        ), amounts AS (
         SELECT m.month_start,
            COALESCE(d.sum_no_commission, (0)::numeric) AS sum_no_commission,
            COALESCE(d.sum_with_commission, (0)::numeric) AS sum_with_commission,
            COALESCE((d.sum_with_commission - d.sum_no_commission), (0)::numeric) AS commission,
            COALESCE(p.courier_pay, (0)::numeric) AS courier_pay
           FROM ((months m
             LEFT JOIN delivered_totals d ON ((d.month_start = m.month_start)))
             LEFT JOIN payout_totals p ON ((p.month_start = m.month_start)))
        ), with_previous AS (
         SELECT amounts.month_start,
            amounts.sum_no_commission,
            amounts.sum_with_commission,
            amounts.commission,
            amounts.courier_pay,
            lag(amounts.commission) OVER (ORDER BY amounts.month_start) AS prev_commission
           FROM amounts
        )
 SELECT to_char((month_start)::timestamp with time zone, 'YYYY-MM'::text) AS year_month,
    sum_no_commission,
    sum_with_commission,
    commission,
    prev_commission,
    (commission - prev_commission) AS commission_diff,
    courier_pay,
    (commission - courier_pay) AS net_profit
   FROM with_previous
  ORDER BY month_start;


--
-- TOC entry 230 (class 1259 OID 17325)
-- Name: order_structure; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.order_structure (
    order_id uuid NOT NULL,
    product_id uuid NOT NULL,
    quantity numeric NOT NULL,
    CONSTRAINT order_structure_quantity_check CHECK ((quantity > (0)::numeric))
);


--
-- TOC entry 231 (class 1259 OID 17359)
-- Name: payment; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.payment (
    payment_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    order_id uuid NOT NULL,
    payment_type levykin_food.payment_type NOT NULL,
    amount numeric NOT NULL,
    transaction_id uuid NOT NULL,
    transaction_timestamp timestamp without time zone NOT NULL,
    status levykin_food.payment_status NOT NULL
);


--
-- TOC entry 226 (class 1259 OID 17211)
-- Name: product; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.product (
    product_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    product_name character varying(100) NOT NULL,
    product_category_id uuid NOT NULL,
    restaurant_id uuid NOT NULL,
    price numeric NOT NULL,
    description text NOT NULL,
    photo_url text,
    rating numeric,
    status levykin_food.product_status NOT NULL,
    CONSTRAINT product_price_check CHECK ((price >= (0)::numeric)),
    CONSTRAINT product_rating_check CHECK (((rating >= (0)::numeric) AND (rating <= (5)::numeric)))
);


--
-- TOC entry 225 (class 1259 OID 17198)
-- Name: product_category; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.product_category (
    product_category_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    product_category_name character varying(100) NOT NULL
);


--
-- TOC entry 224 (class 1259 OID 17181)
-- Name: restaurant; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.restaurant (
    restaurant_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    restaurant_name character varying(100) NOT NULL,
    address_id uuid NOT NULL,
    description text NOT NULL,
    work_start time without time zone NOT NULL,
    work_end time without time zone NOT NULL,
    company_details text NOT NULL,
    rating numeric,
    status levykin_food.restaurant_status NOT NULL,
    CONSTRAINT restaurant_check CHECK ((work_end > work_start)),
    CONSTRAINT restaurant_rating_check CHECK (((rating >= (0)::numeric) AND (rating <= (5)::numeric)))
);


--
-- TOC entry 232 (class 1259 OID 17383)
-- Name: review; Type: TABLE; Schema: levykin_food; Owner: -
--

CREATE TABLE levykin_food.review (
    review_id uuid DEFAULT exts.uuid_generate_v4() NOT NULL,
    client_id uuid NOT NULL,
    order_id uuid NOT NULL,
    review_timestamp timestamp without time zone NOT NULL,
    entity_id uuid NOT NULL,
    entity_type levykin_food.review_entity_type NOT NULL,
    description text NOT NULL,
    photo_url text,
    rating numeric NOT NULL,
    CONSTRAINT review_rating_check CHECK (((rating >= (1)::numeric) AND (rating <= (5)::numeric)))
);


--
-- TOC entry 4876 (class 2606 OID 17156)
-- Name: address address_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.address
    ADD CONSTRAINT address_pkey PRIMARY KEY (address_id);


--
-- TOC entry 4878 (class 2606 OID 17165)
-- Name: client_address client_address_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.client_address
    ADD CONSTRAINT client_address_pkey PRIMARY KEY (client_id, address_id);


--
-- TOC entry 4870 (class 2606 OID 17148)
-- Name: client client_login_key; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.client
    ADD CONSTRAINT client_login_key UNIQUE (login);


--
-- TOC entry 4872 (class 2606 OID 17150)
-- Name: client client_phone_number_key; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.client
    ADD CONSTRAINT client_phone_number_key UNIQUE (phone_number);


--
-- TOC entry 4874 (class 2606 OID 17146)
-- Name: client client_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.client
    ADD CONSTRAINT client_pkey PRIMARY KEY (client_id);


--
-- TOC entry 4890 (class 2606 OID 17261)
-- Name: courier_pay courier_pay_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.courier_pay
    ADD CONSTRAINT courier_pay_pkey PRIMARY KEY (year, month, courier_id);


--
-- TOC entry 4888 (class 2606 OID 17251)
-- Name: courier courier_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.courier
    ADD CONSTRAINT courier_pkey PRIMARY KEY (courier_id);


--
-- TOC entry 4892 (class 2606 OID 17405)
-- Name: order order_id_total_amount_key; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food."order"
    ADD CONSTRAINT order_id_total_amount_key UNIQUE (order_id, total_amount);


--
-- TOC entry 4894 (class 2606 OID 17299)
-- Name: order order_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food."order"
    ADD CONSTRAINT order_pkey PRIMARY KEY (order_id);


--
-- TOC entry 4896 (class 2606 OID 17332)
-- Name: order_structure order_structure_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.order_structure
    ADD CONSTRAINT order_structure_pkey PRIMARY KEY (order_id, product_id);


--
-- TOC entry 4899 (class 2606 OID 17366)
-- Name: payment payment_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.payment
    ADD CONSTRAINT payment_pkey PRIMARY KEY (payment_id);


--
-- TOC entry 4901 (class 2606 OID 17368)
-- Name: payment payment_transaction_id_key; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.payment
    ADD CONSTRAINT payment_transaction_id_key UNIQUE (transaction_id);


--
-- TOC entry 4884 (class 2606 OID 17203)
-- Name: product_category product_category_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.product_category
    ADD CONSTRAINT product_category_pkey PRIMARY KEY (product_category_id);


--
-- TOC entry 4886 (class 2606 OID 17220)
-- Name: product product_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.product
    ADD CONSTRAINT product_pkey PRIMARY KEY (product_id);


--
-- TOC entry 4880 (class 2606 OID 17192)
-- Name: restaurant restaurant_address_id_key; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.restaurant
    ADD CONSTRAINT restaurant_address_id_key UNIQUE (address_id);


--
-- TOC entry 4882 (class 2606 OID 17190)
-- Name: restaurant restaurant_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.restaurant
    ADD CONSTRAINT restaurant_pkey PRIMARY KEY (restaurant_id);


--
-- TOC entry 4903 (class 2606 OID 17393)
-- Name: review review_order_id_entity_type_entity_id_key; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.review
    ADD CONSTRAINT review_order_id_entity_type_entity_id_key UNIQUE (order_id, entity_type, entity_id);


--
-- TOC entry 4905 (class 2606 OID 17391)
-- Name: review review_pkey; Type: CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.review
    ADD CONSTRAINT review_pkey PRIMARY KEY (review_id);


--
-- TOC entry 4897 (class 1259 OID 17374)
-- Name: payment_one_success_per_order; Type: INDEX; Schema: levykin_food; Owner: -
--

CREATE UNIQUE INDEX payment_one_success_per_order ON levykin_food.payment USING btree (order_id) WHERE (status = 'успех'::levykin_food.payment_status);


--
-- TOC entry 4924 (class 2620 OID 17429)
-- Name: order check_new_order_has_items; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE CONSTRAINT TRIGGER check_new_order_has_items AFTER INSERT OR UPDATE OF order_id ON levykin_food."order" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION levykin_food.check_order_has_items();


--
-- TOC entry 4927 (class 2620 OID 17431)
-- Name: order_structure check_order_has_items_after_item_removal; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE CONSTRAINT TRIGGER check_order_has_items_after_item_removal AFTER DELETE OR UPDATE OF order_id ON levykin_food.order_structure DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION levykin_food.check_order_has_items();


--
-- TOC entry 4928 (class 2620 OID 17412)
-- Name: order_structure check_order_product_restaurant; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE TRIGGER check_order_product_restaurant BEFORE INSERT OR UPDATE OF order_id, product_id ON levykin_food.order_structure FOR EACH ROW EXECUTE FUNCTION levykin_food.check_order_product_restaurant();


--
-- TOC entry 4925 (class 2620 OID 17414)
-- Name: order check_order_restaurant_change; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE TRIGGER check_order_restaurant_change AFTER UPDATE OF restaurant_id ON levykin_food."order" FOR EACH ROW WHEN ((old.restaurant_id IS DISTINCT FROM new.restaurant_id)) EXECUTE FUNCTION levykin_food.check_restaurant_change();


--
-- TOC entry 4923 (class 2620 OID 17415)
-- Name: product check_product_restaurant_change; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE TRIGGER check_product_restaurant_change AFTER UPDATE OF restaurant_id ON levykin_food.product FOR EACH ROW WHEN ((old.restaurant_id IS DISTINCT FROM new.restaurant_id)) EXECUTE FUNCTION levykin_food.check_restaurant_change();


--
-- TOC entry 4930 (class 2620 OID 17417)
-- Name: review check_review_target; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE TRIGGER check_review_target BEFORE INSERT OR UPDATE OF client_id, order_id, entity_type, entity_id ON levykin_food.review FOR EACH ROW EXECUTE FUNCTION levykin_food.check_review_target();


--
-- TOC entry 4926 (class 2620 OID 17452)
-- Name: order guard_order_pay_status; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE TRIGGER guard_order_pay_status BEFORE INSERT OR UPDATE OF pay_status ON levykin_food."order" FOR EACH ROW EXECUTE FUNCTION levykin_food.guard_order_pay_status();


--
-- TOC entry 4931 (class 2620 OID 17445)
-- Name: review rating_change; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE TRIGGER rating_change AFTER INSERT OR DELETE OR UPDATE ON levykin_food.review FOR EACH ROW EXECUTE FUNCTION levykin_food.rating_change();


--
-- TOC entry 4929 (class 2620 OID 17426)
-- Name: payment sync_order_pay_status; Type: TRIGGER; Schema: levykin_food; Owner: -
--

CREATE TRIGGER sync_order_pay_status AFTER INSERT OR DELETE OR UPDATE OF status, order_id ON levykin_food.payment FOR EACH ROW EXECUTE FUNCTION levykin_food.sync_order_pay_status();


--
-- TOC entry 4906 (class 2606 OID 17171)
-- Name: client_address client_address_address_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.client_address
    ADD CONSTRAINT client_address_address_id_fkey FOREIGN KEY (address_id) REFERENCES levykin_food.address(address_id);


--
-- TOC entry 4907 (class 2606 OID 17166)
-- Name: client_address client_address_client_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.client_address
    ADD CONSTRAINT client_address_client_id_fkey FOREIGN KEY (client_id) REFERENCES levykin_food.client(client_id);


--
-- TOC entry 4911 (class 2606 OID 17262)
-- Name: courier_pay courier_pay_courier_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.courier_pay
    ADD CONSTRAINT courier_pay_courier_id_fkey FOREIGN KEY (courier_id) REFERENCES levykin_food.courier(courier_id);


--
-- TOC entry 4912 (class 2606 OID 17310)
-- Name: order order_address_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food."order"
    ADD CONSTRAINT order_address_id_fkey FOREIGN KEY (address_id) REFERENCES levykin_food.address(address_id);


--
-- TOC entry 4913 (class 2606 OID 17320)
-- Name: order order_client_id_address_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food."order"
    ADD CONSTRAINT order_client_id_address_id_fkey FOREIGN KEY (client_id, address_id) REFERENCES levykin_food.client_address(client_id, address_id);


--
-- TOC entry 4914 (class 2606 OID 17305)
-- Name: order order_client_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food."order"
    ADD CONSTRAINT order_client_id_fkey FOREIGN KEY (client_id) REFERENCES levykin_food.client(client_id);


--
-- TOC entry 4915 (class 2606 OID 17300)
-- Name: order order_courier_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food."order"
    ADD CONSTRAINT order_courier_id_fkey FOREIGN KEY (courier_id) REFERENCES levykin_food.courier(courier_id);


--
-- TOC entry 4916 (class 2606 OID 17315)
-- Name: order order_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food."order"
    ADD CONSTRAINT order_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES levykin_food.restaurant(restaurant_id);


--
-- TOC entry 4917 (class 2606 OID 17333)
-- Name: order_structure order_structure_order_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.order_structure
    ADD CONSTRAINT order_structure_order_id_fkey FOREIGN KEY (order_id) REFERENCES levykin_food."order"(order_id);


--
-- TOC entry 4918 (class 2606 OID 17338)
-- Name: order_structure order_structure_product_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.order_structure
    ADD CONSTRAINT order_structure_product_id_fkey FOREIGN KEY (product_id) REFERENCES levykin_food.product(product_id);


--
-- TOC entry 4919 (class 2606 OID 17406)
-- Name: payment payment_order_amount_fk; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.payment
    ADD CONSTRAINT payment_order_amount_fk FOREIGN KEY (order_id, amount) REFERENCES levykin_food."order"(order_id, total_amount);


--
-- TOC entry 4920 (class 2606 OID 17369)
-- Name: payment payment_order_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.payment
    ADD CONSTRAINT payment_order_id_fkey FOREIGN KEY (order_id) REFERENCES levykin_food."order"(order_id);


--
-- TOC entry 4909 (class 2606 OID 17221)
-- Name: product product_product_category_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.product
    ADD CONSTRAINT product_product_category_id_fkey FOREIGN KEY (product_category_id) REFERENCES levykin_food.product_category(product_category_id);


--
-- TOC entry 4910 (class 2606 OID 17226)
-- Name: product product_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.product
    ADD CONSTRAINT product_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES levykin_food.restaurant(restaurant_id);


--
-- TOC entry 4908 (class 2606 OID 17193)
-- Name: restaurant restaurant_address_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.restaurant
    ADD CONSTRAINT restaurant_address_id_fkey FOREIGN KEY (address_id) REFERENCES levykin_food.address(address_id);


--
-- TOC entry 4921 (class 2606 OID 17394)
-- Name: review review_client_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.review
    ADD CONSTRAINT review_client_id_fkey FOREIGN KEY (client_id) REFERENCES levykin_food.client(client_id);


--
-- TOC entry 4922 (class 2606 OID 17399)
-- Name: review review_order_id_fkey; Type: FK CONSTRAINT; Schema: levykin_food; Owner: -
--

ALTER TABLE ONLY levykin_food.review
    ADD CONSTRAINT review_order_id_fkey FOREIGN KEY (order_id) REFERENCES levykin_food."order"(order_id);


-- Completed on 2026-11-21 19:43:40

--
-- PostgreSQL database dump complete
--

