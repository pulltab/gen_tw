-module(test_actor).

-behaviour(tw_actor).

-export([init/0,
         tick_tock/2,
         handle_event/4]).

init() ->
    {ok, []}.

tick_tock(LVT, State) ->
    {LVT + 1, State}.

handle_event(_LVT, _ELVT, <<>>, State) ->
    State.
