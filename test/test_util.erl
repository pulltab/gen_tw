-module(test_util).

-export([setup/0,
         setup/1,
         cleanup/1
        ]).

setup() ->
    setup(infinity).

setup(LVTUB) ->
    ok = meck:new(test_actor, [passthrough]),
    {ok, Pid} = gen_tw:start_link(LVTUB, test_actor, []),
    receive
        {ack, _, {ok, _}} ->
            Pid
    after 100 ->
        throw({failed_to_init_test_actor})
    end.

cleanup(Pid) ->
    erlang:unlink(Pid),
    gen_tw:stop(Pid),
    timer:sleep(1000),
    meck:unload(test_actor),
    ok.
