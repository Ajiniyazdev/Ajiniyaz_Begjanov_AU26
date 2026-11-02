/*
===============================================================================
Schema used: public

GENERAL SCHEMA OVERVIEW
- Transactional tables:
    payment, rental
- Main entity / reference tables:
    film, actor, category, customer, staff, store, address, city, country,
    language
- Bridge / relationship tables:
    film_actor, film_category
- Inventory relationship:
    inventory connects a film copy to a store.
- Rental flow:
    payment -> rental -> inventory -> film/store
- Film/actor flow:
    actor -> film_actor -> film
- Film/category flow:
    film -> film_category -> category

===============================================================================
PART 1 - TASK 1
Show all Animation movies released from 2017 through 2019 with rate > 1.
Sort alphabetically.

BUSINESS ASSUMPTIONS
- "Rate" is interpreted as film.rental_rate.
- Both endpoints (2017 and 2019) are included.
- "Alphabetically" means film title ascending.
- The category must be exactly 'Animation'.

SOLUTION A - CTE
Advantages: separates filtering from relationship logic and is easy to extend.
Disadvantages: for a simple query, the CTE adds some extra structure and may
not improve performance; PostgreSQL may inline a non-materialized CTE.
*/
WITH animation_films AS (
    SELECT
        f.film_id,
        f.title,
        f.release_year,
        f.rental_rate
    FROM public.film AS f
    WHERE f.release_year BETWEEN 2017 AND 2019
      AND f.rental_rate > 1
)
SELECT
    af.title,
    af.release_year,
    af.rental_rate
FROM animation_films AS af
INNER JOIN public.film_category AS fc
    ON fc.film_id = af.film_id
INNER JOIN public.category AS c
    ON c.category_id = fc.category_id
WHERE c.name = 'Animation'
ORDER BY af.title ASC;

/*
SOLUTION B - SUBQUERY
Advantages: compact; filtering can be performed close to the film source.
Disadvantages: nested logic can become harder to read as complexity grows.
The IN subquery returns film IDs belonging to Animation.
*/
SELECT
    f.title,
    f.release_year,
    f.rental_rate
FROM public.film AS f
WHERE f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
  AND f.film_id IN (
      SELECT fc.film_id
      FROM public.film_category AS fc
      INNER JOIN public.category AS c
          ON c.category_id = fc.category_id
      WHERE c.name = 'Animation'
  )
ORDER BY f.title ASC;

/*
SOLUTION C - JOIN
Advantages: relationship logic is explicit and straightforward to inspect.
Disadvantages: joins may multiply rows if the relationship is not unique;
the Sakila film_category relationship is intended to assign a film to a
category, so duplicate output is not expected.
JOIN types:
- INNER JOIN keeps only films with a matching category relationship and
  the Animation category; films without such a match are excluded.
*/
SELECT
    f.title,
    f.release_year,
    f.rental_rate
FROM public.film AS f
INNER JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
INNER JOIN public.category AS c
    ON c.category_id = fc.category_id
WHERE f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
  AND c.name = 'Animation'
ORDER BY f.title ASC;

/*
PRODUCTION CHOICE:
Use Solution C (JOIN). The relationships are simple and explicit, and the
query is easy for another analyst to review. The CTE version is preferable
if the filtered film set is reused by several later steps.
*/


