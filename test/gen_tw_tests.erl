-module(gen_tw_tests).

-include_lib("eunit/include/eunit.hrl").

start_stop_test() ->
    Res = gen_tw:spawn(test_actor, []),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    ?assert(is_pid(Pid)),
    gen_tw:stop(Pid).

tw_properties_test_() ->
    {foreach,
        fun() ->
            ok = meck:new(test_actor, [passthrough]),
            {ok, Pid} = gen_tw:spawn_link(test_actor, []),
            Pid
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
            fun rollback/1

        ]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% General Properties
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

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Event Handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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

rollback(Pid) ->
    R =
        fun(LVT, ELVT, Payload, State) ->
            Rollback = erlang:get(rollback),
            case Payload of
                <<"rollback">> when Rollback == undefined ->
                    erlang:put(rollback, true),
                    {ok, State};
                <<"rollback">> when Rollback ->
                    {ok, State};
                _ when Rollback == undefined ->
                    {ok, State};
                _ when Rollback ->
                    case ELVT == LVT + 1 of
                        true ->
                            {ok, State};
                        false ->
                            exit({should_not_be_reached, LVT, ELVT})
                    end
            end
        end,

    meck:expect(test_actor, handle_event, R),

    Events = [gen_tw:event(X, <<>>) || X <- lists:seq(1, 100)],

    gen_tw:notify(Pid, Events),

    timer:sleep(100),

    gen_tw:notify(Pid, gen_tw:event(0,<<"rollback">>)),

    ?_assert(true).
