-module(lvtub_tests).

-include_lib("eunit/include/eunit.hrl").

gvt_test_() ->
    {foreach,
     fun() -> test_util:setup(2) end,
     fun test_util:cleanup/1,
     [
        fun lvtub_bounds_tick_tock/1
     ]}.

tick_tock(MaxLVT) ->
    fun(LVT, State) ->
        case LVT < MaxLVT of
            true ->
                {LVT+1, State};

            false ->
                exit(should_not_be_reached)
        end
    end.

lvtub_bounds_tick_tock(_Pid) ->
    meck:expect(test_actor, tick_tock, tick_tock(2)),
    timer:sleep(100),
    ?_assert(true).
