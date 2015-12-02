-module(gen_tw).

%% API
-export([start/2,
         start/3,
         start/4,
         start_link/2,
         start_link/3,
         start_link/4,
         stop/1,
         stop/2,
         gvt/2,
         event/2,
         event/3,
         antievent/1,
         notify/2,
         rollback/2,
         uuid/0
        ]).

-export_type([ref/0, event/0, virtual_time/0]).

-export([init/5]).

-callback init(Arg::term()) ->
    {ok, InitialState::term()} |
    {stop, Reason::term()} |
    ignore.
-callback tick_tock(CurrentLVT::virtual_time(), State::term()) -> {NextLVT::virtual_time(), NextState::term()}.
-callback handle_event(CurrentLVT::virtual_time(), EventLVT::virtual_time(), Event::term(), ModuleState::term()) ->
    {ok, NextState::term()} |
    {error, Reason::term()}.
-callback handle_info(Term::term()) -> ok | {error, Reason::term()}.
-callback terminate(State::term()) -> any().

-record(event,
    {lvt      :: virtual_time(),    %% Simulation time the event is to be applied
     id       :: uuid:uuid(),       %% Unique identifier for the event
     not_anti :: boolean(),         %% true for event, false for antievent
     link     :: ref() | undefined, %% Causal link for the event (Pid)
     payload  :: term()             %% Event payload
    }).

