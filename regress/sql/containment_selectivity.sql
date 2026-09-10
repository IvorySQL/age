/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

/*
 * Selectivity bindings for the agtype containment (@>, <@, @>>, <<@) and
 * key-existence (?, ?|, ?&) operators, and behaviour of the statistics-aware
 * estimator bound to @> and @>>.
 *
 * History:
 *   - Before #2356 all seven operators used matchingsel / matchingjoinsel.
 *     matchingsel probes the statistics of the whole properties column and
 *     calls agtype_contains() once per MCV / histogram entry at plan time,
 *     which produced a 30%+ planning-time regression on point queries. Those
 *     whole-column statistics also carry no information about any one key,
 *     so the estimate was wrong anyway (it bottoms out at PostgreSQL's 1e-4
 *     floor). #2356 rebound everything to contsel / contjoinsel.
 *   - contsel returns a fixed 0.001. On a multi-hop MATCH the resulting
 *     overestimate of a selective start vertex pushes the planner from
 *     per-vertex index probes to a full scan of every edge table. @> and @>>
 *     are now bound to agtype_contains_sel, which decomposes the constant
 *     into per-key equalities on agtype_access_operator(properties, '"key"')
 *     and reads the expression statistics users attach to that expression.
 *     It never touches the properties column's statistics and never calls
 *     agtype_contains() at plan time, so the #2356 regression cannot recur.
 *     Without expression statistics it returns exactly what contsel did.
 *
 * This file pins the bindings via pg_operator so that a re-introduction of
 * matchingsel is loud, and asserts the estimator's two contracts:
 *   1. an inline property map and the equivalent WHERE clause estimate the
 *      same number of rows once expression statistics exist;
 *   2. without expression statistics, or with
 *      age.enable_containment_statistics = off, the estimate is the one
 *      contsel produced.
 */

LOAD 'age';
SET search_path TO ag_catalog;

-- Selectivity helpers for the four containment operators.
SELECT o.oprname,
       pg_catalog.format_type(o.oprleft,  NULL) AS lhs,
       pg_catalog.format_type(o.oprright, NULL) AS rhs,
       o.oprrest::text  AS restrict_fn,
       o.oprjoin::text  AS join_fn
FROM   pg_catalog.pg_operator o
JOIN   pg_catalog.pg_namespace n ON n.oid = o.oprnamespace
WHERE  n.nspname = 'ag_catalog'
  AND  o.oprname IN ('@>', '<@', '@>>', '<<@')
ORDER  BY o.oprname, lhs, rhs;

-- Selectivity helpers for all key-existence operator overloads
-- (right-hand side may be text, text[], or agtype).
SELECT o.oprname,
       pg_catalog.format_type(o.oprleft,  NULL) AS lhs,
       pg_catalog.format_type(o.oprright, NULL) AS rhs,
       o.oprrest::text  AS restrict_fn,
       o.oprjoin::text  AS join_fn
FROM   pg_catalog.pg_operator o
JOIN   pg_catalog.pg_namespace n ON n.oid = o.oprnamespace
WHERE  n.nspname = 'ag_catalog'
  AND  o.oprname IN ('?', '?|', '?&')
ORDER  BY o.oprname, lhs, rhs;

-- Scoped guard for issue #2356: none of these operators may be bound to
-- matchingsel / matchingjoinsel. The check is limited to these operator names
-- so unrelated operators that legitimately use matchingsel are not affected.
SELECT COUNT(*) AS leaked_matchingsel_bindings
FROM   pg_catalog.pg_operator o
JOIN   pg_catalog.pg_namespace n ON n.oid = o.oprnamespace
WHERE  n.nspname = 'ag_catalog'
  AND  o.oprname IN ('@>', '<@', '@>>', '<<@', '?', '?|', '?&')
  AND  (o.oprrest::text  = 'matchingsel'
        OR o.oprjoin::text = 'matchingjoinsel');

-- Smoke test: each operator still works functionally. Selectivity binding
-- only affects the planner; this guards against an inadvertent operator
-- removal as part of any future cleanup.
SELECT '{"a":1,"b":2}'::agtype @>  '{"a":1}'::agtype             AS contains_yes;
SELECT '{"a":1}'::agtype       <@  '{"a":1,"b":2}'::agtype       AS contained_yes;
SELECT '{"a":{"b":1}}'::agtype @>> '{"a":{"b":1}}'::agtype       AS top_contains_yes;
SELECT '{"a":{"b":1}}'::agtype <<@ '{"a":{"b":1}}'::agtype       AS top_contained_yes;
SELECT '{"a":1}'::agtype       ?   'a'::text                     AS exists_text_yes;
SELECT '{"a":1}'::agtype       ?   '"a"'::agtype                 AS exists_agtype_yes;
SELECT '{"a":1,"b":2}'::agtype ?|  ARRAY['a','c']                AS exists_any_text_yes;
SELECT '{"a":1,"b":2}'::agtype ?|  '["a","c"]'::agtype           AS exists_any_agtype_yes;
SELECT '{"a":1,"b":2}'::agtype ?&  ARRAY['a','b']                AS exists_all_text_yes;
SELECT '{"a":1,"b":2}'::agtype ?&  '["a","b"]'::agtype           AS exists_all_agtype_yes;

