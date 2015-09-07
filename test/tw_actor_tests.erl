-module(tw_actor_tests).

-include_lib("eunit/include/eunit.hrl").

start_stop_test() ->
    Res = tw_actor:spawn(test_actor, []),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    ?assert(is_pid(Pid)),
    tw_actor:stop(Pid).

tw_properties_test_() ->
    {foreach,
        fun() ->
            ok = meck:new(test_actor, [passthrough]),
            {ok, Pid} = tw_actor:spawn_link(test_actor, []),
            Pid
         end,
        fun(Pid) ->
            erlang:unlink(Pid),
            tw_actor:stop(Pid),
            timer:sleep(1000),
            meck:unload(test_actor),
            ok
        end,
        [
            fun tick_tock/1,
            fun in_order_event_processing/1,
            fun in_queue_antievent_cancels_event/1
            %%fun rollback/1

        ]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% General Properties
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% In the absence of events, time is advanced monotonically.
tick_tock(_Pid) ->
    F =
        fun(LVT, OldLVT) ->
            case LVT > OldLVT of
                true ->
                    {LVT + 1, LVT};
                false when (LVT == 0) and (OldLVT == 0) ->
                    {1, 0};
                false ->
                    exit(should_not_be_reached)
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
                    ok;
                _ ->
                    exit(should_not_be_reached)
            end
        end,
    meck:expect(test_actor, handle_event, F),

    Events = [tw_actor:event(X, <<>>) || X <- shuffle(lists:seq(1, 1000))],
    tw_actor:notify(Pid, Events),

    timer:sleep(1000),

    ?_assert(true).

in_queue_antievent_cancels_event(Pid) ->
    meck:expect(test_actor, handle_event, fun(_, _, _, _) -> exit(should_not_be_reached) end),

    Event = tw_actor:event(10, <<>>),
    Antievent = tw_actor:antievent(Event),
    tw_actor:notify(Pid, [Event, Antievent]),
    timer:sleep(100),
    ?_assert(true).

rollback(Pid) ->
    R =
        fun(LVT, ELVT, _, _) ->
            case erlang:get(rb_done) of
                true ->
                    ok;

                undefined when ELVT == 1 ->
                    erlang:put(rb_done, true);

                undefined ->
                    case ELVT < LVT of
                        true ->
                            ok;
                        false ->
                            exit(should_not_be_reach)
                    end
            end
        end,

    meck:expect(test_actor, handle_event, R),

    Events = [tw_actor:event(X, <<>>) || X <- lists:reverse(lists:seq(1, 1000))],

    [begin
        Event = tw_actor:event(Event, <<>>),
        tw_actor:notify(Pid, Event),
        timer:sleep(1)
     end
        || Event <- Events],

    ?_assert(true).
