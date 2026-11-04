# Playa-y-Oleaje
Sistema en Erlang/OTP que decide la bandera de seguridad (verde, amarilla, roja, doble roja, morada) de 6 playas de Tijuana, Rosarito y Ensenada a partir de oleaje, viento, marea, lluvia y calidad del agua. Justifica cada decisión, evita rebotes, avisa cambios y guarda historial auditable.
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Playa y oleaje: banderas de seguridad con decisión transparente

Sistema en **Erlang/OTP** que decide qué bandera corresponde a cada playa
(verde, amarilla, roja, doble roja, más la capa morada de fauna marina), explica
*por qué*, avisa cuando cambia y conserva un historial auditable de cada decisión.

> **Dominio:** Energía y medio ambiente · **Proyecto #58**
> **Contexto:** las playas de Tijuana, Rosarito y Ensenada reciben miles de bañistas
> y surfistas; el oleaje, las resacas, la marea y la calidad del agua cambian durante el día.

## ¿Qué hace?

- **Integra** oleaje (Hs, Tp), viento, marea (por tabla), lluvia reciente y resultados de laboratorio (enterococos).
- **Decide por playa** con la regla "el peor de varios factores manda".
- **Justifica**: cada cambio guarda la razón de cada factor ("Oleaje [ROJA]: Hs=2.12 m, Tp=12.8 s").
- **Evita rebotes** con histéresis: sube de inmediato, baja solo con margen, persistencia de 1 h y de a un escalón.
- **Tolera fallas**: boya perdida, laboratorio atrasado, procesos muertos, datos corruptos.
- **Respeta al salvavidas** con límites: puede subir siempre; bajar solo 1 escalón, con motivo y caducidad; nunca puede levantar un cierre sanitario.

## Arranque rápido

Requiere Erlang/OTP 25+ y rebar3. Sin dependencias externas.

```bash
rebar3 compile
rebar3 eunit          # 60 pruebas, incluye las de caos
erl -noshell -pa _build/default/lib/playa/ebin \
    -eval 'playa_sim:run(), halt().'      # simulación de 72 h
rebar3 shell          # aplicación interactiva
```

## Arquitectura OTP

```
playa_sup (rest_for_one)
├── playa_store          dueño de ETS + persistencia a disco ("error kernel")
├── playa_pg             avisos a suscriptores (pg)
├── playa_banderas_sup   (one_for_one)
│   └── playa_bandera ×6   gen_statem por playa: verde | amarilla | roja | doble_roja
└── playa_reloj          pulso para detectar ausencia de datos
```

| Módulo | Rol |
|---|---|
| `playa_reglas` | Lógica pura: factores, peor-de-varios, cierre sanitario, histéresis |
| `playa_bandera` | Proceso por playa; override del salvavidas; historial |
| `playa_api` | Frontera: valida toda entrada externa |
| `playa_store` | Estado fuera de los procesos de negocio |
| `playa_sim` | Simulación del escenario con fallas inyectadas |

Diseño completo, justificación de cada decisión y quién reinicia a quién:
ver [`docs/DISENO.md`](docs/DISENO.md).

## Uso de la API en Erlang

```erlang
playa_api:oleaje(rosarito, 2.1, 12.8, Ts).
playa_api:viento(rosarito, 38.0, Ts).
playa_api:lluvia(tijuana, 14.0, Ts).
playa_api:laboratorio(tijuana, 480, TomadaTs, RecibidaTs).
playa_api:bandera(rosarito).                    %% estado + razones por factor
playa_api:override(rosarito, doble_roja, <<"rescates multiples">>, <<"salvavidas A">>, Ts, 3*3600).
playa_api:historial(rosarito).
playa_api:suscribir(rosarito).                  %% recibirás {playa_evento, Id, Entrada}
```

## Resultados de la simulación

6 playas · 72 h virtuales · boya c/30 min · viento c/10 min · marejada de 1 a 3 m en 4 h.
*Datos sintéticos.*

- Roja al cruzar Hs 2.0 m; baja a amarilla ~15 h después, cuando el oleaje queda claramente por debajo del umbral.
- Boya perdida → amarilla a los 100 min; anemómetro perdido en plena roja → se mantiene roja.
- Laboratorio con 36 h de atraso → bandera vigente amarilla pasa a **doble roja**, marcada como contradictoria.
- Con oleaje oscilando sobre 1.2 m: 7 cambios con histéresis vs 12 sin ella.

Salida completa: [`docs/salida_simulacion.txt`](docs/salida_simulacion.txt).

## Prueba de caos

| Qué se mata | Resultado |
|---|---|
| Una playa | Reinicia en ~15 ms con su estado y override; las demás ni se enteran |
| La misma playa 6 veces | Escala al supervisor; las 6 se reinician con el estado intacto |
| `playa_store` | Estado recuperado desde disco |
| `playa_store` + instantáneas borradas | Sin datos → **amarilla** (nunca verde); el cierre sanitario se reconstruye desde la bitácora |
| Mensaje malformado | Cae una playa, vuelve intacta, sin bucle |

## Supuestos y cifras verificadas

Los umbrales son **supuestos a calibrar con salvavidas locales** (en `playa_config.erl`).
Cifras del enunciado verificadas: ~80 % de rescates por resacas (USLA), sistema de banderas
(USLA/ILS) y límite de 200 enterococos/100 ml (Playas Limpias/Cofepris). No verificadas y
tratadas como supuestos: demora de laboratorio de 24-48 h, periodo largo ≥ 14 s, efecto de
marea baja y cadencia de boyas. Detalle en [`docs/DISENO.md`](docs/DISENO.md).

## Estado del proyecto

- [x] Dominio y diseño OTP
- [x] Núcleo de reglas, histéresis, cierre sanitario, override
- [x] Simulación con fallas inyectadas
- [x] Pruebas de caos (`rebar3 eunit` en verde)
- [ ] Endpoints HTTP y SSE con cowboy
- [ ] Métricas `/metrics` y diagnóstico con `recon`
- [ ] Pantallas en Stitch ([`design/Stitch.md`](design/Stitch.md)) y capturas
- [ ] Release + systemd
- [ ] Calibración de umbrales con salvavidas reales


## Aviso

Las banderas son orientativas y no sustituyen el criterio de los salvavidas.
Los datos de la simulación son sintéticos; los nombres de playa son solo etiquetas.