--
-- Estimator behaviour.
--
-- csel_plan_rows() returns the planner's row estimate for the scan of the
-- given relation inside EXPLAIN output. Comparing two estimates (rather than
-- printing them) keeps the expected output free of magic numbers that would
-- drift with statistics targets.
--
CREATE FUNCTION csel_plan_rows(q text, rel text) RETURNS numeric
LANGUAGE plpgsql AS $fn$
DECLARE
    j json;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS ON) ' || q INTO j;
    RETURN (pg_catalog.jsonb_path_query_first(
                j::jsonb,
                ('$.** ? (@."Relation Name" == "' || rel || '")."Plan Rows"')::jsonpath
            ))::text::numeric;
END
$fn$;

SELECT create_graph('csel');
SELECT create_vlabel('csel', 'V');

-- 3000 vertices: uid unique, city one of 30, grp one of 4, addr.zip one of 10.
INSERT INTO csel."V" (id, properties)
SELECT ag_catalog._graphid((SELECT l.id FROM ag_catalog.ag_label l
                             JOIN ag_catalog.ag_graph g ON g.graphid = l.graph
                             WHERE g.name = 'csel' AND l.name = 'V'), i::bigint),
       ('{"uid": ' || i || ', "city": "c' || (i % 30) || '", "grp": ' ||
        (i % 4) || ', "addr": {"zip": ' || (i % 10) || '}}')::agtype
FROM pg_catalog.generate_series(1, 3000) AS i;
ANALYZE csel."V";

-- Before any expression statistics exist, the inline map must estimate
-- exactly as it did under contsel: a fixed 0.001 of the table.
CREATE TEMP TABLE csel_baseline AS
SELECT csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {uid: 7}) RETURN n $$) AS (n agtype)$q$, 'V') AS rows_no_stats;

SELECT rows_no_stats = pg_catalog.round(3000 * 0.001) AS no_stats_matches_contsel
FROM csel_baseline;

-- Attach expression statistics: an index on uid and city, a statistics object
-- (no index) on the nested addr.zip. grp deliberately gets none.
CREATE INDEX csel_v_uid_idx  ON csel."V" (agtype_access_operator(properties, '"uid"'::agtype));
CREATE INDEX csel_v_city_idx ON csel."V" (agtype_access_operator(properties, '"city"'::agtype));
CREATE STATISTICS csel_v_zip_stat ON (agtype_access_operator(properties, '"addr"'::agtype, '"zip"'::agtype)) FROM csel."V";
ANALYZE csel."V";

-- Contract 1: inline map == WHERE clause, per key shape.
-- unique key
SELECT csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {uid: 7}) RETURN n $$) AS (n agtype)$q$, 'V')
     = csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V) WHERE n.uid = 7 RETURN n $$) AS (n agtype)$q$, 'V')
       AS unique_key_equal,
       csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {uid: 7}) RETURN n $$) AS (n agtype)$q$, 'V')
       AS unique_key_rows;

-- low-cardinality key (MCV hit)
SELECT csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {city: 'c3'}) RETURN n $$) AS (n agtype)$q$, 'V')
     = csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V) WHERE n.city = 'c3' RETURN n $$) AS (n agtype)$q$, 'V')
       AS lowcard_key_equal,
       csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {city: 'c3'}) RETURN n $$) AS (n agtype)$q$, 'V')
       AS lowcard_key_rows;

-- two keys, one with statistics and one without
SELECT csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {city: 'c3', grp: 1}) RETURN n $$) AS (n agtype)$q$, 'V')
     = csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V) WHERE n.city = 'c3' AND n.grp = 1 RETURN n $$) AS (n agtype)$q$, 'V')
       AS mixed_keys_equal;

-- nested key backed by CREATE STATISTICS rather than an index
SELECT csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {addr: {zip: 5}}) RETURN n $$) AS (n agtype)$q$, 'V')
     = csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V) WHERE n.addr.zip = 5 RETURN n $$) AS (n agtype)$q$, 'V')
       AS nested_key_equal;

-- top-level containment form (=properties) on a scalar key
SELECT csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V ={uid: 7}) RETURN n $$) AS (n agtype)$q$, 'V')
     = csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V) WHERE n.uid = 7 RETURN n $$) AS (n agtype)$q$, 'V')
       AS top_level_equal;

-- a key that has no statistics at all still estimates as contsel did
SELECT csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {grp: 1}) RETURN n $$) AS (n agtype)$q$, 'V')
     = rows_no_stats AS unknown_key_matches_contsel
