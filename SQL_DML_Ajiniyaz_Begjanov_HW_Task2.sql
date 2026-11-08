/*
===============================================================================
 SQL DML HW - Task 2: DELETE vs VACUUM FULL vs TRUNCATE
 Author  : Ajiniyaz Begjanov
 Database: DVD rental database (schema: public)
===============================================================================
*/


/*------------------------------------------------------------------------------
 STEP 1. Create table 'table_to_delete' and fill it
 (DROP IF EXISTS makes the script rerunnable.)
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS public.table_to_delete;

CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1, (10^7)::int) AS x;   -- 10^7 rows: sequential numbers from 1 to 10 000 000

-- Refresh the planner statistics so that row_estimate is not empty in the size report
ANALYZE public.table_to_delete;


/*------------------------------------------------------------------------------
 STEP 2. Space consumed by the table (run this report again after every step below)
------------------------------------------------------------------------------*/
SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS index,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS "table"
FROM (SELECT *, total_bytes - index_bytes - COALESCE(toast_bytes, 0) AS table_bytes
      FROM (SELECT c.oid,
                   nspname                       AS table_schema,
                   relname                       AS table_name,
                   c.reltuples                   AS row_estimate,
                   pg_total_relation_size(c.oid) AS total_bytes,
                   pg_indexes_size(c.oid)        AS index_bytes,
                   pg_total_relation_size(reltoastrelid) AS toast_bytes
            FROM pg_class AS c
            LEFT JOIN pg_namespace AS n
                   ON n.oid = c.relnamespace
            WHERE relkind = 'r') AS a) AS a
WHERE table_name LIKE '%table_to_delete%';

-- Optional: live / dead row versions (statistics can lag a few seconds behind)
SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'table_to_delete';


/*------------------------------------------------------------------------------
 STEP 3. DELETE of 1/3 of the rows
 a) note the execution time of the DELETE;
 b) run the size report (STEP 2) again;
 c) VACUUM FULL VERBOSE;
 d) run the size report again and make conclusions;
 e) recreate the table.
------------------------------------------------------------------------------*/

-- 3a) DELETE - NOTE THE TIME
DELETE FROM public.table_to_delete
WHERE REPLACE(col, 'veeeeeeery_long_string', '')::int % 3 = 0;   -- removes 1/3 of all rows

-- 3b) space after DELETE: run the STEP 2 report again (and the dead-tuple query)
SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS index,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS "table"
FROM (SELECT *, total_bytes - index_bytes - COALESCE(toast_bytes, 0) AS table_bytes
      FROM (SELECT c.oid,
                   nspname                       AS table_schema,
                   relname                       AS table_name,
                   c.reltuples                   AS row_estimate,
                   pg_total_relation_size(c.oid) AS total_bytes,
                   pg_indexes_size(c.oid)        AS index_bytes,
                   pg_total_relation_size(reltoastrelid) AS toast_bytes
            FROM pg_class AS c
            LEFT JOIN pg_namespace AS n
                   ON n.oid = c.relnamespace
            WHERE relkind = 'r') AS a) AS a
WHERE table_name LIKE '%table_to_delete%';

SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'table_to_delete';

-- 3c) VACUUM FULL - NOTE THE TIME (and read the VERBOSE output)
VACUUM FULL VERBOSE public.table_to_delete;

-- 3d) space after VACUUM FULL: run the STEP 2 report again
SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS index,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS "table"
FROM (SELECT *, total_bytes - index_bytes - COALESCE(toast_bytes, 0) AS table_bytes
      FROM (SELECT c.oid,
                   nspname                       AS table_schema,
                   relname                       AS table_name,
                   c.reltuples                   AS row_estimate,
                   pg_total_relation_size(c.oid) AS total_bytes,
                   pg_indexes_size(c.oid)        AS index_bytes,
                   pg_total_relation_size(reltoastrelid) AS toast_bytes
            FROM pg_class AS c
            LEFT JOIN pg_namespace AS n
                   ON n.oid = c.relnamespace
            WHERE relkind = 'r') AS a) AS a
WHERE table_name LIKE '%table_to_delete%';

-- 3e) recreate the table (same as STEP 1)
DROP TABLE IF EXISTS public.table_to_delete;

CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1, (10^7)::int) AS x;

ANALYZE public.table_to_delete;


/*------------------------------------------------------------------------------
 STEP 4. TRUNCATE
 a) note the execution time of the TRUNCATE;
 b) compare it with the DELETE;
 c) run the size report again and make conclusions.
------------------------------------------------------------------------------*/

-- 4a) TRUNCATE - NOTE THE TIME
TRUNCATE TABLE public.table_to_delete;

-- 4c) space after TRUNCATE: run the STEP 2 report again
SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS index,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS "table"
FROM (SELECT *, total_bytes - index_bytes - COALESCE(toast_bytes, 0) AS table_bytes
      FROM (SELECT c.oid,
                   nspname                       AS table_schema,
                   relname                       AS table_name,
                   c.reltuples                   AS row_estimate,
                   pg_total_relation_size(c.oid) AS total_bytes,
                   pg_indexes_size(c.oid)        AS index_bytes,
                   pg_total_relation_size(reltoastrelid) AS toast_bytes
            FROM pg_class AS c
            LEFT JOIN pg_namespace AS n
                   ON n.oid = c.relnamespace
            WHERE relkind = 'r') AS a) AS a
WHERE table_name LIKE '%table_to_delete%';

SELECT pg_size_pretty(pg_total_relation_size('public.table_to_delete')) AS total_size;

