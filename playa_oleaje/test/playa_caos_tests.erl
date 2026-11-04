%% Pruebas de caos: se MATA procesos reales y se verifica la recuperacion.
-module(playa_caos_tests).
-include_lib("eunit/include/eunit.hrl").
-import(playa_test_util, [t0/0, alimentar/6, calma_todas/2, bandera/1, vista/1, tipos/2, esperar/2]).

caos_test_() ->
    {foreach,
     fun() -> playa_test_util:silenciar(), playa_test_util:iniciar() end,
     fun(Ctx) -> playa_test_util:detener(Ctx), playa_test_util:restaurar_logger() end,
     [fun(_) -> {timeout, 30, {"C1 matar una playa: reinicia sola, conserva estado y override",
                               fun c1_matar_playa/0}} end,
      fun(_) -> {timeout, 30, {"C2 caidas en bucle: escala al supervisor y se recupera",
                               fun c2_bucle/0}} end,
      fun(_) -> {timeout, 30, {"C3 matar el almacen: estado en disco; sin estado -> amarilla, nunca verde",
                               fun c3_almacen/0}} end,
      fun(_) -> {timeout, 30, {"C4 mensaje venenoso: cae una playa, vuelve intacta, sin bucle",
                               fun c4_venenoso/0}} end]}.

pid(Id) -> whereis(playa_bandera:via(Id)).
nuevo_pid(Id, Viejo) -> esperar(fun() -> P = pid(Id), is_pid(P) andalso P =/= Viejo end, 3000).

roja_con_override(Id, T0) ->
    Tv = calma_todas(T0, 8),
    T = Tv + 600,
    alimentar(Id, T, 2.4, 9.0, 10.0, 0.0),
    ok = playa_api:override(Id, doble_roja, <<"rescates multiples">>, <<"salvavidas A">>, T, 6 * 3600),
    T.

c1_matar_playa() ->
    T = roja_con_override(tijuana, t0()),
    P0 = pid(tijuana), R0 = pid(rosarito),
    Inicio = erlang:monotonic_time(millisecond),
    exit(P0, kill),
    ?assert(nuevo_pid(tijuana, P0)),
    Ms = erlang:monotonic_time(millisecond) - Inicio,
    ?debugFmt("C1: reinicio de tijuana en ~b ms", [Ms]),
    ?assertEqual(R0, pid(rosarito)),                                   %% las demas ni se enteran
    ?assertMatch(#{bandera := doble_roja, fuente := salvavidas, nivel_sistema := roja,
                   override := #{autor := <<"salvavidas A">>}}, vista(tijuana)),
    ?assertMatch([#{tipo := reinicio}], tipos(tijuana, reinicio)),
    ?assertEqual(verde, bandera(rosarito)),
    _ = T.

c2_bucle() ->
    Tv = calma_todas(t0(), 8),
    alimentar(tijuana, Tv + 600, 2.4, 9.0, 10.0, 0.0),
    BS0 = whereis(playa_banderas_sup), St0 = whereis(playa_store), R0 = pid(rosarito),
    [begin P = pid(tijuana), exit(P, kill), ?assert(nuevo_pid(tijuana, P)) end
     || _ <- lists:seq(1, 5)],
    ?assertEqual(BS0, whereis(playa_banderas_sup)),                    %% 5 caidas: aun dentro de la intensidad
    exit(pid(tijuana), kill),                                          %% la 6a excede 5 reinicios/10 s
    ?assert(esperar(fun() -> B = whereis(playa_banderas_sup),
                             is_pid(B) andalso B =/= BS0 andalso is_pid(pid(tijuana))
                                 andalso is_pid(pid(rosarito)) end, 5000)),
    ?assertEqual(St0, whereis(playa_store)),                           %% el almacen NO se toco
    ?assertNotEqual(R0, pid(rosarito)),                                %% costo: reinicio colateral
    ?assertEqual(roja, bandera(tijuana)),                              %% pero el estado se conserva
    ?assertEqual(verde, bandera(rosarito)).

c3_almacen() ->
    Tv = calma_todas(t0(), 8),
    Rec = Tv + 600,
    ok = playa_api:laboratorio(tijuana, 480, Rec - 36 * 3600, Rec),
    ?assertEqual(doble_roja, bandera(tijuana)),
    N0 = length(playa_api:historial(tijuana)),
    %% (a) se muere el almacen, el disco intacto
    S0 = whereis(playa_store), PT0 = pid(tijuana),
    exit(S0, kill),
    ?assert(esperar(fun() -> S = whereis(playa_store),
                             is_pid(S) andalso S =/= S0 andalso is_pid(pid(tijuana))
                                 andalso pid(tijuana) =/= PT0 andalso is_pid(pid(rosarito)) end, 5000)),
    ?assertEqual(doble_roja, bandera(tijuana)),
    ?assertEqual(verde, bandera(rosarito)),
    ?assert(length(playa_api:historial(tijuana)) >= N0),
    %% (b) ademas se pierden las instantaneas: sin estado previo
    os:cmd("rm -rf " ++ application:get_env(playa, estado_dir, undefined)),
    S1 = whereis(playa_store), PT1 = pid(tijuana),
    exit(S1, kill),
    ?assert(esperar(fun() -> S = whereis(playa_store),
                             is_pid(S) andalso S =/= S1 andalso is_pid(pid(tijuana))
                                 andalso pid(tijuana) =/= PT1 andalso is_pid(pid(rosarito)) end, 5000)),
    ?assertEqual(doble_roja, bandera(tijuana)),    %% el cierre se reconstruye desde la bitacora
    ?assertEqual(amarilla, bandera(rosarito)),     %% sin estado ni datos: PRECAUCION, no verde
    ?assertMatch(#{laboratorio_reconstruido := 1},
                 lists:last(tipos(tijuana, arranque))).

c4_venenoso() ->
    Tv = calma_todas(t0(), 8),
    P0 = pid(tijuana), R0 = pid(rosarito),
    ?assertEqual({error, {invalido, hs}}, playa_api:oleaje(tijuana, <<"abc">>, 9, Tv + 600)),
    %% se salta la validacion a proposito (simula un bug aguas arriba)
    gen_statem:cast(P0, {obs, oleaje, #{hs => <<"abc">>, tp => 9.0}, Tv + 600}),
    ?assert(nuevo_pid(tijuana, P0)),
    P1 = pid(tijuana),
    timer:sleep(300),
    ?assertEqual(P1, pid(tijuana)),                                    %% sin bucle de reinicios
    ?assertEqual(R0, pid(rosarito)),
    ?assertEqual(verde, bandera(tijuana)),                             %% el mensaje no dejo huella
    ?assertMatch([#{tipo := reinicio}], tipos(tijuana, reinicio)).
