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

-- This will only work within a major version of PostgreSQL, not across
-- major versions.

--* This is a TEMPLATE for upgrading from the previous version of Apache AGE
--* Please adjust the below ALTER EXTENSION to reflect the -- correct version it
--* is upgrading to.

-- This will only work within a major version of PostgreSQL, not across
-- major versions.

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION age UPDATE TO '1.X.0'" to load this file. \quit

--* Please add all additions, deletions, and modifications to the end of this
--* file. We need to keep the order of these changes.
--* REMOVE ALL LINES ABOVE, and this one, that start with --*

--
-- Statistics-aware restriction selectivity for the agtype containment
-- operators.
--
-- @> and @>> were bound to contsel, which returns a fixed 0.001 without
-- reading statistics. On a MATCH with an inline property map that makes the
-- start vertex look like "0.1% of the table" regardless of the data, and on
-- multi-hop patterns the overestimate pushes the planner from per-vertex
-- index probes to a full scan of every edge table plus a hash or merge join.
--
-- agtype_contains_sel decomposes the constant into per-key equalities on
-- agtype_access_operator() and uses the expression statistics attached to
-- that expression (expression index or CREATE STATISTICS). With no such
-- statistics it returns the same 0.001 contsel did, so plans are unchanged
-- for installations that have not created any.
--
-- The JOIN estimator stays contjoinsel. <@, <<@ and the key-existence
-- operators are unchanged.
--

CREATE FUNCTION ag_catalog.agtype_contains_sel(internal, oid, internal, integer)
    RETURNS float8
    LANGUAGE c
    STABLE
    STRICT
    PARALLEL SAFE
AS 'MODULE_PATHNAME';

ALTER OPERATOR ag_catalog.@> (agtype, agtype)
    SET (RESTRICT = ag_catalog.agtype_contains_sel);

ALTER OPERATOR ag_catalog.@>> (agtype, agtype)
    SET (RESTRICT = ag_catalog.agtype_contains_sel);