/*
===============================================================================
 STEP 5. REPORT FOR THE MENTOR
===============================================================================

 5a) MY RESULTS (fill in with your own measurements)
 +-----------------------------------+-----------------+-------------------------------+
 | Moment                            | Table size      | Time                          |
 +-----------------------------------+-----------------+-------------------------------+
 | After CREATE TABLE ... (10^7)     |   575MB         | 27 secs 163 msec              |
 | After DELETE (1/3 of rows)        |   575MB         | DELETE: 20 secs 974 msec      |
 | After VACUUM FULL                 |   383MB         | VACUUM FULL: 14 secs 197 msec |
 | After re-creating the table       |   575MB         | 25 secs 80 msec               |
 | After TRUNCATE                    |   8192 bytes    | TRUNCATE:  115 msec           |
 +-----------------------------------+-----------------+-------------------------------+
 My conclusions from the numbers:
  - DELETE: removed one third of the rows (about 3.3 million), but the table size stayed at
            575 MB, because the deleted rows remain in the data file as dead tuples until VACUUM
            runs. It was also slow (about 21 s), because every row had to be checked and marked as deleted.
  - VACUUM FULL: rewrote the table into a new file with only the live rows, so the size
                 dropped by about one third (575 MB -> 383 MB), and the space was returned to the
                 operating system. It took about 14 s and locked the table for that whole time.
  - TRUNCATE: finished in 115 ms, about 180 times faster than DELETE, and the size dropped
              from 575 MB to 8192 bytes (only the empty table's service pages stay). It removes all
              rows at once, cannot use a WHERE clause, and does not leave dead tuples, so no VACUUM is needed.

 5b) DELETE vs TRUNCATE
 +----------------------+-------------------------------------------+---------------------------------------------+
 |                      | DELETE                                    | TRUNCATE                                    |
 +----------------------+-------------------------------------------+---------------------------------------------+
 | Execution time       | Slow on big tables: reads every row,      | Almost instant, independent of the number   |
 |                      | evaluates the WHERE (here a REPLACE+cast  | of rows: it does not scan the table, it just|
 |                      | for each row) and marks each deleted row  | switches the table to a new empty file.     |
 |                      | version; writes a lot of WAL.             |                                             |
 | Disk space           | NOT returned: deleted rows stay in the    | Returned to the OS immediately: the old     |
 |                      | file as dead tuples (table size does not  | data file is removed, the table size is     |
 |                      | change) until VACUUM / VACUUM FULL.       | ~0 bytes (the same for its indexes/TOAST).  |
 | Transaction behavior | Fully transactional, row by row (MVCC),   | Also transactional in PostgreSQL, but works |
 |                      | can remove only some rows (WHERE), fires  | on the whole table, no WHERE, takes an      |
 |                      | row-level triggers.                       | ACCESS EXCLUSIVE lock (blocks even SELECT), |
 |                      |                                           | does not fire row-level DELETE triggers.    |
 | Rollback possible?   | Yes, always (until COMMIT); the old row   | Yes in PostgreSQL (until COMMIT, inside a   |
 |                      | versions are simply still there.          | transaction block) - unlike in some other   |
 |                      |                                           | databases; the old file is kept until       |
 |                      |                                           | COMMIT. (With autocommit it is committed    |
 |                      |                                           | at once, so no rollback in practice.)       |
 +----------------------+-------------------------------------------+---------------------------------------------+

 5c) EXPLANATIONS

 Why DELETE does not free space immediately:
   PostgreSQL uses MVCC. DELETE does not physically remove the row: it only marks the row
   version as deleted by this transaction (sets xmax). Other transactions that started earlier
   may still need to see this version, and the delete could still be rolled back. The dead
   tuples stay inside the table's file, so the file (and pg_total_relation_size) keeps its
   size. Only after the transaction is committed and no one needs the old versions, a
   (auto)VACUUM marks that space as reusable INSIDE the same file for new rows - it normally
   does not shrink the file (only completely empty pages at the very end can be cut off).

 Why VACUUM FULL changes the table size:
   VACUUM FULL rewrites the whole table: it copies only the live rows into a brand-new data
   file (and rebuilds the indexes), then drops the old file. Dead space disappears, so the
   file becomes smaller (here roughly 2/3 of the original, because 1/3 of the rows was
   deleted) and the space is returned to the operating system. The price: it takes an
   ACCESS EXCLUSIVE lock for the whole time (the table is unavailable for reads and writes),
   needs extra disk space for the new copy while it runs, and is slow on big tables.

 Why TRUNCATE behaves differently:
   TRUNCATE is not a row-by-row operation. It does not touch individual rows, it assigns the
   table a new empty file (a new relfilenode) and discards the old file, so no dead tuples are
   produced and no VACUUM is needed. That is why it is nearly instant, writes very little WAL
   and frees the space immediately. The limits: no WHERE clause (all rows go), ACCESS
   EXCLUSIVE lock, no row-level DELETE triggers, and it needs CASCADE if other tables
   reference this one through foreign keys.

 How these operations affect performance and storage:
   - DELETE: heavy I/O and WAL, long running time; leaves bloat (dead tuples), so later
     sequential scans still read the dead pages and the table stays large and slower until it
     is vacuumed; frequent big DELETEs need regular (auto)VACUUM tuning.
   - VACUUM FULL: reclaims the space for good and removes bloat, but blocks the table and
     temporarily doubles the disk use; use it rarely, in a maintenance window (regular
     VACUUM is the everyday, non-blocking tool).
   - TRUNCATE: the fastest way to empty a whole table, with the best storage result, but it is
     all-or-nothing and locks the table.
===============================================================================
*/