/*
===============================================================================
PART 1 - TASK 2
Calculate revenue earned by each rental store after March 2017.
Output: address and address2 as one column, revenue.

BUSINESS ASSUMPTIONS
- "After March 2017 (since April)" means payment_date >= DATE '2017-04-01'.
- Revenue is the sum of actual payment.amount.
- A payment is attributed to the store whose inventory item was rented.
- address2 is optional; NULL/empty values are handled without producing
  a NULL concatenation.
- Stores with no qualifying payments should still appear with revenue = 0.

SOLUTION A - CTE
Advantages: the payment aggregation is isolated and can be checked separately.
Disadvantages: more lines than a direct join; the CTE is only useful when the
intermediate aggregation improves readability or is reused.
*/
WITH store_revenue AS (
    SELECT
        i.store_id,
        SUM(p.amount) AS revenue
    FROM public.payment AS p
    INNER JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    WHERE p.payment_date >= TIMESTAMP '2017-04-01 00:00:00'
    GROUP BY i.store_id
)
SELECT
    s.store_id,
    CONCAT_WS(' ', a.address, NULLIF(a.address2, '')) AS store_address,
    COALESCE(sr.revenue, 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
LEFT JOIN store_revenue AS sr
    ON sr.store_id = s.store_id
ORDER BY revenue DESC, store_address ASC;

/*
SOLUTION B - SUBQUERY
Advantages: keeps the aggregation local to the store row and avoids a
separate named CTE.
Disadvantages: a correlated subquery may be harder to read and, depending
on the optimizer and data volume, may require repeated evaluation.
*/
SELECT
    s.store_id,
    CONCAT_WS(' ', a.address, NULLIF(a.address2, '')) AS store_address,
    COALESCE((
        SELECT SUM(p.amount)
        FROM public.payment AS p
        INNER JOIN public.rental AS r
            ON r.rental_id = p.rental_id
        INNER JOIN public.inventory AS i
            ON i.inventory_id = r.inventory_id
        WHERE i.store_id = s.store_id
          AND p.payment_date >= TIMESTAMP '2017-04-01 00:00:00'
    ), 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
ORDER BY revenue DESC, store_address ASC;

/*
SOLUTION C - JOIN
Advantages: all source relationships are visible in one FROM clause.
Disadvantages: aggregating after several joins requires careful grouping.
JOIN types:
- INNER JOIN from payment to rental and inventory keeps only payments
  connected to a rental and inventory item.
- LEFT JOIN from store to the qualifying transactions preserves stores
  with no revenue in the requested period; their SUM is converted to zero.
*/
SELECT
    s.store_id,
    CONCAT_WS(' ', a.address, NULLIF(a.address2, '')) AS store_address,
    COALESCE(SUM(p.amount), 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
LEFT JOIN public.inventory AS i
    ON i.store_id = s.store_id
LEFT JOIN public.rental AS r
    ON r.inventory_id = i.inventory_id
LEFT JOIN public.payment AS p
    ON p.rental_id = r.rental_id
   AND p.payment_date >= TIMESTAMP '2017-04-01 00:00:00'
GROUP BY
    s.store_id,
    a.address,
    a.address2
ORDER BY revenue DESC, store_address ASC;

/*
PRODUCTION CHOICE:
Use Solution A or C. The CTE version makes the revenue aggregation easy to
validate independently. The direct LEFT JOIN version is also appropriate
when the report must retain stores with zero revenue.
*/


/*
===============================================================================
PART 1 - TASK 3
Show the top 5 actors by number of movies released since 2015.
Output: first_name, last_name, number_of_movies.

BUSINESS ASSUMPTIONS
- "Since 2015" means release_year >= 2015, inclusive.
- Only films with a non-NULL release_year can satisfy this condition.
- Count distinct film IDs to avoid accidental double counting.
- Sort by movie count descending; names are tie-breakers.

SOLUTION A - CTE
Advantages: actor-film counts are calculated in a named intermediate result.
Disadvantages: additional query structure for a relatively small aggregation.
*/
WITH actor_movie_counts AS (
    SELECT
        fa.actor_id,
        COUNT(DISTINCT f.film_id) AS number_of_movies
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year >= 2015
    GROUP BY fa.actor_id
)
SELECT
    a.first_name,
    a.last_name,
    amc.number_of_movies
FROM actor_movie_counts AS amc
INNER JOIN public.actor AS a
    ON a.actor_id = amc.actor_id
ORDER BY
    amc.number_of_movies DESC,
    a.last_name ASC,
    a.first_name ASC
LIMIT 5;

/*
SOLUTION B - SUBQUERY
Advantages: actor-level aggregation is encapsulated in the FROM subquery.
Disadvantages: deeper nesting can make complex extensions less readable.
*/
SELECT
    a.first_name,
    a.last_name,
    counts.number_of_movies
FROM public.actor AS a
INNER JOIN (
    SELECT
        fa.actor_id,
        COUNT(DISTINCT f.film_id) AS number_of_movies
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year >= 2015
    GROUP BY fa.actor_id
) AS counts
    ON counts.actor_id = a.actor_id
ORDER BY
    counts.number_of_movies DESC,
    a.last_name ASC,
    a.first_name ASC
LIMIT 5;

/*
SOLUTION C - JOIN
Advantages: concise and exposes all relationships in one query.
Disadvantages: aggregation and entity lookup are combined in one query block.
JOIN types:
- INNER JOIN excludes actors who have no qualifying film released since 2015.
*/
SELECT
    a.first_name,
    a.last_name,
    COUNT(DISTINCT f.film_id) AS number_of_movies
FROM public.actor AS a
INNER JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
INNER JOIN public.film AS f
    ON f.film_id = fa.film_id
WHERE f.release_year >= 2015
GROUP BY
    a.actor_id,
    a.first_name,
    a.last_name
ORDER BY
    number_of_movies DESC,
    a.last_name ASC,
    a.first_name ASC
LIMIT 5;

/*
PRODUCTION CHOICE:
Use Solution C for this straightforward aggregation. Use the CTE version if
the actor-level counts are needed by several downstream calculations.
*/


/*
===============================================================================
PART 1 - TASK 4
Show yearly counts for Drama, Travel and Documentary films.
Output: release_year, number_of_drama_movies, number_of_travel_movies,
number_of_documentary_movies.

BUSINESS ASSUMPTIONS
- A film is counted in the category assigned through film_category.
- COUNT(DISTINCT film_id) prevents duplicate counting if source relationships
  unexpectedly contain duplicate rows.
- A NULL release_year is retained as its own group.
- Years with no films in one of the requested categories receive zero for
  that category.
- Only years represented by at least one film in one of the three categories
  are returned.

SOLUTION A - CTE
Advantages: category-level counts are calculated in a separate, readable step.
Disadvantages: extra query block; not necessary for a single aggregation.
*/
WITH selected_category_films AS (
    SELECT
        f.film_id,
        f.release_year,
        c.name AS category_name
    FROM public.film AS f
    INNER JOIN public.film_category AS fc
        ON fc.film_id = f.film_id
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name IN ('Drama', 'Travel', 'Documentary')
)
SELECT
    release_year,
    COUNT(DISTINCT CASE
        WHEN category_name = 'Drama' THEN film_id
    END) AS number_of_drama_movies,
    COUNT(DISTINCT CASE
        WHEN category_name = 'Travel' THEN film_id
    END) AS number_of_travel_movies,
    COUNT(DISTINCT CASE
        WHEN category_name = 'Documentary' THEN film_id
    END) AS number_of_documentary_movies
FROM selected_category_films
GROUP BY release_year
ORDER BY release_year DESC NULLS LAST;

/*
SOLUTION B - SUBQUERY
Advantages: the selected film/category set is isolated in a derived table.
Disadvantages: nested SELECT adds indentation and may be less convenient to
extend than a named CTE.
*/
SELECT
    selected.release_year,
    COUNT(DISTINCT CASE
        WHEN selected.category_name = 'Drama' THEN selected.film_id
    END) AS number_of_drama_movies,
    COUNT(DISTINCT CASE
        WHEN selected.category_name = 'Travel' THEN selected.film_id
    END) AS number_of_travel_movies,
    COUNT(DISTINCT CASE
        WHEN selected.category_name = 'Documentary' THEN selected.film_id
    END) AS number_of_documentary_movies
FROM (
    SELECT
        f.film_id,
        f.release_year,
        c.name AS category_name
    FROM public.film AS f
    INNER JOIN public.film_category AS fc
        ON fc.film_id = f.film_id
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name IN ('Drama', 'Travel', 'Documentary')
) AS selected
GROUP BY selected.release_year
ORDER BY selected.release_year DESC NULLS LAST;

/*
SOLUTION C - JOIN
Advantages: a single query block is easy to run and inspect.
Disadvantages: conditional aggregation can look dense when many categories
are added.
JOIN types:
- INNER JOIN keeps only films assigned to one of the three requested
  categories; films without a matching category are excluded.
*/
SELECT
    f.release_year,
    COUNT(DISTINCT CASE
        WHEN c.name = 'Drama' THEN f.film_id
    END) AS number_of_drama_movies,
    COUNT(DISTINCT CASE
        WHEN c.name = 'Travel' THEN f.film_id
    END) AS number_of_travel_movies,
    COUNT(DISTINCT CASE
        WHEN c.name = 'Documentary' THEN f.film_id
    END) AS number_of_documentary_movies
FROM public.film AS f
INNER JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
INNER JOIN public.category AS c
    ON c.category_id = fc.category_id
WHERE c.name IN ('Drama', 'Travel', 'Documentary')
GROUP BY f.release_year
ORDER BY f.release_year DESC NULLS LAST;

/*
PRODUCTION CHOICE:
Use Solution A. It separates category selection from aggregation and is
easier to maintain when the report is extended with more categories.
*/


/*
===============================================================================
PART 2 - TASK 1
Show the three employees who generated the most revenue in 2017.
Also show the last store in which each employee worked during 2017.

BUSINESS ASSUMPTIONS
- Only payment_date is used to define the 2017 reporting period:
  payment_date >= 2017-01-01 and payment_date < 2018-01-01.
- Employee revenue is SUM(payment.amount) for payments processed by staff.
- The store for each payment is derived from rental.inventory_id and
  inventory.store_id, following the task assumption that payment processing
  and the rental store refer to the same store.
- "Last store" means the store on the employee's latest 2017 payment.
- If two payments have the same payment_date, the greatest payment_id wins.
- Employees with no 2017 payments are not eligible for the top 3.
- If a staff member has payments associated with more than one store, all
  payments contribute to their revenue, but only the latest store is shown.

SOLUTION A - CTE
Advantages: revenue aggregation and last-store selection are separated;
each step is independently understandable.
Disadvantages: multiple CTEs make the query longer. The latest-payment
selection uses NOT EXISTS instead of a window function.
*/
WITH employee_revenue AS (
    SELECT
        p.staff_id,
        SUM(p.amount) AS total_revenue
    FROM public.payment AS p
    WHERE p.payment_date >= TIMESTAMP '2017-01-01 00:00:00'
      AND p.payment_date < TIMESTAMP '2018-01-01 00:00:00'
    GROUP BY p.staff_id
),
payment_store AS (
    SELECT
        p.payment_id,
        p.staff_id,
        p.payment_date,
        i.store_id
    FROM public.payment AS p
    INNER JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    WHERE p.payment_date >= TIMESTAMP '2017-01-01 00:00:00'
      AND p.payment_date < TIMESTAMP '2018-01-01 00:00:00'
),
last_employee_store AS (
    SELECT
        ps.staff_id,
        ps.store_id
    FROM payment_store AS ps
    WHERE NOT EXISTS (
        SELECT 1
        FROM payment_store AS newer
        WHERE newer.staff_id = ps.staff_id
          AND (
              newer.payment_date > ps.payment_date
              OR (
                  newer.payment_date = ps.payment_date
                  AND newer.payment_id > ps.payment_id
              )
          )
    )
)
SELECT
    stf.first_name,
    stf.last_name,
    les.store_id AS last_store_id,
    CONCAT_WS(' ', addr.address, NULLIF(addr.address2, '')) AS last_store_address,
    er.total_revenue
FROM employee_revenue AS er
INNER JOIN public.staff AS stf
    ON stf.staff_id = er.staff_id
LEFT JOIN last_employee_store AS les
    ON les.staff_id = er.staff_id
LEFT JOIN public.store AS s
    ON s.store_id = les.store_id
LEFT JOIN public.address AS addr
    ON addr.address_id = s.address_id
ORDER BY er.total_revenue DESC, stf.last_name ASC, stf.first_name ASC
LIMIT 3;

/*
SOLUTION B - SUBQUERY
Advantages: no named CTEs are required; the employee revenue result is
calculated in a derived table.
Disadvantages: the last-store anti-join is nested and can be harder to read.
*/
SELECT
    stf.first_name,
    stf.last_name,
    last_store.store_id AS last_store_id,
    CONCAT_WS(' ', addr.address, NULLIF(addr.address2, '')) AS last_store_address,
    revenue.total_revenue
FROM (
    SELECT
        p.staff_id,
        SUM(p.amount) AS total_revenue
    FROM public.payment AS p
    WHERE p.payment_date >= TIMESTAMP '2017-01-01 00:00:00'
      AND p.payment_date < TIMESTAMP '2018-01-01 00:00:00'
    GROUP BY p.staff_id
) AS revenue
INNER JOIN public.staff AS stf
    ON stf.staff_id = revenue.staff_id
LEFT JOIN (
    SELECT
        ps.staff_id,
        ps.store_id
    FROM (
        SELECT
            p.payment_id,
            p.staff_id,
            p.payment_date,
            i.store_id
        FROM public.payment AS p
        INNER JOIN public.rental AS r
            ON r.rental_id = p.rental_id
        INNER JOIN public.inventory AS i
            ON i.inventory_id = r.inventory_id
        WHERE p.payment_date >= TIMESTAMP '2017-01-01 00:00:00'
          AND p.payment_date < TIMESTAMP '2018-01-01 00:00:00'
    ) AS ps
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.payment AS p2
        INNER JOIN public.rental AS r2
            ON r2.rental_id = p2.rental_id
        INNER JOIN public.inventory AS i2
            ON i2.inventory_id = r2.inventory_id
        WHERE p2.staff_id = ps.staff_id
          AND p2.payment_date >= TIMESTAMP '2017-01-01 00:00:00'
          AND p2.payment_date < TIMESTAMP '2018-01-01 00:00:00'
          AND (
              p2.payment_date > ps.payment_date
              OR (
                  p2.payment_date = ps.payment_date
                  AND p2.payment_id > ps.payment_id
              )
          )
    )
) AS last_store
    ON last_store.staff_id = revenue.staff_id
LEFT JOIN public.store AS s
    ON s.store_id = last_store.store_id
LEFT JOIN public.address AS addr
    ON addr.address_id = s.address_id
ORDER BY revenue.total_revenue DESC, stf.last_name ASC, stf.first_name ASC
LIMIT 3;

/*
SOLUTION C - JOIN
Advantages: the revenue total and latest store are calculated separately
and then combined through explicit joins. This prevents the latest-payment
filter from accidentally reducing the full-year revenue total.
Disadvantages: uses two derived tables, so it is longer than the CTE version.
JOIN types:
- INNER JOIN in the revenue derived table keeps payments with a staff_id.
- INNER JOINs in the latest-store derived table require a matching rental
  and inventory item to identify the store.
- LEFT JOIN from revenue to latest store preserves an employee's revenue
  even if a payment cannot be mapped to a store.
*/
SELECT
    stf.first_name,
    stf.last_name,
    latest_store.store_id AS last_store_id,
    CONCAT_WS(' ', addr.address, NULLIF(addr.address2, '')) AS last_store_address,
    revenue.total_revenue
FROM (
    SELECT
        p.staff_id,
        SUM(p.amount) AS total_revenue
    FROM public.payment AS p
    WHERE p.payment_date >= TIMESTAMP '2017-01-01 00:00:00'
      AND p.payment_date < TIMESTAMP '2018-01-01 00:00:00'
    GROUP BY p.staff_id
) AS revenue
INNER JOIN public.staff AS stf
    ON stf.staff_id = revenue.staff_id
LEFT JOIN (
    SELECT
        ps.staff_id,
        ps.store_id
    FROM (
        SELECT
            p.payment_id,
            p.staff_id,
            p.payment_date,
            i.store_id
        FROM public.payment AS p
        INNER JOIN public.rental AS r
            ON r.rental_id = p.rental_id
        INNER JOIN public.inventory AS i
            ON i.inventory_id = r.inventory_id
        WHERE p.payment_date >= TIMESTAMP '2017-01-01 00:00:00'
          AND p.payment_date < TIMESTAMP '2018-01-01 00:00:00'
    ) AS ps
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.payment AS p2
        INNER JOIN public.rental AS r2
            ON r2.rental_id = p2.rental_id
        INNER JOIN public.inventory AS i2
            ON i2.inventory_id = r2.inventory_id
        WHERE p2.staff_id = ps.staff_id
          AND p2.payment_date >= TIMESTAMP '2017-01-01 00:00:00'
          AND p2.payment_date < TIMESTAMP '2018-01-01 00:00:00'
          AND (
              p2.payment_date > ps.payment_date
              OR (
                  p2.payment_date = ps.payment_date
                  AND p2.payment_id > ps.payment_id
              )
          )
    )
) AS latest_store
    ON latest_store.staff_id = revenue.staff_id
LEFT JOIN public.store AS s
    ON s.store_id = latest_store.store_id
LEFT JOIN public.address AS addr
    ON addr.address_id = s.address_id
ORDER BY
    revenue.total_revenue DESC,
    stf.last_name ASC,
    stf.first_name ASC
LIMIT 3;

/*
PRODUCTION CHOICE:
Use Solution A (CTE). It is the easiest to validate step by step. Solution C
is also valid and demonstrates how the same logic can be assembled with
derived tables and JOINs.
*/

/*
===============================================================================
PART 2 - TASK 2
Show the five most rented movies and the expected audience age.

BUSINESS ASSUMPTIONS
- Popularity is the number of rental records, COUNT(rental_id).
- A rental is connected to a film through rental.inventory_id -> inventory.film_id.
- Films with no rentals are not candidates for the top five.
- Expected age is an approximate interpretation of the film.rating field:
    G     - suitable for all ages.
    PG    - parental guidance suggested; some material may not be suitable
            for children under 10.
    PG-13 - parents strongly cautioned; some material may be inappropriate
            for children under 13.
    R     - under 17 requires an accompanying parent or adult guardian.
    NC-17 - no one 17 and under admitted.
- The rating describes suitability/admission guidance, not the actual
  demographic of customers who rented the film.
- If ratings are NULL or outside the known values, display 'Not specified'.

SOLUTION A - CTE
Advantages: rental counts are isolated from the film metadata and easy to test.
Disadvantages: extra query block for a relatively simple aggregation.
*/
WITH film_rental_counts AS (
    SELECT
        i.film_id,
        COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory AS i
    INNER JOIN public.rental AS r
        ON r.inventory_id = i.inventory_id
    GROUP BY i.film_id
)
SELECT
    f.title,
    frc.number_of_rentals,
    f.rating,
    CASE f.rating
        WHEN 'G' THEN 'All ages'
        WHEN 'PG' THEN 'Parental guidance; some material may be unsuitable under 10'
        WHEN 'PG-13' THEN '13+ guidance; some material may be inappropriate under 13'
        WHEN 'R' THEN 'Under 17 requires an accompanying parent or adult guardian'
        WHEN 'NC-17' THEN '17 and under not admitted'
        ELSE 'Not specified'
    END AS expected_audience_age
FROM film_rental_counts AS frc
INNER JOIN public.film AS f
    ON f.film_id = frc.film_id
ORDER BY frc.number_of_rentals DESC, f.title ASC
LIMIT 5;

/*
SOLUTION B - SUBQUERY
Advantages: count aggregation is encapsulated in a derived table.
Disadvantages: the count logic is nested in the main SELECT and less reusable.
*/
SELECT
    f.title,
    counts.number_of_rentals,
    f.rating,
    CASE f.rating
        WHEN 'G' THEN 'All ages'
        WHEN 'PG' THEN 'Parental guidance; some material may be unsuitable under 10'
        WHEN 'PG-13' THEN '13+ guidance; some material may be inappropriate under 13'
        WHEN 'R' THEN 'Under 17 requires an accompanying parent or adult guardian'
        WHEN 'NC-17' THEN '17 and under not admitted'
        ELSE 'Not specified'
    END AS expected_audience_age
FROM public.film AS f
INNER JOIN (
    SELECT
        i.film_id,
        COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory AS i
    INNER JOIN public.rental AS r
        ON r.inventory_id = i.inventory_id
    GROUP BY i.film_id
) AS counts
    ON counts.film_id = f.film_id
ORDER BY counts.number_of_rentals DESC, f.title ASC
LIMIT 5;

/*
SOLUTION C - JOIN
Advantages: direct relationship path, easy to understand.
Disadvantages: film metadata and rental aggregation are combined in one query.
JOIN types:
- INNER JOIN excludes films without rental records, which is correct because
  the task asks for the most rented movies.
*/
SELECT
    f.title,
    COUNT(r.rental_id) AS number_of_rentals,
    f.rating,
    CASE f.rating
        WHEN 'G' THEN 'All ages'
        WHEN 'PG' THEN 'Parental guidance; some material may be unsuitable under 10'
        WHEN 'PG-13' THEN '13+ guidance; some material may be inappropriate under 13'
        WHEN 'R' THEN 'Under 17 requires an accompanying parent or adult guardian'
        WHEN 'NC-17' THEN '17 and under not admitted'
        ELSE 'Not specified'
    END AS expected_audience_age
FROM public.film AS f
INNER JOIN public.inventory AS i
    ON i.film_id = f.film_id
INNER JOIN public.rental AS r
    ON r.inventory_id = i.inventory_id
GROUP BY
    f.film_id,
    f.title,
    f.rating
ORDER BY number_of_rentals DESC, f.title ASC
LIMIT 5;

/*
PRODUCTION CHOICE:
Use Solution C for a single report. Use Solution A if rental counts are
reused by other analyses or need to be validated independently.
*/


/*
===============================================================================
PART 3 - V1
For each actor, calculate the gap between their latest film release year
and the current calendar year.

BUSINESS ASSUMPTIONS
- release_year is a proxy for acting activity.
- The gap is CURRENT_YEAR - MAX(release_year).
- Actors with no linked films or no known release year are retained with
  NULL latest_release_year and NULL inactivity_years.
- The current year is dynamic and is not hardcoded.
- This is a year-level gap, not an exact duration in days.

SOLUTION A - CTE
Advantages: latest release year is calculated once and can be reused.
Disadvantages: one additional query block.
*/
WITH actor_latest_release AS (
    SELECT
        fa.actor_id,
        MAX(f.release_year) AS latest_release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    GROUP BY fa.actor_id
)
SELECT
    a.first_name,
    a.last_name,
    alr.latest_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - alr.latest_release_year
        AS inactivity_years
FROM public.actor AS a
LEFT JOIN actor_latest_release AS alr
    ON alr.actor_id = a.actor_id
ORDER BY inactivity_years DESC NULLS FIRST, a.last_name, a.first_name;

/*
SOLUTION B - SUBQUERY
Advantages: compact; latest release year is calculated in a derived table.
Disadvantages: less convenient to reuse the intermediate result.
*/
SELECT
    a.first_name,
    a.last_name,
    latest.latest_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - latest.latest_release_year
        AS inactivity_years
FROM public.actor AS a
LEFT JOIN (
    SELECT
        fa.actor_id,
        MAX(f.release_year) AS latest_release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    GROUP BY fa.actor_id
) AS latest
    ON latest.actor_id = a.actor_id
ORDER BY inactivity_years DESC NULLS FIRST, a.last_name, a.first_name;

/*
SOLUTION C - JOIN
Advantages: one query block and explicit actor-film relationships.
Disadvantages: the aggregate must be grouped with all selected actor columns.
JOIN types:
- LEFT JOIN preserves actors even when they have no film relationship.
- INNER JOIN between film_actor and film includes only films with a matching
  film record.
*/
SELECT
    a.first_name,
    a.last_name,
    MAX(f.release_year) AS latest_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - MAX(f.release_year)
        AS inactivity_years
FROM public.actor AS a
LEFT JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
LEFT JOIN public.film AS f
    ON f.film_id = fa.film_id
GROUP BY
    a.actor_id,
    a.first_name,
    a.last_name
ORDER BY inactivity_years DESC NULLS FIRST, a.last_name, a.first_name;

/*
PRODUCTION CHOICE:
Use Solution C for this one-step aggregation. It preserves all actors and
keeps the calculation transparent.
*/


/*
===============================================================================
PART 3 - V2
Calculate gaps between sequential film release years for each actor.

BUSINESS ASSUMPTIONS
- Film release_year is used as a proxy for an actor's activity.
- Multiple films released in the same year are treated as one activity year.
  This prevents zero-year gaps caused only by multiple titles in one year.
- Only known release_year values are included.
- Each output row represents an activity year and the next later activity
  year for the same actor.
- The gap is next_release_year - release_year.
- Actors with fewer than two distinct known activity years have no sequential
  gap and therefore do not appear in this result.
- The query does not use window functions.

SOLUTION A - CTE
Advantages: distinct activity years and next-year lookup are separated;
easy to inspect and extend.
Disadvantages: several query blocks; for very large data sets, indexes on
film_actor(actor_id, film_id) and film(release_year, film_id) may help.
*/
WITH actor_activity_years AS (
    SELECT DISTINCT
        fa.actor_id,
        f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year IS NOT NULL
),
sequential_gaps AS (
    SELECT
        current_year.actor_id,
        current_year.release_year,
        (
            SELECT MIN(next_year.release_year)
            FROM actor_activity_years AS next_year
            WHERE next_year.actor_id = current_year.actor_id
              AND next_year.release_year > current_year.release_year
        ) AS next_release_year
    FROM actor_activity_years AS current_year
)
SELECT
    a.first_name,
    a.last_name,
    sg.release_year,
    sg.next_release_year,
    sg.next_release_year - sg.release_year AS gap_years
FROM sequential_gaps AS sg
INNER JOIN public.actor AS a
    ON a.actor_id = sg.actor_id
WHERE sg.next_release_year IS NOT NULL
ORDER BY gap_years DESC, a.last_name, a.first_name, sg.release_year;

/*
SOLUTION B - SUBQUERY
Advantages: no named CTEs; the next activity year is obtained with a
correlated scalar subquery.
Disadvantages: the correlated lookup may be less readable and can be costly
without appropriate indexes or optimizer support.
*/
SELECT
    a.first_name,
    a.last_name,
    activity.release_year,
    (
        SELECT MIN(next_film.release_year)
        FROM public.film_actor AS next_fa
        INNER JOIN public.film AS next_film
            ON next_film.film_id = next_fa.film_id
        WHERE next_fa.actor_id = activity.actor_id
          AND next_film.release_year > activity.release_year
    ) AS next_release_year,
    (
        SELECT MIN(next_film.release_year)
        FROM public.film_actor AS next_fa
        INNER JOIN public.film AS next_film
            ON next_film.film_id = next_fa.film_id
        WHERE next_fa.actor_id = activity.actor_id
          AND next_film.release_year > activity.release_year
    ) - activity.release_year AS gap_years
FROM (
    SELECT DISTINCT
        fa.actor_id,
        f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year IS NOT NULL
) AS activity
INNER JOIN public.actor AS a
    ON a.actor_id = activity.actor_id
WHERE EXISTS (
    SELECT 1
    FROM public.film_actor AS next_fa
    INNER JOIN public.film AS next_film
        ON next_film.film_id = next_fa.film_id
    WHERE next_fa.actor_id = activity.actor_id
      AND next_film.release_year > activity.release_year
)
ORDER BY gap_years DESC, a.last_name, a.first_name, activity.release_year;

/*
SOLUTION C - SELF JOIN
Advantages: the relationship between one activity year and its next year
is expressed directly through a self-join.
Disadvantages: a simple self-join can produce every later year, not just the
immediate next year. The NOT EXISTS anti-join condition below removes a
candidate next year if an intermediate activity year exists.
JOIN types:
- INNER JOIN pairs activity years for the same actor.
- LEFT JOIN to the intermediate-year alias plus IS NULL keeps only pairs
  with no activity year between them.
*/
SELECT
    a.first_name,
    a.last_name,
    current_activity.release_year,
    next_activity.release_year AS next_release_year,
    next_activity.release_year - current_activity.release_year AS gap_years
FROM (
    SELECT DISTINCT
        fa.actor_id,
        f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year IS NOT NULL
) AS current_activity
INNER JOIN (
    SELECT DISTINCT
        fa.actor_id,
        f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year IS NOT NULL
) AS next_activity
    ON next_activity.actor_id = current_activity.actor_id
   AND next_activity.release_year > current_activity.release_year
INNER JOIN public.actor AS a
    ON a.actor_id = current_activity.actor_id
LEFT JOIN (
    SELECT DISTINCT
        fa.actor_id,
        f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year IS NOT NULL
) AS intermediate_activity
    ON intermediate_activity.actor_id = current_activity.actor_id
   AND intermediate_activity.release_year > current_activity.release_year
   AND intermediate_activity.release_year < next_activity.release_year
WHERE intermediate_activity.release_year IS NULL
ORDER BY gap_years DESC, a.last_name, a.first_name, current_activity.release_year;

/*
PRODUCTION CHOICE:
Use Solution A (CTE). It is the easiest to review and makes the distinct
activity-year set explicit. Solution C is a valid self-join alternative but
is more verbose. For a large production dataset, compare execution plans
(EXPLAIN / EXPLAIN ANALYZE) before choosing based on performance.

===============================================================================
FINAL VALIDATION CHECKLIST
- Confirm the actual schema name. Replace public if needed.
- Execute each solution separately in PostgreSQL.
- Check that payment is the partitioned parent table and includes the
  requested date range. If the environment exposes only monthly child tables,
  use the parent table or the appropriate partitioned table as configured.
- Confirm the intended business definition of store attribution for revenue.
- Confirm the interpretation of "last store" with the mentor.
- Confirm whether "rate" in Part 1 Task 1 means rental_rate.
- Review EXPLAIN ANALYZE for large tables before production use.
- Commit all alternatives, but clearly identify the recommended solution
  for each task.
===============================================================================
