-module(test_actor).

-behaviour(gen_tw).

-export([init/1,
         tick_tock/2,
         handle_event/4,
         handle_info/1,
         terminate/1]).

init(_) ->
    {ok, #{}}.

tick_tock(LVT, _State) ->
    {LVT, _State}.

handle_event(_LVT, _ELVT, <<>>, State) ->
    State.

handle_info(Msg) ->
    Msg.

terminate(_) ->
    ok.
