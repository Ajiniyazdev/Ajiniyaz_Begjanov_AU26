/*
===============================================================================
 SQL_DDL_Func_Ajiniyaz_Begjanov_HW.sql      (Tasks 1-5)
 Database : dvd_rental (tables in schema "public")
 Objects  : created in schema "core" (the task example calls core.<function>)

 General rules followed by every object in this file
   * No hard-coded IDs - everything is looked up by name / computed.
   * CREATE ... IF NOT EXISTS / CREATE OR REPLACE -> the script can be re-run
     any number of times without errors and without creating duplicates.
   * Invalid input raises an explicit exception (RAISE EXCEPTION) with a
     meaningful SQLSTATE; "no data" is NOT an error - it is reported as an
     empty result / NOTICE / message row (explained in each header).
   * Tests that are SUPPOSED to fail are wrapped in DO blocks that catch the
     exception and print it as NOTICE, so the whole file runs top to bottom
     without stopping. Tests that write data run in a transaction that is
     rolled back, so they leave no garbage and can be repeated.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS core;


/*
===============================================================================
 TASK 1. VIEW  core.sales_revenue_by_category_qtr
===============================================================================
 WHY THIS LOGIC
   Management wants "revenue per film category for the quarter we are in now".
   Revenue is money actually paid, so it comes from payment.amount; the
   category of a payment is found through
       payment -> rental -> inventory -> film -> film_category -> category.

 HOW THE RESULT IS CALCULATED
   total_sales_revenue = SUM(payment.amount) per category, only for payments
   whose payment_date lies inside the current calendar quarter.
   A payment belongs to the category of the film that was rented. If a film is
   linked to several categories (possible in newer copies of the sample DB), its
   payments count in each of them; in the classic dvd_rental every film has
   exactly one category, so the category totals add up to total revenue.

 HOW THE CURRENT QUARTER / YEAR ARE DETERMINED (dynamic, nothing hard-coded)
   * current quarter : date_trunc('quarter', CURRENT_DATE) gives the first day
     of the quarter we are in (e.g. 2026-10-01 for any day in Oct-Dec 2026);
     the quarter number is EXTRACT(QUARTER FROM CURRENT_DATE) (= 4 here).
   * current year    : EXTRACT(YEAR FROM CURRENT_DATE) - it is already part of
     the quarter start date, so the window  [start, start + 3 months)  selects
     "this quarter of this year" and automatically excludes Q4 of last year.
   * CURRENT_DATE is evaluated every time the view is queried (a view stores
     the query, not the data), so on 1 January / 1 April / 1 July / 1 October
     the window moves by itself and no one has to edit the view.
   * The window is written as  payment_date >= start AND payment_date < end
     instead of wrapping payment_date in EXTRACT(): a plain range keeps the
     condition index/partition friendly (payment is partitioned by date).

 WHY ONLY CATEGORIES WITH SALES APPEAR / HOW ZERO-SALES CATEGORIES ARE EXCLUDED
   The query starts from payment and uses INNER JOINs to category. A category
   gets a row only if at least one payment in the window reaches it. A category
   with no sale in the quarter has no row to be grouped, so it cannot appear.
   (No LEFT JOIN from category, no COALESCE(…,0) - those would add zero rows.)

 THE DEFAULT DATABASE HAS NO DATA FOR THE CURRENT YEAR - HOW IT IS VERIFIED
   Querying the view today returns 0 rows - that is the CORRECT result when the
   current quarter has no payments, not an error. Correctness was verified by:
     1. test 1.2 - prints the quarter boundaries the view actually uses;
     2. test 1.3 - re-runs the very same filter with "today" frozen to the day
        of the LAST payment in the database (a quarter that has data) and
        reconciles it with an independent SUM over the payment table
        -> must return TRUE;
     3. Task 2 test 2.2 - the function version of the view (same logic) is
        compared with the view (EXCEPT both ways = 0 rows).

 DATA THAT MUST NOT APPEAR IN THE VIEW  (test 1.4 lists real examples)
   * payments of the previous quarter (e.g. Q3 when we are in Q4);
   * payments of the same quarter of the previous year (Q4 last year);
   * categories whose only payments are outside the current quarter.
   A payment dated 30 Sep must not leak into the Q4 view, and one dated
   1 Jan must not appear in the view of Q4 of the previous year.

 IF DATA IS MISSING / INPUT IS WRONG
   The view takes no parameters, so there is no wrong input. No payments in the
   quarter -> empty result set.
===============================================================================
*/
CREATE OR REPLACE VIEW core.sales_revenue_by_category_qtr AS
SELECT  cat.name::text   AS category,
        SUM(p.amount)    AS total_sales_revenue
FROM    public.payment       p
JOIN    public.rental        r   ON r.rental_id     = p.rental_id
JOIN    public.inventory     i   ON i.inventory_id  = r.inventory_id
JOIN    public.film_category fc  ON fc.film_id      = i.film_id
JOIN    public.category      cat ON cat.category_id = fc.category_id
WHERE   p.payment_date >= date_trunc('quarter', CURRENT_DATE)::date
  AND   p.payment_date <  (date_trunc('quarter', CURRENT_DATE) + INTERVAL '3 months')::date
