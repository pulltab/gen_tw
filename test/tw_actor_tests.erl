-module(tw_actor_tests).

-include_lib("eunit/include/eunit.hrl").

spawn_test() ->
    Res = tw_actor:spawn_link(test_actor, []),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    ?assert(is_pid(Pid)).

start_stop_test() ->
    {ok, Pid} = tw_actor:spawn(test_actor, []),
    timer:sleep(1000),
    ok == tw_actor:stop(Pid).

tw_properties_test_() ->
    {foreach,
        fun() ->
            meck:new(test_actor, [passthrough]),
            {ok, Pid} = tw_actor:spawn_link(test_actor, []),
            Pid
         end,
        fun(Pid) ->
            erlang:unlink(Pid),
            tw_actor:stop(Pid),
            meck:unload(test_actor)
        end,
        [
            fun event_antievent_cancel/1,
            fun event_rollback_from_antievent/1
        ]}.

event_antievent_cancel(Pid) ->
    meck:expect(test_actor, handle_event, fun(_, _, _, _) -> exit(should_not_be_reached) end),

    Event = tw_actor:event(10, <<>>),
    Antievent = tw_actor:antievent(Event),
    tw_actor:notify(Pid, [Event, Antievent]),
    timer:sleep(100),
    ?_assert(true).


event_rollback_from_antievent(Pid) ->
    meck:expect(test_actor, handle_event, fun(_, _, _, _) -> ok end),
    ?_assert(true).
