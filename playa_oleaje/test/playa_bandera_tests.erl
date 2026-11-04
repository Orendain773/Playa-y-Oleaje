%% Pruebas con la aplicacion levantada y reloj MANUAL (tiempo virtual: rapido y determinista).
-module(playa_bandera_tests).
-include_lib("eunit/include/eunit.hrl").
-import(playa_test_util, [t0/0, alimentar/6, calma/3, bandera/1, vista/1, cambios/1, tipos/2]).

bandera_test_() ->
    {foreach, fun playa_test_util:iniciar/0, fun playa_test_util:detener/1,
     [fun(_) -> {"arranque prudente: amarilla sin datos, verde tras 1 h de calma",
                 fun t_arranque/0} end,
      fun(_) -> {"marejada: sube de inmediato, baja de a un escalon tras 1 h cada vez",
                 fun t_marejada/0} end,
      fun(_) -> {"rebote en el umbral: UN solo cambio, no uno por lectura",
                 fun t_rebote/0} end,
      fun(_) -> {"boya perdida: verde sube a amarilla a los 90 min sin dato",
                 fun t_datos_faltantes/0} end,
      fun(_) -> {"dato perdido nunca baja una bandera roja",
                 fun t_perdida_no_baja/0} end,
      fun(_) -> {"laboratorio atrasado contradice la bandera vigente y cierra",
                 fun t_laboratorio/0} end,
      fun(_) -> {"salvavidas: bajar exige motivo, 1 escalon, y no bajo un cierre",
                 fun t_override_reglas/0} end,
      fun(_) -> {"salvavidas: override para bajar caduca y vuelve el sistema",
                 fun t_override_caduca/0} end,
      fun(_) -> {"salvavidas: subir es inmediato y se libera",
                 fun t_override_sube/0} end,
      fun(_) -> {"override para bajar se revoca si el sistema empeora",
                 fun t_override_revocado/0} end,
      fun(_) -> {"entrada corrupta rechazada en la frontera; bandera intacta",
                 fun t_validacion/0} end,
      fun(_) -> {"suscriptores reciben el aviso del cambio de bandera",
                 fun t_notificacion/0} end,
      fun(_) -> {"bandera morada (fauna) es una capa, no un nivel",
                 fun t_fauna/0} end]}.

%% Deja la playa en verde y devuelve el ultimo instante usado.
verde(Id) ->
    Tv = calma(Id, t0(), 8),
    ?assertEqual(verde, bandera(Id)),
    Tv.