GROUP BY cat.category_id, cat.name
ORDER BY total_sales_revenue DESC, category;

COMMENT ON VIEW core.sales_revenue_by_category_qtr IS
  'Revenue (SUM of payment.amount) per film category for the CURRENT calendar quarter; categories without sales in it are not shown. Re-evaluated on every query, so it rolls over automatically.';

-- ---- Task 1 tests ---------------------------------------------------------
-- 1.1 Valid call. The default DB has no payments in the current quarter, so
--     0 rows is the expected, correct answer (not an error).
SELECT * FROM core.sales_revenue_by_category_qtr;

-- 1.2 Which quarter does the view use right now?
SELECT  date_trunc('quarter', CURRENT_DATE)::date                           AS quarter_start,
        (date_trunc('quarter', CURRENT_DATE) + INTERVAL '3 months')::date   AS next_quarter_start,
        EXTRACT(QUARTER FROM CURRENT_DATE)::int                             AS current_quarter,
        EXTRACT(YEAR    FROM CURRENT_DATE)::int                             AS current_year;

-- 1.3 Verify the view's logic on a quarter that HAS data: freeze "today" to the
--     day of the last payment and compare with an independent calculation.
--     Expected: matches = TRUE (and the revenue / category counts are > 0).
WITH frozen AS (
    SELECT MAX(payment_date)::date AS fake_today FROM public.payment
),
by_view_logic AS (                      -- identical filter/joins as the view
    SELECT cat.category_id, SUM(p.amount) AS revenue
    FROM   frozen f
    JOIN   public.payment       p   ON p.payment_date >= date_trunc('quarter', f.fake_today)::date
                                   AND p.payment_date <  (date_trunc('quarter', f.fake_today) + INTERVAL '3 months')::date
    JOIN   public.rental        r   ON r.rental_id     = p.rental_id
    JOIN   public.inventory     i   ON i.inventory_id  = r.inventory_id
    JOIN   public.film_category fc  ON fc.film_id      = i.film_id
    JOIN   public.category      cat ON cat.category_id = fc.category_id
    GROUP  BY cat.category_id
),
independent AS (                        -- different route: start from each payment and multiply it by
                                        -- the number of categories its film has (1 in the classic DB)
    SELECT SUM(p.amount * (SELECT COUNT(*)
                           FROM   public.rental r
                           JOIN   public.inventory i      ON i.inventory_id = r.inventory_id
                           JOIN   public.film_category fc ON fc.film_id     = i.film_id
                           WHERE  r.rental_id = p.rental_id)) AS revenue
    FROM   frozen f
    JOIN   public.payment p ON p.payment_date >= date_trunc('quarter', f.fake_today)::date
                           AND p.payment_date <  (date_trunc('quarter', f.fake_today) + INTERVAL '3 months')::date
)
SELECT  (SELECT fake_today FROM frozen)                          AS frozen_today,
        (SELECT COUNT(*)     FROM by_view_logic)                 AS categories_with_sales,
        (SELECT SUM(revenue) FROM by_view_logic)                 AS revenue_by_view_logic,
        (SELECT revenue      FROM independent)                   AS revenue_independent,
        (SELECT SUM(revenue) FROM by_view_logic) = (SELECT revenue FROM independent) AS matches;

-- 1.4 Edge case / data that must NOT appear in the view: real revenue that
--     exists in the database but belongs to the previous quarter or to the same
--     quarter of the previous year. None of these rows may be in test 1.1.
SELECT  'previous quarter'                      AS why_excluded,
        cat.name::text                          AS category,
        SUM(p.amount)                           AS revenue
FROM    public.payment p
JOIN    public.rental r        ON r.rental_id = p.rental_id
JOIN    public.inventory i     ON i.inventory_id = r.inventory_id
JOIN    public.film_category fc ON fc.film_id = i.film_id
JOIN    public.category cat    ON cat.category_id = fc.category_id
WHERE   p.payment_date >= (date_trunc('quarter', CURRENT_DATE) - INTERVAL '3 months')::date
  AND   p.payment_date <   date_trunc('quarter', CURRENT_DATE)::date
GROUP BY cat.name
UNION ALL
SELECT  'same quarter, previous year', cat.name::text, SUM(p.amount)
FROM    public.payment p
JOIN    public.rental r        ON r.rental_id = p.rental_id
JOIN    public.inventory i     ON i.inventory_id = r.inventory_id
JOIN    public.film_category fc ON fc.film_id = i.film_id
JOIN    public.category cat    ON cat.category_id = fc.category_id
WHERE   p.payment_date >= (date_trunc('quarter', CURRENT_DATE) - INTERVAL '1 year')::date
  AND   p.payment_date <  (date_trunc('quarter', CURRENT_DATE) - INTERVAL '1 year' + INTERVAL '3 months')::date
GROUP BY cat.name
ORDER BY 1, 3 DESC;


