-module(test_actor).

-behaviour(tw_actor).

-export([init/0,
         tick_tock/2,
         handle_event/4]).

init() ->
    {ok, 0}.

tick_tock(LVT, _State) ->
    {LVT, _State}.

handle_event(_LVT, _ELVT, <<>>, State) ->
    State.
