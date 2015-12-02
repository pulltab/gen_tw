-module(event_tests).

-include_lib("eunit/include/eunit.hrl").

start_stop_test() ->
    Res = gen_tw:start(test_actor, []),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    ?assert(is_pid(Pid)),

    gen_tw:stop(Pid),

    timer:sleep(100),

    ?assertMatch(undefined, erlang:process_info(Pid)).

local_register_test() ->
    {ok, Pid} = gen_tw:start({local, foo}, test_actor, []),
    Where = whereis(foo),
    ?assertMatch(Pid, Where),
    erlang:unregister(foo),
    exit(Pid, kill),

    {ok, Pid2} = gen_tw:start_link({local, foo}, test_actor, [], #{}),
    ?assertMatch(Pid2, whereis(foo)),
    erlang:unlink(Pid2),
    erlang:unregister(foo),
    exit(Pid2, kill).

ignore_test() ->
    meck:expect(test_actor, init, fun(_) -> ignore end),
    ?assertMatch(ignore, gen_tw:start({local, foobar}, test_actor, [])),
    ?assertMatch(undefined, whereis(foobar)),
    meck:unload(test_actor).

stop_test() ->
    meck:expect(test_actor, init, fun(_) -> {stop, deadbeef} end),
    ?assertMatch({error, deadbeef}, gen_tw:start({local, foobar}, test_actor, [])),
    ?assertMatch(undefined, whereis(foobar)),
    meck:unload(test_actor).

throw_test() ->
    meck:expect(test_actor, init, fun(_) -> throw(deadbeef) end),
    ?assertMatch({error, deadbeef}, gen_tw:start({local, foobar}, test_actor, [])),
    ?assertMatch(undefined, whereis(foobar)),
    meck:unload(test_actor).

already_registered_test() ->
    {ok, P1} = gen_tw:start({local, foobar}, test_actor, []),
    P2Res = gen_tw:start({local, foobar}, test_actor, []),
    exit(P1, kill),
    ?assertMatch(P1, whereis(foobar)),
    ?assertMatch({error, already_registered}, P2Res).

tw_events_test_() ->
    {foreach,
        fun test_util:setup/0,
        fun test_util:cleanup/1,
        [
            fun handle_info/1,
            fun handle_info_error/1,
            fun tick_tock/1,
            fun in_order_event_processing/1,
            fun in_queue_antievent_cancels_event/1,
            fun rollback_event_replay/1,
            fun rollback_antievent/1,
            fun rollback_causal_antievents/1,
            fun rollback_skip_modstate/1
        ]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% General Properties
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Event Handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Terms which are not events pass through via handle_info
handle_info(Pid) ->
    ets:new(test, [named_table, public]),

    F =
        fun(foobar) ->
            ets:insert(test, {called, true}),
            ok
        end,
   meck:expect(test_actor, handle_info, F),

   Pid ! foobar,
   timer:sleep(100),

   [{called, true}] = ets:lookup(test, called),
   ?_assert(true).

%% handle_info returning error tuple halts gen_tw process
handle_info_error(Pid) ->
    process_flag(trap_exit, true),

    F = fun(Reason) -> {error, Reason} end,
    meck:expect(test_actor, handle_info, F),

    Pid ! foobar,

    timer:sleep(100), %% Wait for the exit message to trigger
    process_flag(trap_exit, false),  %%Disable trap_exit for future tests

    receive
        {'EXIT', Pid, foobar} ->
            ?_assert(true)
    after
        100 ->
            ?_assert(false)
    end.

%% In the absence of events, time is advanced monotonically.
tick_tock(_Pid) ->
    F =
        fun(LVT, State) ->
            case maps:get("oldLVT", State, undefined) of
                undefined ->
                    {1, #{"oldLVT" => 0}};

                OldLVT ->
                    case LVT > OldLVT of
                        true ->
                            {LVT + 1, State#{"oldLVT" := LVT}};
                        false when (LVT == 0) and (OldLVT == 0) ->
                            {1, State};
                        false ->
                            exit(should_not_be_reached)
                    end
            end
        end,

    meck:expect(test_actor, tick_tock, F),

    timer:sleep(100),
    ?_assert(true).

shuffle(L) ->
    [X || {_, X} <- lists:sort([{random:uniform(), X} || X <- L])].

%% Events are pulled from erlang message queues and processed with
%% earliest-first priority.
in_order_event_processing(Pid) ->
    F =
        fun(LVT, ELVT, _, _) ->
            case ELVT - LVT of
                1 ->
                    {ok, ok};
                _ ->
                    exit(should_not_be_reached)
            end
        end,
    meck:expect(test_actor, handle_event, F),

    Events = [gen_tw:event(X, <<>>) || X <- shuffle(lists:seq(1, 1000))],
    gen_tw:notify(Pid, Events),

    timer:sleep(1000),

    ?_assert(true).

in_queue_antievent_cancels_event(Pid) ->
    meck:expect(test_actor, handle_event, fun(_, _, _, _) -> exit(should_not_be_reached) end),

    Event = gen_tw:event(10, <<>>),
    Antievent = gen_tw:antievent(Event),
    gen_tw:notify(Pid, [Event, Antievent]),
    timer:sleep(100),
    ?_assert(true).

rollback_event_replay(Pid) ->
    R =
        fun(LVT, ELVT, Payload, State) ->
            Rollback = erlang:get(rollback),
            case Payload of
                <<"rollback">> when Rollback == undefined ->
                    erlang:put(rollback, true),
                    {ok, State};

                _ when Rollback == undefined ->
                    {ok, State};

                <<"rollback">> ->
                    {ok, State};

                _ when (ELVT == LVT + 1)->
                    {ok, State};
                _ ->
                    exit({should_not_be_reached, LVT, ELVT})
            end
        end,

    meck:expect(test_actor, handle_event, R),

    Events = [gen_tw:event(X, <<>>) || X <- lists:seq(1, 100)],

    gen_tw:notify(Pid, Events),

    timer:sleep(100),

    gen_tw:notify(Pid, gen_tw:event(0,<<"rollback">>)),

    timer:sleep(100),

    ?_assert(true).

rollback_skip_modstate(Pid) ->
    Self = self(),
    Ref = make_ref(),
    meck:expect(test_actor, handle_event,
        fun(LVT, ELVT, _Payload, State) ->
            %% Send the LVT and ELVT back to the unit test.
            Self ! {Ref, LVT, ELVT},
            {ok, State}
        end),

    %% Send an event at T=0 - expect the actor to advance from 0 to 0.
    gen_tw:notify(Pid, gen_tw:event(0, <<>>)),
    receive {Ref, 0, 0} -> ok after 1000 -> ?assert(false) end,

    %% Send an event at T=2 - expect the actor to advance from 0 to 2.
    gen_tw:notify(Pid, gen_tw:event(2, <<>>)),
    receive {Ref, 0, 2} -> ok after 100 -> ?assert(false) end,

    %% Send an event at T=1 - roll back and expect the actor to advance from 0
    %% to 1, then 1 to 2.
    gen_tw:notify(Pid, gen_tw:event(1, <<>>)),
    receive {Ref, 0, 1} -> ok after 100 -> ?assert(false) end,
    receive {Ref, 1, 2} -> ok after 100 -> ?assert(false) end,

    ?_assert(true).

rollback_antievent(Pid) ->
    StartLVT = 1,
    EndLVT = 100,
    F =
        fun(_LVT, ELVT, _Payload, State) ->
            ets:update_counter(rollback_antievent, ELVT, {2, 1}, {count, 0}),
            {ok, State}
        end,

    rollback_antievent = ets:new(rollback_antievent, [named_table, public]),

    meck:expect(test_actor, handle_event, F),

    Events = [gen_tw:event(ELVT, <<>>) || ELVT <- lists:seq(StartLVT, EndLVT)],
    gen_tw:notify(Pid, Events),

    timer:sleep(100),

    %% Rollback to the middle
    RollbackLVT = 49,
    RBEvent1 = gen_tw:antievent(lists:nth(RollbackLVT, Events)),
    gen_tw:notify(Pid, RBEvent1),

    %% Ensure that it is safe to rollback to the beginning of time (GVT)
    [FirstEvent|_] = Events,
    gen_tw:notify(Pid, gen_tw:antievent(FirstEvent)),

    timer:sleep(100),

    [?_assertEqual(ets:lookup_element(rollback_antievent, 49, 2), 1),
     ?_assertEqual(ets:lookup_element(rollback_antievent, 1, 2), 1),
     [?_assertEqual(ets:lookup_element(rollback_antievent, X, 2), 2) || X <- lists:seq(2, 48)],
     [?_assertEqual(ets:lookup_element(rollback_antievent, X, 2), 2) || X <- lists:seq(50, 100)]].

rollback_causal_antievents_recv(LVT, LVT) ->
    ?_assert(true);
rollback_causal_antievents_recv(LVT, Max) ->
    receive
        {event, ELVT, _, false, _, _} when ELVT == LVT + 1 ->
            rollback_causal_antievents_recv(LVT+1, Max);

        _Event ->
            exit({unexpected_antievent, LVT, _Event})
    end.

 rollback_causal_antievents(Pid) ->
    StartLVT = 1,
    EndLVT = 100,
    F =
        fun(_LVT, _ELVT, _Payload, State) ->
            {ok, State}
        end,

    meck:expect(test_actor, handle_event, F),

    Events = [gen_tw:event(self(), ELVT, <<>>) || ELVT <- lists:seq(StartLVT, EndLVT)],
    gen_tw:notify(Pid, Events),

    timer:sleep(100),

    %% Rollback to the middle
    RollbackLVT = 49,
    RBEvent = gen_tw:event(self(), RollbackLVT, <<"rollback">>),
    gen_tw:notify(Pid, RBEvent),
    rollback_causal_antievents_recv(RollbackLVT, EndLVT),

    %% Ensure that it is safe to rollback to the beginning of time (GVT)
    gen_tw:notify(Pid, gen_tw:event(self(), StartLVT, <<"rollback">>)),
    rollback_causal_antievents_recv(StartLVT, RollbackLVT).
