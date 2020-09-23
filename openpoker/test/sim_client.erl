-module(sim_client).
-export([start/1, start/2, stop/1, send/2, head/1, box/0, box/1]).
-export([player/2, setup_players/1]).

-export([loop/3]).

%% 模拟网络链接到服务器
%% 通过启动一个进程，模拟对网络链接的双向请求，
%% 提供单元测试一种模拟客户端的机制。

%% 由于使用webtekcos提供的wesocket链接，通过op_game模块
%% 处理客户端与服务器间通信的各种消息。sim_client启动后同样模拟
%% webtekcos的消息层，将各种消息同样发到op_game模块进行处理
%% 以达到Mock的效果。同时sim_client为测试程序提供了一些格外的接口
%% 以检查通信进程内部进程数据的正确性。

%% sim_client采用erlang最基本的消息元语进行编写。

-include("openpoker.hrl").
-include("openpoker_test.hrl").

-record(pdata, { box = [], host = ?UNDEF, timeout = 2000 }).

%%%
%%% client
%%%

start(Key, Timeout) ->
  ?assert(undefined =:= whereis(Key)),
  PD = #pdata{host = self(), timeout = Timeout},
  PID = spawn(?MODULE, loop, [op_game_handler, ?UNDEF, PD]),
  ?assert(true =:= register(Key, PID)),
  PID.

start(Key) when is_atom(Key) ->
  start(Key, 60 * 1000).

stop(Id) when is_pid(Id) ->
  exit(Id, kill).

send(Id, R) ->
  Id ! {sim, send, R},
  ?SLEEP.

head(Id) ->
  case whereis(Id) of
    ?UNDEF ->
      error_logger:error_report("sim_client:head/1 to undefined process"),
      ?UNDEF;
    Pid ->
      Pid ! {sim, head, self()},
      receive 
        R when is_tuple(R) -> R
      after
        500 -> exit(request_timeout)
      end
  end.

box() ->
  receive 
    Box when is_list(Box) -> Box
  end.

box(Id) ->
  Id ! {sim, box, self()},
  box().

%% tools function

player(Identity, Players) when is_atom(Identity) ->
  proplists:get_value(Identity, Players).

setup_players(L) ->
  sim:setup_players(L).

%%%
%%% callback
%%%

loop(Mod, ?UNDEF, Data = #pdata{}) ->
  LoopData = Mod:connect(Data#pdata.timeout),
  loop(Mod, LoopData, Data);

loop(Mod, LoopData, Data = #pdata{box = Box}) ->
  receive
    %% sim send protocol from client to server
    {sim, send, R} when is_tuple(R) ->
      Bin = base64:encode(list_to_binary(protocol:write(R))),
      NewLoopData = Mod:handle_data(Bin, LoopData),
      loop(Mod, NewLoopData, Data);
    %% sim get client side header message
    {sim, head, From} when is_pid(From) ->
      case Box of
        [H|T] ->
          From ! H,
          loop(Mod, LoopData, Data#pdata{box = T});
        [] ->
          loop(Mod, LoopData, Data#pdata{box = []})
      end;
    {sim, box, From} when is_pid(From) ->
      From ! Box,
      loop(Mod, LoopData, Data#pdata{box = []});
    {sim, kill} ->
      exit(kill);
    close ->
      Data#pdata.host ! Box,
      exit(normal);
    {send, Bin} when is_binary(Bin) ->
      R = protocol:read(base64:decode(Bin)),
      loop(Mod, LoopData, Data#pdata{box = Box ++ [R]});
    Message ->
      NewLoopData = Mod:handle_message(Message, LoopData),
      loop(Mod, NewLoopData, Data)
  end.
