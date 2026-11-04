-module(playa_test_util).
-export([t0/0, iniciar/0, iniciar/1, detener/1, alimentar/6, calma/3, calma_todas/2, bandera/1, vista/1,
         esperar/2, cambios/1, tipos/2, silenciar/0, restaurar_logger/0]).

t0() ->
    calendar:datetime_to_gregorian_seconds({{2026, 11, 7}, {6, 0, 0}})
        - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).

iniciar() -> iniciar([]).
iniciar(Extra) ->
    application:load(playa),                    %% antes de set_env: si no, el .app lo pisa
    N = integer_to_list(erlang:unique_integer([positive])),
    Arch = "/tmp/playa_t_" ++ N ++ ".terms",
    Dir = "/tmp/playa_t_" ++ N ++ "_estado",
    T0 = t0(),
    Env = [{reloj, manual}, {reloj_inicio, T0}, {historial_archivo, Arch},
           {estado_dir, Dir}, {playas, [tijuana, rosarito]},
           {mareas, [{T0 - 86400, 1.5}, {T0 + 30 * 86400, 1.5}]}],   %% marea alta constante
    [application:set_env(playa, K, V) || {K, V} <- Env ++ Extra],
    {ok, _} = application:ensure_all_started(playa),
    #{archivo => Arch, dir => Dir}.

detener(#{archivo := A, dir := D}) ->
    application:stop(playa),
    application:unload(playa),
    file:delete(A),
    os:cmd("rm -rf " ++ D),
    ok.

%% Una "pasada" de datos de una playa en el instante T + tick (con sincronizacion).
alimentar(Id, T, Hs, Tp, Kmh, Mm) ->
    ok = playa_api:oleaje(Id, Hs, Tp, T),
    ok = playa_api:viento(Id, Kmh, T),
    ok = playa_api:lluvia(Id, Mm, T),
    playa_api:tick(T),
    vista(Id), ok.

%% N pasadas de calma cada 10 min desde Desde; devuelve el ultimo instante.
calma(Id, Desde, N) ->
    lists:foldl(fun(I, _) -> T = Desde + I * 600, alimentar(Id, T, 0.5, 8.0, 10.0, 0.0), T end,
                Desde, lists:seq(0, N - 1)).

%% Igual que calma/3 pero para TODAS las playas en el mismo instante (reloj coherente).
calma_todas(Desde, N) ->
    Ids = playa_api:playas(),
    lists:foldl(fun(I, _) ->
                    T = Desde + I * 600,
                    [begin ok = playa_api:oleaje(Id, 0.5, 8.0, T),
                           ok = playa_api:viento(Id, 10.0, T),
                           ok = playa_api:lluvia(Id, 0.0, T) end || Id <- Ids],
                    playa_api:tick(T),
                    [vista(Id) || Id <- Ids],
                    T
                end, Desde, lists:seq(0, N - 1)).

vista(Id) -> playa_api:bandera(Id).
bandera(Id) -> maps:get(bandera, vista(Id)).
cambios(Id) -> tipos(Id, cambio).
tipos(Id, Tipo) -> [E || E = #{tipo := T} <- playa_api:historial(Id), T =:= Tipo].

esperar(Fun, Ms) when Ms =< 0 -> Fun();
esperar(Fun, Ms) ->
    case catch Fun() of
        true -> true;
        _ -> timer:sleep(10), esperar(Fun, Ms - 10)
    end.

silenciar() -> logger:set_primary_config(level, none).
restaurar_logger() -> logger:set_primary_config(level, notice).