%% Invariant: The list contains no duplicates, and the events are sorted by
%% increasing LVT.
-type event_list() :: [#event{}].

%% Invariant: The list contains no duplicates, and the events are sorted by
%% decreasing LVT.
-type past_event_list() :: [#event{}].

-type module_state() :: {virtual_time(), term()}.

%% List of past states of client module.
%%
%% Invariant: The LVTs are unique and sorted in descending order.
-type module_state_list() :: [module_state()].

-opaque ref() :: pid().
-opaque event() :: #event{}.
-type virtual_time() :: integer().

-define(STOP_PAYLOAD(Reason), {'$stop', Reason}).
-define(GVT_UPDATE_PAYLOAD, '$gvt').

%%%===================================================================
%%% API
%%%===================================================================

-type name() :: undefined | {local, atom()} | {global, atom()}.
-spec start(atom(), term()) -> {ok, ref()}.
start(Module, Arg) ->
    start(undefined, Module, Arg).

-spec start(name(), atom(), term()) -> {ok, ref()}.
start(Name, Module, Arg) ->
    start(Name, Module, Arg, #{}).

-spec start(name(), atom(), term(), map()) -> {ok, ref()}.
start(Name, Module, ModuleArgs, GenTWArgs) ->
    do_spawn(nolink, Name, Module, ModuleArgs, GenTWArgs).

-spec start_link(atom(), term()) -> {ok, ref()}.
start_link(Module, Args) ->
    start_link(Module, Args, #{}).

-spec start_link(atom(), term(), map()) -> {ok, ref()}.
start_link(Module, Args, GenTWArgs) ->
    start_link(undefined, Module, Args, GenTWArgs).

-spec start_link(name(), atom(), term(), map()) -> {ok, ref()}.
start_link(Name, Module, Args, GenTWArgs) ->
    do_spawn(link, Name, Module, Args, GenTWArgs).

-spec stop(ref()) -> ok.
stop(Pid) ->
    stop(Pid, normal).

-spec stop(ref(), term()) -> ok.
stop(Pid, Reason) ->
    notify(Pid, event(undefined, ?STOP_PAYLOAD(Reason))).

-spec gvt(ref(), integer()) -> ok.
gvt(Pid, GVT) when is_integer(GVT) andalso GVT >= 0 ->
    notify(Pid, event(GVT, ?GVT_UPDATE_PAYLOAD)).

-spec antievent(Event::event()) -> event().
antievent(Event=#event{}) ->
    Event#event{
        not_anti = false,
        link = undefined
    }.

-spec event(virtual_time(), term()) -> event().
event(LVT, Payload) ->
    event(undefined, LVT, Payload).

-spec event(ref() | undefined, virtual_time(), term()) -> event().
event(Link, LVT, Payload) ->
    #event{
        lvt      = LVT,
        id       = uuid(),
        not_anti = true,
        link     = Link,
        payload  = Payload
    }.

-spec notify(ref(), event() | [event()]) -> ok.
notify(Ref, Events) when is_list(Events) ->
    Ref ! Events,
    ok;
notify(Ref, Event) when is_record(Event, event) ->
    notify(Ref, [Event]).

%%%===================================================================
%%% Internals
%%%===================================================================

-spec do_spawn(link | nolink, name(), atom(), [term()], map()) -> {ok, pid()} | {error, term()}.
do_spawn(Link, Name, Module, ModuleArgs, GenTWArgs) ->
    SpawnFun =
        case Link of
            nolink ->
                fun proc_lib:start/3;
            link ->
                fun proc_lib:start_link/3
        end,
    SpawnFun(?MODULE, init, [self(), Name, Module, ModuleArgs, GenTWArgs]).

-spec do_register(name()) -> ok | {error, term()}.
do_register(undefined) ->
    ok;
do_register({local, LocalName}) ->
    try register(LocalName, self()) of
        true ->
            ok;
        false ->
            {error, already_registered}
    catch
        error:Reason ->
            {error, Reason}
    end;
do_register({global, GlobalName}) ->
    case global:register_name(GlobalName, self()) of
        yes ->
            ok;
        no ->
            {error, already_registered}
    end.

-spec do_unregister(name()) -> ok | {error, term()}.
do_unregister(undefined) ->
    ok;
do_unregister({local, LocalName}) ->
    (catch unregister(LocalName));
do_unregister({global, GlobalName}) ->
    global:unregister_name(GlobalName).

do_init(Parent, Name, Module, Arg, GenTWArgs) ->
    GVT = maps:get(gvt, GenTWArgs, 0),
    LVTUB = maps:get(lvtub, GenTWArgs, infinity),

    InitRes =
        try
            Module:init(Arg)
        catch

            _:Reason ->
                do_unregister(Name),
                exit(Reason)
        end,

    case InitRes of
        {ok, ModuleState} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            loop(GVT, lvt_ub(GVT, LVTUB), [], [], Module, [{GVT, ModuleState}]);

        ignore ->
            do_unregister(Name),
            proc_lib:init_ack(Parent, ignore),
            exit(normal);

        {stop, StopReason} ->
            do_unregister(Name),
            proc_lib:init_ack(Parent, {error, StopReason}),
            exit(StopReason)
    end.

-spec init(pid(), name(), atom(), term(), map()) -> no_return().
init(Parent, Name, Module, Arg, GenTWArgs) ->
    case do_register(Name) of
        ok ->
            do_init(Parent, Name, Module, Arg, GenTWArgs);

        Error = {error, Reason} ->
            proc_live:init_ack(Parent, Error),
            exit(Reason)
    end.

-spec lvt_ub(virtual_time(), virtual_time() | infinity) -> virtual_time() | infinity.
lvt_ub(_, infinity) ->
    infinity;
lvt_ub(GVT, Offset) ->
    GVT + Offset.

-spec drain_msgq(Module::atom(), Events::event_list(), TMO::integer()) -> event_list().
drain_msgq(Module, Events, TMO) ->
    receive
        NewEvents when is_list(NewEvents) ->
            drain_msgq(Module, NewEvents ++ Events, 0);

        EventOrAntievent when is_record(EventOrAntievent, event) ->
            drain_msgq(Module, [EventOrAntievent | Events], 0);

        Msg ->
            case Module:handle_info(Msg) of
                ok ->
                    drain_msgq(Module, Events, 0);

                {error, Reason} ->
                    %%Discard any events and inject the stop event
                    [event(undefined, ?STOP_PAYLOAD(Reason))]
            end

    after TMO ->
        ordsets:from_list(Events)
    end.

-spec drain_msgq(Module::atom(), TMO::integer()) -> event_list().
drain_msgq(Module, InitialTMO) ->
    drain_msgq(Module, [], InitialTMO).

-spec append_state(virtual_time(), term(), module_state_list()) -> module_state_list().
append_state(LVT, State, []) ->
    [{LVT, State}];
append_state(LVT, NewState, [{LVT, _OldState}|T]) ->
    [{LVT, NewState}|T];
append_state(NewLVT, NewState, OldStates = [{OldLVT, _}|_]) when NewLVT > OldLVT ->
    [{NewLVT, NewState}|OldStates].

-spec tick_tock(virtual_time(), atom(), term()) -> module_state().
tick_tock(LVT, Module, ModuleState) ->
    Module:tick_tock(LVT, ModuleState).

%% Current LVT value is at or beyond LVT upperbound.  Nothing to do but wait for
%% events.  Note:  GVT Updates are events, as such, we will only be blocked here
%% for as long as we do not receive such an event.
loop(LVT, LVTUB, [], PastEvents, Module, ModState) when LVT >= LVTUB ->
    Events = drain_msgq(Module, infinity),
    loop(LVT, LVTUB, Events, PastEvents, Module, ModState);

%% No events to process, we are behind lvt upperbound so advance our local virtual time.
loop(LVT, LVTUB, _Events = [], PastEvents, Module, ModStates=[{LVT, ModState}|_]) ->
    case drain_msgq(Module, 0) of
        [] ->
            {NewLVT, NewModState} = tick_tock(LVT, Module, ModState),
            loop(NewLVT, LVTUB, [], PastEvents, Module, append_state(NewLVT, NewModState, ModStates));
        Events ->
            loop(LVT, LVTUB, Events, PastEvents, Module, ModStates)
    end;

loop(_LVT, _LVTUB, _Events = [#event{payload=?STOP_PAYLOAD(Reason)}|_], _PastEvents, Module, [{_, ModState}|_]) ->
    Module:terminate(ModState),
    exit(Reason);

%% GVT Update.  We are guaranteed to never rollback to a time previous to this
%% time value, thus, we can safely garbage collect ModStates and PastEvents occuring
%% before GVT.
%%
%% NOTE:  We make no attempt to calculate GVT amongst gen_tw actors.  This is
%% the responsibility of a system higher up the application stack.
loop(LVT, LVTUB, _Events=[#event{lvt=GVT, payload=?GVT_UPDATE_PAYLOAD}|T], PastEvents, Module, ModStates) when LVT >= GVT ->
    NewLVTUB = lvt_ub(GVT, LVTUB),
    NewModStates = [{ModLVT, ModState} || {ModLVT, ModState} <- ModStates, ModLVT >= GVT],
    NewPastEvents = [E || E<-PastEvents, E#event.lvt >= GVT],
    erlang:garbage_collect(),

    loop(LVT, NewLVTUB, T, NewPastEvents, Module, NewModStates);

%% First event in queue is an antievent for an event in PastEvents.  In this
%% case we roll back to a state occuring before the antievent, and resume
%% processing.  Placing events in PastEvents back into Events ensures that
%% the antievent and event will cancel each other out in the Events queue.
loop(LVT, LVTUB, Events=[#event{lvt=ELVT, not_anti=false}|_], PastEvents, Module, ModStates)
        when ELVT =< LVT ->
    NewModStates = lists:dropwhile(fun({SLVT, _}) -> SLVT >= ELVT end, ModStates),
    [{LastKnownLVT, _}|_] = NewModStates,
    rollback_loop(LastKnownLVT, LVTUB, Events, PastEvents, Module, NewModStates);

%% First event in queue occurs before LVT.  Rollback to LVT of the event and
%% handle the event.  We assume here that events are cumulative.
%%
%% Note:  This clause must applied before applying other rules such as
%% antievent/event cancellation.
loop(LVT, LVTUB, Events=[#event{lvt=ELVT}|_], PastEvents, Module, ModStates) when ELVT < LVT ->
    rollback_loop(ELVT, LVTUB, Events, PastEvents, Module, ModStates);

%% Antievent and events meeting in Events cancel each other
%% out.  Note:  We are relying on antievents appearing in the ordering first.
%% This prevents us from having to search PastEvents for the corresponding
%% event, in this case.
loop(LVT, LVTUB, [#event{id=EID, not_anti=false}|T], PastEvents, Module, ModStates) ->
    NewEvents = [E || E <- T, E#event.id /= EID],
    loop(LVT, LVTUB, NewEvents, PastEvents, Module, ModStates);

%% Event at or after the current value of LVT.  Process the event by invoking
%% Module:handle_event and looping on the new state provided.
%%
%% TODO:  We are currently halting on error here.  This is likely not what we
%% want to do.
loop(_LVT, LVTUB, [Event = #event{lvt=ELVT}|T], PastEvents, Module, ModStates=[{LVT, ModState}|_]) ->
    case handle_event(LVT, Event, Module, ModState) of
        {ok, NewModState} ->
            loop(ELVT, LVTUB, T, [Event|PastEvents], Module, append_state(ELVT, NewModState, ModStates));

        {error, Reason} ->
            %% TODO:  This can result in deadlock
            %% How can we more completely handle this?
            erlang:throw(Reason)
    end.

-spec rollback_loop(virtual_time(), event_list(), past_event_list(), virtual_time(), atom(), module_state_list()) -> no_return().
rollback_loop(RollbackLVT, LVTUB, Events, PastEvents, Module, ModStates) ->
    {ReplayOrUndo, NewPastEvents} = rollback(RollbackLVT, PastEvents),

    {Replay, Undo} = lists:partition(fun(#event{link=Link}) -> Link == undefined end, ReplayOrUndo),

    %%Send antievents for all events that occured within (ELVT, LVT] that have
    %%a causal link.
    [begin
        Link = Event#event.link,
        Link ! antievent(Event)
     end || Event <- Undo],

    NewEvents = ordsets:union(Replay, Events),
    NewModStates = lists:dropwhile(fun({SLVT, _}) -> SLVT > RollbackLVT end, ModStates),

    loop(RollbackLVT, LVTUB, NewEvents, NewPastEvents, Module, NewModStates).

%% Partition past events into two lists: events othat occurred before the given
%% LVT, and events that occurred at or after the given LVT.
%%
%% e.g. if LVT = 2, [3,2,1,0] becomes {[1,0], [2,3]}
-spec rollback(virtual_time(), past_event_list(), event_list()) -> {event_list(), past_event_list()}.
rollback(_LVT, [], NewEvents) ->
    {NewEvents, []};
rollback(LVT, Events=[#event{lvt=ELVT}|_], NewEvents) when LVT >= ELVT ->
    {NewEvents, Events};
rollback(LVT, [Event|T], NewEvents) ->
    rollback(LVT, T, [Event|NewEvents]).

-spec rollback(virtual_time(), past_event_list()) -> {event_list(), past_event_list()}.
rollback(LVT, Events) when is_integer(LVT) andalso LVT >= 0 ->
    rollback(LVT, Events, []).

handle_event(LVT, #event{lvt=EventLVT, payload=Payload}, Module, ModuleState) ->
    Module:handle_event(LVT, EventLVT, Payload, ModuleState).

-spec uuid() -> uuid:uuid().
uuid() ->
    uuid:uuid4().

%%%===================================================================
%%% Unit Tests
%%%===================================================================

-include_lib("eunit/include/eunit.hrl").

event_test() ->
    %% 2-ary event generates non-causal event
    E1 = event(0, <<"foo">>),
    ?assertEqual(E1#event.link, undefined),
    ?assertEqual(E1#event.lvt, 0),
    ?assertEqual(E1#event.payload, <<"foo">>),

    %% 3-ary event generates a causal event
    E2 = event(self(), 10, <<"bar">>),
    ?assertEqual(E2#event.link, self()),
    ?assertEqual(E2#event.lvt, 10),
    ?assertEqual(E2#event.payload, <<"bar">>).

%% Antievents are non-causal
antievent_test() ->
    E = event(self(), 150, <<"bar">>),
    A = antievent(E),

    ?assertEqual(A#event.not_anti, false),
    ?assertEqual(A#event.link, undefined).

append_state_test() ->
    T1 = append_state(0, foo, []),
    ?assertMatch(T1, [{0, foo}]),

    %% Latest states appear at the head of the list
    T2 = append_state(2, bar, T1),
    ?assertMatch([{2,bar} | T1], T2),

    %% Updating head element replaces the old value
    T3 = append_state(2, foobar, T2),
    ?assertMatch([{2,foobar}|T1], T3),

    %% Updating a value which is not the latest is not allowed
    try
        append_state(0, foobar, T2),
        ?assert(false)
    catch
        _:_ ->
            ok
    end.

rollback_test() ->
    InOrder = [event(LVT, <<>>) || LVT <- lists:seq(100,1, -1)],

    ?assertMatch({[], []}, rollback(0, [])),
    ?assertMatch({[], InOrder}, rollback(110, InOrder)),

    Temp = lists:reverse(InOrder),
    ?assertMatch({Temp, []}, rollback(0, InOrder)),

    {ResultReplay, ResultPast} = rollback(50, InOrder),
    ExpectedReplay = [E || E <- InOrder, E#event.lvt > 50],
    ExpectedPast = [E || E <- InOrder, E#event.lvt =< 50],

    ReplayDiff = ResultReplay -- ExpectedReplay,
    PastDiff = ResultPast -- ExpectedPast,

    ?assertMatch(ReplayDiff, []),
    ?assertMatch(PastDiff, []).
