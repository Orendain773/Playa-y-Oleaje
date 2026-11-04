# Playa y oleaje (#58): banderas por playa con decisión transparente

Erlang/OTP 25, sin dependencias externas. `rebar3 compile` y `rebar3 eunit` en verde (60 pruebas).

```
rebar3 compile
rebar3 eunit
erl -noshell -pa _build/default/lib/playa/ebin -eval 'playa_sim:run(), halt().'   # simulación de 72 h
```

## 1. Diseño OTP

```
playa_sup (rest_for_one, 3 reinicios/10 s)
├── playa_store          dueño de las tablas ETS (instantáneas + historial). Casi sin código.
├── playa_pg             scope de `pg` (suscriptores / avisos)
├── playa_banderas_sup   (one_for_one, 5 reinicios/10 s)
│   ├── playa_bandera(tijuana)      gen_statem: verde|amarilla|roja|doble_roja
│   └── … 5 más (baja_malibu, rosarito, puerto_nuevo, ensenada_hermosa, ensenada_estero)
└── playa_reloj          pulso para detectar ausencia de datos
```
Puro y sin procesos: `playa_reglas` (factores, peor-de-varios, cierre sanitario, histéresis), `playa_marea` (tabla), `playa_api` (validación en la frontera).

**Quién reinicia a quién**
| Cae | Lo reinicia | Efecto |
|---|---|---|
| una playa | `playa_banderas_sup` (one_for_one) | solo esa playa; restaura su instantánea de ETS |
| 6 caídas seguidas de una playa | `playa_sup` reinicia `playa_banderas_sup` | las 6 playas se reinician (costo colateral), estado intacto |
| `playa_store` | `playa_sup` (rest_for_one) → reinicia también pg, banderas y reloj | estado se recarga desde disco |
| el árbol raíz (más de 3 reinicios/10 s) | systemd / release (pendiente) | cae la aplicación completa |

**Decisiones frente a los casos difíciles**
- *Rebote:* subir es inmediato; bajar exige (a) umbrales con margen del 15 % (`prudente`), (b) persistencia de 1 h sin interrupciones, (c) un escalón a la vez. El costo de una falsa alarma es una hora de playa perdida; el de una bajada tardía, un ahogado.
- *Boya perdida:* un factor sin dato en 90 min (viento 30 min, lluvia 3 h) aporta al menos amarilla. Un dato perdido nunca baja una bandera roja. Los ticks del reloj son los que detectan el silencio (nadie "habla" cuando una boya muere).
- *Peor de varios:* `max` de oleaje (Hs + periodo largo), resaca (Hs × marea baja), viento y lluvia/calidad del agua. Cada factor aporta su razón en texto y queda en el historial.
- *Estado fuera de los procesos:* `playa_store` solo es dueño de ETS (el patrón "error kernel": casi no puede fallar). Los procesos de negocio pueden caer porque su estado vive aparte; y se persiste a disco (instantánea por playa + bitácora append-only), así que sobrevive incluso a la caída del almacén.
- *Mensajes venenosos:* se valida todo en `playa_api`. Si uno malformado llega a una playa, esta cae, el buzón (con el mensaje) se destruye y reinicia con el estado previo: no hay bucle.
- *Sin estado previo:* arranque en **amarilla**, nunca verde. Un cierre sanitario se reconstruye desde la bitácora.

**Preguntas guía**
1. *¿Cómo evitas que la bandera cambie cada 5 min?* Histéresis asimétrica (arriba inmediato; abajo con margen, persistencia y un escalón). En la simulación, con oleaje oscilando sobre 1.2 m, `puerto_nuevo` tuvo 7 cambios contra 12 sin histéresis; en el test equivalente, 1 contra 17.
2. *¿Quién tiene la última palabra?* El salvavidas, con límites: **puede subir siempre**; **bajar** solo 1 escalón, con motivo, con caducidad (se vuelve al sistema) y se revoca si el sistema empeora; **nunca puede bajar un cierre sanitario** (lo gobierna el laboratorio / la autoridad sanitaria). El nivel del sistema siempre queda visible y cada divergencia queda registrada con autor y motivo.

## 2. Simulación (`playa_sim`)
6 playas, 72 h de tiempo virtual (T0 = 2026-11-07 06:00 UTC), boya c/30 min, viento c/10 min, marea por tabla (sintética), marejada de 1 a 3 m en 4 h, lluvia fuerte en una cuenca. **Datos sintéticos; los nombres de playa son solo etiquetas.** Fallas inyectadas: boya de rosarito perdida 6 h; anemómetro de baja_malibu perdido 3 h en plena marejada; lecturas corruptas; rebote sobre 1.2 m; override de salvavidas (subir y bajar, y un intento de bajar un cierre); **muestra de laboratorio con 36 h de atraso** que contradice la bandera; muerte del proceso de rosarito y del `playa_store`.

Resultados observados (ejecución real):
- Marejada en tijuana: amarilla (viento) +08:40 → **roja +10:00 al cruzar Hs 2.0 m** → baja a amarilla recién +25:30 (esperó a Hs claramente bajo el umbral, marea baja incluida).
- Boya perdida: verde → amarilla a los 100 min sin dato (+37:10), vuelve a verde 1 h después de que regresan los datos.
- Anemómetro perdido en plena roja: la bandera **se mantuvo roja**.
- Laboratorio atrasado: bandera vigente amarilla (presunción por lluvia) → **doble roja** al llegar la muestra (480 NMP/100 ml, edad 36 h), marcada `contradice_vigente`. El intento de un salvavidas de bajarla fue rechazado. Reabre al llegar la 2ª muestra limpia tomada después de la mala (+62:00).
- Cambios por causa "condiciones" (con vs sin histéresis): tijuana 4 vs 7, puerto_nuevo 7 vs 12, rosarito 7 vs 8. Con ruido moderado la ganancia es pequeña; con rebote sobre un umbral es grande.

