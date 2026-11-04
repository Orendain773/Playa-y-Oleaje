%% "Error kernel": este proceso NO hace logica de negocio. Solo es dueno de las tablas ETS
%% (instantaneas por playa + historial) para que sobrevivan a la caida de los procesos de
%% playa. Como casi no tiene codigo, casi no puede fallar. Ademas persiste a disco:
%%  - historial_archivo: bitacora append-only (auditoria + reconstruccion de laboratorio)
%%  - estado_dir:        una instantanea por playa (sobrevive a reinicio de la VM)
-module(playa_store).
-behaviour(gen_server).
-export([start_link/0, guardar/3, restaurar/1, registrar/3, historial/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ets:new(playa_snap, [named_table, public, set]),
    ets:new(playa_hist, [named_table, public, ordered_set]),
    recargar_historial(),
    recargar_snapshots(),
    {ok, #{}}.

handle_call(_Req, _From, S) -> {reply, ok, S}.
handle_cast(_Msg, S) -> {noreply, S}.

%% --- instantaneas ----------------------------------------------------------
guardar(Id, Estado, Datos) ->
    ets:insert(playa_snap, {Id, Estado, Datos}),
    case application:get_env(playa, estado_dir, undefined) of
        undefined -> ok;
        Dir -> escribir_atomico(archivo_snap(Dir, Id), term_to_binary({Estado, Datos}))
    end,
    ok.

restaurar(Id) ->
    case ets:lookup(playa_snap, Id) of
        [{_, E, D}] -> {ok, E, D};
        [] -> error
    end.

archivo_snap(Dir, Id) -> filename:join(Dir, atom_to_list(Id) ++ ".snap").

escribir_atomico(Ruta, Bin) ->
    try
        ok = filelib:ensure_dir(Ruta),
        Tmp = Ruta ++ ".tmp",
        ok = file:write_file(Tmp, Bin),
        ok = file:rename(Tmp, Ruta)
    catch C:R -> logger:warning("playa_store: no se pudo persistir ~s: ~p:~p", [Ruta, C, R])
    end.

recargar_snapshots() ->
    case application:get_env(playa, estado_dir, undefined) of
        undefined -> ok;
        Dir ->
            [begin
                 try
                     {ok, Bin} = file:read_file(archivo_snap(Dir, Id)),
                     {E, D} = binary_to_term(Bin, [safe]),
                     ets:insert(playa_snap, {Id, E, D})
                 catch _:_ -> ok
                 end
             end || Id <- playa_config:playas()],
            ok
    end.

%% --- historial -------------------------------------------------------------
registrar(Id, Ts, Entry) ->
    ets:insert(playa_hist, {{Id, Ts, erlang:unique_integer([monotonic])}, Entry}),
    anexar({Id, Ts, Entry}),
    ok.

historial(Id) ->
    [E || {_, E} <- ets:match_object(playa_hist, {{Id, '_', '_'}, '_'})].

anexar(Term) ->
    case application:get_env(playa, historial_archivo, undefined) of
        undefined -> ok;
        Ruta ->
            try file:write_file(Ruta, unicode:characters_to_binary(io_lib:format("~0tp.~n", [Term])), [append])
            catch C:R -> logger:warning("playa_store: bitacora no escrita: ~p:~p", [C, R])
            end,
            ok
    end.

recargar_historial() ->
    case application:get_env(playa, historial_archivo, undefined) of
        undefined -> ok;
        Ruta ->
            case file:consult(Ruta) of
                {ok, Terms} ->
                    [ets:insert(playa_hist, {{Id, Ts, erlang:unique_integer([monotonic])}, E})
                     || {Id, Ts, E} <- Terms],
                    ok;
                {error, _} -> ok
            end
    end.
