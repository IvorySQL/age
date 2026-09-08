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

--
-- Contains operators @> <@
--
CREATE FUNCTION ag_catalog.agtype_contains(agtype, agtype)
    RETURNS boolean
    LANGUAGE c
    IMMUTABLE
RETURNS NULL ON NULL INPUT
PARALLEL SAFE
AS 'MODULE_PATHNAME';

--
-- Statistics-aware restriction selectivity for @> and @>>. Decomposes a
-- constant object into per-key equalities on agtype_access_operator() and
-- consults the expression statistics users attach to that expression; falls
-- back to the constant contsel returned when none exist. See
-- agtype_selfuncs.c.
--
CREATE FUNCTION ag_catalog.agtype_contains_sel(internal, oid, internal, integer)
    RETURNS float8
    LANGUAGE c
    STABLE
    STRICT
    PARALLEL SAFE
AS 'MODULE_PATHNAME';

CREATE OPERATOR @> (
  LEFTARG = agtype,
  RIGHTARG = agtype,
  FUNCTION = ag_catalog.agtype_contains,
  COMMUTATOR = '<@',
  RESTRICT = ag_catalog.agtype_contains_sel,
  JOIN = contjoinsel
);

CREATE FUNCTION ag_catalog.agtype_contained_by(agtype, agtype)
    RETURNS boolean
    LANGUAGE c
    IMMUTABLE
RETURNS NULL ON NULL INPUT
PARALLEL SAFE
AS 'MODULE_PATHNAME';

CREATE OPERATOR <@ (
  LEFTARG = agtype,
  RIGHTARG = agtype,
  FUNCTION = ag_catalog.agtype_contained_by,
  COMMUTATOR = '@>',
  RESTRICT = contsel,
  JOIN = contjoinsel
);

CREATE FUNCTION ag_catalog.agtype_contains_top_level(agtype, agtype)
    RETURNS boolean
    LANGUAGE c
    IMMUTABLE
RETURNS NULL ON NULL INPUT
PARALLEL SAFE
AS 'MODULE_PATHNAME';

CREATE OPERATOR @>> (
  LEFTARG = agtype,
  RIGHTARG = agtype,
  FUNCTION = ag_catalog.agtype_contains_top_level,
  COMMUTATOR = '<<@',
  RESTRICT = ag_catalog.agtype_contains_sel,
  JOIN = contjoinsel
);

CREATE FUNCTION ag_catalog.agtype_contained_by_top_level(agtype, agtype)
    RETURNS boolean
    LANGUAGE c
    IMMUTABLE
RETURNS NULL ON NULL INPUT
PARALLEL SAFE
AS 'MODULE_PATHNAME';

CREATE OPERATOR <<@ (
  LEFTARG = agtype,
  RIGHTARG = agtype,
  FUNCTION = ag_catalog.agtype_contained_by_top_level,
  COMMUTATOR = '@>>',
  RESTRICT = contsel,
  JOIN = contjoinsel
);