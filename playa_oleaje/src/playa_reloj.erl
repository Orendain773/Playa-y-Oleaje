%% Reloj de pulso: sin ticks no se detecta la ausencia de datos (nadie "habla" cuando
%% una boya se pierde). En modo manual (simulacion/pruebas) el tiempo lo avanza quien llama.
-module(playa_reloj).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    case application:get_env(playa, reloj, auto) of
        auto -> programar();
        manual -> ok
    end,
    {ok, #{}}.

programar() ->
    erlang:send_after(application:get_env(playa, tick_ms, 60000), self(), tick).

handle_call(_R, _F, S) -> {reply, ok, S}.
handle_cast(_M, S) -> {noreply, S}.
handle_info(tick, S) ->
    Now = erlang:system_time(second),
    [playa_bandera:tick(Id, Now) || Id <- playa_config:playas()],
    programar(),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.
