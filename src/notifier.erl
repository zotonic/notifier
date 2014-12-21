%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2009 Marc Worrell
%% @copyright 2014 Maas-Maarten Zeeman
%%
%% @doc Simple implementation of an observer/notifier. Relays events to observers of that event.
%% Also implements map and fold operations over the observers.

%% Copyright 2009 Marc Worrell, 2014 Maas-Maarten Zeeman
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(notifier).

-author("Marc Worrell <marc@worrell.nl>").

-behaviour(gen_server).

%% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% interface functions
-export([
    start_link/1,
    stop/1,
    observe/3,
    observe/4,
    detach/3,
    detach_all/2,
    get_observers/2,
    notify/3, 
    notify1/3, 
    first/3, 
    map/3, 
    foldl/4, 
    foldr/4
]).

%% internal
-export([notify_observer/5]).

-define(TIMEOUT, 60000).

-define(TIMER_INTERVAL, [ {1, tick_1s}, 
                          {60, tick_1m}, 
                          {3600, tick_1h},
                          {7200, tick_2h},
                          {43200, tick_12h},
                          {86400, tick_24h} ]).

-define(NOTIFIER_DEFAULT_PRIORITY, 500).

-record(state, {observers, timers, name, tick_arg}).

%%====================================================================
%% API
%%====================================================================
%% @spec start_link(SiteProps) -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the notification server
start_link(Name) when is_atom(Name) ->
    start_link([{name, Name}]);
start_link(Args) ->
    {name, Name} = proplists:lookup(name, Args),

    %% If the notifier crashes the supervisor gets ownership
    %% of the observer table. When it restarts the notifier
    %% it will give ownership back to the notifier.
    ObserverTable = ensure_observer_table(Name),

    case gen_server:start_link({local, Name}, ?MODULE, Args, []) of
        {ok, P} ->
            ets:give_away(ObserverTable, P, observer_table),
            {ok, P};
        {already_started, P} ->
            ets:give_away(ObserverTable, P, observer_table),
            {already_started, P};
        R -> R
    end.

%% @doc Stop the notification server.
stop(Name) ->
    gen_server:call(Name, stop).

% Make sure the observer table exists.
%
ensure_observer_table(Name) ->
    case ets:info(Name) of
        undefined -> ets:new(Name, [named_table, set, {keypos, 1}, protected, 
                    {read_concurrency, true}, {heir, self(), []}]);
        _ -> Name 
    end.


%%====================================================================
%% API for subscription
%%====================================================================

%% @doc Subscribe to an event. Observer is a {M,F} or pid()
observe(Name, Event, {Module, Function}) ->
    observe(Name, Event, {Module, Function}, ?NOTIFIER_DEFAULT_PRIORITY);
observe(Name, Event, Observer) ->
    observe(Name, Event, Observer, ?NOTIFIER_DEFAULT_PRIORITY).

%% @doc Subscribe to an event. Observer is a {M,F} or pid()
observe(Name, Event, Observer, Priority) ->
    gen_server:call(Name, {'observe', Event, Observer, Priority}).


%% @doc Detach all observers and delete the event
detach_all(Name, Event) ->
    gen_server:call(Name, {'detach_all', Event}).

%% @doc Unsubscribe from an event. Observer is a {M,F} or pid()
detach(Name, Event, Observer) ->
    gen_server:call(Name, {'detach', Event, Observer}).

%% @doc Return all observers for a particular event
get_observers(Name, Msg) when is_tuple(Msg) ->
    get_observers(Name, element(1, Msg));
get_observers(Name, Event) ->
    case ets:info(Name, name) of
        undefined -> 
            lager:warning("Notifier ~p not started.", [Name]),
            [];
        _ -> 
            case ets:lookup(Name, Event) of
                [] -> [];
                [{Event, Observers}] -> Observers
            end
    end.


%%====================================================================
%% API for notification
%% Calls are done in the calling process, to prevent copying of 
%% possibly large contexts for small notifications.
%%====================================================================

%% @doc Cast the event to all observers. The prototype of the observer is: f(Msg, Arg) -> void
notify(Name, Msg, Arg) ->
    case get_observers(Name, Msg) of
        [] -> ok;
        Observers ->
            F = fun() ->
                    lists:foreach(fun(Obs) -> 
                                notify_observer(Name, Msg, Obs, false, Arg) 
                        end, Observers)
            end,
            spawn(F),
            ok
    end.

%% @doc Cast the event to the first observer. The prototype of the observer is: f(Msg, Context) -> void
notify1(Name, Msg, Arg) ->
    case get_observers(Name, Msg) of
        [] -> ok;
        [Obs|_] -> 
            F = fun() -> notify_observer(Name, Msg, Obs, false, Arg) end,
            _ = spawn(F),
            ok
    end.


