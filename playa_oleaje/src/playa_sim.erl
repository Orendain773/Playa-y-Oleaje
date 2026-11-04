%% Simulacion del escenario (DATOS SINTETICOS; los nombres de playa son solo etiquetas).
%% 72 h de tiempo virtual, 6 playas, boya c/30 min, viento c/10 min, marea por tabla,
%% marejada de 1 m a 3 m en 4 h, resultado de laboratorio atrasado y fallas inyectadas.
%% Uso:  erl -noshell +pc unicode -pa _build/default/lib/playa/ebin -eval 'playa_sim:run(), halt().'
-module(playa_sim).
-export([run/0]).

-define(PASO, 600).
-define(DURACION, 72 * 3600).

t0() ->
    calendar:datetime_to_gregorian_seconds({{2026, 11, 7}, {6, 0, 0}})
        - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).

%% {Id, exposicion, retraso_min}
playas() -> [{tijuana, 1.00, 0}, {baja_malibu, 0.95, 15}, {rosarito, 1.05, 30},
             {puerto_nuevo, 1.00, 45}, {ensenada_hermosa, 0.85, 60}, {ensenada_estero, 0.80, 90}].

%% Marejada (horas desde T0): 0.6 m calma; 7-8 h preoleaje; 8-12 h sube 1->3 m (4 h);
%% 12-16 h meseta; 16-28 h decae; despues calma.
swell(H) when H < 7 -> 0.6;
swell(H) when H < 8 -> 0.6 + 0.4 * (H - 7);
swell(H) when H < 12 -> 1.0 + 2.0 * (H - 8) / 4;
swell(H) when H < 16 -> 3.0;
swell(H) when H < 28 -> 3.0 - 2.4 * (H - 16) / 12;
swell(_) -> 0.6.

frac(S) -> max(0.0, min(1.0, (S - 0.6) / 2.4)).
ruido(Id, T, Esc) -> (erlang:phash2({Id, T}, 2001) - 1000) / 1000 * Esc.

hs(Id, K, Ret, T) ->
    H = (T - t0()) / 3600,
    case Id =:= puerto_nuevo andalso H >= 30 andalso H < 33 of
        true -> case (T div 1800) rem 2 of 0 -> 1.25; 1 -> 1.15 end;   %% FALLA: rebote sobre 1.2 m
        false ->
            S = swell(H - Ret / 60),
            max(0.1, 0.6 + (S - 0.6) * K + ruido({hs, Id}, T, 0.10))
    end.
tp(Id, Ret, T) ->
    S = swell((T - t0()) / 3600 - Ret / 60),
    8.0 + 7.0 * frac(S) + ruido({tp, Id}, T, 0.4).
viento(Id, Ret, T) ->
    S = swell((T - t0()) / 3600 - Ret / 60),
    max(0.0, 12.0 + 30.0 * frac(S) + ruido({v, Id}, T, 6.0)).
lluvia(tijuana, T) ->
    H = (T - t0()) / 3600,
    case H >= 9 andalso H < 33 of true -> 14.0; false -> 1.0 end;
lluvia(_, _) -> 1.0.

%% ---- bitacora de la propia simulacion -------------------------------------------
nota(T, Fmt, Args) -> put(notas, [{T, playa_reglas:fmt(Fmt, Args)} | get(notas)]).
rel(Ts) -> S = Ts - t0(), playa_reglas:fmt("+~2..0b:~2..0b", [S div 3600, (S rem 3600) div 60]).
suma(Clave, N) -> put(Clave, get(Clave) + N).

%% ---- envio + seguimiento "ingenuo" (sin histeresis) para comparar -------------
enviar(Id, Factor, Args, T) ->
    R = case Factor of
            oleaje -> [Hs, Tp] = Args, playa_api:oleaje(Id, Hs, Tp, T);
            viento -> [V] = Args, playa_api:viento(Id, V, T);
            lluvia -> [M] = Args, playa_api:lluvia(Id, M, T)
        end,
    case R of
        ok -> ingenuo_obs(Id, Factor, Args, T);
        {error, _} -> suma(rechazos, 1)
    end,
    R.

ingenuo_obs(Id, Factor, Args, T) ->
    {Obs, Niv, C} = get({naive, Id}),
    V = case {Factor, Args} of
            {oleaje, [Hs, Tp]} -> #{hs => Hs, tp => Tp, ts => T};
            {viento, [Kmh]} -> #{kmh => Kmh, ts => T};
            {lluvia, [Mm]} -> #{mm24 => Mm, ts => T}
        end,
    Obs1 = Obs#{Factor => V},
    Obs2 = case Factor =:= lluvia andalso hd(Args) >= 10.0 of
               true -> Obs1#{lluvia_fuerte_ts => T};
               false -> Obs1
           end,
    put({naive, Id}, {Obs2, Niv, C}).

