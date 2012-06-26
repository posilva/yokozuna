-module(yokozuna).
-include("yokozuna.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

%% -export([
%%          index/1,
%%          ping/0
%%         ]).

-compile(export_all).


%%%===================================================================
%%% API
%%%===================================================================

%% @doc Index the given object `O'.
-spec index(riak_object:riak_object()) -> ok | {error, term()}.
index(O) ->
    yokozuna_solr:index([make_doc(O)]).

%% @doc Pings a random vnode to make sure communication is functional
ping() ->
    DocIdx = riak_core_util:chash_key({<<"ping">>, term_to_binary(now())}),
    PrefList = riak_core_apl:get_primary_apl(DocIdx, 1, yokozuna),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, ping, yokozuna_vnode_master).

covering_nodes() ->
    Selector = all,
    %% TODO: remove hardcoded n_val
    NVal = 3,
    NumPrimaries = 1,
    ReqId = erlang:phash2(erlang:now()),
    Service = yokozuna,

    {CoveringSet, _} = riak_core_coverage_plan:create_plan(Selector,
                                                           NVal,
                                                           NumPrimaries,
                                                           ReqId,
                                                           Service),
    [Node || {_, Node} <- CoveringSet].


%%%===================================================================
%%% Private
%%%===================================================================

%% @doc Given an object generate the doc to be indexed by Solr.
-spec make_doc(riak_object:riak_object()) -> doc().
make_doc(O) ->
    %% TODO: For now assume text/plain to prototype
    %%
    %% TODO: change 'text' to 'value'
    Fields = [{id, doc_id(O)},
              {text, value(O)},
              {'_vc', gen_vc(O)}],
    {doc, Fields}.

%% @doc Given an object generate the vector clock doc to be indexed by
%%      Solr.
%% -spec make_vclock_doc(riak_object:riak_object()) -> doc().
%% make_vclock_doc(O) ->
%%     Fields = {id, doc

doc_id(O) ->
    riak_object:key(O).

%% TODO: Just pass metadata in?
%%
%% TODO: I don't like having X-Riak-Last-Modified in here.  Add
%%       function to riak_object.
doc_ts(O) ->
    MD = riak_object:get_metadata(O),
    dict:fetch(<<"X-Riak-Last-Modified">>, MD).

doc_vclock(O) ->
    riak_object:vclock(O).

gen_ts() ->
    {{Year, Month, Day},
     {Hour, Min, Sec}} = calendar:now_to_universal_time(erlang:now()),
    list_to_binary(io_lib:format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0B",
                                 [Year,Month,Day,Hour,Min,Sec])).

gen_vc(O) ->
    TS = gen_ts(),
    ID = doc_id(O),
    VClock = base64:encode(crypto:sha(term_to_binary(doc_vclock(O)))),
    <<TS/binary," ",ID/binary," ",VClock/binary>>.

value(O) ->
    riak_object:get_value(O).

test_it() ->
    application:start(esolr),
    B = <<"fruit">>,
    O1 = riak_object:new(B, <<"apples">>, <<"2">>),
    O2 = riak_object:new(B, <<"oranges">>, <<"1">>),
    O3 = riak_object:new(B, <<"strawberries">>, <<"6">>),
    O4 = riak_object:new(B, <<"lemons">>, <<"1">>),
    O5 = riak_object:new(B, <<"celery">>, <<"4">>),
    O6 = riak_object:new(B, <<"lime">>, <<"1">>),
    [index(O) || O <- [O1, O2, O3, O4, O5, O6]],
    esolr:commit().

demo_write_objs() ->
    application:start(esolr),
    write_n_objs(1000),
    esolr:commit().

demo_build_tree(Name) ->
    ibrowse:start(),
    TP = yokozuna_entropy:new_tree_proc(Name),
    Pid = element(3, TP),
    Ref = make_ref(),
    Pid ! {get_tree, self(), Ref},
    receive {tree, Ref, Tree} -> Tree end,
    %% returning TreeProc too in case want to play with it
    {Tree, TP}.

demo_new_vclock(N) ->
    %% the timestamp will change causing hash to change
    NS = list_to_binary(integer_to_list(N)),
    B = <<"test">>,
    K = <<"key_",NS/binary>>,
    V = <<"val_",NS/binary>>,
    O = riak_object:new(B, K, V),
    O2 = riak_object:increment_vclock(O, dummy_node),
    index(O2),
    esolr:commit().

demo_delete(N) ->
    NS = integer_to_list(N),
    K = "key_" ++ NS,
    ok = esolr:delete({id,K}),
    ok = esolr:commit().

write_n_objs(0) ->
    ok;
write_n_objs(N) ->
    NS = list_to_binary(integer_to_list(N)),
    B = <<"test">>,
    K = <<"key_",NS/binary>>,
    V = <<"val_",NS/binary>>,
    O = riak_object:new(B, K, V),
    O2 = riak_object:increment_vclock(O, dummy_node),
    index(O2),
    write_n_objs(N-1).