%% @doc Call all observers till one returns something else than undefined. The prototype of the observer is: f(Msg, Context)
first(Name, Msg, Arg) ->
    Observers = get_observers(Name, Msg),
    first1(Name, Observers, Msg, Arg).

first1(_Name, [], _Msg, _Arg) ->
    undefined;
first1(Name, [Obs|Rest], Msg, Arg) ->
    case notify_observer(Name, Msg, Obs, true, Arg) of
        Continue when Continue =:= undefined; Continue =:= continue -> 
            first1(Name, Rest, Msg, Arg);
        {continue, Msg1} ->
            first1(Name, Rest, Msg1, Arg);
        Result ->
            Result
    end.


%% @doc Call all observers, return the list of answers. The prototype of the observer is: f(Msg, Context)
map(Name, Msg, Arg) ->
    Observers = get_observers(Name, Msg),
    [notify_observer(Name, Msg, Obs, true, Arg) || Obs <- Observers].


%% @doc Do a fold over all observers, prio 1 observers first. The prototype of the observer is: f(Msg, Acc, Context)
foldl(Name, Msg, Acc0, Arg) ->
    Observers = get_observers(Name, Msg),
    lists:foldl(
            fun(Obs, Acc) -> 
                notify_observer_fold(Name, Msg, Obs, Acc, Arg) 
            end, 
            Acc0,
            Observers).

%% @doc Do a fold over all observers, prio 1 observers last
foldr(Name, Msg, Acc0, Arg) ->
    Observers = get_observers(Name, Msg),
    lists:foldr(
            fun(Obs, Acc) -> 
                notify_observer_fold(Name, Msg, Obs, Acc, Arg) 
            end, 
            Acc0,
            Observers).



%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore               |
%%                     {stop, Reason}
%% @doc Initiates the server, creates a new observer list
init(Args) ->
    {name, Name} = proplists:lookup(name, Args),

    %% Get the argument to pass for tick events.
    TickArg = case proplists:get_value(tick_arg, Args) of
        undefined -> [];
        Arg -> Arg
    end,

    Timers = [ timer:send_interval(timer:seconds(Time), {tick, Msg}) || {Time, Msg} <- ?TIMER_INTERVAL ],
    State = #state{observers=undefined, timers=Timers, name=Name, tick_arg=TickArg},
    {ok, State}.


