/*
===============================================================================
 SQL DML HW - Task 1
 Author  : Ajiniyaz Begjanov
 Database: DVD rental database (schema: public)
===============================================================================
*/

/*------------------------------------------------------------------------------
 SUB-TASK 1. Add 3 favorite movies to public.film (and link them to genres)
 Condition: Choose your real top-3 favorite movies (released in different years, belong to
 different genres) and add them to the 'film' table. Fill in rental rates with 4.99, 9.99
 and 19.99 and rental durations with 1, 2 and 3 weeks respectively.
------------------------------------------------------------------------------*/

BEGIN;

INSERT INTO public.film (title, description, release_year, language_id, rental_duration,
                         rental_rate, length, rating, last_update, fulltext)
SELECT v.title,
       v.description,
       v.release_year,
       l.language_id,
       v.rental_duration,
       v.rental_rate,
       v.length,
       CAST(v.rating AS public.mpaa_rating),
       CURRENT_DATE,
       to_tsvector('english', v.title || ' ' || v.description)  -- fulltext is NOT NULL; the table trigger also maintains it
FROM (VALUES
        ('THE SHAWSHANK REDEMPTION',
         'Two imprisoned men bond over several years, finding solace and eventual redemption through acts of common decency.',
         1994, 7, 4.99, 142, 'R'),
        ('THE DARK KNIGHT',
         'Batman faces the Joker, a criminal mastermind who plunges Gotham City into anarchy.',
         2008, 14, 9.99, 152, 'PG-13'),
        ('INTERSTELLAR',
         'A team of explorers travels through a wormhole in space to ensure the survival of humanity.',
         2014, 21, 19.99, 169, 'PG-13')
     ) AS v(title, description, release_year, rental_duration, rental_rate, length, rating)
INNER JOIN public.language AS l          -- INNER JOIN: no English language row -> nothing inserted (no film without language)
        ON l.name = 'English'
WHERE NOT EXISTS (SELECT 1
                  FROM public.film AS f
                  WHERE UPPER(f.title) = v.title
                    AND f.release_year = v.release_year)
RETURNING film_id, title, release_year, rental_duration, rental_rate, rating, last_update;

INSERT INTO public.film_category (film_id, category_id, last_update)
SELECT f.film_id,
       c.category_id,
       CURRENT_DATE
FROM (VALUES
        ('THE SHAWSHANK REDEMPTION', 1994, 'Drama'),
        ('THE DARK KNIGHT',          2008, 'Action'),
        ('INTERSTELLAR',             2014, 'Sci-Fi')
     ) AS v(title, release_year, category_name)
INNER JOIN public.film AS f              -- INNER JOIN: only films that really exist get a link
        ON UPPER(f.title) = v.title
       AND f.release_year = v.release_year
INNER JOIN public.category AS c          -- INNER JOIN: only existing categories can be linked
        ON c.name = v.category_name
WHERE NOT EXISTS (SELECT 1
                  FROM public.film_category AS fc
                  WHERE fc.film_id = f.film_id
                    AND fc.category_id = c.category_id)
RETURNING film_id, category_id, last_update;

COMMIT;


/*------------------------------------------------------------------------------
 SUB-TASK 2. Add actors to public.actor and link them to the films in public.film_actor
 Condition: Add the real actors who play leading roles in your favorite movies to the
 'actor' and 'film_actor' tables (6 or more actors in total). You must decide how to identify
 actors that already exist in the system and how to avoid duplicates.
------------------------------------------------------------------------------*/
BEGIN;

INSERT INTO public.actor (first_name, last_name, last_update)
SELECT v.first_name,
       v.last_name,
       CURRENT_DATE
FROM (VALUES
        ('TIM',       'ROBBINS'),
        ('MORGAN',    'FREEMAN'),
        ('CHRISTIAN', 'BALE'),
        ('HEATH',     'LEDGER'),
        ('MATTHEW',   'MCCONAUGHEY'),
        ('ANNE',      'HATHAWAY')
     ) AS v(first_name, last_name)