ingenuo_eval(Id, T) ->
    {Obs, Niv, C} = get({naive, Id}),
    Cfg = (playa_config:cfg()),
    Marea = playa_marea:altura(T, maps:get(mareas, Cfg)),
    {N, _} = playa_reglas:evaluar(estricto, Obs, Marea, [], T, Cfg),
    put({naive, Id}, {Obs, N, case Niv =/= undefined andalso Niv =/= N of true -> C + 1; false -> C end}).

esperar(F, Ms) when Ms =< 0 -> F();
esperar(F, Ms) -> case catch F() of true -> true; _ -> timer:sleep(10), esperar(F, Ms - 10) end.

todas_vivas() ->
    is_pid(whereis(playa_banderas_sup)) andalso
        lists:all(fun({Id, _, _}) -> is_pid(whereis(playa_bandera:via(Id))) end, playas()).

%% ---- fallas y ordenes humanas (hora desde T0 en segundos) ----------------------
eventos() ->
    H = 3600,
    T0 = t0(),
    [{12 * H + 1800, fun(T) ->
         R = playa_api:override(rosarito, doble_roja, <<"rescates multiples por resaca">>,
                                <<"salvavidas Rosarito">>, T, 3 * H),
         nota(T, "salvavidas de rosarito SUBE a doble roja (3 h): ~0p", [R]) end},
     {13 * H, fun(T) ->
         A = playa_api:bandera(rosarito),
         P0 = whereis(playa_bandera:via(rosarito)),
         exit(P0, kill),
         esperar(fun() -> P = whereis(playa_bandera:via(rosarito)), is_pid(P) andalso P =/= P0 end, 3000),
         D = playa_api:bandera(rosarito),
         nota(T, "CAOS: se mata el proceso de rosarito con override activo. Antes: ~s/~s; "
                 "despues: ~s/~s; override conservado: ~0p",
              [maps:get(bandera, A), maps:get(fuente, A), maps:get(bandera, D), maps:get(fuente, D),
               maps:get(override, D) =/= undefined]) end},
     {14 * H, fun(T) ->
         R = playa_api:override(baja_malibu, amarilla, <<"resaca controlada con banderas de zona">>,
                                <<"salvavidas Baja Malibu">>, T, 2 * H),
         nota(T, "salvavidas de baja_malibu BAJA roja->amarilla (2 h): ~0p", [R]),
         R2 = playa_api:override(baja_malibu, verde, <<"intento de bajar 2 niveles">>,
                                 <<"salvavidas Baja Malibu">>, T, 2 * H),
         nota(T, "...e intenta bajar a verde (2 escalones): ~0p", [R2]) end},
     {20 * H, fun(T) ->
         R1 = playa_api:oleaje(ensenada_hermosa, -5.0, 10.0, T),
         R2 = playa_api:oleaje(ensenada_hermosa, <<"abc">>, 10.0, T),
         R3 = playa_api:viento(ensenada_hermosa, 9999.0, T),
         suma(rechazos, 3),
         nota(T, "CAOS: lecturas corruptas en ensenada_hermosa -> ~0p ~0p ~0p", [R1, R2, R3]),
         playa_api:fauna(ensenada_estero, true, T),
         nota(T, "bandera morada en ensenada_estero (medusas)", []) end},
     {24 * H, fun(T) -> playa_api:fauna(ensenada_estero, false, T) end},
     {46 * H, fun(T) ->
         V = playa_api:bandera(tijuana),
         R = playa_api:laboratorio(tijuana, 480, T0 + 10 * H, T),
         D = playa_api:bandera(tijuana),
         nota(T, "LABORATORIO ATRASADO: llega muestra tomada +10:00 (480 NMP/100 ml, limite 200), "
                 "36 h tarde. Bandera vigente: ~s -> ahora: ~s (~0p)",
              [maps:get(bandera, V), maps:get(bandera, D), R]) end},
     {47 * H, fun(T) ->
         R = playa_api:override(tijuana, roja, <<"el agua se ve limpia">>, <<"salvavidas Tijuana">>, T, H),
         nota(T, "salvavidas de tijuana intenta bajar el cierre sanitario: ~0p", [R]) end},
     {50 * H, fun(T) ->
         A = playa_api:bandera(tijuana),
         S0 = whereis(playa_store),
         exit(S0, kill),
         esperar(fun() -> S = whereis(playa_store), is_pid(S) andalso S =/= S0 andalso todas_vivas() end, 5000),
         D = playa_api:bandera(tijuana),
         nota(T, "CAOS: se mata playa_store (dueno de ETS) con cierre sanitario vigente. "
                 "Antes: ~s; despues: ~s; cierre conservado: ~0p; reinicio de las 6 playas por rest_for_one",
              [maps:get(bandera, A), maps:get(bandera, D), maps:get(cierre_sanitario, D) =/= undefined]) end},
     {58 * H, fun(T) -> playa_api:laboratorio(tijuana, 90, T0 + 36 * H, T),
                        nota(T, "llega muestra limpia #1 (tomada +36:00, 90 NMP)", []) end},
     {62 * H, fun(T) -> playa_api:laboratorio(tijuana, 60, T0 + 40 * H, T),
                        nota(T, "llega muestra limpia #2 (tomada +40:00, 60 NMP): reapertura", []) end}].

