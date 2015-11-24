-module(test_util).

-export([setup/0,
         setup/1,
         cleanup/1
        ]).

setup() ->
    setup(infinity).

setup(LVTUB) ->
    ok = meck:new(test_actor, [passthrough]),
    {ok, Pid} = gen_tw:start_link(test_actor, [], LVTUB),
    Pid.

cleanup(Pid) ->
    erlang:unlink(Pid),
    gen_tw:stop(Pid),
    timer:sleep(1000),
    meck:unload(test_actor),
    ok.
