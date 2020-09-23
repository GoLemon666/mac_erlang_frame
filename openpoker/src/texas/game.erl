-module(game).
-behaviour(op_exch).

-export([id/0, init/2, stop/1, dispatch/2, call/2]).
-export([start/0, start/1, start_conf/2, config/0]).
-export([watch/2, unwatch/2, join/2, leave/2, bet/2]).
-export([reward/3, query_seats/1, list/0, raise/2, fold/2]).
-export([do_leave/2, start_timer/2, cancel_timer/1]).
-export([broadcast/2, broadcast/3, info/1]).

-include("openpoker.hrl").

%%%
%%% callback
%%% 

id() ->
  counter:bump(game).

init(GID, R = #tab_game_config{}) ->
  create_runtime(GID, R),
  #texas { 
    gid = GID,
    seats = seat:new(R#tab_game_config.seat_count),
    max_joined = R#tab_game_config.seat_count,
    limit = R#tab_game_config.limit,
    timeout = ?PLAYER_TIMEOUT,
    start_delay = R#tab_game_config.start_delay,
    required = R#tab_game_config.required,
    xref = gb_trees:empty(),
    pot = pot:new(),
    deck = deck:new(),
    b = ?UNDEF,
    sb = ?UNDEF,
    bb = ?UNDEF
  }.

stop(#texas{gid = GID, timer = Timer}) ->
  catch erlang:cancel_timer(Timer),
  clear_runtime(GID).

call(_, Ctx) ->
  {ok, Ctx, Ctx}.

dispatch(R = #cmd_watch{proc = Proc, identity = Identity}, Ctx = #texas{observers = Obs}) ->
  player:notify(Proc, gen_game_detail(Ctx)),

  WatchedCtx = case proplists:lookup(Identity, Obs) of
    {Identity, _Proc} ->
      NewObs = [{Identity, Proc}] ++ proplists:delete(Identity, Obs),
      Ctx#texas{observers = NewObs};
    none ->
      Ctx#texas{observers = [{Identity, Proc}] ++ Obs}
  end,

  notify_player_seats(Proc, WatchedCtx),

  NotifyWatch = #notify_watch{
    proc = self(),
    game = Ctx#texas.gid,
    player = R#cmd_watch.pid},
  broadcast(NotifyWatch, WatchedCtx),

  WatchedCtx;

dispatch(R = #cmd_unwatch{identity = Identity}, Ctx = #texas{observers = Obs}) ->
  case proplists:lookup(Identity, Obs) of
    {Identity, _Proc} ->
      NotifyUnwatch = #notify_unwatch{
        proc = self(),
        game = Ctx#texas.gid,
        player = R#cmd_unwatch.pid},
      broadcast(NotifyUnwatch, Ctx),
      Ctx#texas{observers = proplists:delete(Identity, Obs)};
    none ->
      Ctx
  end;

dispatch(#cmd_join{buyin = Buyin}, Ctx = #texas{limit = Limit, joined = Joined, max_joined = MaxJoin})
when Joined =:= MaxJoin; Buyin < Limit#limit.min; Buyin > Limit#limit.max ->
  Ctx;

dispatch(R = #cmd_join{sn = SN}, Ctx = #texas{seats = Seats}) when SN /= 0 ->
  case seat:get(SN, Seats) of
    Seat = #seat{state = ?PS_EMPTY} ->
      do_join(R, Seat, Ctx);
    _ ->
      dispatch(R#cmd_join{sn = 0}, Ctx)
  end;

dispatch(R = #cmd_join{sn = SN}, Ctx = #texas{seats = Seats}) when SN =:= 0 ->
  %% auto compute player seat number
  [H = #seat{}|_] = seat:lookup(?PS_EMPTY, Seats),
  do_join(R, H, Ctx);
  
dispatch(R = #cmd_leave{}, Ctx = #texas{}) ->
  do_leave(R, Ctx);

dispatch({query_seats, Player}, Ctx) when is_pid(Player)->
  notify_player_seats(Player, Ctx).

%%%
%%% client
%%%

start() ->
  Fun = fun(R = #tab_game_config{max = Max}, _Acc) ->
      start_conf(R, Max)
  end, 

  ok = mnesia:wait_for_tables([tab_game_config], ?WAIT_TABLE),
  {atomic, Result} = mnesia:transaction(fun() -> mnesia:foldl(Fun, nil, tab_game_config) end),
  Result.

start(Mods) when is_list(Mods)->
  Conf = #tab_game_config{id = 1, module = game, mods = Mods, limit = no_limit, seat_count = 9, start_delay = 3000, required = 2, timeout = 1000, max = 1},
  start_conf(Conf, 1);

start(Conf = #tab_game_config{max = Max}) ->
  start_conf(Conf, Max).

start_conf(Conf, N) -> 
  start_conf(Conf, N, []).

start_conf(_Conf, 0, L) -> L;
start_conf(Conf = #tab_game_config{module = Module, mods = Mods}, N, L) when is_list(Mods) ->
  {ok, Pid} = op_exch:start_link(Module, Conf, Mods),
  start_conf(Conf, N - 1, L ++ [{ok, Pid}]);
start_conf(Conf = #tab_game_config{}, N, L) ->
  start_conf(Conf#tab_game_config{mods = default_mods()}, N, L).

config() ->
  Fun = fun(R, Acc) -> [R] ++ Acc end, 
  ok = mnesia:wait_for_tables([tab_game_config], ?WAIT_TABLE),
  {atomic, NewAcc} = mnesia:transaction(fun() -> mnesia:foldl(Fun, [], tab_game_config) end),
  lists:reverse(NewAcc).

%% check

bet({R = #seat{}, Amt}, Ctx = #texas{}) ->
  bet({R, Amt, 0}, Ctx);

bet({R = #seat{sn = SN}, _Call = 0, _Raise = 0}, Ctx = #texas{seats = Seats}) ->
  broadcast(#notify_raise{game = Ctx#texas.gid, player = R#seat.pid, sn = SN, raise = 0, call = 0}, Ctx),
  NewSeats = seat:set(SN, ?PS_BET, Seats),
  Ctx#texas{seats = NewSeats};

%% call & raise
bet({S = #seat{inplay = Inplay, bet = Bet, pid = PId, sn = SN}, Call, Raise}, Ctx = #texas{seats = Seats}) ->
  Amt = Call + Raise,
  {State, AllIn, CostAmt} = case Amt < Inplay of 
    true -> {?PS_BET, false, Amt}; 
    _ -> {?PS_ALL_IN, true, Inplay} 
  end,

  Fun = fun() ->
      [R] = mnesia:read(tab_inplay, PId, write),
      ok = mnesia:write(R#tab_inplay{inplay = Inplay - CostAmt}),
      ok = mnesia:write(#tab_turnover_log{
          pid = PId, game = Ctx#texas.gid,
          amt = 0 - CostAmt, cost = 0, inplay = Inplay - CostAmt})
  end,
  
  case mnesia:transaction(Fun) of
    {atomic, ok} ->
      broadcast(#notify_raise{game = Ctx#texas.gid, player = PId, sn = SN, raise = Raise, call = Call}, Ctx),
      NewSeats = seat:set(S#seat{inplay = Inplay - CostAmt, state = State, bet = Bet + CostAmt}, Seats),
      NewPot = pot:add(Ctx#texas.pot, PId, Amt, AllIn),
      Ctx#texas{seats = NewSeats, pot = NewPot}
  end.

reward(#hand{seat_sn = SN, pid = PId}, Amt, Ctx = #texas{seats = Seats}) when Amt > 0 ->
  WinAmt = Amt,
  Seat = seat:get(SN, Seats),
  PId = Seat#seat.pid,

  Fun = fun() ->
      [R] = mnesia:read(tab_inplay, PId, write),
      RewardInplay = R#tab_inplay.inplay + WinAmt,
      ok = mnesia:write(R#tab_inplay{inplay = R#tab_inplay.inplay + WinAmt}),
      ok = mnesia:write(#tab_turnover_log{
          pid = Seat#seat.pid, game = Ctx#texas.gid,
          amt = WinAmt, cost = Amt - WinAmt, inplay = RewardInplay}),
      RewardInplay
  end,
  
  case mnesia:transaction(Fun) of
    {atomic, RewardInplay} ->
      broadcast(#notify_win{ game = Ctx#texas.gid, sn = SN, player = PId, amount = WinAmt}, Ctx),
      RewardedSeats = seat:set(Seat#seat{inplay = RewardInplay, bet = 0}, Seats),
      Ctx#texas{seats = RewardedSeats}
  end.

broadcast(Msg, #texas{observers = Obs}, []) ->
  broadcast(Msg, Obs);
broadcast(Msg, Ctx = #texas{observers = Obs}, _Exclude = [H|T]) ->
  broadcast(Msg, Ctx#texas{observers = proplists:delete(H, Obs)}, T).

broadcast(Msg, #texas{observers = Obs}) -> 
  broadcast(Msg, Obs);
broadcast(_Msg, []) -> ok;
broadcast(Msg, [{_, Process}|T]) ->
  player:notify(Process, Msg),
  broadcast(Msg, T).

watch(Game, R = #cmd_watch{}) when is_pid(Game) ->
  gen_server:cast(Game, R#cmd_watch{proc = self()}).

unwatch(Game, R =  #cmd_unwatch{}) when is_pid(Game) ->
  gen_server:cast(Game, R#cmd_unwatch{proc = self()}).

join(Game, R = #cmd_join{}) when is_pid(Game) ->
  gen_server:cast(Game, R#cmd_join{proc = self()}).

leave(Game, R = #cmd_leave{}) when is_pid(Game) ->
  gen_server:cast(Game, R).

raise(Game, R = #cmd_raise{}) when is_pid(Game) ->
  gen_server:cast(Game, R).

fold(Game, R = #cmd_fold{}) when is_pid(Game) ->
  gen_server:cast(Game, R).

query_seats(Game) when is_pid(Game) ->
  gen_server:cast(Game, {query_seats, self()}).

list() ->
  Fun = fun(#tab_game_xref{process = Game}, Acc) ->
      Acc ++ [info(Game)]
  end,
  {atomic, Result} = mnesia:transaction(fun() -> mnesia:foldl(Fun, [], tab_game_xref) end),
  Result.

info(Game) ->
  State = op_common:get_status(Game),
  get_notify_game(State#exch.ctx).

start_timer(Ctx = #texas{timeout = Timeout}, Msg) ->
  Timer = erlang:start_timer(Timeout, self(), Msg),
  Ctx#texas{timer = Timer}.

cancel_timer(Ctx = #texas{timer = T}) ->
  catch erlang:cancel_timer(T),
  Ctx#texas{timer = ?UNDEF}.

do_leave(R = #cmd_leave{sn = SN, pid = PId}, Ctx = #texas{seats = Seats}) ->
  #seat{pid = PId} = seat:get(SN, Seats),
    
  DoLeaveFun = fun() -> 
      [Info] = mnesia:read(tab_player_info, PId, write),
      [Inplay] = mnesia:read(tab_inplay, PId, write),

      true = Inplay#tab_inplay.inplay >= 0,

      NewCash = Info#tab_player_info.cash + Inplay#tab_inplay.inplay,

      ok = mnesia:write(#tab_buyin_log{
          gid = Ctx#texas.gid, 
          pid = R#cmd_leave.pid, 
          amt = Inplay#tab_inplay.inplay,
          cash = NewCash,
          credit = Info#tab_player_info.credit}),
      ok = mnesia:write(Info#tab_player_info{cash = NewCash}),
      ok = mnesia:delete_object(Inplay)
  end,

  {atomic, ok} = mnesia:transaction(DoLeaveFun),

  LeaveMsg = #notify_leave{
    sn = SN, 
    player = PId,
    game = Ctx#texas.gid,
    proc = self()},
  broadcast(LeaveMsg, Ctx),

  %% 目前还不清楚当玩家离开时设置PS_EMPTY会对后面的结算有什么影响。
  %% 但当收到cmd_leave请求时确实应该将其状态设置为EMPTY而不是什么LEAVE。
  %% 或者说还不太清楚LEAVE这个状态到底代表什么意思。

  LeavedSeats = seat:clear(SN, Seats),
  Ctx#texas{seats = LeavedSeats, joined = Ctx#texas.joined - 1}.

%%%
%%% private
%%%

get_notify_game(#texas{gid = GId, joined = Joined, required = Required, seats = Seats, limit = Limit}) ->
  #notify_game{
    game = GId,
    name = <<"TEXAS_TABLE">>,
    limit = Limit,
    seats = seat:info(size, Seats),
    require = Required,
    joined = Joined
  }.


create_runtime(GID, R) ->
  mnesia:dirty_write(#tab_game_xref {
      gid = GID,
      process = self(),
      module = R#tab_game_config.module,
      limit = R#tab_game_config.limit,
      seat_count = R#tab_game_config.seat_count,
      timeout = R#tab_game_config.timeout,
      required = R#tab_game_config.required
  }).

clear_runtime(GID) ->
  ok = mnesia:dirty_delete(tab_game_xref, GID).

notify_player_seats(Player, Ctx) ->
  Fun = fun(R) ->
      R1 = #notify_seat{
        game = Ctx#texas.gid,
        sn = R#seat.sn,
        state = R#seat.state,
        player = R#seat.pid,
        inplay = R#seat.inplay,
        bet = R#seat.bet,
        nick = R#seat.nick,
        photo = R#seat.photo
      },

      player:notify(Player, R1)
  end,
  SeatsList = seat:get(Ctx#texas.seats),
  lists:map(Fun, SeatsList),
  player:notify(Player, #notify_seats_list_end{size = length(SeatsList)}),
  Ctx.

default_mods() ->
  ?DEF_MOD.

do_join(R = #cmd_join{identity = Identity, proc = Process}, Seat = #seat{}, Ctx = #texas{observers = Obs, seats = Seats}) ->
  case proplists:lookup(Identity, Obs) of
    {Identity, Process} ->
      JoinedSeats = seat:set(Seat#seat{
          identity = Identity,
          pid = R#cmd_join.pid,
          process = Process,
          hand = hand:new(),
          bet = 0,
          inplay = R#cmd_join.buyin,
          state = ?PS_WAIT,
          nick = R#cmd_join.nick,
          photo = R#cmd_join.photo
        }, Seats),


      JoinMsg = #notify_join{
        game = Ctx#texas.gid,
        player = R#cmd_join.pid,
        sn = Seat#seat.sn,
        buyin = R#cmd_join.buyin,
        nick = R#cmd_join.nick,
        photo = R#cmd_join.photo,
        proc = self()
      },

      Fun = fun() ->
          [] = mnesia:read(tab_inplay, R#cmd_join.pid), % check none inplay record
          [Info] = mnesia:read(tab_player_info, R#cmd_join.pid, write),
          Balance = Info#tab_player_info.cash + Info#tab_player_info.credit,

          case Balance < R#cmd_join.buyin of
            true ->
              exit(err_join_less_balance);
            _ ->
              ok
          end,

          ok = mnesia:write(#tab_buyin_log{
              pid = R#cmd_join.pid, gid = Ctx#texas.gid, 
              amt = 0 - R#cmd_join.buyin, cash = Info#tab_player_info.cash - R#cmd_join.buyin,
              credit = Info#tab_player_info.credit}),
          ok = mnesia:write(#tab_inplay{pid = R#cmd_join.pid, inplay = R#cmd_join.buyin}),
          ok = mnesia:write(Info#tab_player_info{cash = Info#tab_player_info.cash - R#cmd_join.buyin})
      end,

      case mnesia:transaction(Fun) of
        {atomic, ok} ->
          broadcast(JoinMsg, Ctx),
          Ctx#texas{seats = JoinedSeats, joined = Ctx#texas.joined + 1};
        {aborted, Err} ->
          ?LOG([{game, error}, {join, R}, {ctx, Ctx}, {error, Err}]),
          Ctx
      end;
    _ -> % not find watch in observers
      ?LOG([{game, error}, {join, R}, {ctx, Ctx}, {error, not_find_observer}]),
      Ctx
  end.

gen_game_detail(Ctx = #texas{}) ->
  #notify_game_detail{
    game = Ctx#texas.gid, 
    pot = pot:total(Ctx#texas.pot),
    stage = Ctx#texas.stage,
    limit = Ctx#texas.limit,
    seats = seat:info(size, Ctx#texas.seats),
    require = Ctx#texas.required,
    joined = Ctx#texas.joined
  }.