/*
===============================================================================
 TASK 2. QUERY-LANGUAGE (LANGUAGE sql) FUNCTION
         core.get_sales_revenue_by_category_qtr(p_quarter_year text DEFAULT NULL)
===============================================================================
 WHY A PARAMETER IS NEEDED
   The view is welded to CURRENT_DATE: it can only answer "what is the revenue
   NOW". Reporting also needs history ("Q3 2025") and, for testing, a quarter
   that really contains data (the sample DB has none for the current year).
   A function with a parameter gives the same result as the view for any
   quarter. The parameter is ONE text value in the format 'YYYY-Qn'
   (e.g. '2026-Q4'); it carries both quarter and year. It is optional:
   omitted / NULL = the current quarter, i.e. exactly what the view returns.

 HOW THE RESULT IS CALCULATED
   'YYYY-Qn' -> first day of the quarter = make_date(YYYY, (n-1)*3+1, 1);
   then the same SUM(payment.amount) per category over
   [quarter_start, quarter_start + 3 months) as in the view.

 WHY LANGUAGE sql HAS TWO STATEMENTS
   The first statement only parses/validates the parameter; a LANGUAGE sql
   function has no IF/RAISE, so validation is done by the parsing itself. The
   second statement is the real query (its result is what is returned).
   Running validation as a separate, always-executed statement guarantees that
   a bad parameter fails loudly even if the main query would find no rows.

 WHAT HAPPENS IF AN INVALID QUARTER IS PASSED
   The function raises an error (nothing is returned):
     '2026-Q5', '2026-Q0'  -> ERROR: date field value out of range
        (month = 3*n-2 is only a valid month for n = 1..4, so ANY quarter other
         than 1-4 is rejected);
     '2026-3', 'abc', ''   -> ERROR: invalid input syntax for type integer
        (the value does not follow the 'YYYY-Qn' format).
   Lower case / surrounding spaces ('2026-q4 ') are accepted.

 WHAT HAPPENS IF NO DATA EXISTS
   A valid quarter without payments (e.g. '1999-Q1' or the current quarter of
   the sample DB) returns an EMPTY result set. It is not an error - there is
   simply nothing to report; the caller can distinguish "bad input" (error)
   from "no sales" (0 rows).
===============================================================================
*/
CREATE OR REPLACE FUNCTION core.get_sales_revenue_by_category_qtr(p_quarter_year text DEFAULT NULL)
RETURNS TABLE (category text, total_sales_revenue numeric)
LANGUAGE sql
STABLE
AS $func$
    -- Statement 1: validate the parameter (raises an error for a bad quarter/format)
    SELECT make_date( split_part(upper(btrim(p_quarter_year)), '-Q', 1)::int,
                     (split_part(upper(btrim(p_quarter_year)), '-Q', 2)::int - 1) * 3 + 1,
                      1)
    WHERE  p_quarter_year IS NOT NULL;

    -- Statement 2: same logic as core.sales_revenue_by_category_qtr, for the requested quarter
    WITH q AS (
        SELECT CASE
                 WHEN p_quarter_year IS NULL
                      THEN date_trunc('quarter', CURRENT_DATE)::date          -- default = current quarter
                 ELSE make_date( split_part(upper(btrim(p_quarter_year)), '-Q', 1)::int,
                                (split_part(upper(btrim(p_quarter_year)), '-Q', 2)::int - 1) * 3 + 1,
                                 1)
               END AS q_start
    )
    SELECT  cat.name::text  AS category,
            SUM(p.amount)   AS total_sales_revenue
    FROM    q
    JOIN    public.payment       p   ON p.payment_date >= q.q_start
                                    AND p.payment_date <  (q.q_start + INTERVAL '3 months')::date
    JOIN    public.rental        r   ON r.rental_id     = p.rental_id
    JOIN    public.inventory     i   ON i.inventory_id  = r.inventory_id
    JOIN    public.film_category fc  ON fc.film_id      = i.film_id
    JOIN    public.category      cat ON cat.category_id = fc.category_id
    GROUP BY cat.category_id, cat.name
    ORDER BY total_sales_revenue DESC, category;
$func$;

COMMENT ON FUNCTION core.get_sales_revenue_by_category_qtr(text) IS
  'Revenue per film category for the quarter given as ''YYYY-Qn'' (default: current quarter = same result as view core.sales_revenue_by_category_qtr). Invalid quarter -> error; quarter without payments -> empty set.';

-- ---- Task 2 tests ---------------------------------------------------------
-- 2.1 Valid input: the quarter of the last payment in the DB (a quarter WITH data).
--     Expected: one row per category that had sales, highest revenue first.
SELECT *
FROM   core.get_sales_revenue_by_category_qtr(
           to_char((SELECT MAX(payment_date) FROM public.payment), 'YYYY-"Q"Q'));

-- 2.2 Optional parameter omitted = current quarter = must equal the view.
--     Expected: 0 (rows that differ in either direction).
SELECT COUNT(*) AS differing_rows
FROM (
    (SELECT * FROM core.sales_revenue_by_category_qtr
     EXCEPT
     SELECT * FROM core.get_sales_revenue_by_category_qtr())
    UNION ALL
    (SELECT * FROM core.get_sales_revenue_by_category_qtr()
     EXCEPT
     SELECT * FROM core.sales_revenue_by_category_qtr)
) d;

