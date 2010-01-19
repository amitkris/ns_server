% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_client_ascii_ac).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% A memcached client that speaks ascii protocol,
%% with an "API conversion" interface.

cmd(Cmd, Sock, RecvCallback, Entry) when is_atom(Cmd) ->
    mc_client_ascii:cmd(Cmd, Sock, RecvCallback, Entry);

cmd(Cmd, Sock, RecvCallback, Entry) ->
    % Dispatch to cmd_binary() in case the caller was
    % using a binary protocol opcode.
    cmd_binary(Cmd, Sock, RecvCallback, Entry).

% -------------------------------------------------

%% For binary upstream talking to downstream ascii server.
%% The RecvCallback function will receive ascii-oriented parameters.

cmd_binary(?SET, Sock, RecvCallback, Entry) ->
    cmd(set, Sock, RecvCallback, Entry);

cmd_binary(?DELETE, Sock, RecvCallback, Entry) ->
    cmd(delete, Sock, RecvCallback, Entry);

cmd_binary(?FLUSH, Sock, RecvCallback, Entry) ->
    cmd(flush_all, Sock, RecvCallback, Entry);

cmd_binary(?NOOP, _Sock, RecvCallback, _Entry) ->
    % Assuming NOOP used to uncork GETKQ's.
    case is_function(RecvCallback) of
       true  -> RecvCallback(<<"END">>, #mc_entry{});
       false -> ok
    end;

cmd_binary(?VERSION, Sock, RecvCallback, Entry) ->
    cmd(version, Sock, RecvCallback, Entry);

cmd_binary(?GETKQ, Sock, RecvCallback, Entry) ->
    cmd(get, Sock, RecvCallback, Entry);

cmd_binary(Cmd, _S, _RC, _E) -> exit({unimplemented, Cmd}).

% -------------------------------------------------

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    flush_test_sock(Sock),
    (fun () ->
        {ok, RB} = cmd(?SET, Sock, undefined,
                       #mc_entry{key =  Key,
                                 data = <<"AAA">>}),
        ?assertMatch(RB, <<"STORED">>)
    end)().

flush_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    ok = gen_tcp:close(Sock).

flush_test_sock(Sock) ->
    {ok, RB} = cmd(?FLUSH, Sock, undefined, #mc_entry{}),
    ?assertMatch(RB, <<"OK">>).

