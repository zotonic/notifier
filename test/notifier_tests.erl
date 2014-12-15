%% @author Maas-Maarten Zeeman <mmzeeman@xs4all.nl>

-module(notifier_tests).

-include_lib("eunit/include/eunit.hrl").

observe_notify_test() ->
    {ok, _N} = notifier:start_link([{name, test_notifier}]),

    %% Notify without observers should work
    ?assertEqual(ok, notifier:notify(test_notifier, test, [1,2,3])),

    %% Observe 'test' event.
    ?assertEqual(ok, notifier:observe(test_notifier, test, self())),

    %% Send an atom event
    ?assertEqual(ok, notifier:notify(test_notifier, test, [1,2,3])),
    Msg = receive M -> M after 100 -> nothing end,
    ?assertEqual({'$gen_cast', {test, [1,2,3]}}, Msg),

    %% Send a different atom event, nothing should be received.
    ?assertEqual(ok, notifier:notify(test_notifier, something_else, [1,2,3])),
    Msg1 = receive M1 -> M1 after 100 -> nothing end,
    ?assertEqual(nothing, Msg1),

    %% Send a tuple event, the tuple is received.
    ?assertEqual(ok, notifier:notify(test_notifier, {test, "bla"}, [1,2,3])),
    Msg2 = receive M2 -> M2 after 100 -> nothing end,
    ?assertEqual({'$gen_cast', {{test, "bla"}, [1,2,3]}}, Msg2),

    %% Detach... 
    ?assertEqual(ok, notifier:detach(test_notifier, test, self())),

    %% Send an atom event
    ?assertEqual(ok, notifier:notify(test_notifier, test, [1,2,3])),
    Msg3 = receive M3 -> M3 after 100 -> nothing end,
    ?assertEqual(nothing, Msg3),

    notifier:stop(test_notifier),

    ok.

stopper() ->
    stopper([]).

stopper(Received) ->
    receive 
        {stop, P} -> 
            P ! {stopped, lists:reverse(Received)};
        Msg ->
            stopper([Msg|Received]) 
    after 
        1000 -> undefined 
    end.

lazy_detach_test() ->
    {ok, _N} = notifier:start_link([{name, test_notifier}]),

    Pid = spawn(fun stopper/0), 

    ?assertEqual(ok, notifier:observe(test_notifier, test, Pid)),
    ?assertEqual([{500, Pid}], notifier:get_observers(test_notifier, test)),

    % Stop the observer
    Pid ! {stop, self()},
    receive {stopped, _} -> ok end,

    %% And send a notification.
    ?assertEqual(ok, notifier:notify(test_notifier, test, [])),

    %% All the observers should be gone.
    receive wait -> ok after 100 -> ok end,
    ?assertEqual([], notifier:get_observers(test_notifier, test)),

    notifier:stop(test_notifier),

    ok.

notify1_test() ->
    {ok, _N} = notifier:start_link([{name, test_notifier}]),

    Pid1 = spawn(fun stopper/0), 
    Pid2 = spawn(fun stopper/0), 
    Pid3 = spawn(fun stopper/0), 

    ?assertEqual(ok, notifier:observe(test_notifier, test, Pid1)),
    ?assertEqual(ok, notifier:observe(test_notifier, test, Pid2)),
    ?assertEqual(ok, notifier:observe(test_notifier, test, Pid3)),

    ?assertEqual(ok, notifier:notify1(test_notifier, test, [])),

    receive after 100 -> undefined end,

    Pid1 ! {stop, self()},
    Pid2 ! {stop, self()},
    Pid3 ! {stop, self()},

    Received1 = receive {stopped, R1} -> R1 end,
    Received2 = receive {stopped, R2} -> [R2 | Received1] end,
    Received3 = receive {stopped, R3} -> [R3 | Received2]  end,

    %% We should have just one notification
    ?assertEqual([{'$gen_cast', {test, []}}], lists:flatten(Received3)),

    notifier:stop(test_notifier),

    ok.

tick_test() ->
    {ok, Notifier} = notifier:start_link([{name, test_notifier}]),
    Pid1 = spawn(fun stopper/0), 
    ?assertEqual(ok, notifier:observe(test_notifier, tick_1s, Pid1)),
    ?assertEqual(ok, notifier:observe(test_notifier, tick_1m, Pid1)),
    ?assertEqual(ok, notifier:observe(test_notifier, tick_1h, Pid1)),
    ?assertEqual(ok, notifier:observe(test_notifier, tick_2h, Pid1)),
    ?assertEqual(ok, notifier:observe(test_notifier, tick_12h, Pid1)),
    ?assertEqual(ok, notifier:observe(test_notifier, tick_24h, Pid1)),

    %% Simulate the ticks.
    Notifier ! {tick, tick_1s},
    Notifier ! {tick, tick_1m},
    Notifier ! {tick, tick_1h},
    Notifier ! {tick, tick_2h},
    Notifier ! {tick, tick_12h},
    Notifier ! {tick, tick_24h},

    receive after 100 -> undefined end,

    Pid1 ! {stop, self()},
    Received1 = receive {stopped, R1} -> R1 end,

    ?assertEqual([
            {'$gen_cast', {tick_1s, []}},
            {'$gen_cast', {tick_1m, []}},
            {'$gen_cast', {tick_1h, []}},
            {'$gen_cast', {tick_2h, []}},
            {'$gen_cast', {tick_12h, []}},
            {'$gen_cast', {tick_24h, []}}
        ], lists:flatten(Received1)),

    notifier:stop(test_notifier),
    ok.




