-module(test_actor).

-behaviour(gen_tw).

-export([init/0,
         tick_tock/2,
         handle_event/4]).

init() ->
    {ok, #{}}.

tick_tock(LVT, _State) ->
    {LVT, _State}.

handle_event(_LVT, _ELVT, <<>>, State) ->
    State.
