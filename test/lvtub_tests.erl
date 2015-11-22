-module(lvtub_tests).

-include_lib("eunit/include/eunit.hrl").

gvt_test_() ->
    {foreach,
     fun() -> test_util:setup(2) end,
     fun test_util:cleanup/1,
     [
        fun lvtub_bounds_tick_tock/1,
        fun bounded_sim_resumes_after_gvt_update/1,
        fun bounded_sim_still_advances_with_events/1
     ]}.

tick_tock(Parent, MaxLVT) ->
    fun(LVT, State) ->
        case LVT < MaxLVT of
            true ->
                {LVT+1, State};

            false ->
                Parent ! {violation, LVT}
        end
    end.

handle_event(Parent) ->
    fun(_LVT, _ELVT, _Payload, State) ->
        Parent ! pong,
        {ok, State}
    end.

%% Simulation advancement is bounded by LVTUB.
lvtub_bounds_tick_tock(_Pid) ->
    meck:expect(test_actor, tick_tock, tick_tock(self(), 2)),
    assert_bounded().

%% Bounded simulation resumes after GVT is updated.
bounded_sim_resumes_after_gvt_update(Pid) ->
    meck:expect(test_actor, tick_tock, tick_tock(self(), 2)),
    gen_tw:gvt(Pid, 2),
    receive
        {violation, _} ->
            ?_assert(true)
    after
        100 ->
            ?_assert(false)
    end.

%% A bounded simulation still advances time in response to simulation events.
bounded_sim_still_advances_with_events(Pid) ->
    meck:expect(test_actor, tick_tock, tick_tock(self(), 2)),
    meck:expect(test_actor, handle_event, handle_event(self())),
    gen_tw:notify(Pid, gen_tw:event(4, ping)),
    receive
        pong ->
            assert_bounded()
    after
        100 ->
            ?_assert(false)
    end.

assert_bounded() ->
    receive
        {violation, _} ->
            ?_assert(false)
    after
        100 ->
            ?_assert(true)
    end.
