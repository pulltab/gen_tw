-module(test_util).

-export([setup/0,
         setup/1,
         cleanup/1,
         expect/2
        ]).

setup() ->
    setup(infinity).

setup(LVTUB) ->
    ok = meck:new(test_actor, [passthrough]),
    {ok, Pid} = gen_tw:start_link(test_actor, [], #{lvtub=>LVTUB}),
    Pid.

cleanup(Pid) ->
    erlang:unlink(Pid),
    exit(Pid, kill),
    meck:unload(test_actor),
    ok.

expect([], _) ->
    true;
expect([Msg|T], TMO) ->
    receive
        Msg ->
            expect(T, TMO)
    after
        TMO ->
            false
    end.
