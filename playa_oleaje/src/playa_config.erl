%% Configuracion: umbrales (SUPUESTOS a calibrar con salvavidas locales) y utilidades.
-module(playa_config).
-export([defaults/0, cfg/0, playas/0, ahora/0, playa_id/1]).

defaults() ->
    #{%% oleaje: altura significativa Hs (m), tabla ascendente {umbral, nivel}
      oleaje_hs => [{1.2, amarilla}, {2.0, roja}, {3.5, doble_roja}],
      %% periodo largo (s): agrava el oleaje (Hs 2 m con Tp > 14 s es peligroso)
      periodo_largo_s => 14.0,
      periodo_hs => [{1.0, amarilla}, {2.0, roja}],
      %% viento km/h
      viento_kmh => [{25.0, amarilla}, {40.0, roja}, {70.0, doble_roja}],
      %% marea baja expone bancos de arena -> resacas
      marea_baja_m => 0.5,
      resaca_hs_marea_baja => [{0.9, amarilla}, {1.6, roja}],
      %% calidad del agua
      lluvia_fuerte_mm => 10.0,
      ventana_lluvia_s => 72 * 3600,
      limite_enterococos => 200,
      muestras_limpias_reapertura => 2,
      %% frescura de datos (segundos): boya c/30 min -> 3 lecturas perdidas; viento c/10 min -> 3
      max_edad_s => #{oleaje => 90 * 60, resaca => 90 * 60,
                      viento => 30 * 60, lluvia => 180 * 60},
      nivel_sin_dato => amarilla,
      %% histeresis
      margen_prudente => 0.85,
      espera_bajar_s => 3600,
      %% salvavidas
      max_bajada_salvavidas => 1}.

cfg() ->
    Over = application:get_env(playa, umbrales, #{}),
    M = maps:merge(defaults(), Over),
    M#{mareas => application:get_env(playa, mareas, [])}.

playas() -> application:get_env(playa, playas, []).

%% Reloj: auto = hora real; manual = tiempo virtual (simulacion/pruebas)
ahora() ->
    case application:get_env(playa, reloj, auto) of
        auto -> erlang:system_time(second);
        manual -> application:get_env(playa, reloj_inicio, 0)
    end.

%% Sin crear atomos desde entrada externa
playa_id(A) when is_atom(A) ->
    case lists:member(A, playas()) of true -> {ok, A}; false -> error end;
playa_id(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) of A -> playa_id(A)
    catch error:badarg -> error end;
playa_id(_) -> error.
