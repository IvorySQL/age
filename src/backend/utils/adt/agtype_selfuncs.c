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
 * Statistics-aware restriction selectivity for the agtype containment
 * operators @> and @>>.
 *
 * A MATCH property constraint such as (n:Label {key: value}) is compiled to
 *
 *     properties @> '{"key": value}'
 *
 * Neither stock estimator can see through that. contsel returns a fixed
 * constant. matchingsel (the binding before #2356) consults the statistics
 * of the whole properties column, which say nothing about the distribution
 * of any one key, and it is expensive: it calls agtype_contains() once per
 * MCV and histogram entry. Both give {person_id: <unique value>} and
 * {city: <one of 50>} the same estimate. On a multi-hop MATCH the resulting
 * overestimate of the start vertex pushes the planner away from per-vertex
 * index probes toward a full scan of every edge label table joined with a
 * hash or merge join.
 *
 * This estimator decomposes the constant exactly the way the parser does
 * when age.enable_containment = off (transform_map_to_ind_recursive for @>,
 * transform_map_to_ind_top_level for @>>): one equality per leaf on
 *
 *     agtype_access_operator(VARIADIC ARRAY[properties, '"key"', ...])
 *
 * That is the expression users index or attach extended statistics to.
 * examine_variable() finds those statistics by structural equality and
 * var_eq_const() turns them into the selectivity an explicit
 * WHERE n.key = value gets, so the two ways of writing the filter estimate
 * identically.
 *
 * The properties column's own statistics are never read and
 * agtype_contains() is never called at plan time. The only per-MCV work is
 * inside var_eq_const() on the extracted key's short scalar values, which is
 * what an equality on that key already costs.
 *
 * Fallback contract: when age.enable_containment_statistics is off, when
 * the relation has neither an expression index nor extended statistics,
 * when the operand is not a constant non-empty object, or when no leaf finds
 * statistics, the result is AGTYPE_CONTAIN_DEFAULT_SEL, the value contsel
 * returned. Installations without expression statistics see byte-identical
 * plans.
 */

#include "postgres.h"

#include "catalog/namespace.h"
#include "catalog/pg_operator.h"
#include "catalog/pg_type.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "nodes/pathnodes.h"
#include "nodes/pg_list.h"
#include "utils/elog.h"
#include "utils/lsyscache.h"
#include "utils/selfuncs.h"
#include "utils/syscache.h"

#include "utils/ag_func.h"
#include "utils/ag_guc.h"
#include "utils/agtype.h"

/* the constant contsel returns; see geo_selfuncs.c */
#define AGTYPE_CONTAIN_DEFAULT_SEL 0.001

PG_FUNCTION_INFO_V1(agtype_contains_sel);

typedef struct contains_sel_context
{
    PlannerInfo *root;
    int varRelid;
    Node *propvar;           /* variable side of the operator */
    Oid eq_opoid;            /* ag_catalog.=(agtype, agtype) */
    Oid access_fnoid;        /* ag_catalog.agtype_access_operator(agtype[]) */
    bool top_level;          /* @>> : do not descend into nested maps */
    int nleaves_with_stats;  /* leaves for which statistics were found */
    double sel;
} contains_sel_context;

static Oid cached_eq_opoid = InvalidOid;
static Oid cached_access_fnoid = InvalidOid;

/*
 * The operator and function oids are stable for the life of the extension,
 * but the extension can be dropped and recreated within a backend, so the
 * cached oid is revalidated against the syscache before use.
 */
static Oid get_agtype_eq_opoid(void)
{
    if (!OidIsValid(cached_eq_opoid) ||
        !SearchSysCacheExists1(OPEROID, ObjectIdGetDatum(cached_eq_opoid)))
    {
        cached_eq_opoid = OpernameGetOprid(list_make2(makeString("ag_catalog"),
                                                      makeString("=")),
                                           AGTYPEOID, AGTYPEOID);
    }

    return cached_eq_opoid;
}

static Oid get_access_operator_fnoid(void)
{
    if (!OidIsValid(cached_access_fnoid) ||
        !SearchSysCacheExists1(PROCOID, ObjectIdGetDatum(cached_access_fnoid)))
    {
        cached_access_fnoid = get_ag_func_oid("agtype_access_operator", 1,
                                              AGTYPEARRAYOID);
    }

    return cached_access_fnoid;
}

/*
 * Cheap gate so that relations without any expression statistics never pay
 * for node synthesis. Both lists are already in memory at this point.
 */
static bool rel_has_expression_statistics(RelOptInfo *rel)
{
    ListCell *lc;

    if (rel == NULL)
    {
        return false;
    }

    if (rel->statlist != NIL)
    {
        return true;
    }

    foreach(lc, rel->indexlist)
    {
        IndexOptInfo *index = (IndexOptInfo *) lfirst(lc);

        if (index->indexprs != NIL)
        {
            return true;
        }
    }

    return false;
}

/*
 * Build agtype_access_operator(VARIADIC ARRAY[<propvar>, '"k1"', '"k2"', ...])
 * with the same node shape transform_A_Indirection produces, so that equal()
 * matches an expression index or extended statistics object built on the
 * documented CREATE INDEX ... (agtype_access_operator(properties, '"key"'))
 * form.
 */
static Node *build_access_expr(contains_sel_context *ctx, List *keys)
{
    ArrayExpr *arr = makeNode(ArrayExpr);
    FuncExpr *fexpr;
    ListCell *lc;

    arr->elements = list_make1(copyObject(ctx->propvar));

    foreach(lc, keys)
    {
        agtype_value *keyval = string_to_agtype_value((char *) lfirst(lc));
        agtype *keyagt = agtype_value_to_agtype(keyval);
        Const *keyconst;

        keyconst = makeConst(AGTYPEOID, -1, InvalidOid, -1,
                             AGTYPE_P_GET_DATUM(keyagt), false, false);
        arr->elements = lappend(arr->elements, keyconst);
    }

    arr->element_typeid = AGTYPEOID;
    arr->array_typeid = AGTYPEARRAYOID;
    arr->multidims = false;
    arr->location = -1;

    fexpr = makeFuncExpr(ctx->access_fnoid, AGTYPEOID, list_make1(arr),
                         InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);
    fexpr->funcvariadic = true;
    fexpr->location = -1;

    return (Node *) fexpr;
}

static char *key_path_to_string(List *keys)
{
    StringInfoData buf;
    ListCell *lc;

    initStringInfo(&buf);

    foreach(lc, keys)
    {
        if (buf.len > 0)
        {
            appendStringInfoChar(&buf, '.');
        }
        appendStringInfoString(&buf, (char *) lfirst(lc));
    }

    return buf.data;
}

/*
 * One decomposed leaf: <access expr on keys> OP <val>.
 *
 * Mirrors transform_map_to_ind_recursive / _top_level: in top-level mode
 * every value is compared with =; in deep mode lists and (empty) maps are
 * compared with @>, everything else with =.
 */
static void estimate_leaf(contains_sel_context *ctx, List *keys,
                          agtype_value *val)
{
    bool is_container = (val->type == AGTV_BINARY);
    bool use_equality;
    double s;
    bool found = false;

    if (ctx->top_level)
    {
        use_equality = true;
    }
    else
    {
        use_equality = !is_container;
    }

    if (use_equality)
    {
        VariableStatData vd;
        Node *expr = build_access_expr(ctx, keys);
        agtype *valagt = agtype_value_to_agtype(val);

        examine_variable(ctx->root, expr, ctx->varRelid, &vd);

        /*
         * var_eq_const gives the same answer eqsel would for an explicit
         * equality on this expression, including the 1/ndistinct fallback
         * when no statistics exist.
         */
        s = var_eq_const(&vd, ctx->eq_opoid, InvalidOid,
                         AGTYPE_P_GET_DATUM(valagt), false, true, false);

        found = HeapTupleIsValid(vd.statsTuple) || vd.isunique;

        ReleaseVariableStats(vd);
    }
    else
    {
        /* a nested containment: this is what contsel gave it */
        s = AGTYPE_CONTAIN_DEFAULT_SEL;
    }

    if (found)
    {
        ctx->nleaves_with_stats++;
    }

    if (message_level_is_interesting(DEBUG1))
    {
        ereport(DEBUG1,
                (errmsg_internal("agtype_contains_sel: key %s: %s, selectivity %g",
                                 key_path_to_string(keys),
                                 use_equality ?
                                     (found ? "statistics found" :
                                              "no statistics") :
                                     "containment, default",
                                 s)));
    }

    ctx->sel *= s;
}

/*
 * Walk one object level of the containment constant, descending into
 * non-empty nested objects when in deep (@>) mode.
 */
static void walk_object(contains_sel_context *ctx, agtype_container *agtc,
                        List *keys)
{
    agtype_iterator *it;
    agtype_iterator_token tok;
    agtype_value v;
    char *key = NULL;

    check_stack_depth();

    it = agtype_iterator_init(agtc);

    while ((tok = agtype_iterator_next(&it, &v, true)) != WAGT_DONE)
    {
        List *leaf_keys;

        if (tok == WAGT_KEY)
        {
            key = pnstrdup(v.val.string.val, v.val.string.len);
            continue;
        }

        if (tok != WAGT_VALUE || key == NULL)
        {
            continue;
        }

        leaf_keys = lappend(list_copy(keys), key);
        key = NULL;

        if (!ctx->top_level &&
            v.type == AGTV_BINARY &&
            AGTYPE_CONTAINER_IS_OBJECT(v.val.binary.data) &&
            AGTYPE_CONTAINER_SIZE(v.val.binary.data) > 0)
        {
            walk_object(ctx, v.val.binary.data, leaf_keys);
        }
        else
        {
            estimate_leaf(ctx, leaf_keys, &v);
        }
    }
}

/*
 * Restriction selectivity for agtype @> agtype and agtype @>> agtype.
 * Signature: (internal, oid, internal, integer) -> float8.
 */
Datum agtype_contains_sel(PG_FUNCTION_ARGS)
{
    PlannerInfo *root = (PlannerInfo *) PG_GETARG_POINTER(0);
    Oid operator = PG_GETARG_OID(1);
    List *args = (List *) PG_GETARG_POINTER(2);
    int varRelid = PG_GETARG_INT32(3);
    VariableStatData vardata;
    Node *other = NULL;
    bool varonleft = false;
    Const *cnst;
    agtype *agt;
    char *opname;
    contains_sel_context ctx;

    if (!age_enable_containment_statistics || root == NULL)
    {
        PG_RETURN_FLOAT8(AGTYPE_CONTAIN_DEFAULT_SEL);
    }

    if (!get_restriction_variable(root, args, varRelid, &vardata, &other,
                                  &varonleft))
    {
        PG_RETURN_FLOAT8(AGTYPE_CONTAIN_DEFAULT_SEL);
    }

    /* need <variable> @> <constant>; anything else keeps the old estimate */
    if (!varonleft || other == NULL || !IsA(other, Const) ||
        vardata.var == NULL ||
        !rel_has_expression_statistics(vardata.rel))
    {
        ReleaseVariableStats(vardata);
        PG_RETURN_FLOAT8(AGTYPE_CONTAIN_DEFAULT_SEL);
    }

    cnst = (Const *) other;

    if (cnst->constisnull || cnst->consttype != AGTYPEOID)
    {
        ReleaseVariableStats(vardata);
        PG_RETURN_FLOAT8(AGTYPE_CONTAIN_DEFAULT_SEL);
    }

    agt = DATUM_GET_AGTYPE_P(cnst->constvalue);

    if (!AGT_ROOT_IS_OBJECT(agt) || AGT_ROOT_COUNT(agt) == 0)
    {
        ReleaseVariableStats(vardata);
        PG_RETURN_FLOAT8(AGTYPE_CONTAIN_DEFAULT_SEL);
    }

    ctx.root = root;
    ctx.varRelid = varRelid;
    ctx.propvar = vardata.var;
    ctx.eq_opoid = get_agtype_eq_opoid();
    ctx.access_fnoid = get_access_operator_fnoid();
    ctx.nleaves_with_stats = 0;
    ctx.sel = 1.0;

    opname = get_opname(operator);
    ctx.top_level = (opname != NULL && strcmp(opname, "@>>") == 0);

    if (!OidIsValid(ctx.eq_opoid) || !OidIsValid(ctx.access_fnoid))
    {
        ReleaseVariableStats(vardata);
        PG_RETURN_FLOAT8(AGTYPE_CONTAIN_DEFAULT_SEL);
    }

    walk_object(&ctx, &agt->root, NIL);

    ReleaseVariableStats(vardata);

    /* no leaf had statistics: keep the estimate contsel produced */
    if (ctx.nleaves_with_stats == 0)
    {
        PG_RETURN_FLOAT8(AGTYPE_CONTAIN_DEFAULT_SEL);
    }

    CLAMP_PROBABILITY(ctx.sel);

    PG_RETURN_FLOAT8(ctx.sel);
}