WHERE NOT EXISTS (SELECT 1
                  FROM public.actor AS a
                  WHERE UPPER(a.first_name) = v.first_name
                    AND UPPER(a.last_name)  = v.last_name)
RETURNING actor_id, first_name, last_name, last_update;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT a.actor_id,
       f.film_id,
       CURRENT_DATE
FROM (VALUES
        ('THE SHAWSHANK REDEMPTION', 1994, 'TIM',       'ROBBINS'),
        ('THE SHAWSHANK REDEMPTION', 1994, 'MORGAN',    'FREEMAN'),
        ('THE DARK KNIGHT',          2008, 'CHRISTIAN', 'BALE'),
        ('THE DARK KNIGHT',          2008, 'HEATH',     'LEDGER'),
        ('INTERSTELLAR',             2014, 'MATTHEW',   'MCCONAUGHEY'),
        ('INTERSTELLAR',             2014, 'ANNE',      'HATHAWAY')
     ) AS v(title, release_year, first_name, last_name)
INNER JOIN public.film AS f              -- INNER JOIN: the film must exist
        ON UPPER(f.title) = v.title
       AND f.release_year = v.release_year
INNER JOIN public.actor AS a             -- INNER JOIN: the actor must exist
        ON UPPER(a.first_name) = v.first_name
       AND UPPER(a.last_name)  = v.last_name
WHERE NOT EXISTS (SELECT 1
                  FROM public.film_actor AS fa
                  WHERE fa.actor_id = a.actor_id
                    AND fa.film_id  = f.film_id)
RETURNING actor_id, film_id, last_update;

COMMIT;


/*------------------------------------------------------------------------------
 SUB-TASK 3. Add the favorite movies to a store's inventory
 Condition: Add your favorite movies to any store's inventory.
------------------------------------------------------------------------------*/
BEGIN;

INSERT INTO public.inventory (film_id, store_id, last_update)
SELECT f.film_id,
       s.store_id,
       CURRENT_DATE
FROM public.film AS f
CROSS JOIN (SELECT MIN(st.store_id) AS store_id    -- CROSS JOIN with a 1-row set: every film gets the same single store
            FROM public.store AS st) AS s
WHERE (UPPER(f.title), f.release_year) IN (('THE SHAWSHANK REDEMPTION', 1994),
                                           ('THE DARK KNIGHT',          2008),
                                           ('INTERSTELLAR',             2014))
  AND NOT EXISTS (SELECT 1
                  FROM public.inventory AS i
                  WHERE i.film_id  = f.film_id
                    AND i.store_id = s.store_id)
RETURNING inventory_id, film_id, store_id, last_update;

COMMIT;


/*------------------------------------------------------------------------------
 SUB-TASK 4. Change an existing customer (>= 43 rentals and >= 43 payments) to me
 Condition: Alter any existing customer in the database with at least 43 rental and 43
 payment records. Change their personal data to yours (first name, last name, address, etc.).
 You can use any existing address from the "address" table. Do not perform any updates on the
 "address" table.
------------------------------------------------------------------------------*/
BEGIN;

-- Check BEFORE the update: candidates and their number of rentals / payments
SELECT c.customer_id,
       c.first_name,
       c.last_name,
       (SELECT COUNT(*) FROM public.rental  AS r WHERE r.customer_id = c.customer_id) AS rentals,
       (SELECT COUNT(*) FROM public.payment AS p WHERE p.customer_id = c.customer_id) AS payments
FROM public.customer AS c
WHERE (SELECT COUNT(*) FROM public.rental  AS r WHERE r.customer_id = c.customer_id) >= 43
  AND (SELECT COUNT(*) FROM public.payment AS p WHERE p.customer_id = c.customer_id) >= 43
ORDER BY c.customer_id
LIMIT 5;

