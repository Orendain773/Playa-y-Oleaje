%% Reglas PURAS: sin procesos, sin reloj propio, sin efectos. Todo lo que decide la
%% bandera esta aqui y se prueba con eunit sin levantar la aplicacion.
%%
%% Niveles: verde < amarilla < roja < doble_roja (cerrado al agua).
%% Regla central: el nivel del sistema es el PEOR (maximo) de varios factores.
-module(playa_reglas).
-export([niveles/0, num/1, nivel/1, max_nivel/1,
         evaluar/6, cierre/2, histeresis/6,
         fecha/1, fmt/2, texto_cierre/1]).

niveles() -> [verde, amarilla, roja, doble_roja].

num(verde) -> 0;
num(amarilla) -> 1;
num(roja) -> 2;
num(doble_roja) -> 3.

nivel(0) -> verde;
nivel(1) -> amarilla;
nivel(2) -> roja;
nivel(3) -> doble_roja.

max_nivel(Ns) -> nivel(lists:max([0 | [num(N) || N <- Ns]])).

fmt(F, A) -> unicode:characters_to_binary(io_lib:format(F, A)).

fecha(Ts) ->
    {{Y, Mo, D}, {H, Mi, _}} = calendar:system_time_to_universal_time(Ts, second),
    fmt("~4..0b-~2..0b-~2..0bT~2..0b:~2..0bZ", [Y, Mo, D, H, Mi]).