%% Fallas por ausencia de datos
sin_viento(baja_malibu, H) -> H >= 10 andalso H < 13;
sin_viento(_, _) -> false.
sin_boya(rosarito, H) -> H >= 36 andalso H < 42;
sin_boya(_, _) -> false.

%% ---------------------------------------------------------------------------------
run() ->
    io:setopts(standard_io, [{encoding, unicode}]),
    logger:set_primary_config(level, none),   %% los reportes de supervisor ensucian el informe
    T0 = t0(),
    Arch = "/tmp/playa_sim_historial.terms", Dir = "/tmp/playa_sim_estado",
    file:delete(Arch), os:cmd("rm -rf " ++ Dir),
    application:load(playa),
    [application:set_env(playa, K, V) ||
        {K, V} <- [{reloj, manual}, {reloj_inicio, T0}, {historial_archivo, Arch}, {estado_dir, Dir},
                   {mareas, playa_marea:extremos_sinteticos(T0 - 12 * 3600, T0 + 80 * 3600)}]],
    {ok, _} = application:ensure_all_started(playa),
    put(notas, []), put(rechazos, 0),
    [put({naive, Id}, {#{}, undefined, 0}) || {Id, _, _} <- playas()],
    Ev0 = lists:keysort(1, eventos()),
    {Linea, _} = lists:foldl(
        fun(K, {Lin, Ev}) ->
            T = T0 + K * ?PASO,
            Off = K * ?PASO,
            H = Off / 3600,
            {Hoy, Resto} = lists:partition(fun({O, _}) -> O =< Off end,
                                           [{O, F} || {O, F} <- Ev]),
            [F(T) || {_, F} <- Hoy],
            [begin
                 case sin_viento(Id, H) of
                     false -> enviar(Id, viento, [viento(Id, Ret, T)], T);
                     true -> ok
                 end,
                 case K rem 3 =:= 0 of
                     true ->
                         case sin_boya(Id, H) of
                             false -> enviar(Id, oleaje, [hs(Id, Kx, Ret, T), tp(Id, Ret, T)], T);
                             true -> ok
                         end,
                         enviar(Id, lluvia, [lluvia(Id, T)], T);
                     false -> ok
                 end
             end || {Id, Kx, Ret} <- playas()],
            playa_api:tick(T),
            [ingenuo_eval(Id, T) || {Id, _, _} <- playas()],
            Lin1 = case K rem 12 =:= 0 of
                       true -> [{Off, [playa_api:bandera(Id) || {Id, _, _} <- playas()]} | Lin];
                       false -> Lin
                   end,
            {Lin1, Resto}
        end, {[], [{O, F} || {O, F} <- Ev0]}, lists:seq(0, ?DURACION div ?PASO)),
    informe(T0, lists:reverse(Linea)),
    application:stop(playa),
    ok.

%% ---------------------------------------------------------------------------------
simbolo(#{bandera := B, fuente := F}) ->
    S = case B of verde -> "V"; amarilla -> "A"; roja -> "R"; doble_roja -> "X" end,
    case F of salvavidas -> S ++ "*"; sistema -> S ++ " " end.

linea(E) ->
    #{ts := Ts, tipo := Tipo} = E,
    Det = case Tipo of
              cambio -> playa_reglas:fmt("~s -> ~s [~s/~s] ~ts",
                                         [maps:get(de, E), maps:get(a, E), maps:get(fuente, E),
                                          maps:get(causa, E), hd(maps:get(razones, E))]);
              nivel_sistema -> playa_reglas:fmt("sistema ~s -> ~s (bandera efectiva sigue ~s)",
                                                [maps:get(de, E), maps:get(a, E), maps:get(bandera_efectiva, E)]);
              laboratorio -> playa_reglas:fmt("muestra ~.1f NMP, edad ~b h, ~s, contradice vigente: ~0p",
                                              [float(maps:get(nmp, E)), maps:get(edad_s, E) div 3600,
                                               maps:get(veredicto, E), maps:get(contradice_vigente, E)]);
              override -> playa_reglas:fmt("override ~s ~s por ~ts",
                                           [maps:get(accion, E), maps:get(nivel, E), maps:get(autor, E)]);
              reinicio -> <<"proceso reiniciado; estado restaurado">>;
              arranque -> <<"arranque prudente">>;
              fauna -> playa_reglas:fmt("fauna activa: ~0p", [maps:get(activa, E)])
          end,
    io:format("  ~ts  ~-13s ~ts~n", [rel(Ts), Tipo, Det]).

entre(Id, DeH, AH, Tipos) ->
    T0 = t0(),
    [E || E = #{ts := Ts, tipo := Tp} <- playa_api:historial(Id),
          Ts >= T0 + DeH * 3600, Ts =< T0 + AH * 3600, lists:member(Tp, Tipos)].

informe(T0, Lineas) ->
    io:format("~n=== SIMULACION (datos sinteticos, hora UTC, T0 = ~ts) ===~n", [playa_reglas:fecha(T0)]),
    io:format("~n--- Linea de tiempo cada 2 h: V verde, A amarilla, R roja, X doble roja, * = decide el salvavidas ---~n"),
    io:format("  hora  ~ts~n", [string:join([string:pad(atom_to_list(Id), 6) || {Id, _, _} <- playas()], " ")]),
    [io:format("  ~ts ~ts~n", [rel(T0 + Off), string:join([simbolo(V) ++ "    " || V <- Vs], " ")])
     || {Off, Vs} <- Lineas],
    io:format("~n--- Acciones, ordenes humanas y fallas inyectadas ---~n"),
    [io:format("  ~ts  ~ts~n", [rel(T), N]) || {T, N} <- lists:reverse(get(notas))],

    io:format("~n--- Marejada en tijuana (+06:00..+30:00): cada cambio con su justificacion ---~n"),
    [linea(E) || E <- entre(tijuana, 6, 30, [cambio, nivel_sistema])],

    io:format("~n--- Boya de rosarito perdida (+36:00..+44:00) ---~n"),
    [linea(E) || E <- entre(rosarito, 35, 44, [cambio, nivel_sistema])],

    io:format("~n--- Anemometro de baja_malibu perdido en plena marejada (+10:00..+13:00 y override) ---~n"),
    [linea(E) || E <- entre(baja_malibu, 9, 18, [cambio, nivel_sistema, override])],

    io:format("~n--- Rebote inyectado en puerto_nuevo: Hs alterna 1.15/1.25 m sobre el umbral de 1.2 m (+30:00..+33:00) ---~n"),
    [linea(E) || E <- entre(puerto_nuevo, 29, 38, [cambio, nivel_sistema])],

    io:format("~n--- Laboratorio atrasado en tijuana (+44:00..+66:00) ---~n"),
    [linea(E) || E <- entre(tijuana, 44, 66, [cambio, laboratorio, override, reinicio, nivel_sistema])],

    io:format("~n--- Anti-rebote: cambios de bandera por causa 'condiciones' (3 dias) ---~n"),
    io:format("  ~-18s ~12s ~12s~n", ["playa", "sin histeresis", "con histeresis"]),
    [begin
         {_, _, Naive} = get({naive, Id}),
         Sist = length([x || #{tipo := cambio, causa := condiciones} <- playa_api:historial(Id)]),
         io:format("  ~-18s ~12b ~12b~n", [Id, Naive, Sist])
     end || {Id, _, _} <- playas()],
    io:format("  (sin histeresis = bandera = peor factor en cada lectura; incluye el efecto del ruido en viento y oleaje)~n"),
    io:format("~n--- Lecturas rechazadas en la frontera: ~b ---~n", [get(rechazos)]),
    io:format("~n--- Historial total por playa (todas las decisiones, auditables) ---~n"),
    [io:format("  ~-18s ~b entradas~n", [Id, length(playa_api:historial(Id))]) || {Id, _, _} <- playas()].
