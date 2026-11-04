%% Un proceso por playa. Estados del gen_statem = NIVEL DEL SISTEMA con histeresis
%% (verde | amarilla | roja | doble_roja). Sobre ese nivel se aplican, en este orden:
%%   1. cierre sanitario (laboratorio)  -> fuerza doble_roja, no lo anula el salvavidas
%%   2. override del salvavidas         -> puede SUBIR siempre; BAJAR solo 1 escalon, con
%%                                         motivo, con caducidad, y nunca bajo un cierre
%% La bandera EFECTIVA es la que se muestra; el nivel del sistema siempre queda visible
%% y toda divergencia queda en el historial con quien y por que.
%%
%% Todo el tiempo llega como argumento (Ts): el mismo codigo corre en vivo y en simulacion.
-module(playa_bandera).
-behaviour(gen_statem).

-export([start_link/1, via/1]).
-export([observar/4, laboratorio/2, tick/2, fauna/3, override/2, liberar/3,
         estado/1, historial/1]).
-export([callback_mode/0, init/1, terminate/3]).
-export([verde/3, amarilla/3, roja/3, doble_roja/3]).

-record(d, {id, cfg, now = 0, obs = #{}, lab = [], cierre, espera_desde, override,
            fauna = false, efectiva, fuente = sistema, desde = 0, factores = []}).

via(Id) -> list_to_atom("playa_" ++ atom_to_list(Id)).   %% conjunto fijo y pequeno

start_link(Id) -> gen_statem:start_link({local, via(Id)}, ?MODULE, Id, []).

%% --- API (casts: no bloquean al ingestor; calls: solo consultas/ordenes humanas) ---
observar(Id, Factor, Valor, Ts) -> gen_statem:cast(via(Id), {obs, Factor, Valor, Ts}).
laboratorio(Id, Muestra) -> gen_statem:cast(via(Id), {lab, Muestra}).
tick(Id, Now) -> gen_statem:cast(via(Id), {tick, Now}).
fauna(Id, Bool, Ts) -> gen_statem:cast(via(Id), {fauna, Bool, Ts}).
override(Id, Spec) -> llamar(Id, {override, Spec}).
liberar(Id, Autor, Ts) -> llamar(Id, {liberar, Autor, Ts}).
estado(Id) -> llamar(Id, estado).
historial(Id) -> playa_store:historial(Id).

llamar(Id, Msg) ->
    try gen_statem:call(via(Id), Msg, 5000)
    catch exit:_ -> {error, no_disponible}
    end.

callback_mode() -> state_functions.