-- 2.3 Edge: valid quarter that has no data -> empty result, no error. Expected: 0 rows.
SELECT * FROM core.get_sales_revenue_by_category_qtr('1999-Q1');

-- 2.4 Edge / invalid input: quarter 5 and a wrong format -> errors (caught and printed).
DO $test$
DECLARE
    v_bad text;
BEGIN
    FOREACH v_bad IN ARRAY ARRAY['2026-Q5', '2026-Q0', '2026-3', 'abc'] LOOP
        BEGIN
            PERFORM * FROM core.get_sales_revenue_by_category_qtr(v_bad);
            RAISE NOTICE 'TEST FAILED: % was accepted', v_bad;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'OK - input % rejected: % (SQLSTATE %)', quote_literal(v_bad), SQLERRM, SQLSTATE;
        END;
    END LOOP;
END
$test$;


/*
===============================================================================
 TASK 3. PL/pgSQL FUNCTION  core.most_popular_films_by_countries(text[])
===============================================================================
 WHY THIS LOGIC
   For every requested country we need ONE film: the most popular among
   customers living in that country. Customer -> address -> city -> country
   gives "where the customer lives"; rentals of those customers are counted
   per film. ROW_NUMBER() per country picks the winner, so exactly one film per
   country comes back (the task's sample output has one row per country).

 HOW 'MOST POPULAR' IS DEFINED  -> BY NUMBER OF RENTALS
   COUNT(DISTINCT rental_id) of the country's customers per film
   (a rental = a customer actually took the film; the number of copies in
   inventory does not distort it, and DISTINCT protects against multiplication
   when a rental has several payments). Revenue is used only as a tie-breaker.

 HOW TIES ARE HANDLED (deterministic - same input, same answer every run)
   most rentals  ->  highest revenue (SUM(payment.amount))  ->  title A-Z
   ->  lowest film_id. Only the first one is returned.

 INPUT NORMALISATION
   Names are trimmed and compared case-insensitively ('  brazil ' = 'Brazil');
   duplicates in the array are collapsed; NULL / blank elements are ignored.

 WHAT HAPPENS IF INPUT IS INCORRECT
   * NULL or empty array, or an array with only blank elements
       -> RAISE EXCEPTION (SQLSTATE 22023 invalid_parameter_value).
   * A name that is not in the country table (typo, 'Atlantis')
       -> NOT an exception, so one typo does not kill a report for 10
          countries: the country is still returned, film columns NULL, and a
          NOTICE says "country not found". The caller sees the problem.

 WHAT HAPPENS IF A COUNTRY HAS NO DATA
   A real country with no customers / no rentals is returned with NULL in the
   film columns and a NOTICE - the row is kept so the caller can tell
   "no data" from "country not requested".

 OUTPUT TYPES: rating enum -> text, language char/varchar -> trimmed text,
   length/release_year -> integer.
===============================================================================
*/
CREATE OR REPLACE FUNCTION core.most_popular_films_by_countries(p_countries text[])
RETURNS TABLE (country text, film text, rating text, language text, length integer, release_year integer)
LANGUAGE plpgsql
STABLE
AS $func$
#variable_conflict use_column
DECLARE
    v_rec record;
