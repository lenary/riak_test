% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%% @doc A module to test riak_ts queries with ORDER BY/LIMIT/OFFSET
%%      clauses, which use query buffers.  There are three test cases:
%%
%%      1. query_orderby_no_updates: check that, in an existing query
%%         buffer which has not expired, updates to the mother table
%%         do not get picked up by a follow-up query;

%%      2. query_orderby_expiring: conversely, check that updates do
%%         get picked up after query buffer expiry;

%%      3. query_orderby_comprehensive: test all combinations of up to
%%         5 ORDER BY elements, with and without NULLS FIRST/LAST and
%%         ASC/DESC modifiers.

%%      The DDL includes NULL fields, and data generated include
%%      duplicate fields as well as NULLs.

-module(ts_simple_query_buffers_SUITE).

-export([suite/0, init_per_suite/1, groups/0, all/0,
         init_per_testcase/2, end_per_testcase/2]).
-export([query_orderby_comprehensive/1,
         query_orderby_cleanup/1,
         query_orderby_inmem2ldb/1,
         %% query_orderby_no_updates/1,
         %% query_orderby_expiring/1,  %% re-enable when clients will (in 1.6) learn to make use of qbuf_id
         query_orderby_max_quanta_error/1,
         query_orderby_max_data_size_error/1,
         query_orderby_ldb_io_error/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("ts_qbuf_util.hrl").

-define(RIDICULOUSLY_SMALL_MAX_QUERY_DATA_SIZE, 100).
-define(RIDICULOUSLY_SMALL_MAX_QUERY_QUANTA, 3).


suite() ->
    [{timetrap, {hours, 2}}].

init_per_suite(Cfg) ->
    Cluster = ts_setup:start_cluster(1),
    C = rt:pbc(hd(Cluster)),
    Data = ts_qbuf_util:make_data(),
    ExtraData = ts_qbuf_util:make_extra_data(),
    ok = ts_qbuf_util:create_table(C, ?TABLE),
    ok = ts_qbuf_util:insert_data(C, ?TABLE,  Data),
    [{cluster, Cluster},
     {data, Data},
     {extra_data, ExtraData}
     | Cfg].

groups() ->
    [].

all() ->
    [
     %% check how error conditions are reported
     query_orderby_max_quanta_error,
     query_orderby_max_data_size_error,
     %% check transition of inmem->ldb during data collection
     query_orderby_inmem2ldb,
     %% check that no temp tables are left behind
     query_orderby_cleanup,
     %% check LIMIT and ORDER BY, in various combinations of columns and qualifiers
     query_orderby_comprehensive
     %% query_orderby_ldb_io_error
     %% with single-instance, always-open leveldb, the renaming trick doesn't work.
    ].

%%
%% 1. checking happy-path operations
%% ---------------------------------

query_orderby_comprehensive(Cfg) ->
    C = rt:pbc(hd(proplists:get_value(cluster, Cfg))),
    Data = proplists:get_value(data, Cfg),
    ct:print("Testing all possible combinations of up to 5 elements in ORDER BY (can take 5 min or more) ...", []),
    OrderByBattery1 =
        [[F1, F2, F3, F4, F5] ||
            F1 <- ?ORDBY_COLS,
            F2 <- ?ORDBY_COLS,
            F3 <- ?ORDBY_COLS,
            F4 <- ?ORDBY_COLS,
            F5 <- ?ORDBY_COLS,
            all_different([F1, F2, F3, F4, F5])],
    OrderByBattery2 =
        lists:usort(
          lists:map(
            fun(FF) ->
                    [F || F <- FF, F /= undefined]
            end,
            OrderByBattery1)),
    OrderByBattery3 =
        lists:append([make_ordby_item_variants(Items) || Items <- OrderByBattery2]),
    ExecuteF =
        fun() ->
                lists:foreach(
                  fun(OrdByItems) ->
                       check_sorted(C, ?TABLE, Data, [{order_by, OrdByItems}, {limit, 1}]),
                       check_sorted(C, ?TABLE, Data, [{order_by, OrdByItems}, {limit, 2}, {offset, 4}]),
                       check_sorted(C, ?TABLE, Data, [{order_by, OrdByItems}])
                  end,
                  OrderByBattery3)
        end,
    {ExecTime, ok} = timer:tc(ExecuteF),
    TotalQueries = 3 * length(OrderByBattery3),
    ct:pal("Executed ~b queries in ~.2f sec (~b msec per query)",
           [TotalQueries, ExecTime / 1000 / 1000, round((ExecTime / 1000) / TotalQueries)]).

all_different(XX) ->
    YY = [X || X <- XX, X /= undefined],
    length(lists:usort(YY)) == length(YY).

%% given a single list of fields, e.g., ["a", "b", "c"], produce all
%% variants featuring all possible modifiers with each field, thus:
%%  [[{"a", "asc", "nulls first"}, ...], ...,
%%   [{"a", undefined, undefined}, ...]]
make_ordby_item_variants([]) ->
    [[]];  %% this special case gets lost in rolling/unrolling wizardry
make_ordby_item_variants(FF) ->
    Modifiers =
        [{Dir, Nul} || Dir <- ["asc", "desc", undefined],
                       Nul <- ["nulls first", "nulls last", undefined]],
    Unrolled =
        lists:append(
          [[{F, M1, M2}] || {M1, M2} <- Modifiers,
                            F <- FF]),
    rollup(length(FF), Unrolled, []).

rollup(_, [], Acc) ->
    Acc;
rollup(N, FF, Acc) ->
    {R, T} = lists:split(N, FF),
    rollup(N, T, [R | Acc]).


query_orderby_cleanup(Cfg) ->
    Node = hd(proplists:get_value(cluster, Cfg)),
    {ok, QbufExpiryMsec} = rpc:call(Node, application, get_env, [riak_kv, timeseries_query_buffers_expire_ms]),
    QbufAbsPath = get_qbuf_dir(Node),
    ct:print("Waiting ~b msec to check that all temp tables in ~s are gone ...", [QbufExpiryMsec, QbufAbsPath]),
    timer:sleep(QbufExpiryMsec + 1000),
    Leftovers = filelib:wildcard(
                  filename:join([QbufAbsPath, "*"])),
    ?assertEqual(Leftovers, []),
    ok.

%%
%% 2. checking error conditions reporting
%% --------------------------------------

init_per_testcase(query_orderby_max_quanta_error, Cfg) ->
    Node = hd(proplists:get_value(cluster, Cfg)),
    ok = rpc:call(Node, application, set_env, [riak_kv, timeseries_query_max_quanta_span, ?RIDICULOUSLY_SMALL_MAX_QUERY_QUANTA]),
    Cfg;

init_per_testcase(query_orderby_max_data_size_error, Cfg) ->
    Node = hd(proplists:get_value(cluster, Cfg)),
    ok = rpc:call(Node, riak_kv_qry_buffers, set_max_query_data_size, [?RIDICULOUSLY_SMALL_MAX_QUERY_DATA_SIZE]),
    Cfg;

init_per_testcase(query_orderby_ldb_io_error, Cfg) ->
    Cfg;

init_per_testcase(query_orderby_inmem2ldb, Cfg) ->
    Cfg;

init_per_testcase(_, Cfg) ->
    Cfg.

end_per_testcase(query_orderby_max_quanta_error, Cfg) ->
    Node = hd(proplists:get_value(cluster, Cfg)),
    ok = rpc:call(Node, application, set_env, [riak_kv, timeseries_query_max_quanta_span, 1000]),
    ok;

end_per_testcase(query_orderby_max_data_size_error, Cfg) ->
    Node = hd(proplists:get_value(cluster, Cfg)),
    ok = rpc:call(Node, riak_kv_qry_buffers, set_max_query_data_size, [5*1000*1000]),
    ok;

end_per_testcase(query_orderby_ldb_io_error, _Cfg) ->
    ok;

end_per_testcase(query_orderby_inmem2ldb, _Cfg) ->
    ok;

end_per_testcase(_, Cfg) ->
    Cfg.


query_orderby_max_quanta_error(Cfg) ->
    ct:print("Testing error reporting (max_query_quanta) ...", []),
    Query = ts_qbuf_util:full_query(?TABLE, [{order_by, [{"d", undefined, undefined}]}]),
    ok = ts_qbuf_util:ack_query_error(Cfg, Query, ?E_QUANTA_LIMIT).

query_orderby_max_data_size_error(Cfg) ->
    ct:print("Testing error reporting (max_query_data_size) ...", []),
    Query1 = ts_qbuf_util:full_query(?TABLE, [{order_by, [{"d", undefined, undefined}]}]),
    ok = ts_qbuf_util:ack_query_error(Cfg, Query1, ?E_SELECT_RESULT_TOO_BIG),
    Query2 = ts_qbuf_util:full_query(?TABLE, [{order_by, [{"d", undefined, undefined}]}, {limit, 99999}]),
    ok = ts_qbuf_util:ack_query_error(Cfg, Query2, ?E_SELECT_RESULT_TOO_BIG).

query_orderby_ldb_io_error(Cfg) ->
    ct:print("Testing error reporting (IO error) ...", []),
    Node = hd(proplists:get_value(cluster, Cfg)),

    C = rt:pbc(Node),
    %% force immediate creation of ldb instance (otherwise taking away permission will not take effect)
    load_intercept(Node, C, {riak_kv_qry_buffers, [{{can_afford_inmem, 1}, can_afford_inmem_no}]}),

    QBufDir = get_qbuf_dir(Node),
    modify_dir_access(take_away, QBufDir),

    Query = ts_qbuf_util:full_query(?TABLE, [{order_by, [{"d", undefined, undefined}]}]),
    Res = ts_qbuf_util:ack_query_error(Cfg, Query, ?E_QBUF_INTERNAL_ERROR),

    modify_dir_access(give_back, QBufDir),
    rt_intercept:clean(Node, riak_kv_qry_buffers),

    ok = Res,
    ok.


%%
%% 4. checking transition from inmem to ldb during data collection
%% --------------------------------------

query_orderby_inmem2ldb(Cfg) ->
    ct:print("Testing inmem vs ldb vs mixed code paths (3 x 100 queries) ...", []),
    Node = hd(proplists:get_value(cluster, Cfg)),
    Data = proplists:get_value(data, Cfg),
    C = rt:pbc(Node),

    %% a hack to enable intercepts to load precooked modules. Without it,
    %% CT harness runs the tests in a directory under ct_logs (for example,
    %% riak_test/ct_logs/ct_run.riak_test@127.0.0.1.2016-12-23_20.35.46),
    %% which confuses rt_intercept.
    rpc:call(Node, code, add_patha, [filename:join([rt_local:home_dir(), "../../ebin"])]),
    rt_intercept:load_code(Node),

    Exec100F =
        fun() ->
                [begin
                     F = fun() -> check_sorted(C, ?TABLE, Data, [{order_by, [{"c", undefined, undefined}]}]) end,
                     {ExecTime, ok} = timer:tc(F),
                     ExecTime
                 end || _ <- lists:seq(1, 99)]
        end,

    load_intercept(Node, C, {riak_kv_qry_buffers, [{{can_afford_inmem, 1}, can_afford_inmem_random}]}),
    ExecTimesRandom = Exec100F(),

    load_intercept(Node, C, {riak_kv_qry_buffers, [{{can_afford_inmem, 1}, can_afford_inmem_yes}]}),
    ExecTimesAllInmem = Exec100F(),

    load_intercept(Node, C, {riak_kv_qry_buffers, [{{can_afford_inmem, 1}, can_afford_inmem_no}]}),
    ExecTimesNoneInmem = Exec100F(),

    ct:pal("Avg query exec times: All inmem: ~b msec\n"
           "                     None inmem: ~b msec\n"
           "                          Mixed: ~b msec\n",
           [round(lists:sum(ExecTimesAllInmem)  / 100 / 1000),
            round(lists:sum(ExecTimesNoneInmem) / 100 / 1000),
            round(lists:sum(ExecTimesRandom)    / 100 / 1000)]),
    rt_intercept:clean(Node, riak_kv_qry_buffers).

load_intercept(Node, C, Intercept) ->
    ok = rt_intercept:add(Node, Intercept),
    %% when code changes underneath the riak_kv_qry_buffers
    %% gen_server, it gets reinitialized. We need to probe it with a
    %% dummy query until it becomes ready.
    wait_until_qbuf_mgr_reinit(C).

wait_until_qbuf_mgr_reinit(C) ->
    ProbingQuery = ts_qbuf_util:full_query(?TABLE, [{order_by, [{"c", undefined, undefined}]}]),
    case riakc_ts:query(C, ProbingQuery, [], undefined, []) of
        {ok, _Data} ->
            ok;
        {error, {ErrCode, _NotReadyMessage}}
          when ErrCode == ?E_QBUF_CREATE_ERROR;
               ErrCode == ?E_QBUF_INTERNAL_ERROR ->
            timer:sleep(100),
            wait_until_qbuf_mgr_reinit(C)
    end.

%% Supporting functions
%% ---------------------------

%% Prepare original data for comparison, and compare Expected with Got

check_sorted(C, Table, OrigData, Clauses) ->
    check_sorted(C, Table, OrigData, Clauses, [{allow_qbuf_reuse, true}]).
check_sorted(C, Table, OrigData, Clauses, Options) ->
    Query = ts_qbuf_util:full_query(Table, Clauses),
    ct:log("Query: \"~s\"", [Query]),
    {ok, {_Cols, Returned}} =
        riakc_ts:query(C, Query, [], undefined, Options),
    OrderBy = proplists:get_value(order_by, Clauses),
    Limit   = proplists:get_value(limit, Clauses),
    Offset  = proplists:get_value(offset, Clauses),
    %% emulate the SELECT on original data,
    %% including sorting according to ORDER BY
    %% uncomment these log entries to inspect the data visually (else
    %% it's just going to blow up the log into tens of megs):
    %% ct:log("Fetched ~p", [Returned]),
    PreSelected = sort_by(
                    where_filter(OrigData, [{"a", ?WHERE_FILTER_A},
                                            {"b", ?WHERE_FILTER_B}]),
                    OrderBy),
    %% .. and including the LIMIT/OFFSET positions
    PreLimited =
        lists:sublist(PreSelected, safe_offset(Offset) + 1, safe_limit(Limit)),
    %% and finally, for comparison, truncate each record to only
    %% contain fields by which sorting was done (i.e., if ORDER BY is
    %% [a, b, d], and if multiple records are selected with the same
    %% [a, b, d] fields but different [c, e], then these records may
    %% not come out in predictable order).
    case truncate(Returned, OrderBy) ==
        truncate(PreLimited, OrderBy) of
        true ->
            ok;
        false ->
            ct:fail("Query ~s failed\nGot ~p\nNeed: ~p\n", [Query, Returned, PreLimited])
    end.

safe_offset(undefined) -> 0;
safe_offset(X) -> X.

safe_limit(undefined) -> ?LIFESPAN_EXTRA;
safe_limit(X) -> X.

truncate(RR, OrderBy) ->
    OrdByFieldPoses = [F - $a + 1 || {[F], _, _} <- OrderBy],
    lists:map(
      fun(Row) ->
              FF = tuple_to_list(Row),
              list_to_tuple(
                [lists:nth(Pos, FF) || Pos <- OrdByFieldPoses])
      end, RR).


where_filter(Rows, Filter) ->
    lists:filter(
      fun(Row) ->
              lists:all(
                fun({F, V}) ->
                        C = col_no(F),
                        element(C, Row) == V
                end,
                Filter)
      end,
      Rows).

%% emulate sorting of original data
sort_by(Data, OrderBy) ->
    OrdByDefined = default_orderby_modifiers(OrderBy),
    lists:sort(
      fun(R1, R2) ->
              LessThan =
                  lists:foldl(
                    fun(_, true) -> true;
                       (_, false) -> false;
                       ({Fld, Dir, Nul}, _) ->
                            C = col_no(Fld),
                            F1 = element(C, R1),
                            F2 = element(C, R2),
                            if F1 == F2 ->
                                    undefined;  %% let fields of lower precedence decide

                               (F1 /= []) and (F2 == []) ->
                                    %% null < Value?
                                    case {Nul, Dir} of
                                        {"nulls first", "asc"} ->
                                            false;
                                        {"nulls first", "desc"} ->
                                            true;
                                        {"nulls last", "asc"} ->
                                            true;
                                        {"nulls last", "desc"} ->
                                            false
                                    end;

                               (F1 == []) and (F2 /= []) ->
                                    %% null > Value?
                                    case {Nul, Dir} of
                                        {"nulls first", "asc"} ->
                                            true;
                                        {"nulls first", "desc"} ->
                                            false;
                                        {"nulls last", "asc"} ->
                                            false;
                                        {"nulls last", "desc"} ->
                                            true
                                    end;

                               F1 < F2 ->
                                    (Dir == "asc");
                               F1 > F2 ->
                                    (Dir == "desc")
                            end
                    end,
                    undefined,
                    OrdByDefined),
              if LessThan == undefined ->
                      false;
                 el/=se ->
                      LessThan
              end
      end,
      Data).

default_orderby_modifiers(OrderBy) ->
    lists:map(
      %% "If NULLS LAST is specified, null values sort after all non-null
      %%  values; if NULLS FIRST is specified, null values sort before all
      %%  non-null values. If neither is specified, the default behavior is
      %%  NULLS LAST when ASC is specified or implied, and NULLS FIRST when
      %%  DESC is specified (thus, the default is to act as though nulls are
      %%  larger than non-nulls)."
      fun({F, "asc", undefined}) ->
              {F, "asc", "nulls last"};
         ({F, "desc", undefined}) ->
              {F, "desc", "nulls first"};
         ({F, Dir, Nul}) ->
              {F,
               if Dir == undefined -> "asc"; el/=se -> Dir end,
               if Nul == undefined -> "nulls last"; el/=se -> Nul end}
      end,
      OrderBy).

%% rely on "a" being column #1, "b" column #2, etc:
col_no([A|_]) ->
    A - $a + 1;
col_no({[A|_], _}) ->
    A - $a + 1;
col_no({[A|_], _, _}) ->
    A - $a + 1.


get_qbuf_dir(Node) ->
    {ok, QBufDir} = rpc:call(Node, application, get_env, [riak_kv, timeseries_query_buffers_root_path]),
    case hd(QBufDir) of
        $/ ->
            QBufDir;
        _ ->
            filename:join([rtdev:node_path(Node), QBufDir])
    end.

modify_dir_access(take_away, QBufDir) ->
    ct:pal("take away access from ~s\n", [QBufDir]),
    ok = file:rename(QBufDir, QBufDir++".boo"),
    ok = file:write_file(QBufDir, "nothing here");

modify_dir_access(give_back, QBufDir) ->
    ct:pal("restore access to ~s\n", [QBufDir]),
    ok = file:delete(QBufDir),
    ok = file:rename(QBufDir++".boo", QBufDir).