%% --- arranque / recuperacion -------------------------------------------------
init(Id) ->
    Cfg = playa_config:cfg(),
    case playa_store:restaurar(Id) of
        {ok, Estado, D} ->
            D1 = D#d{cfg = Cfg},
            registrar(D1, #{ts => D1#d.now, tipo => reinicio, playa => Id,
                            bandera => D1#d.efectiva,
                            detalle => <<"proceso reiniciado; estado restaurado desde el almacén">>}),
            {ok, Estado, D1};
        error ->
            %% Sin instantanea: arranque PRUDENTE (amarilla), nunca verde por omision.
            %% El laboratorio se reconstruye desde la bitacora para no perder un cierre.
            Hist = playa_store:historial(Id),
            Lab = [#{tomada => T, nmp => N, recibida => R}
                   || #{tipo := laboratorio, tomada := T, nmp := N, ts := R} <- Hist],
            Now = lists:max([playa_config:ahora() | [Ts || #{ts := Ts} <- Hist]]),
            Cierre = playa_reglas:cierre(Lab, Cfg),
            Ef = case Cierre of undefined -> amarilla; _ -> doble_roja end,
            D = #d{id = Id, cfg = Cfg, now = Now, lab = Lab, cierre = Cierre,
                   efectiva = Ef, desde = Now},
            registrar(D, #{ts => Now, tipo => arranque, playa => Id, bandera => Ef,
                           laboratorio_reconstruido => length(Lab),
                           detalle => <<"arranque sin estado previo; prudencia: amarilla "
                                        "hasta recibir datos (cierre sanitario si hay "
                                        "laboratorio en la bitácora)">>}),
            playa_store:guardar(Id, amarilla, D#d{cfg = undefined}),
            {ok, amarilla, D}
    end.

terminate(_Reason, _State, _D) -> ok.

%% --- estados: todos comparten el mismo manejador ------------------------------
verde(T, E, D) -> comun(verde, T, E, D).
amarilla(T, E, D) -> comun(amarilla, T, E, D).
roja(T, E, D) -> comun(roja, T, E, D).
doble_roja(T, E, D) -> comun(doble_roja, T, E, D).

comun(E, cast, {obs, Factor, Valor, Ts}, D)
  when (Factor =:= oleaje orelse Factor =:= viento orelse Factor =:= lluvia),
       is_map(Valor), is_integer(Ts) ->
    accion(E, guardar_obs(Factor, Valor, Ts, avanzar(D, Ts)), #{});

comun(E, cast, {lab, #{tomada := Tom, nmp := N, recibida := Rec} = M}, D)
  when is_number(N), is_integer(Tom), is_integer(Rec) ->
    D1 = avanzar(D, Rec),
    Limite = maps:get(limite_enterococos, D1#d.cfg),
    NoApta = N > Limite,
    Contradice = NoApta andalso D1#d.efectiva =/= doble_roja,
    registrar(D1, #{ts => Rec, tipo => laboratorio, playa => D1#d.id, tomada => Tom,
                    nmp => N, limite => Limite, edad_s => Rec - Tom,
                    veredicto => case NoApta of true -> no_apta; false -> apta end,
                    bandera_vigente => D1#d.efectiva, contradice_vigente => Contradice}),
    Lab = [X || X <- D1#d.lab, maps:get(tomada, X) =/= Tom] ++ [M],
    accion(E, D1#d{lab = Lab}, #{contradice_vigente => Contradice});

comun(E, cast, {tick, Now}, D) when is_integer(Now) ->
    accion(E, avanzar(D, Now), #{});

comun(E, cast, {fauna, B, Ts}, D) when is_boolean(B), is_integer(Ts) ->
    D1 = avanzar(D, Ts),
    case D1#d.fauna =:= B of
        true -> {keep_state, D1};
        false ->
            D2 = D1#d{fauna = B},
            registrar(D2, #{ts => Ts, tipo => fauna, playa => D2#d.id, activa => B,
                            detalle => <<"bandera morada: fauna marina peligrosa (reporte del salvavidas)">>}),
            playa_store:guardar(D2#d.id, E, D2#d{cfg = undefined}),
            {keep_state, D2}
    end;

comun(E, {call, From}, estado, D) ->
    {keep_state_and_data, [{reply, From, vista(E, D)}]};

comun(E, {call, From}, {override, Spec}, D) ->
    case fijar_override(E, Spec, D) of
        {ok, D1} ->
            {Nuevo, D2} = reevaluar(E, D1, #{}),
            {next_state, Nuevo, D2, [{reply, From, ok}]};
        {error, _} = Err ->
            {keep_state_and_data, [{reply, From, Err}]}
    end;

comun(_E, {call, From}, {liberar, _Autor, _Ts}, #d{override = undefined}) ->
    {keep_state_and_data, [{reply, From, {error, sin_override}}]};
comun(E, {call, From}, {liberar, Autor, Ts}, #d{override = Ov} = D) when is_integer(Ts) ->
    D1 = avanzar(D, Ts),
    registrar(D1, #{ts => D1#d.now, tipo => override, accion => liberado, playa => D1#d.id,
                    nivel => maps:get(nivel, Ov), autor => Autor}),
    {Nuevo, D2} = reevaluar(E, D1#d{override = undefined}, #{}),
    {next_state, Nuevo, D2, [{reply, From, ok}]};

comun(_E, {call, From}, _Otro, _D) ->
    {keep_state_and_data, [{reply, From, {error, peticion_desconocida}}]};

comun(_E, _Tipo, _Evento, _D) ->
    keep_state_and_data.   %% mensajes desconocidos se ignoran; los MALFORMADOS de tipo conocido caen (ver README)

accion(E, D, Extra) ->
    {Nuevo, D2} = reevaluar(E, D, Extra),
    {next_state, Nuevo, D2}.

avanzar(#d{now = N} = D, Ts) -> D#d{now = max(N, Ts)}.

%% Ignora lecturas fuera de orden (el reloj de la boya no retrocede).
guardar_obs(Factor, Valor, Ts, #d{obs = Obs, cfg = Cfg} = D) ->
    case maps:get(Factor, Obs, undefined) of
        #{ts := Previo} when Previo > Ts -> D;
        _ ->
            Obs1 = Obs#{Factor => Valor#{ts => Ts}},
            Obs2 = case Factor of
                       lluvia -> marcar_lluvia(Valor, Ts, Obs1, Cfg);
                       _ -> Obs1
                   end,
            D#d{obs = Obs2}
    end.

marcar_lluvia(#{mm24 := Mm}, Ts, Obs, Cfg) when is_number(Mm) ->
    case Mm >= maps:get(lluvia_fuerte_mm, Cfg) of
        true -> Obs#{lluvia_fuerte_ts => max(Ts, maps:get(lluvia_fuerte_ts, Obs, 0))};
        false -> Obs
    end.

%% --- el ciclo de decision --------------------------------------------------------
reevaluar(Estado, D0, Extra) ->
    #d{cfg = Cfg, now = Now, obs = Obs, lab = Lab} = D0,
    Marea = playa_marea:altura(Now, maps:get(mareas, Cfg, [])),
    {Estr, Factores} = playa_reglas:evaluar(estricto, Obs, Marea, Lab, Now, Cfg),
    {Prud, _} = playa_reglas:evaluar(prudente, Obs, Marea, Lab, Now, Cfg),
    {Nuevo, Espera} = playa_reglas:histeresis(Estado, Estr, Prud, D0#d.espera_desde, Now, Cfg),
    D1 = D0#d{espera_desde = Espera, cierre = playa_reglas:cierre(Lab, Cfg), factores = Factores},
    D2 = gestionar_override(Estado, Nuevo, D1),
    {Ef, Fuente} = efectiva(Nuevo, D2),
    D3 = publicar(Estado, Nuevo, Ef, Fuente, D0, D2, Extra),
    playa_store:guardar(D3#d.id, Nuevo, D3#d{cfg = undefined}),
    {Nuevo, D3}.

efectiva(Estado, #d{cierre = undefined, override = #{nivel := ON}}) when ON =/= Estado ->
    {ON, salvavidas};
efectiva(Estado, #d{cierre = undefined}) -> {Estado, sistema};
efectiva(_Estado, _ConCierre) -> {doble_roja, sistema}.

gestionar_override(_Ant, _Nuevo, #d{override = undefined} = D) -> D;
gestionar_override(Ant, Nuevo, #d{override = #{nivel := ON, hasta := H} = Ov, now = Now} = D) ->
    Cancelar = if Now >= H -> vencido;
                  true ->
                      case playa_reglas:num(ON) < playa_reglas:num(Nuevo)
                           andalso playa_reglas:num(Nuevo) > playa_reglas:num(Ant) of
                          true -> revocado_por_empeoramiento;
                          false -> no
                      end
               end,
    case Cancelar of
        no -> D;
        Motivo ->
            registrar(D, #{ts => Now, tipo => override, accion => Motivo, playa => D#d.id,
                           nivel => ON, autor => maps:get(autor, Ov), nivel_sistema => Nuevo}),
            D#d{override = undefined}
    end.

publicar(Estado, Nuevo, Ef, Fuente, D0, D2, Extra) ->
    case Ef =:= D0#d.efectiva of
        true ->
            case Nuevo =/= Estado of
                true -> registrar(D2, #{ts => D2#d.now, tipo => nivel_sistema, playa => D2#d.id,
                                        de => Estado, a => Nuevo, bandera_efectiva => Ef,
                                        fuente => Fuente, razones => razones(Nuevo, Fuente, D2),
                                        factores => D2#d.factores});
                false -> ok
            end,
            D2#d{fuente = Fuente};
        false ->
            Entry = #{ts => D2#d.now, tipo => cambio, playa => D2#d.id,
                      de => D0#d.efectiva, a => Ef, fuente => Fuente,
                      causa => causa(D0, Fuente, D2),
                      nivel_sistema => Nuevo,
                      cierre_sanitario => D2#d.cierre =/= undefined,
                      override => D2#d.override,
                      razones => razones(Nuevo, Fuente, D2),
                      factores => D2#d.factores},
            registrar(D2, maps:merge(Entry, Extra)),
            D2#d{efectiva = Ef, fuente = Fuente, desde = D2#d.now}
    end.

causa(D0, Fuente, D2) ->
    case {D0#d.cierre, D2#d.cierre} of
        {undefined, C} when C =/= undefined -> cierre_sanitario;
        {C, undefined} when C =/= undefined -> reapertura_sanitaria;
        _ ->
            case {D0#d.fuente, Fuente} of
                {_, salvavidas} -> override_salvavidas;
                {salvavidas, sistema} -> fin_override;
                _ -> condiciones
            end
    end.

%% Justificacion transparente: que factores determinan el nivel, con sus valores.
razones(Nuevo, Fuente, #d{factores = Fs, cierre = C, override = Ov}) ->
    Hidro = case Nuevo of
                verde -> [<<"todos los factores en verde">>];
                _ ->
                    case [playa_reglas:fmt("~s [~s]: ~ts", [F, N, R])
                          || #{factor := F, nivel := N, razon := R} <- Fs, N =:= Nuevo] of
                        [] -> [<<"nivel sostenido o escalonado por histéresis: condiciones por "
                                 "debajo del umbral, esperando persistencia antes de bajar">>];
                        L -> L
                    end
            end,
    Cierre = case C of undefined -> []; _ -> [playa_reglas:texto_cierre(C)] end,
    Humano = case {Fuente, Ov} of
                 {salvavidas, #{nivel := ON, autor := A, motivo := Mo, hasta := H}} ->
                     [playa_reglas:fmt("override de ~ts: ~s hasta ~s; motivo: ~ts",
                                       [A, ON, playa_reglas:fecha(H), Mo])];
                 _ -> []
             end,
    Cierre ++ Humano ++ Hidro.

%% Override: subir siempre; bajar solo con reglas estrictas (ver encabezado).
fijar_override(Estado, #{nivel := N, autor := A, ts := Ts, duracion_s := Dur} = Spec,
               #d{cfg = Cfg} = D)
  when is_integer(Ts), is_integer(Dur), Dur > 0, is_binary(A) ->
    Motivo = maps:get(motivo, Spec, <<>>),
    case lists:member(N, playa_reglas:niveles()) of
        false -> {error, nivel_invalido};
        true ->
            Base = case D#d.cierre of undefined -> Estado; _ -> doble_roja end,
            NumN = playa_reglas:num(N),
            NumB = playa_reglas:num(Base),
            Max = maps:get(max_bajada_salvavidas, Cfg),
            Verif = if NumN >= NumB -> ok;
                       D#d.cierre =/= undefined -> {error, cierre_sanitario_vigente};
                       NumB - NumN > Max -> {error, bajada_excesiva};
                       Motivo =:= <<>> -> {error, motivo_requerido};
                       true -> ok
                    end,
            case Verif of
                ok ->
                    D1 = avanzar(D, Ts),
                    Ov = #{nivel => N, autor => A, motivo => Motivo, desde => Ts, hasta => Ts + Dur},
                    registrar(D1, #{ts => D1#d.now, tipo => override, accion => fijado,
                                    playa => D1#d.id, nivel => N, autor => A, motivo => Motivo,
                                    hasta => Ts + Dur, nivel_sistema => Estado}),
                    {ok, D1#d{override = Ov}};
                Err -> Err
            end
    end;
fijar_override(_, _, _) -> {error, spec_invalida}.

vista(Estado, D) ->
    #{playa => D#d.id, bandera => D#d.efectiva, fuente => D#d.fuente,
      nivel_sistema => Estado, desde => D#d.desde, ahora => D#d.now,
      cierre_sanitario => D#d.cierre, override => D#d.override,
      bandera_morada => D#d.fauna, factores => D#d.factores,
      espera_bajar_desde => D#d.espera_desde}.

registrar(#d{id = Id}, Entry) ->
    playa_store:registrar(Id, maps:get(ts, Entry), Entry),
    playa_bus:publicar(Id, Entry).
