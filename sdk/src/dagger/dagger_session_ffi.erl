-module(dagger_session_ffi).
-export([open_session/1, close_session/1]).

%% Lancia `dagger session`, aspetta il JSON di connessione su stdout,
%% e restituisce {ok, {Port, JsonLine}} | {error, Reason}.
%% La Port deve essere tenuta viva finché dura la sessione.
-spec open_session(binary()) -> {ok, {port(), binary()}} | {error, binary()}.
open_session(Command) ->
    CmdStr = binary_to_list(Command),
    Port = erlang:open_port(
        {spawn, CmdStr},
        [binary, {line, 65536}, exit_status]
    ),
    wait_for_json(Port).

%% Legge righe da stdout scartando quelle che non iniziano con '{'.
%% dagger session può emettere log prima del JSON.
wait_for_json(Port) ->
    receive
        {Port, {data, {eol, Line}}} ->
            case Line of
                <<"{", _/binary>> -> {ok, {Port, Line}};
                _Other             -> wait_for_json(Port)
            end;
        {Port, {data, {noeol, _Chunk}}} ->
            wait_for_json(Port);
        {Port, {exit_status, Code}} ->
            Msg = <<"dagger session exited prematurely with code ",
                    (integer_to_binary(Code))/binary>>,
            {error, Msg}
    after 30000 ->
        erlang:port_close(Port),
        {error, <<"timeout: dagger session did not respond within 30s">>}
    end.

%% Chiude la Port, terminando il processo `dagger session`.
-spec close_session(port()) -> ok.
close_session(Port) ->
    catch erlang:port_close(Port),
    ok.
