%% Notificaciones: suscriptores via `pg`. Fire-and-forget: un suscriptor caido no
%% afecta a la playa (pg lo saca solo del grupo).
-module(playa_bus).
-export([suscribir/1, publicar/2]).
-define(SCOPE, playa_pg).

suscribir(todas) -> pg:join(?SCOPE, playa_todas, self());
suscribir(Id) -> pg:join(?SCOPE, {playa, Id}, self()).

publicar(Id, Entry) ->
    try
        Ms = pg:get_members(?SCOPE, {playa, Id}) ++ pg:get_members(?SCOPE, playa_todas),
        [M ! {playa_evento, Id, Entry} || M <- Ms],
        ok
    catch _:_ -> ok
    end.
