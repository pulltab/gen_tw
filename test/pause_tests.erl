-module(pause_tests).

-include_lib("eunit/include/eunit.hrl").

pause_test_() ->
    {foreach,
        fun test_util:setup/0,
        fun test_util:cleanup/1,
        [
         fun pause_halts_sim/1,
         fun stop_paused_sim/1,
         fun pause_for/1,
         fun resume_resumes_sim/1
        ]}.

pause_halts_sim(Pid) ->
    F = fun(_, _, _, _) -> exit(deadbeef) end,
    meck:expect(test_actor, handle_event, F),

    %% Note:  We rely on pause event being processed before all other simulation
    %% events.
    gen_tw:pause(Pid),
    gen_tw:notify(Pid, gen_tw:event(1, foo)),

    timer:sleep(10),

    ?_assert(true).

stop_paused_sim(Pid) ->
    Parent = self(),
    StopReason = deadbeef,
    F = fun(Reason, _State) -> Parent ! Reason end,
    meck:expect(test_actor, terminate, F),

    process_flag(trap_exit, true),

    gen_tw:pause(Pid),

    timer:sleep(10),

    gen_tw:stop(Pid, StopReason),

    receive
        deadbeef ->
            ?_assert(true);

        Else ->
            ?_assertMatch(true, Else)

    after
        500 ->
            ?_assert(false)
    end.

pause_for(Pid) ->
    PauseDuration = 10,
    PauseStart = erlang:timestamp(),
    gen_tw:pause_for(Pid, PauseDuration),

    Parent = self(),
    TT =
        fun(LVT, State) ->
            Parent ! {tick_tock, erlang:timestamp()},
            {LVT+1, State}
        end,
    meck:expect(test_actor, tick_tock, TT),

    receive
        {tick_tock, Timestamp} ->
            ?_assert(timer:now_diff(Timestamp, PauseStart) >= PauseDuration)
     after
        50 ->
            ?_assert(false)
    end.

resume_resumes_sim(Pid) ->
    Parent = self(),
    gen_tw:pause(Pid),

    HE =
        fun(_, _, _, State) ->
            Parent ! handle_event,
            {ok, State}
        end,
    meck:expect(test_actor, handle_event, HE),

    TT =
        fun(LVT, State) ->
            Parent ! tick_tock,
            {LVT+1, State}
        end,
    meck:expect(test_actor, tick_tock, TT),

    gen_tw:notify(Pid, gen_tw:event(1, foo)),
    gen_tw:resume(Pid),

    HEVal = receive handle_event -> true after 10 -> false end,
    TTVal = receive tick_tock -> true after 10 -> false end,

    [
     ?_assert(HEVal),
     ?_assert(TTVal)
    ].
