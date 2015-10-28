-module(gen_tw_tests).

-include_lib("eunit/include/eunit.hrl").

start_stop_test() ->
    Res = gen_tw:spawn(test_actor, []),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    ?assert(is_pid(Pid)),

    %% Ensure proc_lib init acks are being sent out.
    receive
        {ack, Pid, {ok, Pid}} ->
            ok
    after 100 ->
        ?assert(false)
    end,

    gen_tw:stop(Pid),

    timer:sleep(100),

    ?assertMatch(undefined, erlang:process_info(Pid)).

tw_events_test_() ->
    {foreach,
        fun() ->
            ok = meck:new(test_actor, [passthrough]),
            {ok, Pid} = gen_tw:spawn_link(test_actor, []),
            receive
                {ack, _, {ok, _}} ->
                    Pid
            after 100 ->
                throw({failed_to_init_test_actor})
            end
         end,
        fun(Pid) ->
            erlang:unlink(Pid),
            gen_tw:stop(Pid),
            timer:sleep(1000),
            meck:unload(test_actor),
            ok
        end,
        [
            fun tick_tock/1,
            fun in_order_event_processing/1,
            fun in_queue_antievent_cancels_event/1,
            fun rollback_event_replay/1,
            fun rollback_causal_antievents/1,
            fun rollback_skip_modstate/1
        ]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% General Properties
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Event Handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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

rollback_causal_antievents_recv(LVT, Max) when LVT > Max ->
    ?_assert(true);
rollback_causal_antievents_recv(LVT, Max) ->
    receive
        {event, LVT, _, false, _, _} ->
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
