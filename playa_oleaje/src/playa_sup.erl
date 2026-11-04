%% Supervisor raiz: rest_for_one. El orden ES la dependencia:
%%   store -> pg -> banderas_sup -> reloj
%% Si cae el store (dueno de ETS) se reinician todos los que dependen de el; si cae
%% banderas_sup, solo se reinicia el reloj. Intensidad baja (3/10 s): si el arbol raiz no
%% logra estabilizarse, la aplicacion cae y systemd/release la reinicia entera.
-module(playa_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => rest_for_one, intensity => 3, period => 10},
    Hijos = [
        #{id => playa_store, start => {playa_store, start_link, []},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => playa_pg, start => {pg, start_link, [playa_pg]},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => playa_banderas_sup, start => {playa_banderas_sup, start_link, []},
          restart => permanent, shutdown => infinity, type => supervisor},
        #{id => playa_reloj, start => {playa_reloj, start_link, []},
          restart => permanent, shutdown => 5000, type => worker}
    ],
    {ok, {Flags, Hijos}}.
