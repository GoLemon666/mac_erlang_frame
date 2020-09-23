-module(deck).
-export([new/0, new/1, draw/1, size/1]).

-include("openpoker.hrl").

new() -> 
  case op_common:get_env(deck, ?UNDEF) of
    ?UNDEF ->
      shuffle(make_deck());
    Cards ->
      hand:make_cards(Cards)
  end.

new(Cards) ->
  Cards.

draw([]) ->
  none;

draw([H|T]) ->
  {H, T}.

size(Cards) ->
  length(Cards).

make_deck() ->
    L1 = [ ?CF_TWO, 
           ?CF_THREE, 
           ?CF_FOUR,
           ?CF_FIVE,
           ?CF_SIX,
           ?CF_SEVEN,
           ?CF_EIGHT,
           ?CF_NINE,
           ?CF_TEN,
           ?CF_JACK,
           ?CF_QUEEN,
           ?CF_KING,
           ?CF_ACE ],
    L2 = [ ?CS_CLUBS, 
           ?CS_DIAMONDS, 
           ?CS_HEARTS,
           ?CS_SPADES ],
    [?POKER_ENCODE(Suit, Face) || Face <- L1, Suit <- L2].

shuffle(Cards) ->
  random:seed(now()),
  Temp = lists:map(fun(X) -> {random:uniform(), X} end, Cards),
  Temp1 = lists:keysort(1, Temp),
  lists:map(fun(X) -> element(2, X) end, Temp1).