t_arranque() ->
    ?assertEqual(amarilla, bandera(tijuana)),
    ?assertMatch([#{tipo := arranque}], tipos(tijuana, arranque)),
    Tv = calma(tijuana, t0(), 6),                 %% 50 min de calma
    ?assertEqual(amarilla, bandera(tijuana)),
    _ = calma(tijuana, Tv + 600, 2),              %% >= 60 min sostenidos
    ?assertEqual(verde, bandera(tijuana)).

t_marejada() ->
    T = verde(tijuana) + 600,
    alimentar(tijuana, T, 2.4, 15.0, 10.0, 0.0),
    ?assertEqual(roja, bandera(tijuana)),                       %% sube YA
    Pasos = [begin
                 alimentar(tijuana, T + K * 600, 0.5, 8.0, 10.0, 0.0),
                 {K, bandera(tijuana)}
             end || K <- lists:seq(1, 14)],
    ?assertEqual(roja, proplists:get_value(6, Pasos)),          %% 50 min de calma: aun roja
    ?assertEqual(amarilla, proplists:get_value(7, Pasos)),      %% 1 h sostenida: un escalon
    ?assertEqual(amarilla, proplists:get_value(12, Pasos)),     %% no baja dos de golpe
    ?assertEqual(verde, proplists:get_value(13, Pasos)),        %% otra hora: el siguiente escalon
    ?assertMatch(#{causa := condiciones}, lists:last(cambios(tijuana))).

t_rebote() ->
    T = verde(tijuana) + 600,
    Hs = fun(K) -> case K rem 2 of 0 -> 1.25; 1 -> 1.15 end end,   %% cruza 1.2 m cada lectura
    [alimentar(tijuana, T + K * 600, Hs(K), 8.0, 10.0, 0.0) || K <- lists:seq(0, 17)],
    ?assertEqual(amarilla, bandera(tijuana)),
    %% historial: amarilla->verde (arranque) y verde->amarilla. NADA mas en 3 h de rebote.
    ?assertEqual(2, length(cambios(tijuana))),
    Naive = length([x || K <- lists:seq(0, 17),
                         (case K rem 2 of 0 -> amarilla; 1 -> verde end) =/=
                             (case (K + 1) rem 2 of 0 -> amarilla; 1 -> verde end)]),
    ?assert(Naive >= 17).                                       %% sin histeresis: 1 cambio/lectura

t_datos_faltantes() ->
    Tb = verde(tijuana),
    Solo = fun(J) ->                                            %% viento+lluvia siguen; boya no
               T = Tb + J * 600,
               ok = playa_api:viento(tijuana, 10.0, T),
               ok = playa_api:lluvia(tijuana, 0.0, T),
               playa_api:tick(T), vista(tijuana)
           end,
    [Solo(J) || J <- lists:seq(1, 9)],
    ?assertEqual(verde, bandera(tijuana)),                      %% 90 min exactos: aun vigente
    Solo(10),
    ?assertEqual(amarilla, bandera(tijuana)),                   %% 100 min: precaucion
    #{razones := R} = lists:last(cambios(tijuana)),
    ?assert(lists:any(fun(B) -> binary:match(B, <<"obsoleto">>) =/= nomatch end, R)).

t_perdida_no_baja() ->
    T = verde(tijuana) + 600,
    alimentar(tijuana, T, 2.4, 9.0, 10.0, 0.0),
    ?assertEqual(roja, bandera(tijuana)),
    [begin                                                      %% 3 h sin boya
         ok = playa_api:viento(tijuana, 10.0, T + J * 600),
         ok = playa_api:lluvia(tijuana, 0.0, T + J * 600),
         playa_api:tick(T + J * 600)
     end || J <- lists:seq(1, 18)],
    ?assertEqual(roja, bandera(tijuana)).

t_laboratorio() ->
    Tv = verde(tijuana),
    Rec = Tv + 600,
    ok = playa_api:laboratorio(tijuana, 480, Rec - 36 * 3600, Rec),   %% resultado de hace 36 h
    ?assertEqual(doble_roja, bandera(tijuana)),
    ?assertMatch(#{cierre_sanitario := #{limpias := 0}}, vista(tijuana)),
    ?assertMatch(#{tipo := cambio, de := verde, a := doble_roja, causa := cierre_sanitario,
                   contradice_vigente := true}, lists:last(cambios(tijuana))),
    [#{edad_s := Edad, contradice_vigente := true}] = tipos(tijuana, laboratorio),
    ?assertEqual(36 * 3600, Edad),
    ?assertEqual({error, cierre_sanitario_vigente},
                 playa_api:override(tijuana, roja, <<"x">>, <<"salvavidas">>, Rec, 3600)),
    ok = playa_api:laboratorio(tijuana, 60, Rec - 40 * 3600, Rec + 60),   %% limpia ANTERIOR
    ?assertEqual(doble_roja, bandera(tijuana)),
    ok = playa_api:laboratorio(tijuana, 60, Rec - 3600, Rec + 120),       %% 1 limpia: no basta
    ?assertEqual(doble_roja, bandera(tijuana)),
    ok = playa_api:laboratorio(tijuana, 70, Rec - 1800, Rec + 180),       %% 2a limpia: reabre
    ?assertEqual(verde, bandera(tijuana)),
    ?assertMatch(#{causa := reapertura_sanitaria}, lists:last(cambios(tijuana))).

roja_por_marejada(Id) ->
    T = verde(Id) + 600,
    alimentar(Id, T, 2.4, 9.0, 10.0, 0.0),
    ?assertEqual(roja, bandera(Id)),
    T.

t_override_reglas() ->
    T = roja_por_marejada(tijuana),
    S = <<"salvavidas A">>,
    ?assertEqual({error, bajada_excesiva}, playa_api:override(tijuana, verde, <<"m">>, S, T, 3600)),
    ?assertEqual({error, motivo_requerido}, playa_api:override(tijuana, amarilla, <<>>, S, T, 3600)),
    ?assertEqual({error, nivel_invalido}, playa_api:override(tijuana, morada, <<"m">>, S, T, 3600)),
    ?assertEqual({error, spec_invalida}, playa_bandera:override(tijuana, #{nivel => roja})),
    ?assertEqual(roja, bandera(tijuana)).

t_override_caduca() ->
    T = roja_por_marejada(tijuana),
    ok = playa_api:override(tijuana, amarilla, <<"resaca controlada">>, <<"salvavidas A">>, T, 3600),
    ?assertMatch(#{bandera := amarilla, fuente := salvavidas, nivel_sistema := roja}, vista(tijuana)),
    ?assertMatch(#{causa := override_salvavidas}, lists:last(cambios(tijuana))),
    [alimentar(tijuana, T + K * 600, 2.4, 9.0, 10.0, 0.0) || K <- lists:seq(1, 5)],
    ?assertEqual(amarilla, bandera(tijuana)),                    %% aun vigente
    alimentar(tijuana, T + 6 * 600, 2.4, 9.0, 10.0, 0.0),        %% se cumple la hora
    ?assertMatch(#{bandera := roja, fuente := sistema}, vista(tijuana)),
    ?assertMatch(#{causa := fin_override}, lists:last(cambios(tijuana))),
    ?assertMatch([#{accion := vencido}], [E || E = #{accion := vencido} <- tipos(tijuana, override)]).

t_override_sube() ->
    T = roja_por_marejada(tijuana),
    ok = playa_api:override(tijuana, doble_roja, <<"rescates multiples">>, <<"salvavidas B">>, T, 7200),
    ?assertMatch(#{bandera := doble_roja, fuente := salvavidas, nivel_sistema := roja}, vista(tijuana)),
    ok = playa_api:liberar(tijuana, <<"salvavidas B">>, T + 60),
    ?assertMatch(#{bandera := roja, fuente := sistema}, vista(tijuana)),
    ?assertEqual({error, sin_override}, playa_api:liberar(tijuana, <<"salvavidas B">>, T + 120)).

t_override_revocado() ->
    T = verde(tijuana) + 600,
    alimentar(tijuana, T, 1.5, 8.0, 10.0, 0.0),
    ?assertEqual(amarilla, bandera(tijuana)),
    ok = playa_api:override(tijuana, verde, <<"oleaje en descenso">>, <<"salvavidas A">>, T, 36000),
    ?assertEqual(verde, bandera(tijuana)),
    alimentar(tijuana, T + 600, 2.4, 9.0, 10.0, 0.0),            %% el sistema empeora
    ?assertMatch(#{bandera := roja, fuente := sistema, override := undefined}, vista(tijuana)),
    ?assertMatch([_], [E || E = #{accion := revocado_por_empeoramiento} <- tipos(tijuana, override)]).

t_validacion() ->
    Tv = verde(tijuana),
    Antes = bandera(tijuana),
    ?assertEqual({error, {invalido, hs}}, playa_api:oleaje(tijuana, -5, 8, Tv + 1)),
    ?assertEqual({error, {invalido, hs}}, playa_api:oleaje(tijuana, <<"abc">>, 8, Tv + 1)),
    ?assertEqual({error, {invalido, tp}}, playa_api:oleaje(tijuana, 1.0, 400, Tv + 1)),
    ?assertEqual({error, {invalido, kmh}}, playa_api:viento(tijuana, 9999, Tv + 1)),
    ?assertEqual({error, {invalido, ts}}, playa_api:oleaje(tijuana, 1.0, 8, -1)),
    ?assertEqual({error, playa_desconocida}, playa_api:oleaje(narnia, 1.0, 8, Tv)),
    ?assertEqual({error, playa_desconocida}, playa_api:oleaje(<<"narnia">>, 1.0, 8, Tv)),
    ?assertEqual(Antes, bandera(tijuana)).

t_notificacion() ->
    T = verde(tijuana) + 600,
    ok = playa_api:suscribir(tijuana),
    alimentar(tijuana, T, 2.4, 9.0, 10.0, 0.0),
    receive {playa_evento, tijuana, #{tipo := cambio, de := verde, a := roja}} -> ok
    after 1000 -> ?assert(false)
    end.

t_fauna() ->
    T = verde(tijuana) + 600,
    ok = playa_api:fauna(tijuana, true, T),
    ?assertMatch(#{bandera := verde, bandera_morada := true}, vista(tijuana)),
    ?assertMatch([#{activa := true}], tipos(tijuana, fauna)).