WITH me AS (                       -- already changed on a previous run?
    SELECT c.customer_id
    FROM public.customer AS c
    WHERE UPPER(c.first_name) = 'AJINIYAZ'
      AND UPPER(c.last_name)  = 'BEGJANOV'
    ORDER BY c.customer_id
    LIMIT 1
),
candidate AS (                     -- first customer with >= 43 rentals and >= 43 payments
    SELECT c.customer_id
    FROM public.customer AS c
    WHERE (SELECT COUNT(*) FROM public.rental  AS r WHERE r.customer_id = c.customer_id) >= 43
      AND (SELECT COUNT(*) FROM public.payment AS p WHERE p.customer_id = c.customer_id) >= 43
    ORDER BY c.customer_id
    LIMIT 1
),
target AS (
    SELECT COALESCE((SELECT customer_id FROM me),
                    (SELECT customer_id FROM candidate)) AS customer_id
),
new_address AS (                   -- existing address; unused ones first, then the smallest id
    SELECT a.address_id
    FROM public.address AS a
    CROSS JOIN target AS t
    WHERE a.address_id <> (SELECT cu.address_id FROM public.customer AS cu WHERE cu.customer_id = t.customer_id)
    ORDER BY (EXISTS (SELECT 1 FROM public.staff AS s2 WHERE s2.address_id = a.address_id)
              OR EXISTS (SELECT 1 FROM public.store AS st2 WHERE st2.address_id = a.address_id)),   -- not a staff / store address
             EXISTS (SELECT 1 FROM public.customer AS c2 WHERE c2.address_id = a.address_id),       -- then not used by another customer
             a.address_id
    LIMIT 1
)
UPDATE public.customer AS c
SET first_name  = 'AJINIYAZ',
    last_name   = 'BEGJANOV',
    email       = 'ajiniyaz.begjanov@example.com',
    address_id  = CASE WHEN EXISTS (SELECT 1 FROM me)
                       THEN c.address_id                                   -- rerun: keep the address chosen earlier
                       ELSE COALESCE((SELECT address_id FROM new_address), c.address_id)
                  END,
    last_update = CURRENT_DATE
FROM target AS t
WHERE c.customer_id = t.customer_id
RETURNING c.customer_id, c.first_name, c.last_name, c.email, c.address_id, c.last_update;

COMMIT;


/*------------------------------------------------------------------------------
 SUB-TASK 5. Delete all records related to me (as a customer) except Customer and Inventory
 Condition: Remove any records related to you (as a customer) from all tables except
 'Customer' and 'Inventory'.
------------------------------------------------------------------------------*/
BEGIN;

-- Check BEFORE the delete: how many rows will be removed (and that exactly one customer matches)
SELECT c.customer_id,
       (SELECT COUNT(*) FROM public.customer AS cc
        WHERE UPPER(cc.first_name) = 'AJINIYAZ' AND UPPER(cc.last_name) = 'BEGJANOV') AS customers_with_my_name,
       (SELECT COUNT(*) FROM public.rental  AS r WHERE r.customer_id = c.customer_id) AS rentals_to_delete,
       (SELECT COUNT(*) FROM public.payment AS p WHERE p.customer_id = c.customer_id) AS payments_to_delete
FROM public.customer AS c
WHERE UPPER(c.first_name) = 'AJINIYAZ'
  AND UPPER(c.last_name)  = 'BEGJANOV';

DELETE FROM public.payment AS p
USING public.customer AS c
WHERE p.customer_id = c.customer_id
  AND UPPER(c.first_name) = 'AJINIYAZ'
  AND UPPER(c.last_name)  = 'BEGJANOV'
  AND (SELECT COUNT(*) FROM public.customer AS cc
       WHERE UPPER(cc.first_name) = 'AJINIYAZ' AND UPPER(cc.last_name) = 'BEGJANOV') = 1
RETURNING p.payment_id, p.customer_id, p.rental_id, p.amount, p.payment_date;

DELETE FROM public.rental AS r
USING public.customer AS c
WHERE r.customer_id = c.customer_id
  AND UPPER(c.first_name) = 'AJINIYAZ'
  AND UPPER(c.last_name)  = 'BEGJANOV'
  AND (SELECT COUNT(*) FROM public.customer AS cc
       WHERE UPPER(cc.first_name) = 'AJINIYAZ' AND UPPER(cc.last_name) = 'BEGJANOV') = 1