%% ---------------------------------------------------------------------------
%% Evaluacion de factores.
%% Modo = estricto: para SUBIR (umbrales tal cual).
%% Modo = prudente: para BAJAR (umbrales * margen_prudente: el valor debe quedar
%%                  claramente por debajo del umbral, no rozandolo).
%% Devuelve {PeorNivel, [Factor]} con una razon legible por factor.
%% ---------------------------------------------------------------------------
evaluar(Modo, Obs, Marea, Lab, Now, Cfg) ->
    Fs = [f_oleaje(Modo, Obs, Now, Cfg),
          f_resaca(Modo, Obs, Marea, Now, Cfg),
          f_viento(Modo, Obs, Now, Cfg),
          f_lluvia(Obs, Lab, Now, Cfg)],
    {max_nivel([N || #{nivel := N} <- Fs]), Fs}.

umbral(estricto, U, _) -> U;
umbral(prudente, U, #{margen_prudente := M}) -> U * M.

por_umbrales(V, Tabla, Modo, Cfg) ->
    lists:foldl(fun({U, N}, Acc) ->
                        case V >= umbral(Modo, U, Cfg) of true -> N; false -> Acc end
                end, verde, Tabla).

%% Dato obsoleto: nunca baja el nivel; aporta como minimo `nivel_sin_dato` (amarilla).
frescura(Factor, Ts, Now, Cfg, Nivel, Texto) ->
    MaxEdad = maps:get(Factor, maps:get(max_edad_s, Cfg)),
    Edad = Now - Ts,
    case Edad > MaxEdad of
        false ->
            #{factor => Factor, nivel => Nivel, estado => vigente, razon => Texto};
        true ->
            Piso = maps:get(nivel_sin_dato, Cfg),
            #{factor => Factor, nivel => max_nivel([Nivel, Piso]), estado => obsoleto,
              razon => fmt("dato obsoleto (~b min; máximo ~b min); último valor: ~ts; "
                           "nivel mínimo por precaución: ~s",
                           [Edad div 60, MaxEdad div 60, Texto, Piso])}
    end.

sin_dato(Factor, Cfg) ->
    Piso = maps:get(nivel_sin_dato, Cfg),
    #{factor => Factor, nivel => Piso, estado => sin_dato,
      razon => fmt("sin datos de ~s; nivel mínimo por precaución: ~s", [Factor, Piso])}.

f_oleaje(Modo, #{oleaje := #{hs := Hs, tp := Tp, ts := Ts}}, Now, Cfg)
  when is_number(Hs), is_number(Tp) ->
    Base = por_umbrales(Hs, maps:get(oleaje_hs, Cfg), Modo, Cfg),
    Largo = case Tp >= umbral(Modo, maps:get(periodo_largo_s, Cfg), Cfg) of
                true -> por_umbrales(Hs, maps:get(periodo_hs, Cfg), Modo, Cfg);
                false -> verde
            end,
    Nivel = max_nivel([Base, Largo]),
    Texto = fmt("Hs=~.2f m, Tp=~.1f s", [float(Hs), float(Tp)]),
    Razon = case num(Largo) > num(Base) of
                true -> fmt("~ts; el periodo largo (>= ~.1f s) agrava el oleaje",
                            [Texto, maps:get(periodo_largo_s, Cfg)]);
                false -> Texto
            end,
    frescura(oleaje, Ts, Now, Cfg, Nivel, Razon);
f_oleaje(_, Obs, _, Cfg) when not is_map_key(oleaje, Obs) ->
    sin_dato(oleaje, Cfg).

%% Resaca: marea baja expone bancos de arena. Combina Hs (boya) con la marea (tabla).
f_resaca(Modo, #{oleaje := #{hs := Hs, ts := Ts}}, Marea, Now, Cfg) when is_number(Hs) ->
    Baja = maps:get(marea_baja_m, Cfg),
    {EsBaja, TxtMarea} =
        case Marea of
            undefined -> {true, <<"sin tabla de marea para esta hora: se supone marea baja">>};
            M when M =< Baja -> {true, fmt("marea baja (~.2f m <= ~.2f m)", [M, Baja])};
            M -> {false, fmt("marea ~.2f m (no baja)", [M])}
        end,
    Nivel = case EsBaja of
                true -> por_umbrales(Hs, maps:get(resaca_hs_marea_baja, Cfg), Modo, Cfg);
                false -> verde
            end,
    Razon = case Nivel of
                verde -> fmt("~ts; Hs=~.2f m", [TxtMarea, float(Hs)]);
                _ -> fmt("~ts con Hs=~.2f m: bancos de arena expuestos favorecen resacas",
                         [TxtMarea, float(Hs)])
            end,
    frescura(resaca, Ts, Now, Cfg, Nivel, Razon);
f_resaca(_, _, _, _, _) ->
    #{factor => resaca, nivel => verde, estado => dependiente,
      razon => <<"depende del oleaje (ver factor oleaje)">>}.

f_viento(Modo, #{viento := #{kmh := V, ts := Ts}}, Now, Cfg) when is_number(V) ->
    Nivel = por_umbrales(V, maps:get(viento_kmh, Cfg), Modo, Cfg),
    frescura(viento, Ts, Now, Cfg, Nivel, fmt("viento ~.1f km/h", [float(V)]));
f_viento(_, Obs, _, Cfg) when not is_map_key(viento, Obs) ->
    sin_dato(viento, Cfg).

%% Lluvia -> presuncion de contaminacion mientras no haya una muestra limpia
%% TOMADA DESPUES de la ultima lluvia fuerte (el laboratorio tarda 24-48 h).
f_lluvia(#{lluvia := #{mm24 := Mm, ts := Ts}} = Obs, Lab, Now, Cfg) when is_number(Mm) ->
    {Nivel, Texto} = presuncion(Obs, Lab, Now, Cfg, Mm),
    frescura(lluvia, Ts, Now, Cfg, Nivel, Texto);
f_lluvia(Obs, _, _, Cfg) when not is_map_key(lluvia, Obs) ->
    sin_dato(lluvia, Cfg).

presuncion(Obs, Lab, Now, Cfg, Mm) ->
    Limite = maps:get(limite_enterococos, Cfg),
    case maps:get(lluvia_fuerte_ts, Obs, undefined) of
        undefined ->
            {verde, fmt("lluvia 24 h: ~.1f mm; sin lluvia fuerte reciente", [float(Mm)])};
        TR ->
            Edad = Now - TR,
            Limpias = [T || #{tomada := T, nmp := N} <- Lab, N =< Limite, T > TR],
            Ventana = maps:get(ventana_lluvia_s, Cfg),
            if
                Edad > Ventana ->
                    {verde, fmt("última lluvia fuerte hace ~b h (fuera de la ventana de ~b h)",
                                [Edad div 3600, Ventana div 3600])};
                Limpias =/= [] ->
                    {verde, fmt("lluvia fuerte hace ~b h, pero hay muestra limpia posterior "
                                "(tomada ~s)", [Edad div 3600, fecha(lists:max(Limpias))])};
                true ->
                    {amarilla, fmt("lluvia fuerte hace ~b h (>= ~.1f mm/24 h) sin muestra limpia "
                                   "posterior: se presume contaminación elevada (ventana ~b h)",
                                   [Edad div 3600, maps:get(lluvia_fuerte_mm, Cfg),
                                    Ventana div 3600])}
            end
    end.

%% ---------------------------------------------------------------------------
%% Cierre sanitario (laboratorio). No pasa por la histeresis temporal: lo gobierna
%% la autoridad sanitaria. Se activa con una muestra > limite y se levanta con N
%% muestras limpias TOMADAS DESPUES de la mala (una limpia anterior no cuenta).
%% ---------------------------------------------------------------------------
cierre(Lab, Cfg) ->
    Limite = maps:get(limite_enterococos, Cfg),
    Req = maps:get(muestras_limpias_reapertura, Cfg),
    case [M || #{nmp := N} = M <- Lab, N > Limite] of
        [] -> undefined;
        Malas ->
            Ult = lists:last(lists:sort(fun(#{tomada := A}, #{tomada := B}) -> A =< B end, Malas)),
            #{tomada := TM} = Ult,
            Limpias = length([x || #{nmp := N, tomada := T} <- Lab, N =< Limite, T > TM]),
            case Limpias >= Req of
                true -> undefined;
                false -> #{tomada => TM, nmp => maps:get(nmp, Ult), limpias => Limpias,
                           requeridas => Req}
            end
    end.

texto_cierre(#{tomada := T, nmp := N, limpias := L, requeridas := R}) ->
    fmt("cierre sanitario: muestra tomada ~s con ~.1f NMP/100 ml (> límite); "
        "reabre con ~b muestras limpias posteriores (lleva ~b)", [fecha(T), float(N), R, L]).

%% ---------------------------------------------------------------------------
%% Histeresis (anti-rebote):
%%  * SUBIR es inmediato y al nivel estricto (el costo de esperar es un ahogado).
%%  * BAJAR exige: (a) nivel PRUDENTE por debajo del actual (margen del 15 %),
%%    (b) sostenido `espera_bajar_s` sin interrupciones, (c) de a UN escalon.
%%  Devuelve {NuevoNivel, EsperaDesde}.
%% ---------------------------------------------------------------------------
histeresis(Actual, Estr, Prud, EsperaDesde, Now, Cfg) ->
    A = num(Actual),
    case {num(Estr) > A, num(Prud) < A} of
        {true, _} ->
            {Estr, undefined};
        {false, true} ->
            Desde = case EsperaDesde of undefined -> Now; X -> X end,
            case Now - Desde >= maps:get(espera_bajar_s, Cfg) of
                true -> {nivel(A - 1), undefined};
                false -> {Actual, Desde}
            end;
        {false, false} ->
            {Actual, undefined}
    end.