## 3. Prueba de caos (reales: `exit(Pid, kill)` en eunit y en la simulación)
| # | Qué maté | Qué esperaba | Qué ocurrió |
|---|---|---|---|
| C1 | `playa_tijuana` en doble roja por override | reinicia sola, conserva bandera/override, vecinas intactas, entrada `reinicio` | Reinicio en ~15 ms; mismo estado y override; rosarito con el mismo pid. |
| C2 | `playa_tijuana` 6 veces seguidas | 5 absorbidas; la 6ª escala y reinicia `banderas_sup`; el almacén no se toca | Así fue. Costo observado: las 6 playas se reinician (otros pids), pero el estado se conserva. |
| C3a | `playa_store` con disco intacto | todas las playas vuelven con su estado | tijuana sigue en doble roja, rosarito verde, historial íntegro. |
| C3b | `playa_store` **y** se borran las instantáneas | tijuana reabre en doble roja (cierre reconstruido); rosarito sin datos → amarilla, **no verde** | Confirmado. Se pierde el override del salvavidas (hay que reingresarlo). |
| C4 | Mensaje malformado saltándose la validación | cae una playa, vuelve intacta, sin bucle | Reinicio único y estable tras 300 ms; estado sin la lectura. |
| C5 | (inyección) datos corruptos por la API | rechazo, bandera intacta | 3 lecturas rechazadas; bandera sin cambios. |
| C6 | (inyección) boya perdida | verde sube a amarilla | Ver simulación y `t_datos_faltantes`. |

Defectos reales que encontraron las pruebas y ya están corregidos: un `io_lib:format("~.0f")` inválido que habría **tumbado el proceso justo con oleaje de periodo largo**, y una bitácora escrita en latin-1 pero leída como UTF-8 (la recarga fallaba en silencio).

## 4. Supuestos propios (todos configurables en `playa_config`)
- **Umbrales** (a calibrar con salvavidas): Hs 1.2 / 2.0 / 3.5 m; periodo largo ≥ 14 s agrava (≥ 1.0 m → amarilla, ≥ 2.0 m → roja); viento 25 / 40 / 70 km/h; marea baja ≤ 0.5 m con Hs ≥ 0.9 → amarilla, ≥ 1.6 → roja.
- Lluvia ≥ 10 mm/24 h presume contaminación 72 h (amarilla) hasta una muestra limpia **tomada después** de la lluvia.
- Cierre sanitario con una muestra > 200 NMP/100 ml; se levanta con 2 muestras limpias posteriores (supuesto; la práctica real varía por comité).
- Frescura: boya 90 min, viento 30 min, lluvia 3 h; sin dato = al menos amarilla.
- Histéresis: margen 15 %, persistencia 1 h, un escalón.
- Salvavidas: bajar máx. 1 escalón; caducidad definida por quien ordena.
- La bandera morada es una capa (reportada por el salvavidas), no un nivel.
- Una boya por playa; todos los instantes en UTC; la marea de la simulación es sintética.
- No se modela: temperatura del agua, corrientes medidas, aforo, ni fuentes alternas de oleaje.

## 5. Cifras del enunciado: qué verifiqué
| Cifra | Resultado |
|---|---|
| ~80 % de rescates por resacas (USLA) | **Verificada.** USLA reporta ~82 % (muestra 1990-99); estudio revisado por pares (NHESS 2019): 81.9 %, 84.7 % en costa oeste de EE. UU. Son datos de EE. UU., útiles solo como orden de magnitud para Baja California. |
| Banderas verde/amarilla/roja/doble roja/morada | **Verificada** (USLA/ILS). Matiz: la morada indica *plagas marinas* (medusas, rayas), y USLA aclara que **no** es para tiburones; "fauna peligrosa" es una paráfrasis amplia. Doble roja = agua cerrada al público. |
| Límite 200 enterococos/100 ml (Playas Limpias) | **Verificada** (Cofepris, criterio OMS). En el monitoreo de verano 2026 (15 jun-1 jul) 284 de 289 playas fueron aptas y "Playa de Tijuana" aparece entre las 5 no aptas (según prensa; verificar el boletín oficial antes de citarlo). |
| Resultados de laboratorio en 24-48 h | **No verificada de punta a punta.** Solo encontré que el método incuba 24 h; el tiempo de traslado y reporte lo asumí. |
| Hs 2 m con Tp > 14 s peligroso; marea baja y resacas; boyas NDBC/CDIP cada 30 min; temperatura del agua | **No verificadas** (no las busqué). Usadas como supuestos. |
| Cierres largos por el río Tijuana | **No verificada** como cifra; no se usa en ningún cálculo. |

## 6. Pendiente / fuera de alcance de esta entrega
- No hay capa HTTP (cowboy/SSE), `/metrics`, ni `recon`: el sandbox donde construí esto no alcanza hex.pm. `playa_api` es la frontera y `playa_bus` ya emite los eventos que consumiría un handler SSE.
- No hay capturas de Stitch ni de una app real (no hay interfaz en esta entrega), ni release/systemd.
- Los umbrales no están calibrados con datos reales ni con salvavidas locales.