RETURNING r.rental_id, r.customer_id, r.inventory_id, r.rental_date;

-- Check BEFORE commit: nothing of mine is left, the customer row is still there
SELECT c.customer_id,
       c.first_name,
       c.last_name,
       (SELECT COUNT(*) FROM public.rental  AS r WHERE r.customer_id = c.customer_id) AS rentals_left,
       (SELECT COUNT(*) FROM public.payment AS p WHERE p.customer_id = c.customer_id) AS payments_left
FROM public.customer AS c
WHERE UPPER(c.first_name) = 'AJINIYAZ'
  AND UPPER(c.last_name)  = 'BEGJANOV';

COMMIT;


/*------------------------------------------------------------------------------
 SUB-TASK 6. Rent my favorite movies from the store they are in and pay for them
 Condition: Rent your favorite movies from the store they are in and pay for them (add
 corresponding records to the database to represent this activity). (To insert payment_date
 into payment, create a new partition or add records for the first half of 2017.)
------------------------------------------------------------------------------*/
BEGIN;

INSERT INTO public.rental (rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT v.rental_date,
       i.inventory_id,
       c.customer_id,
       v.rental_date + INTERVAL '2 days',
       (SELECT MIN(st.staff_id)                       -- a staff member of the store where the film is
        FROM public.staff AS st
        WHERE st.store_id = i.store_id),
       CURRENT_DATE
FROM (VALUES
        ('THE SHAWSHANK REDEMPTION', 1994, TIMESTAMPTZ '2017-05-10 10:00:00+00'),
        ('THE DARK KNIGHT',          2008, TIMESTAMPTZ '2017-05-11 10:00:00+00'),
        ('INTERSTELLAR',             2014, TIMESTAMPTZ '2017-05-12 10:00:00+00')
     ) AS v(title, release_year, rental_date)
INNER JOIN public.film AS f                 -- INNER JOIN: only existing films can be rented
        ON UPPER(f.title) = v.title
       AND f.release_year = v.release_year
INNER JOIN public.inventory AS i            -- INNER JOIN: only films that are in a store's inventory; one copy per film
        ON i.film_id = f.film_id
       AND i.inventory_id = (SELECT MIN(i2.inventory_id)
                             FROM public.inventory AS i2
                             WHERE i2.film_id = f.film_id)
INNER JOIN public.customer AS c             -- INNER JOIN: the rental needs my customer row
        ON UPPER(c.first_name) = 'AJINIYAZ'
       AND UPPER(c.last_name)  = 'BEGJANOV'
WHERE NOT EXISTS (SELECT 1
                  FROM public.rental AS r
                  WHERE r.inventory_id = i.inventory_id
                    AND r.customer_id  = c.customer_id)
RETURNING rental_id, rental_date, inventory_id, customer_id, staff_id, return_date, last_update;

INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
SELECT r.customer_id,
       r.staff_id,
       r.rental_id,
       f.rental_rate,
       r.rental_date + INTERVAL '1 hour'
FROM public.rental AS r
INNER JOIN public.customer AS c             -- INNER JOIN: only rentals of my customer
        ON c.customer_id = r.customer_id
       AND UPPER(c.first_name) = 'AJINIYAZ'
       AND UPPER(c.last_name)  = 'BEGJANOV'
INNER JOIN public.inventory AS i            -- INNER JOIN: to get the film of the rental
        ON i.inventory_id = r.inventory_id
INNER JOIN public.film AS f                 -- INNER JOIN: only my three favorite films (the price comes from the film)
        ON f.film_id = i.film_id
WHERE (UPPER(f.title), f.release_year) IN (('THE SHAWSHANK REDEMPTION', 1994),
                                           ('THE DARK KNIGHT',          2008),
                                           ('INTERSTELLAR',             2014))
  AND NOT EXISTS (SELECT 1
                  FROM public.payment AS p
                  WHERE p.rental_id = r.rental_id)
RETURNING payment_id, customer_id, staff_id, rental_id, amount, payment_date;

COMMIT;
