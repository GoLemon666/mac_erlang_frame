-module(mod_betting_test).

-include("openpoker.hrl").
-include("openpoker_test.hrl").

-define(TWO_PLAYERS, [{?JACK, ?JACK_ID}, {?TOMMY, ?TOMMY_ID}]).
-define(THREE_PLAYERS, ?TWO_PLAYERS ++ [{?FOO, ?FOO_ID}]).

normal_betting_test_() -> {setup, fun setup_normal/0, fun sim:clean/1, fun () ->
        Players = ?THREE_PLAYERS,
        sim:join_and_start_game(Players),

        %% SB 10 BB 20
        B = 1, SB = 2, BB = 3, 
        sim:check_blind(Players, B, SB, BB),

        %% B CALL 20
        sim:check_notify_actor(B, Players),
        ?assertMatch(#notify_betting{call = 20, min = 20, max = 80}, sim_client:head(?JACK)),
        sim_client:send(?JACK, #cmd_raise{game = ?GAME, amount = 0}),
        sim:check_notify_raise(20, 0, Players),

        %% SB CALL 10
        sim:check_notify_actor(SB, Players),
        ?assertMatch(#notify_betting{call = 10, min = 20, max = 80}, sim_client:head(?TOMMY)),
        sim_client:send(?TOMMY, #cmd_raise{game = ?GAME, amount = 0}),
        sim:check_notify_raise(10, 0, Players),

        %% BB RAISE 20
        sim:check_notify_actor(BB, Players),
        ?assertMatch(#notify_betting{call = 0, min = 20, max = 80}, sim_client:head(?FOO)),
        sim_client:send(?FOO, #cmd_raise{game = ?GAME, amount = 20}),
        sim:check_notify_raise(0, 20, Players),

        %% B CALL 20
        sim:check_notify_actor(B, Players),
        ?assertMatch(#notify_betting{call = 20, min = 40, max = 60}, sim_client:head(?JACK)),
        sim_client:send(?JACK, #cmd_raise{game = ?GAME, amount = 0}),
        sim:check_notify_raise(20, 0, Players),

        %% SB CALL 20
        sim:check_notify_actor(SB, Players),
        ?assertMatch(#notify_betting{call = 20, min = 40, max = 60}, sim_client:head(?TOMMY)),
        sim_client:send(?TOMMY, #cmd_raise{game = ?GAME, amount = 0}),
        sim:check_notify_raise(20, 0, Players),

        %% TURNOVER STAGE
        sim:check_notify_stage_end(?GS_PREFLOP, Players),
        sim:check_notify_stage(?GS_FLOP, Players),

        %% SB CHECK
        sim:check_notify_actor(SB, Players),
        ?assertMatch(#notify_betting{call = 0, min = 20, max = 60}, sim_client:head(?TOMMY)),
        sim_client:send(?TOMMY, #cmd_raise{game = ?GAME, amount = 0}),
        sim:check_notify_raise(0, 0, Players),

        %% BB RAISE 20
        sim:check_notify_actor(BB, Players),
        ?assertMatch(#notify_betting{call = 0, min = 20, max = 60}, sim_client:head(?FOO)),
        sim_client:send(?FOO, #cmd_raise{game = ?GAME, amount = 20}),
        sim:check_notify_raise(0, 20, Players),

        %% B CALL 20
        sim:check_notify_actor(B, Players),
        ?assertMatch(#notify_betting{call = 20, min = 20, max = 40}, sim_client:head(?JACK)),
        sim_client:send(?JACK, #cmd_raise{game = ?GAME, amount = 0}),
        sim:check_notify_raise(20, 0, Players),

        %% SB CALL
        sim:check_notify_actor(SB, Players),
        ?assertMatch(#notify_betting{call = 20, min = 20, max = 40}, sim_client:head(?TOMMY)),
        sim_client:send(?TOMMY, #cmd_raise{game = ?GAME, amount = 0}),
        sim:check_notify_raise(20, 0, Players),

        %% FLOP OVER
        sim:check_notify_stage_end(?GS_FLOP, Players),
        ?assertMatch(stop, sim:game_state())
    end}.

normal_betting_and_fold_test_() -> {setup, fun setup_normal/0, fun sim:clean/1, fun () ->
        B = 1, SB = 2, BB = 3,
        Players = set_sn([{?JACK, B}, {?TOMMY, SB}, {?FOO, BB}], ?THREE_PLAYERS),

        sim:join_and_start_game(Players),
        sim:check_blind(Players, B, SB, BB),

        sim:turnover_player_raise({?JACK, Players},  {20, 20, 80}, 0),
        sim:turnover_player_raise({?TOMMY, Players}, {10, 20, 80}, 0),
        sim:turnover_player_raise({?FOO, Players},   { 0, 20, 80}, 0),

        sim:check_notify_stage_end(?GS_PREFLOP, Players),
        sim:check_notify_stage(?GS_FLOP, Players),

        sim:turnover_player_raise({?TOMMY, Players}, { 0, 20, 80}, 20),
        sim:turnover_player_fold ({?FOO, Players},   {20, 20, 60}),
        sim:turnover_player_raise({?JACK, Players},  {20, 20, 60}, 0),

        sim:check_notify_stage_end(?GS_FLOP, Players),
        ?assertMatch(#texas{joined = 3}, sim:game_ctx()),
        ?assertMatch(stop, sim:game_state())
    end}.

normal_betting_and_leave_test_() -> {setup, fun setup_normal/0, fun sim:clean/1, fun () ->
        B = 1, SB = 2, BB = 3,
        Players = set_sn([{?JACK, B}, {?TOMMY, SB}, {?FOO, BB}], ?THREE_PLAYERS),

        sim:join_and_start_game(Players),
        sim:check_blind(Players, B, SB, BB),

        sim:turnover_player_raise({?JACK, Players},  {20, 20, 80}, 0),
        sim:turnover_player_raise({?TOMMY, Players}, {10, 20, 80}, 0),
        sim:turnover_player_raise({?FOO, Players},   { 0, 20, 80}, 0),

        sim:check_notify_stage_end(?GS_PREFLOP, Players),
        sim:check_notify_stage(?GS_FLOP, Players),

        sim:turnover_player_raise({?TOMMY, Players}, { 0, 20, 80}, 20),
        sim:turnover_player_leave({?FOO, Players},   {20, 20, 60}),
        sim:turnover_player_raise({?JACK, proplists:delete(?FOO, Players)},  {20, 20, 60}, 0),

        sim:check_notify_stage_end(?GS_FLOP, proplists:delete(?FOO, Players)),
        ?assertMatch(#texas{joined = 2}, sim:game_ctx()),
        ?assertMatch(stop, sim:game_state())
    end}.

headsup_betting_test_() -> {setup, fun setup_normal/0, fun sim:clean/1, fun () ->
        SB = 1, BB = 2,
        Players = set_sn([{?JACK, SB}, {?TOMMY, BB}], ?TWO_PLAYERS),

        sim:join_and_start_game(Players),
        sim:check_blind(Players, SB, SB, BB),

        sim:turnover_player_raise({?JACK, Players},  {10, 20, 80}, 0),
        sim:turnover_player_raise({?TOMMY, Players}, { 0, 20, 80}, 0),

        sim:check_notify_stage_end(?GS_PREFLOP, Players),
        sim:check_notify_stage(?GS_FLOP, Players),

        sim:turnover_player_raise({?TOMMY, Players}, {0, 20, 80}, 0),
        sim:turnover_player_raise({?JACK, Players},  {0, 20, 80}, 20),
        sim:turnover_player_raise({?TOMMY, Players}, {20, 20, 60}, 0),

        sim:check_notify_stage_end(?GS_FLOP, Players),
        ?assertMatch(stop, sim:game_state())
    end}.

headsup_betting_and_fold_test_() -> {setup, fun setup_normal/0, fun sim:clean/1, fun () ->
        SB = 1, BB = 2,
        Players = set_sn([{?JACK, SB}, {?TOMMY, BB}], ?TWO_PLAYERS),

        sim:join_and_start_game(Players),
        sim:check_blind(Players, SB, SB, BB),

        sim:turnover_player_raise({?JACK, Players},  {10, 20, 80}, 0),
        sim:turnover_player_fold({?TOMMY, Players},  { 0, 20, 80}),

        ?assertMatch(#texas{joined = 2}, sim:game_ctx()),
        ?assertMatch(stop, sim:game_state())
    end}.

headsup_betting_and_leave_test_() -> {setup, fun setup_normal/0, fun sim:clean/1, fun () ->
        SB = 1, BB = 2,
        Players = set_sn([{?JACK, SB}, {?TOMMY, BB}], ?TWO_PLAYERS),

        sim:join_and_start_game(Players),
        sim:check_blind(Players, SB, SB, BB),

        sim:turnover_player_raise({?JACK, Players},  {10, 20, 80}, 0),
        sim:turnover_player_leave({?TOMMY, Players}, { 0, 20, 80}),

        ?assertMatch(#texas{joined = 1}, sim:game_ctx()),
        ?assertMatch(stop, sim:game_state())
    end}.

setup_normal() ->
  setup([{op_mod_blinds, []}, {op_mod_betting, [?GS_PREFLOP]}, {op_mod_betting, [?GS_FLOP]}]).

setup(MixinMods) ->
  sim:setup(),
  sim:setup_game(
    #tab_game_config{
      module = game, seat_count = 9, required = 2,
      limit = #limit{min = 100, max = 400, small = 10, big = 20},
      mods = [{op_mod_suspend, []}, {wait_players, []}] ++ MixinMods ++ [{stop, []}],
      start_delay = 0, timeout = 1000, max = 1}).

%%%
%%% private test until
%%%

set_sn([], Players) -> Players;
set_sn([{Key, SN}|T], Players) ->
  lists:keyreplace(Key, 1, Players, {Key, SN}),
  set_sn(T, Players).