BEGIN
    -- 1. Validate the parameter
    IF p_countries IS NULL OR cardinality(p_countries) = 0 THEN
        RAISE EXCEPTION 'most_popular_films_by_countries: p_countries must be a non-empty array of country names'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM unnest(p_countries) AS c WHERE NULLIF(btrim(c), '') IS NOT NULL) THEN
        RAISE EXCEPTION 'most_popular_films_by_countries: p_countries contains only NULL/blank values'
            USING ERRCODE = '22023';
    END IF;

    -- 2. One row per requested country (even when it has no data); film chosen by rentals
    FOR v_rec IN
        WITH req AS (                                   -- normalised, de-duplicated request
            SELECT DISTINCT ON (lower(btrim(c)))
                   lower(btrim(c)) AS key,
                   btrim(c)        AS input_name
            FROM   unnest(p_countries) AS c
            WHERE  NULLIF(btrim(c), '') IS NOT NULL
            ORDER  BY lower(btrim(c)), btrim(c)
        ),
        req_country AS (                                -- map to real countries (if they exist)
            SELECT req.key, req.input_name, co.country_id, co.country AS country_name
            FROM   req
            LEFT   JOIN public.country co ON lower(btrim(co.country)) = req.key
        ),
        film_stats AS (                                 -- popularity per (country, film)
            SELECT rc.key,
                   i.film_id,
                   COUNT(DISTINCT r.rental_id)  AS rentals,
                   COALESCE(SUM(pay.amount), 0) AS revenue
            FROM   req_country rc
            JOIN   public.city      ci  ON ci.country_id  = rc.country_id
            JOIN   public.address   a   ON a.city_id      = ci.city_id
            JOIN   public.customer  cu  ON cu.address_id  = a.address_id
            JOIN   public.rental    r   ON r.customer_id  = cu.customer_id
            JOIN   public.inventory i   ON i.inventory_id = r.inventory_id
            LEFT   JOIN public.payment pay ON pay.rental_id = r.rental_id
            GROUP  BY rc.key, i.film_id
        ),
        ranked AS (                                     -- 1 = winner, ties broken deterministically
            SELECT fs.key, fs.film_id,
                   ROW_NUMBER() OVER (PARTITION BY fs.key
                                      ORDER BY fs.rentals DESC, fs.revenue DESC, f.title, f.film_id) AS rn
            FROM   film_stats fs
            JOIN   public.film f ON f.film_id = fs.film_id
        )
        SELECT  COALESCE(rc.country_name, rc.input_name)  AS country_name,
                (rc.country_id IS NULL)                   AS unknown_country,
                f.title::text                             AS film_title,
                f.rating::text                            AS rating_text,
                btrim(l.name::text)                       AS language_name,
                f.length::int                             AS length_min,
                f.release_year::int                       AS year_released
        FROM    req_country rc
        LEFT    JOIN ranked        rk ON rk.key = rc.key AND rk.rn = 1
        LEFT    JOIN public.film   f  ON f.film_id = rk.film_id
        LEFT    JOIN public.language l ON l.language_id = f.language_id
        ORDER   BY 1
    LOOP
        IF v_rec.unknown_country THEN
            RAISE NOTICE 'most_popular_films_by_countries: country "%" does not exist in the country table', v_rec.country_name;
        ELSIF v_rec.film_title IS NULL THEN
            RAISE NOTICE 'most_popular_films_by_countries: no rental data for country "%"', v_rec.country_name;
        END IF;

        country      := v_rec.country_name;
        film         := v_rec.film_title;
        rating       := v_rec.rating_text;
        language     := v_rec.language_name;
        length       := v_rec.length_min;
        release_year := v_rec.year_released;
        RETURN NEXT;
    END LOOP;
END;
$func$;

COMMENT ON FUNCTION core.most_popular_films_by_countries(text[]) IS
  'Most rented film (ties: revenue, title, film_id) among customers living in each requested country. NULL/empty input -> exception; unknown country or no rentals -> row with NULL film + NOTICE.';

-- ---- Task 3 tests ---------------------------------------------------------
-- 3.1 Valid input (the example from the task).
SELECT * FROM core.most_popular_films_by_countries(array['Afghanistan','Brazil','United States']);

-- 3.2 Edge input: different case/spaces, a duplicate, a NULL element and a country
--     that does not exist. Expected: Brazil once (cleaned), 'Atlantis' with NULL
--     film columns + a NOTICE; nothing fails.
SELECT * FROM core.most_popular_films_by_countries(array['  brazil ', 'BRAZIL', NULL, 'Atlantis']);

-- 3.3 Invalid input -> exceptions (caught and printed).
DO $test$
DECLARE
    v_case record;
BEGIN
    FOR v_case IN
        SELECT * FROM (VALUES
            ('NULL array',        NULL::text[]),
            ('empty array',       '{}'::text[]),
            ('only NULL / blank', ARRAY[NULL, '  ']::text[])
        ) AS t(case_name, input)
    LOOP
        BEGIN
            PERFORM * FROM core.most_popular_films_by_countries(v_case.input);
            RAISE NOTICE 'TEST FAILED: % was accepted', v_case.case_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'OK - %: % (SQLSTATE %)', v_case.case_name, SQLERRM, SQLSTATE;
        END;
    END LOOP;
END
$test$;