%% @spec handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% @doc Add an observer to an event
handle_call({'observe', Event, Observer, Priority}, _From, State) ->
    Event1 = case is_tuple(Event) of true -> element(1,Event); false -> Event end,
    PObs = {Priority, Observer},
    UpdatedObservers = case ets:lookup(State#state.observers, Event1) of 
        [] -> 
            [PObs];
        [{Event1, Observers}] ->
            % Prevent double observers, remove old observe first
            OtherObservers = lists:filter(fun({_Prio,Obs}) -> Obs /= Observer end, Observers),
            lists:sort([PObs | OtherObservers])
    end,
    ets:insert(State#state.observers, {Event1, UpdatedObservers}),
    {reply, ok, State};

%% @doc Detach an observer from an event
handle_call({'detach', Event, Observer}, _From, State) ->
    Event1 = case is_tuple(Event) of true -> element(1,Event); false -> Event end,
    case ets:lookup(State#state.observers, Event1) of 
        [] -> ok;
        [{Event1, Observers}] -> 
            UpdatedObservers = lists:filter(fun({_Prio,Obs}) -> Obs /= Observer end, Observers),
            ets:insert(State#state.observers, {Event1, UpdatedObservers})
    end,
    {reply, ok, State};

%% @doc Detach all observer from an event
handle_call({'detach_all', Event}, _From, State) ->
    Event1 = case is_tuple(Event) of true -> element(1,Event); false -> Event end,
    ets:delete(State#state.observers, Event1),  
    {reply, ok, State};


%% @doc Stop the notifier
handle_call('stop', _From, State) ->
    {stop, normal, ok, State};

%% @doc Trap unknown calls
handle_call(Message, _From, State) ->
    {stop, {unknown_call, Message}, State}.

%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @doc Trap unknown casts
handle_cast(Message, State) ->
    {stop, {unknown_cast, Message}, State}.


%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% @doc Handle timer ticks
handle_info({tick, Msg}, #state{name=Name, tick_arg=TickArg} = State) ->
    spawn(fun() -> ?MODULE:notify(Name, Msg, TickArg) end),
    flush_message({tick, Msg}),
    {noreply, State};

%% @doc Handle ets table transfers
handle_info({'ETS-TRANSFER', Table, _FromPid, observer_table}, State) ->
    {noreply, State#state{observers=Table}};

%% @doc Handling all non call/cast messages
handle_info(_Info, State) ->
    {noreply, State}.


%% @spec terminate(Reason, State) -> void()
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
terminate(normal, State) ->
    cancel_timers(State#state.timers),
    ets:delete(State#state.observers),
    ok;
terminate(_Reason, State) ->
    cancel_timers(State#state.timers),
    ok.


%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @doc Convert process state when code is changed

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% support functions
%%====================================================================

cancel_timers(Timers) ->
    [ timer:cancel(TRef)  || {ok, TRef} <- Timers ].


%% @doc Notify an observer of an event
notify_observer(_Name, Msg, {_Prio, Fun}, _IsCall, Arg) when is_function(Fun) ->
    Fun(Msg, Arg);
notify_observer(Name, Msg, {_Prio, Pid}, IsCall, Arg) when is_pid(Pid) ->
    try
        case IsCall of
            true ->
                gen_server:call(Pid, {Msg, Arg}, ?TIMEOUT);
            false ->
                %% Make sure the process is alive before casting.
                true = is_it_alive(Pid),
                gen_server:cast(Pid, {Msg, Arg})
        end
    catch M:E ->
        case is_it_alive(Pid) of
            false ->
                lager:error("Error notifying ~p with event ~p. Detaching pid.", [Pid, Msg]),
                detach(Name, msg_event(Msg), Pid);
            true ->
                % Assume transient error
                nop
        end,
        {error, {notify_observer, Pid, Msg, M, E}}
    end;
notify_observer(_Name, Msg, {_Prio, {M,F}}, _IsCall, Arg) ->
    M:F(Msg, Arg);
notify_observer(Name, Msg, {_Prio, {M,F,[Pid]}}, _IsCall, Arg) when is_pid(Pid) ->
    try
        M:F(Pid, Msg, Arg)
    catch EM:E ->
        case is_it_alive(Pid) of
            false ->
                lager:error("Error notifying ~p with event ~p. Detaching pid.", [{M,F,Pid}, Msg]),
                detach(Name, msg_event(Msg), {M,F,[Pid]});
            true ->
                % Assume transient error
                nop
        end,
        {error, {notify_observer, Pid, Msg, EM, E}}
    end;
notify_observer(_Name, Msg, {_Prio, {M,F,Args}}, _IsCall, Arg) ->
    erlang:apply(M, F, Args++[Msg, Arg]).


%% @doc Notify an observer of an event, used in fold operations.  The receiving function should accept the message, the
%% accumulator and the context.
notify_observer_fold(_Name, Msg, {_Prio, Fun}, Acc, Arg) when is_function(Fun) ->
    Fun(Msg, Acc, Arg);
notify_observer_fold(Name, Msg, {_Prio, Pid}, Acc, Arg) when is_pid(Pid) ->
    try
        gen_server:call(Pid, {Msg, Acc, Arg}, ?TIMEOUT)
    catch M:E ->
        lager:error("Error folding ~p with event ~p. Detaching pid.", [Pid, Msg]),
        detach(Name, msg_event(Msg), Pid),
        {error, {notify_observer_fold, Pid, Msg, M, E}}
    end;
notify_observer_fold(_Name, Msg, {_Prio, {M,F}}, Acc, Arg) ->
    M:F(Msg, Acc, Arg);
notify_observer_fold(Name, Msg, {_Prio, {M,F,[Pid]}}, Acc, Arg) when is_pid(Pid) ->
    try
        M:F(Pid, Msg, Acc, Arg)
    catch EM:E ->
        lager:error("Error folding ~p with event ~p. Detaching pid.", [{M,F,Pid}, Msg]),
        detach(Name, msg_event(Msg), {M,F,[Pid]}),
        {error, {notify_observer, Pid, Msg, EM, E}}
    end;
notify_observer_fold(_Name, Msg, {_Prio, {M,F,Args}}, Acc, Arg) ->
    erlang:apply(M, F, Args++[Msg, Acc, Arg]).

%%
%% Helpers
%%

msg_event(E) when is_atom(E) -> 
    E;
msg_event(Msg) -> 
    element(1, Msg).

%% @doc Multinode is_alive check
is_it_alive(Pid) when is_pid(Pid) ->
    %% If node(Pid) is down, rpc:call returns something other than true or false.
    case rpc:call(node(Pid), erlang, is_process_alive, [Pid]) of
        true -> true;
        _ -> false
    end;
is_it_alive(_Pid) ->
    false.

%% @doc Flush all messages from the mailbox.
flush_message(Msg) ->
    receive
        Msg -> flush_message(Msg)
    after 0 ->
            ok
    end.
