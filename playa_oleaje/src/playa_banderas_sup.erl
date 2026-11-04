%% Una playa = un proceso (gen_statem). one_for_one: la caida de una playa NO toca a
%% las otras cinco. Intensidad 5/10 s: una playa que se cae en bucle (bug) escala al
%% supervisor raiz en vez de reiniciarse para siempre; el estado vive en playa_store.
-module(playa_banderas_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    Hijos = [#{id => Id, start => {playa_bandera, start_link, [Id]},
               restart => permanent, shutdown => 5000, type => worker}
             || Id <- playa_config:playas()],
    {ok, {Flags, Hijos}}.