FROM csel_baseline;

-- Contract 2: the GUC restores the contsel estimate.
SET age.enable_containment_statistics = off;
SELECT csel_plan_rows($q$SELECT * FROM cypher('csel', $$ MATCH (n:V {uid: 7}) RETURN n $$) AS (n agtype)$q$, 'V')
     = rows_no_stats AS guc_off_matches_contsel
FROM csel_baseline;
RESET age.enable_containment_statistics;

-- Results are unaffected by the estimator.
SELECT * FROM cypher('csel', $$ MATCH (n:V {uid: 7}) RETURN n.city $$) AS (city agtype);
SELECT * FROM cypher('csel', $$ MATCH (n:V {city: 'c3', grp: 1}) RETURN count(n) $$) AS (c agtype);
SELECT * FROM cypher('csel', $$ MATCH (n:V {addr: {zip: 5}}) RETURN count(n) $$) AS (c agtype);

SELECT drop_graph('csel', true);
DROP FUNCTION csel_plan_rows(text, text);

--
-- Upgrade-path assertion.
--
-- The checks above cover a FRESH install. Existing installs pick up the
-- bindings from the ALTER OPERATOR blocks shipped in the upgrade scripts and
-- replayed by "ALTER EXTENSION age UPDATE". We replay those statements
-- directly rather than running ALTER EXTENSION: the dev upgrade script targets
-- the placeholder version "y.y.y" and is not a stable version-chain target
-- inside the regression harness. The section runs in a transaction that is
-- rolled back, so the operator catalog is not permanently mutated.
BEGIN;

-- Simulate a stale (pre-#2356) install: force all ten overloads back onto
-- matchingsel / matchingjoinsel.
ALTER OPERATOR ag_catalog.@>(agtype, agtype)   SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.<@(agtype, agtype)   SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.@>>(agtype, agtype)  SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.<<@(agtype, agtype)  SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.?(agtype, text)      SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.?(agtype, agtype)    SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.?|(agtype, text[])   SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.?|(agtype, agtype)   SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.?&(agtype, text[])   SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);
ALTER OPERATOR ag_catalog.?&(agtype, agtype)   SET (RESTRICT = matchingsel, JOIN = matchingjoinsel);

-- Stale state: every overload now reports matchingsel / matchingjoinsel.
SELECT o.oprname,
       pg_catalog.format_type(o.oprleft,  NULL) AS lhs,
       pg_catalog.format_type(o.oprright, NULL) AS rhs,
       o.oprrest::text  AS restrict_fn,
       o.oprjoin::text  AS join_fn
FROM   pg_catalog.pg_operator o
JOIN   pg_catalog.pg_namespace n ON n.oid = o.oprnamespace
WHERE  n.nspname = 'ag_catalog'
  AND  o.oprname IN ('@>', '<@', '@>>', '<<@', '?', '?|', '?&')
ORDER  BY o.oprname, lhs, rhs;

-- Replay the ALTER OPERATOR block shipped in age--1.7.0--1.8.0.sql (#2356).
ALTER OPERATOR ag_catalog.@>(agtype, agtype)   SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.<@(agtype, agtype)   SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.@>>(agtype, agtype)  SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.<<@(agtype, agtype)  SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.?(agtype, text)      SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.?(agtype, agtype)    SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.?|(agtype, text[])   SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.?|(agtype, agtype)   SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.?&(agtype, text[])   SET (RESTRICT = contsel, JOIN = contjoinsel);
ALTER OPERATOR ag_catalog.?&(agtype, agtype)   SET (RESTRICT = contsel, JOIN = contjoinsel);

-- Then the block shipped in age--1.8.0--y.y.y.sql: @> and @>> move to the
-- statistics-aware estimator; the JOIN estimator and all other operators
-- stay where #2356 put them.
ALTER OPERATOR ag_catalog.@> (agtype, agtype)  SET (RESTRICT = ag_catalog.agtype_contains_sel);
ALTER OPERATOR ag_catalog.@>> (agtype, agtype) SET (RESTRICT = ag_catalog.agtype_contains_sel);

-- After the upgrade replay the bindings match a fresh install.
SELECT o.oprname,
       pg_catalog.format_type(o.oprleft,  NULL) AS lhs,
       pg_catalog.format_type(o.oprright, NULL) AS rhs,
       o.oprrest::text  AS restrict_fn,
       o.oprjoin::text  AS join_fn
FROM   pg_catalog.pg_operator o
JOIN   pg_catalog.pg_namespace n ON n.oid = o.oprnamespace
WHERE  n.nspname = 'ag_catalog'
  AND  o.oprname IN ('@>', '<@', '@>>', '<<@', '?', '?|', '?&')
ORDER  BY o.oprname, lhs, rhs;

ROLLBACK;
