%% Marea "por tabla": lista de extremos [{Ts, AlturaM}] (pleamares/bajamares).
%% Entre extremos se interpola con coseno, como se usan las tablas de mareas.
-module(playa_marea).
-export([altura/2, extremos_sinteticos/2]).

altura(Ts, [{T0, H0}, {T1, H1} | _]) when Ts >= T0, Ts =< T1 ->
    H0 + (H1 - H0) * (1 - math:cos(math:pi() * (Ts - T0) / (T1 - T0))) / 2;
altura(Ts, [_ | Resto]) when length(Resto) >= 2 -> altura(Ts, Resto);
altura(_Ts, _) -> undefined.   %% fuera de la tabla: el llamador asume el caso prudente

%% Tabla SINTETICA semidiurna (~6.2 h entre extremos) para simulacion; no es prediccion real.
extremos_sinteticos(Desde, Hasta) ->
    Paso = 22350,
    N = (Hasta - Desde) div Paso + 2,
    [{Desde + K * Paso, case K rem 2 of 0 -> 0.1; 1 -> 1.7 end} || K <- lists:seq(0, N)].
