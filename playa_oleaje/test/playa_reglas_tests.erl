-module(playa_reglas_tests).
-include_lib("eunit/include/eunit.hrl").

cfg() -> (playa_config:defaults())#{mareas => []}.

obs(Hs, Tp, Kmh, Mm, Ts) ->
    #{oleaje => #{hs => Hs, tp => Tp, ts => Ts},
      viento => #{kmh => Kmh, ts => Ts},
      lluvia => #{mm24 => Mm, ts => Ts}}.

nivel(Modo, Obs, Marea, Lab, Now) ->
    element(1, playa_reglas:evaluar(Modo, Obs, Marea, Lab, Now, cfg())).

factor(F, Modo, Obs, Marea, Lab, Now) ->
    {_, Fs} = playa_reglas:evaluar(Modo, Obs, Marea, Lab, Now, cfg()),
    hd([X || X = #{factor := N} <- Fs, N =:= F]).

umbrales_oleaje_test_() ->
    [?_assertEqual(N, nivel(estricto, obs(Hs, 8.0, 10.0, 0.0, 0), 1.5, [], 0))
     || {Hs, N} <- [{0.5, verde}, {1.19, verde}, {1.2, amarilla}, {1.99, amarilla},
                    {2.0, roja}, {3.49, roja}, {3.5, doble_roja}]].

periodo_largo_agrava_test_() ->
    [?_assertEqual(N, nivel(estricto, obs(Hs, Tp, 10.0, 0.0, 0), 1.5, [], 0))
     || {Hs, Tp, N} <- [{2.0, 15.0, roja},      %% 2 m con periodo largo: peligroso
                        {1.1, 15.0, amarilla},  %% Hs bajo pero periodo largo
                        {1.1, 9.0, verde},      %% mismo Hs, periodo corto
                        {0.9, 15.0, verde}]].

peor_de_varios_test_() ->
    [?_assertEqual(verde,   nivel(estricto, obs(0.5, 8.0, 10.0, 0.0, 0), 1.5, [], 0)),
     ?_assertEqual(roja,    nivel(estricto, obs(0.5, 8.0, 45.0, 0.0, 0), 1.5, [], 0)),
     ?_assertEqual(roja,    nivel(estricto, obs(1.5, 8.0, 45.0, 0.0, 0), 1.5, [], 0)),
     ?_assertEqual(doble_roja, nivel(estricto, obs(0.5, 8.0, 75.0, 0.0, 0), 1.5, [], 0))].

marea_baja_resaca_test_() ->
    [?_assertEqual(amarilla, nivel(estricto, obs(1.0, 8.0, 10.0, 0.0, 0), 0.3, [], 0)),
     ?_assertEqual(verde,    nivel(estricto, obs(1.0, 8.0, 10.0, 0.0, 0), 1.5, [], 0)),
     ?_assertEqual(roja,     nivel(estricto, obs(1.7, 8.0, 10.0, 0.0, 0), 0.3, [], 0)),
     %% sin tabla de marea: caso prudente (se supone marea baja)
     ?_assertEqual(amarilla, nivel(estricto, obs(1.0, 8.0, 10.0, 0.0, 0), undefined, [], 0))].

dato_obsoleto_test_() ->
    Now = 6000,
    Fresco = fun(Hs, TsOleaje) ->
                 (obs(Hs, 8.0, 10.0, 0.0, Now))#{oleaje => #{hs => Hs, tp => 8.0, ts => TsOleaje}}
             end,
    [%% 90 min exactos: aun vigente; 1 s mas: obsoleto
     ?_assertEqual(verde,    nivel(estricto, Fresco(0.5, 600), 1.5, [], 6000)),
     ?_assertEqual(amarilla, nivel(estricto, Fresco(0.5, 599), 1.5, [], 6000)),
     %% dato perdido NUNCA baja: ultimo valor rojo sigue rojo
     ?_assertEqual(roja,     nivel(estricto, Fresco(2.5, 0), 1.5, [], 6000)),
     %% sin ningun dato: prudente
     ?_assertEqual(amarilla, nivel(estricto, #{}, 1.5, [], 0)),
     ?_assertEqual(obsoleto, maps:get(estado, factor(oleaje, estricto, Fresco(0.5, 0), 1.5, [], 6000)))].

lluvia_presuncion_test_() ->
    Rain = fun(Now) -> (obs(0.5, 8.0, 10.0, 14.0, Now))#{lluvia_fuerte_ts => 0} end,
    N5 = 5 * 3600,
    [?_assertEqual(amarilla, nivel(estricto, Rain(N5), 1.5, [], N5)),
     %% muestra limpia tomada DESPUES de la lluvia levanta la presuncion
     ?_assertEqual(verde, nivel(estricto, Rain(N5), 1.5,
                                [#{tomada => 3600, nmp => 50.0, recibida => N5}], N5)),
     %% muestra limpia ANTERIOR a la lluvia no sirve
     ?_assertEqual(amarilla, nivel(estricto, Rain(N5), 1.5,
                                   [#{tomada => -10, nmp => 50.0, recibida => N5}], N5)),
     %% fuera de la ventana de 72 h
     ?_assertEqual(verde, nivel(estricto, Rain(73 * 3600), 1.5, [], 73 * 3600))].

cierre_test_() ->
    Mala = #{tomada => 100, nmp => 480.0, recibida => 200},
    L = fun(T) -> #{tomada => T, nmp => 50.0, recibida => T + 10} end,
    C = fun(Lab) -> playa_reglas:cierre(Lab, cfg()) end,
    [?_assertEqual(undefined, C([])),
     ?_assertMatch(#{limpias := 0, requeridas := 2}, C([Mala])),
     ?_assertMatch(#{limpias := 1}, C([Mala, L(150)])),           %% una limpia no basta
     ?_assertEqual(undefined, C([Mala, L(150), L(160)])),         %% dos limpias reabren
     ?_assertMatch(#{limpias := 0}, C([Mala, L(50), L(60)])),     %% limpias anteriores no cuentan
     ?_assertMatch(#{tomada := 300}, C([Mala, L(150), L(160),
                                        #{tomada => 300, nmp => 900.0, recibida => 400}]))].

histeresis_test_() ->
    C = cfg(),
    H = fun(A, E, P, D, N) -> playa_reglas:histeresis(A, E, P, D, N, C) end,
    [?_assertEqual({roja, undefined}, H(verde, roja, roja, undefined, 0)),          %% sube YA
     ?_assertEqual({roja, 0},         H(roja, verde, verde, undefined, 0)),         %% empieza espera
     ?_assertEqual({roja, 0},         H(roja, verde, verde, 0, 1800)),              %% aun no
     ?_assertEqual({amarilla, undefined}, H(roja, verde, verde, 0, 3600)),          %% un escalon
     ?_assertEqual({amarilla, undefined}, H(roja, verde, verde, 0, 99999)),         %% nunca 2
     ?_assertEqual({roja, undefined}, H(roja, amarilla, roja, 0, 1800))].           %% rebote reinicia

margen_prudente_test_() ->
    %% Hs = 1.15 m: estrictamente verde (< 1.2) pero NO "claramente" verde (>= 1.02)
    O = obs(1.15, 8.0, 10.0, 0.0, 0),
    [?_assertEqual(verde,    nivel(estricto, O, 1.5, [], 0)),
     ?_assertEqual(amarilla, nivel(prudente, O, 1.5, [], 0))].

marea_interpolacion_test() ->
    T = [{0, 0.0}, {100, 1.0}, {200, 0.0}],
    Cerca = fun(A, B) -> ?assert(abs(A - B) < 1.0e-9) end,
    Cerca(0.0, playa_marea:altura(0, T)),
    Cerca(0.5, playa_marea:altura(50, T)),
    Cerca(1.0, playa_marea:altura(100, T)),
    Cerca(0.5, playa_marea:altura(150, T)),
    ?assertEqual(undefined, playa_marea:altura(300, T)),
    ?assertEqual(undefined, playa_marea:altura(-1, T)),
    ?assertEqual(undefined, playa_marea:altura(10, [])).