/*
===============================================================================
 TASK 4. PL/pgSQL FUNCTION  core.films_in_stock_by_title(p_title_pattern text)
===============================================================================
 WHY THIS LOGIC
   Staff type part of a title ('%love%') and want to know which matching films
   can be handed out right now and who rented them last.

 WHAT 'IN STOCK' MEANS
   A film is in stock when at least one of its inventory copies is on the shelf.
   A copy is on the shelf when it has no open rental (return_date IS NULL).
   This is the same rule as the database's own inventory_in_stock(), but written
   set-based with NOT EXISTS instead of calling that function once per row.

 HOW THE RESULT IS CALCULATED (one row per film)
   * film_title / language : the film and its language (name trimmed).
   * customer_name / rental_date : the MOST RECENT rental (latest rental_date,
     rental_id as tie-break) among the copies that are in stock now, i.e. the
     last customer who took and returned that film. A film in stock that has
     never been rented has NULL customer and date (LEFT JOIN keeps it).
   * row_num : ROW_NUMBER() over title A-Z -> 1, 2, 3 ... generated per call.

 HOW PATTERN MATCHING WORKS (LIKE / %)
   The caller passes the pattern including wildcards: '%love%' = title contains
   "love" anywhere; 'love%' = starts with; '%love' = ends with; '_' = exactly
   one character. Without % or _ the match is a case-insensitive exact title.

 CASE SENSITIVITY
   ILIKE is used, so '%LOVE%', '%love%' and '%Love%' all return the same films.
   Whatever case the titles are stored in (upper in some copies of the DB,
   capitalised in others) the result is the same.

 PERFORMANCE
   * The only potentially slow part is the pattern search: a leading wildcard
     ('%love%') cannot use a B-tree index on film.title, so the title filter is
     a scan of the film table. film is small (1000 rows) and is scanned ONCE.
   * Everything big (inventory 4.5k rows, rental 16-50k+ rows) is touched only
     AFTER the title filter, and only for the matched film_ids: matching films
     -> their copies -> NOT EXISTS probe on rental(inventory_id) -> one
     "latest rental" lookup per film (ORDER BY ... LIMIT 1). No rental history
     of unrelated films is read, no per-row function calls, no DISTINCT over
     the big tables.
   * If film ever becomes huge: CREATE EXTENSION pg_trgm; CREATE INDEX ON
     film USING gin (title gin_trgm_ops); makes ILIKE '%x%' index-assisted.
     (Not created here: it needs the extension/privileges.)

 WHAT HAPPENS IF
   * multiple matches : every matching film that is in stock is returned,
     one row each, numbered 1..N.
   * no matches       : a single row is returned whose film_title holds the
     message "Film matching '<pattern>' was not found in stock" (row_num and
     the other columns NULL). This covers both "no such title" and "title
     exists but all copies are rented out".
   * pattern is NULL, blank or only wildcards ('%', '__')
       -> RAISE EXCEPTION (SQLSTATE 22023): such a pattern would return the
          whole catalogue and is almost certainly a caller bug.
===============================================================================
*/
CREATE OR REPLACE FUNCTION core.films_in_stock_by_title(p_title_pattern text)
RETURNS TABLE (row_num integer, film_title text, language_name text, customer_name text, rental_date timestamp)
LANGUAGE plpgsql
STABLE
AS $func$
#variable_conflict use_column
BEGIN
    IF p_title_pattern IS NULL
       OR btrim(p_title_pattern) = ''
       OR btrim(p_title_pattern) ~ '^[%_]+$' THEN
        RAISE EXCEPTION 'films_in_stock_by_title: pattern must contain at least one literal character (got %)',
                        COALESCE(quote_literal(p_title_pattern), 'NULL')
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH matched_films AS (                    -- 1) cheap filter on the small table first
        SELECT f.film_id, f.title, f.language_id
        FROM   public.film f
        WHERE  f.title ILIKE p_title_pattern
    ),
    copies_on_shelf AS (                       -- 2) only copies of matched films with no open rental
        SELECT i.inventory_id, i.film_id
        FROM   public.inventory i
        JOIN   matched_films mf ON mf.film_id = i.film_id
        WHERE  NOT EXISTS (SELECT 1
                           FROM   public.rental r
                           WHERE  r.inventory_id = i.inventory_id
                             AND  r.return_date IS NULL)
    ),
    films_in_stock AS (
        SELECT DISTINCT film_id FROM copies_on_shelf
    )
    SELECT  (ROW_NUMBER() OVER (ORDER BY mf.title, mf.film_id))::int  AS row_num,
            mf.title::text                                            AS film_title,
            btrim(l.name::text)                                       AS language_name,
            (cu.first_name || ' ' || cu.last_name)::text              AS customer_name,
            lr.rental_date::timestamp                                 AS rental_date
    FROM    matched_films mf
    JOIN    films_in_stock fis    ON fis.film_id = mf.film_id
    JOIN    public.language l     ON l.language_id = mf.language_id
    LEFT    JOIN LATERAL (                     -- 3) last rental of an in-stock copy of this film
                SELECT r.rental_date, r.customer_id
                FROM   public.rental r
                JOIN   copies_on_shelf cs ON cs.inventory_id = r.inventory_id
                WHERE  cs.film_id = mf.film_id
                ORDER  BY r.rental_date DESC, r.rental_id DESC
                LIMIT  1
            ) lr ON TRUE
    LEFT    JOIN public.customer cu ON cu.customer_id = lr.customer_id
    ORDER   BY mf.title, mf.film_id;

    IF NOT FOUND THEN                          -- RETURN QUERY sets FOUND = false when 0 rows were returned
        RETURN QUERY
        SELECT NULL::integer,
               format('Film matching %L was not found in stock', p_title_pattern),
               NULL::text, NULL::text, NULL::timestamp;
    END IF;
END;
$func$;

COMMENT ON FUNCTION core.films_in_stock_by_title(text) IS
  'Films matching a LIKE pattern (case-insensitive) with at least one copy on the shelf, plus the last customer/rental of those copies. Nothing found -> one message row. NULL/blank/wildcard-only pattern -> exception.';

-- ---- Task 4 tests ---------------------------------------------------------
-- 4.1 Valid input (the example from the task); row_num starts at 1.
SELECT * FROM core.films_in_stock_by_title('%love%');

-- 4.2 Same search in different case -> must return the same films.
SELECT COUNT(*) AS rows_for_upper_case,
       (SELECT COUNT(*) FROM core.films_in_stock_by_title('%LoVe%')) AS rows_for_mixed_case
FROM   core.films_in_stock_by_title('%LOVE%');

