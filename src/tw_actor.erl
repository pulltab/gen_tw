-module(tw_actor).

%% API
-export([spawn_link/2
        ]).

-export([init/3]).

-callback init() -> {ok, InitialState::term()}.
-callback tick_tock(CurrentLVT::integer(), State::term()) -> {NextLVT::integer(), NextState::term()}.
-callback handle_event(CurrentLVT::integer(), EventLVT::integer(), Event::term(), ModuleState::term()) -> NextState::term() | {error, Reason::term()}.

-record(ack,
    {id}).

-record(event,
    {lvt,           %% Simulation time the event is to be applied
     id,            %% Unique identifier for the event
     anti = 0,      %% 0 for event, -1 for antievent
     src,           %% Originating pid
     payload         %% Event payload
    }).

%%%===================================================================
%%% API
%%%===================================================================

-spec spawn_link(atom(), [term()]) -> {ok, pid()}.
spawn_link(Module, Args) ->
    Pid = proc_lib:spawn_link(?MODULE, init, [0, Module, Args]),
    {ok, Pid}.

-spec init(integer(), atom(), list(term())) -> no_return().
init(InitialLVT, Module, Args) ->
    case erlang:apply(Module, init, Args) of
        {ok, ModuleState} ->
            loop(InitialLVT, [], [], [], Module, ModuleState);

        Error ->
            erlang:throw(Error)
    end.

drain_msgq(Events, TMO) ->
    receive
        EventOrAntievent ->
            drain_msgq([EventOrAntievent | Events], 0)
    after TMO ->
        Events
    end.

drain_msgq(InitialTMO) ->
    drain_msgq([], InitialTMO).

-spec tick_tock(integer(), atom(), term()) -> {integer(), term()}.
tick_tock(LVT, Module, ModuleState) ->
    Module:tick_tock(LVT, ModuleState).

%% No events to process and not waiting on any acks, integrate ourselves forward in time.
loop(LVT, _Events = [], PastEvents, _PendingAcks = [], Module, ModState) ->
    case drain_msgq(0) of
        [] ->
            {NewLVT, NewModState} = tick_tock(LVT, Module, ModState),
            loop(NewLVT, [], PastEvents, [], Module, NewModState);
        Events ->
            loop(LVT, ordset:from_list(Events), PastEvents, [], Module, ModState)
    end;

%% Acknowledgement of an event we sent.  Forcibly remove from PendingAcks.
loop(LVT, [#ack{id=AckID} | T], PastEvents, PendingAcks, Module, ModState) ->
    NewPendingAcks = ordsets:del_element(AckID, PendingAcks),
    loop(LVT, T, PastEvents, NewPendingAcks, Module, ModState);

%% First queued event is earlier than LVT, need to rollback before handling.
%% Add any new pending ACKs to the list we are already waiting for.
loop(LVT, Events = [_PastEvent = #event{lvt=ELVT}|_], PendingAcks, PastEvents, Module, ModState) when ELVT < LVT ->
    %%TODO:  Rollback
    loop(LVT, Events, PastEvents, PendingAcks, Module, ModState);

%% Antievent and events meeting in Events cancel each other
%% out.  Note:  We are relying on antievents appearing in the ordering first.
%% This prevents us from having to search PastEvents for the corresponding
%% event, in this case.
loop(LVT, [#event{id=EID, anti=-1}|T], PastEvents, PendingAcks, Module, ModState) ->
    NewEvents = [E || E <- T, E#event.id /= EID],
    loop(LVT, NewEvents, PastEvents, PendingAcks, Module, ModState);

%% First queue event is at or later than LVT.
loop(LVT, [Event = #event{}|T], PastEvents, [], Module, ModState) ->
    {NewLVT, NewModState} = handle_event(LVT, Event, Module, ModState),
    loop(NewLVT, T, [Event | PastEvents], [], Module, NewModState);

loop(LVT, Events, PastEvents, PendingAcks, Module, ModState) ->
    AddEvents = drain_msgq(infinity),
    NewEvents = ordsets:union(ordsets:from_list(AddEvents, Events)),
    loop(LVT, NewEvents, PastEvents, PendingAcks, Module, ModState).

handle_event(LVT, #event{lvt=EventLVT, payload=Payload}, Module, ModuleState) ->
    case Module:handle_event(LVT, EventLVT, Payload, ModuleState) of
        {error, Reason} ->
            %% TODO:  This can result in deadlock
            %% How can we more completely handle this?
            erlang:throw(Reason);
        NewModuleState ->
            {EventLVT, NewModuleState}
    end.
