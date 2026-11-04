%% Frontera del sistema: TODA entrada externa se valida aqui antes de llegar a un proceso.
%% (Los handlers cowboy/SSE serian delgados y solo llamarian a este modulo.)
-module(playa_api).
-export([playas/0, oleaje/4, viento/3, lluvia/3, laboratorio/4, fauna/3, tick/1,
         override/6, liberar/3, bandera/1, historial/1, suscribir/1]).

playas() -> playa_config:playas().

oleaje(P, Hs, Tp, Ts) ->
    enviar(P, Ts, [{hs, Hs, 0.0, 20.0}, {tp, Tp, 1.0, 30.0}],
           fun(Id, [H, T]) -> playa_bandera:observar(Id, oleaje, #{hs => H, tp => T}, Ts) end).

viento(P, Kmh, Ts) ->
    enviar(P, Ts, [{kmh, Kmh, 0.0, 300.0}],
           fun(Id, [V]) -> playa_bandera:observar(Id, viento, #{kmh => V}, Ts) end).

lluvia(P, Mm24, Ts) ->
    enviar(P, Ts, [{mm24, Mm24, 0.0, 1000.0}],
           fun(Id, [M]) -> playa_bandera:observar(Id, lluvia, #{mm24 => M}, Ts) end).

laboratorio(P, Nmp, Tomada, Recibida) when is_integer(Tomada), Tomada >= 0, Tomada =< Recibida ->
    enviar(P, Recibida, [{nmp, Nmp, 0.0, 10000000.0}],
           fun(Id, [N]) ->
                   playa_bandera:laboratorio(Id, #{tomada => Tomada, nmp => N, recibida => Recibida})
           end);
laboratorio(_, _, _, _) -> {error, {invalido, tomada}}.

fauna(P, Bool, Ts) when is_boolean(Bool) ->
    enviar(P, Ts, [], fun(Id, []) -> playa_bandera:fauna(Id, Bool, Ts) end);
fauna(_, _, _) -> {error, {invalido, activa}}.

%% Solo para reloj manual (simulacion/pruebas); en vivo lo hace playa_reloj.
tick(Ts) when is_integer(Ts) ->
    [playa_bandera:tick(Id, Ts) || Id <- playas()],
    ok.

override(P, Nivel, Motivo, Autor, Ts, DuracionS) ->
    con_id(P, fun(Id) ->
        playa_bandera:override(Id, #{nivel => Nivel, motivo => Motivo, autor => Autor,
                                     ts => Ts, duracion_s => DuracionS})
    end).

liberar(P, Autor, Ts) -> con_id(P, fun(Id) -> playa_bandera:liberar(Id, Autor, Ts) end).
bandera(P) -> con_id(P, fun playa_bandera:estado/1).
historial(P) -> con_id(P, fun playa_bandera:historial/1).
suscribir(P) -> con_id(P, fun playa_bus:suscribir/1).

%% --- helpers ---
con_id(P, F) ->
    case playa_config:playa_id(P) of
        {ok, Id} -> F(Id);
        error -> {error, playa_desconocida}
    end.

enviar(P, Ts, Campos, Enviar) ->
    con_id(P, fun(Id) ->
        case is_integer(Ts) andalso Ts >= 0 of
            false -> {error, {invalido, ts}};
            true ->
                case validar(Campos, []) of
                    {ok, Vs} -> Enviar(Id, Vs), ok;
                    {error, _} = E -> E
                end
        end
    end).

validar([], Acc) -> {ok, lists:reverse(Acc)};
validar([{_N, V, Min, Max} | R], Acc) when is_number(V), V >= Min, V =< Max ->
    validar(R, [float(V) | Acc]);
validar([{N, _, _, _} | _], _) -> {error, {invalido, N}}.