-- 4.3 Edge input: nothing matches -> one row with the "not found" message.
SELECT * FROM core.films_in_stock_by_title('%zzzzqqqq%');

-- 4.4 Invalid input -> exceptions (caught and printed).
DO $test$
DECLARE
    v_bad text;
BEGIN
    FOREACH v_bad IN ARRAY ARRAY[NULL, '', '   ', '%', '%%', '_%'] LOOP
        BEGIN
            PERFORM * FROM core.films_in_stock_by_title(v_bad);
            RAISE NOTICE 'TEST FAILED: pattern % was accepted', COALESCE(quote_literal(v_bad), 'NULL');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'OK - pattern % rejected: % (SQLSTATE %)', COALESCE(quote_literal(v_bad), 'NULL'), SQLERRM, SQLSTATE;
        END;
    END LOOP;
END
$test$;


/*
===============================================================================
 TASK 5. PL/pgSQL FUNCTION
         core.new_movie(p_title text, p_release_year integer DEFAULT NULL,
                        p_language text DEFAULT NULL)  RETURNS integer
===============================================================================
 WHY THIS LOGIC
   One safe entry point for adding a movie: all business defaults (rental rate
   4.99, rental duration 3 days, replacement cost 19.99, release year = now,
   language = Klingon) live in one place and every check runs before anything
   is written.

 OPTIONAL PARAMETERS
   p_release_year omitted/NULL -> current year (EXTRACT(YEAR FROM CURRENT_DATE)).
   p_language     omitted/NULL/blank -> 'Klingon'.
   The function returns the film_id of the new row.

 HOW THE UNIQUE ID IS GENERATED
   film.film_id is filled by the table's own sequence (DEFAULT nextval(...)):
   the column is omitted from the INSERT and the value is taken back with
   RETURNING film_id. A sequence never hands the same number to two sessions,
   so it is safe under concurrency, and (unlike SELECT MAX(film_id)+1) it needs
   no lock and no ID is hard-coded.

 HOW DUPLICATES ARE PREVENTED / WHAT HAPPENS IF THE MOVIE ALREADY EXISTS
   film.title has no UNIQUE constraint, so the function enforces it:
   it looks for a film with the same title ignoring case and surrounding spaces
   ('dune' = ' DUNE ') and, if found, RAISES EXCEPTION (SQLSTATE 23505
   unique_violation) with the existing title in the message; nothing is
   inserted. To stop two sessions inserting the same new title at the same
   moment (both would pass the check), a transaction-level advisory lock on the
   normalised title serialises them: the second session waits, then sees the
   first one's row and fails with the duplicate error. The lock is released
   automatically at COMMIT/ROLLBACK.

 HOW LANGUAGE EXISTENCE IS VALIDATED
   The language is looked up by name (case-insensitive, trimmed) in the
   language table and its language_id is used - no ID is hard-coded. If it is
   not found -> RAISE EXCEPTION (SQLSTATE 23503 foreign_key_violation), nothing
   is inserted. NOTE: 'Klingon' is not part of the standard dvd_rental data; the
   test section adds it once (idempotently) so the default works.

 OTHER VALIDATION (incorrect parameters)
   * title NULL / blank          -> exception 22004 (null_value_not_allowed)
   * year outside 1901..2155     -> exception 22003 (the range of the table's
                                    "year" domain)

 WHAT HAPPENS IF THE INSERT FAILS
   Any error raised by the INSERT (constraint, trigger, permission, ...) is
   caught in an inner block, whose changes are rolled back, and re-raised with
   a clear message that names the title and the original error. Because
   validation happens first and the INSERT is a single statement, the function
   either inserts exactly one complete row or nothing.

 HOW CONSISTENCY IS PRESERVED
   * all checks (title, year, language, duplicate) run BEFORE the write;
   * one INSERT of one row = atomic; the caller's transaction decides COMMIT or
     ROLLBACK (the function never commits by itself);
   * the advisory lock closes the check-then-insert race;
   * table defaults/constraints/triggers (last_update, the full-text trigger,
     the year domain, FK to language) still apply as for any insert.
   Side note: a rolled-back call leaves a gap in the film_id sequence - normal
   and harmless for sequences.
===============================================================================
*/
CREATE OR REPLACE FUNCTION core.new_movie(
        p_title         text,
        p_release_year  integer DEFAULT NULL,
        p_language      text    DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
AS $func$
DECLARE
    v_title        text := btrim(p_title);
    v_year         integer := COALESCE(p_release_year, EXTRACT(YEAR FROM CURRENT_DATE)::integer);
    v_language     text := COALESCE(NULLIF(btrim(p_language), ''), 'Klingon');
    v_language_id  integer;
    v_existing     text;
    v_film_id      integer;
BEGIN
    -- 1. Validate input
    IF v_title IS NULL OR v_title = '' THEN
        RAISE EXCEPTION 'new_movie: title must not be NULL or empty' USING ERRCODE = '22004';
    END IF;

    IF v_year NOT BETWEEN 1901 AND 2155 THEN
        RAISE EXCEPTION 'new_movie: release year % is outside the allowed range 1901..2155', v_year
            USING ERRCODE = '22003';
    END IF;

    -- 2. The language must exist (looked up by name, no hard-coded id)
    SELECT l.language_id
    INTO   v_language_id
    FROM   public.language l
    WHERE  lower(btrim(l.name::text)) = lower(v_language)
    ORDER  BY l.language_id
    LIMIT  1;

    IF v_language_id IS NULL THEN
        RAISE EXCEPTION 'new_movie: language "%" does not exist in the language table', v_language
            USING ERRCODE = '23503';
    END IF;

    -- 3. Serialise concurrent inserts of the same title, then check for a duplicate
    PERFORM pg_advisory_xact_lock(hashtextextended('core.new_movie:' || lower(v_title), 0));

    SELECT f.title::text
    INTO   v_existing
    FROM   public.film f
    WHERE  lower(btrim(f.title::text)) = lower(v_title)
    LIMIT  1;

    IF v_existing IS NOT NULL THEN
        RAISE EXCEPTION 'new_movie: movie "%" already exists in the film table (as "%")', v_title, v_existing
            USING ERRCODE = '23505';
    END IF;

    -- 4. Insert exactly one row; film_id comes from the table's sequence default
    BEGIN
        INSERT INTO public.film (title, release_year, language_id,
                                 rental_duration, rental_rate, replacement_cost)
        VALUES (v_title, v_year, v_language_id,
                3, 4.99, 19.99)
        RETURNING film_id INTO v_film_id;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'new_movie: insert of movie "%" failed: % (SQLSTATE %)', v_title, SQLERRM, SQLSTATE;
    END;

    RAISE NOTICE 'new_movie: movie "%" created with film_id %', v_title, v_film_id;
    RETURN v_film_id;
END;
$func$;

COMMENT ON FUNCTION core.new_movie(text, integer, text) IS
  'Inserts a film (rate 4.99, 3 days, replacement cost 19.99; year default = current, language default = Klingon). Validates title/year/language, rejects duplicate titles (case-insensitive) with an exception; returns the new film_id.';

-- ---- Task 5 tests ---------------------------------------------------------
-- Prerequisite: the default language 'Klingon' must exist. Added once and only
-- if missing (safe to re-run); it is intentionally NOT rolled back below.
INSERT INTO public.language (name)
SELECT 'Klingon'
WHERE  NOT EXISTS (SELECT 1 FROM public.language l WHERE lower(btrim(l.name::text)) = 'klingon');

-- All tests below write data inside a transaction that is rolled back at the end,
-- so the script leaves the film table untouched and can be re-run.
BEGIN;

-- 5.1 Valid input, optional parameters omitted -> defaults (current year, Klingon).
SELECT core.new_movie('Hw Test Movie Alpha') AS new_film_id;

--     Expected: rental_rate 4.99, rental_duration 3, replacement_cost 19.99,
--     release_year = current year, language = Klingon.
SELECT f.film_id, f.title, f.release_year, l.name AS language,
       f.rental_duration, f.rental_rate, f.replacement_cost
FROM   public.film f
JOIN   public.language l ON l.language_id = f.language_id
WHERE  f.title = 'Hw Test Movie Alpha';

-- 5.2 Valid input with the optional parameters given (year 2020, English).
SELECT core.new_movie('Hw Test Movie Beta', 2020, 'english') AS new_film_id;   -- language name is case-insensitive

SELECT f.title, f.release_year, l.name AS language
FROM   public.film f
JOIN   public.language l ON l.language_id = f.language_id
WHERE  f.title = 'Hw Test Movie Beta';

-- 5.3 Edge / invalid inputs -> each must raise an exception (caught and printed),
--     and nothing is inserted.
DO $test$
DECLARE
    v_case record;
BEGIN
    FOR v_case IN
        SELECT * FROM (VALUES
            ('duplicate title (other case, extra spaces)', '  HW TEST movie alpha ', NULL::int,  NULL::text),
            ('language does not exist',                    'Hw Test Movie Gamma',     NULL,       'Elvish'),
            ('release year out of range',                  'Hw Test Movie Delta',     1850,       NULL),
            ('NULL title',                                 NULL,                      NULL,       NULL),
            ('blank title',                                '   ',                     NULL,       NULL)
        ) AS t(case_name, title, year, lang)
    LOOP
        BEGIN
            PERFORM core.new_movie(v_case.title, v_case.year, v_case.lang);
            RAISE NOTICE 'TEST FAILED: "%" was accepted', v_case.case_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'OK - %: % (SQLSTATE %)', v_case.case_name, SQLERRM, SQLSTATE;
        END;
    END LOOP;
END
$test$;

-- 5.4 Proof that the failed calls inserted nothing: only Alpha and Beta exist.
--     Expected: 2 rows.
SELECT f.title FROM public.film f WHERE f.title LIKE 'Hw Test Movie%' ORDER BY f.title;

ROLLBACK;   -- removes Alpha and Beta again; film is back to its original state

-- 5.5 After the rollback the test movies must be gone. Expected: 0.
SELECT COUNT(*) AS leftover_test_movies FROM public.film WHERE title LIKE 'Hw Test Movie%';
