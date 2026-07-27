# Plan de mejora del modelo predictivo (rastros del fantasma)

> **Documento de trabajo y bitácora.** Se creó para que el estado del trabajo
> sobreviva a un reinicio de contexto. Cada fase tiene su estado y su registro
> de lo que realmente se hizo. **Al terminar cada fase hay que actualizar aquí
> mismo el estado y el log.**

- **Rama:** `feature/smc-unified-system`
- **Creado:** 2026-07-26
- **Última actualización:** 2026-07-26
- **Referencia:** `Indicaciones-Proyecto-parte-final_v1.0.pdf`

## Estado general

| Fase | Descripción | Estado |
|---|---|---|
| 0 | Diagnóstico y medición del techo del dataset | ✅ Completada |
| 1 | Exponer el estado del fantasma en `GhostSwings.pm` | ✅ Completada |
| 2 | Nuevas columnas en `ghost_dataset.pl` (+ regenerar CSV) | ✅ Completada |
| 3 | Normalizar distancias por ATR en el entrenamiento | ✅ Completada |
| 4 | Loss y salida correctas para conteos | ✅ Completada |
| 5 | Re-sintonizar la regularización | ✅ Cerrada — hipótesis refutada, sin cambios |
| 6 | Métricas defendibles para la exposición | ✅ Completada |

---

## FASE 0 — Diagnóstico (✅ completada)

### El problema no era el entrenamiento, eran las features

Se evaluó el dataset de forma honesta (entrenar con abril-junio → evaluar julio)
usando **ridge regression** como proxy del techo lineal del dataset. Resultado
con las 75 features actuales (`dist_*`/`thick_*` en PIP):

| Conjunto | Mejora de MAE sobre baseline "predecir la media" | R² en test |
|---|---|---|
| Las 75 features actuales (en PIP) | −0.5% / +0.2% / −2.0% / −3.4% (3m/5m/10m/15m) | −0.01 a −0.11 |

**Las 75 columnas no contienen información sobre el target.** El LSTM no estaba
aprendiendo a "ignorar la basura": colapsaba a predecir la media, que es lo
óptimo cuando no hay señal. Llegar a la época 20 en vez de la 2 **no** era señal
de aprendizaje — la sobre-regularización del commit `d1a90dd`
(`dropout 0.5` + `wd 0.01` + `hidden 16`) hace que converja *más lento* a esa
media, así que el early stopping tarda más en dispararse.

### Causa raíz

En `Market/Indicators/GhostSwings.pm` (`_update_live_tracking`), un **rastro es
un nuevo extremo (récord) desde el último pivote confirmado** — exactamente el
"movimiento hacia afuera del rango actual de precio" del ejemplo del PDF.
Ninguna de las 75 features describe el estado de ese proceso de récords: falta
la dirección que se trackea, la distancia del cierre al extremo actual, la edad
del récord y cuántos récords van en la pierna.

### Lo que sí funciona (medido)

Se replicó el indicador en Python (**10422/10422 rastros idénticos**, validación
exacta) y se probaron 18 features de estado del fantasma + volatilidad:

| Conjunto | Mejora MAE: 3m / 5m / 10m / 15m | R² test (3m) |
|---|---|---|
| 18 features de estado nuevas | **+6.3% / +7.6% / +4.2% / +2.6%** | **+0.132** |
| 75 del PDF normalizadas por ATR (en vez de PIP crudo) | −0.1% / +1.0% / +0.5% / +0.8% | ~0 |
| **75 norm-ATR + 18 nuevas** | **+6.9% / +7.5% / +3.6% / +3.4%** | mejor combinación |

R² train 0.138 vs test 0.132 → **generaliza**, no es sobreajuste. La feature
dominante es `|extremo_nuevo − close| / ATR(14)` (corr −0.22): si el precio
quedó lejos del récord que acaba de marcar, vienen menos récords después.

Otros hallazgos medidos:

- **Las secuencias no aportan nada.** `seq_len` 1, 2, 3 y 5 dan el mismo
  resultado (±0.1 pp). El valor no está en la recurrencia del LSTM. Se mantiene
  el LSTM porque el PDF lo pide, pero no hay que agrandar `SEQ_LEN`.
- **Desbalance de targets:** varianzas 1.02 / 1.94 / 4.41 / 7.03. Con `L2Loss`
  multi-salida sin estandarizar, `target_15m` pesa 7× en el gradiente y es
  justo el menos predecible.
- **Recortar a ≥0 y redondear a entero** da **+1 a +2 pp** de MAE gratis (los
  rastros son conteos, no reales).
- La no-linealidad aporta poco pero existe: expansión cuadrática = +1.4 pp
  sobre el lineal en `target_3m`.

### Descartado tras medirlo (no repetir el intento)

- `log1p(target)`: empeora 10m y 15m (+0.2% vs +2.6% en 15m).
- Descartar el arranque en frío de abril (las primeras 1000-5000 filas, con
  13-29% de columnas vacías): no mejora nada; se pierde más por tener menos
  datos que lo que se gana alineando distribuciones con el test.
- Ampliar `SEQ_LEN`: sin ganancia (ver arriba).

### Cómo reproducir las mediciones

Los scripts de medición se escribieron en el **scratchpad de la sesión**
(efímero, fuera del entregable, según la regla del proyecto de no meter tests en
el repo). Para reconstruirlos:

1. Replicar `GhostSwings` en Python: pivotes con ventana simétrica `length=50`
   (`ta.pivothigh/pivotlow`), alternancia forzada con inserción de pivote
   fantasma, y tracking en vivo del extremo opuesto. Validar que la lista de
   `ts` de rastros coincide 1:1 con `dataset_ghosts_train.csv` (10422 filas).
2. Ridge regression con estandarización calculada solo en train, evaluando en
   `dataset_ghosts_test.csv` (julio, 3242 filas).
3. Baseline de comparación: predecir siempre la media de cada target en train.

---

## Alcance y garantías del plan

**Se toca:** `Market/Indicators/GhostSwings.pm` (solo aditivo), `ghost_dataset.pl`,
`train_lstm_ghosts.pl`.

**No se toca:** ningún otro indicador ni overlay, `market.pl`,
`Market/MarketData.pm`, `Market/Replay.pm`, ni la Fase A completa
(`dataset.pl`, `preprocess.py`, `train_tsne_gmm_hmm.py`, `dataset_ml.csv`).

**Cumplimiento del PDF:**

- Las 75 columnas exigidas (puntos 1-11, en PIP, sobre 1m/10m/1h) se conservan
  tal cual en el CSV: es la "tabla de features" que se presenta.
- Las features nuevas caen bajo *"A añadir columnas con información adicional
  como ATR de 1 minuto, volumen de 1 minuto, EMA(9) del volumen, etc."*.
- Ninguna feature nueva usa fecha/hora/minuto, respetando *"Metadato... no se usa
  para entrenar modelo. Servirá para validar en la fase de testeo"*.
- Ninguna mira al futuro: todas se calculan con velas ≤ índice del rastro.
- Se mantiene el LSTM sin capas convolucionales, como sugiere el PDF.

**Verificado antes de empezar:** el overlay solo lee `{price, ts, kind}` de cada
rastro (`Market/Overlays/GhostSwings.pm:170-197`) y ningún consumidor itera las
claves del hashref, así que **añadir claves al rastro no puede romper el render**.

---

## FASE 1 — Exponer el estado del fantasma

**Estado:** ✅ Completada (2026-07-26)
**Archivo:** `Market/Indicators/GhostSwings.pm` (+34 / −1 líneas)

### Cambios

1. **Contador de pierna:** campo `_leg_trace_count` en `new` y `reset`, puesto a
   0 en `_reset_tracking`, incrementado en `_update_live_tracking`.
2. **Enriquecer el rastro** en `_update_live_tracking`, capturando el estado
   **anterior a la reubicación** antes de sobrescribir `_track_price` /
   `_track_index`:

```perl
push @{ $self->{_traces} }, {
    index => $i, ts => $c->{ts}, price => $candidate_price, kind => $kind,
    prev_price   => $prev_price,          # récord anterior (undef si aparición de pierna)
    prev_index   => $prev_index,          # índice donde se fijó ese récord
    pivot_index  => $self->{_last_pivot}{index},
    pivot_price  => $self->{_last_pivot}{price},
    n_in_leg     => $self->{_leg_trace_count},
};
```

**Riesgo: nulo.** La lógica de detección no cambia (`moved`, `_track_*`,
pivotes, alternancia quedan idénticos).

### Verificación

- La lista de `ts` de los rastros sigue siendo idéntica a la de
  `dataset_ghosts_train.csv` (10422 rastros sobre `2026_Abril-Junio.csv`).
- Las claves nuevas vienen pobladas y son coherentes.
- `perl market.pl` renderiza los rastros igual que antes.

### Log

**Hecho tal como estaba planeado.** Tres cambios, todos aditivos:

1. Campo `_leg_trace_count` en `new` (con comentario que apunta a la nota de
   `_update_live_tracking`), reseteado en `reset` y en `_reset_tracking`.
2. En `_update_live_tracking`, captura de `$prev_price` / `$prev_index`
   **antes** de sobrescribir `_track_price` / `_track_index`, y push del rastro
   con las 5 claves nuevas (`prev_price`, `prev_index`, `pivot_index`,
   `pivot_price`, `n_in_leg`). El contador se incrementa **después** del push,
   así que `n_in_leg` = rastros ya emitidos en la pierna (0 para el primero).
3. Bloque de comentario `ESTADO EXPUESTO` explicando por qué el estado se
   adjunta aquí en vez de reconstruirse desde fuera, y que no rompe la garantía
   de no-fuga-de-futuro.

**Resultados de la verificación** (script `verify_f1.pl` en el scratchpad de la
sesión, ~2 s sobre las 88736 velas de `2026_Abril-Junio.csv`):

| Comprobación | Resultado |
|---|---|
| Rastros detectados | **10422** (idénticos a `dataset_ghosts_train.csv`) |
| `ts` distintos respecto al CSV actual | **0** → detección intacta |
| Incoherencias en las claves nuevas | **0** |
| Aperturas de pierna (`prev_price` undef) | 1100 (= número de piernas) |
| `perl -c` en `GhostSwings.pm`, `Overlays/GhostSwings.pm`, `market.pl` | syntax OK |

Comprobaciones de coherencia que pasaron: el récord siempre se bate en la
dirección correcta (`price > prev_price` si `kind` es H, `<` si es L);
`prev_index < index`; `pivot_index <= index`; en apertura de pierna `prev_price`
y `prev_index` son undef **a la vez** y `n_in_leg` es 0.

**Hallazgo relevante para la Fase 2:** dos piernas consecutivas **pueden
compartir el mismo `kind`** (ejemplo real: rastro idx=44251 kind=H
pivot_idx=44156, y el siguiente idx=44265 kind=H pivot_idx=44215). O sea que la
alternancia H/L de los pivotes **no** implica alternancia del extremo trackeado,
y el límite de pierna **no** se puede inferir desde fuera mirando si `kind`
cambia. Esto confirma que adjuntar el estado dentro del indicador era necesario:
la Fase 2 debe usar `pivot_index` / `n_in_leg` del rastro y **no** intentar
deducir la pierna comparando `kind` entre rastros consecutivos.

**Nota:** el `prev_price` undef en aperturas de pierna es intencional y hay que
tratarlo explícitamente en la Fase 2 (`ghost_broke` = 0 y `ghost_prev_age` = 0
en ese caso, tal como se midió en la Fase 0).

---

## FASE 2 — Nuevas columnas en el extractor

**Estado:** ✅ Completada (2026-07-26)
**Archivos:** `ghost_dataset.pl`, `dataset_ghosts_train.csv`, `dataset_ghosts_test.csv`

### Cambios

1. **Helper `atr_ratio`:** divide una distancia ya en PIP por
   `to_pip($atr_val_1m)`, devolviendo un ratio sin unidades. Guarda contra
   ATR ≤ 0 → `undef`.

2. **Estado del fantasma — 9 columnas** derivadas del rastro enriquecido de la
   Fase 1 (el loop ya tiene `$tr`, `$c`, `$idx`, `$atr_val_1m` disponibles):

| Columna | Definición |
|---|---|
| `ghost_track_kind` | +1 si trackea H, −1 si L |
| `ghost_wick` | \|`price` − `close`\| en PIP |
| `ghost_wick_atr` | ídem / ATR ← **feature dominante (corr −0.22)** |
| `ghost_broke` | \|`price` − `prev_price`\| en PIP (0 si aparición de pierna) |
| `ghost_broke_atr` | ídem / ATR |
| `ghost_prev_age` | `idx` − `prev_index` (velas que aguantó el récord anterior) |
| `ghost_bars_since_pivot` | `idx` − `pivot_index` |
| `ghost_n_in_leg` | récords acumulados en la pierna actual |
| `ghost_leg_extent_atr` | \|`price` − `pivot_price`\| / ATR |

3. **Volatilidad y forma de la barra — 8 columnas**, sobre el array de 1m hasta
   `$idx`: `rvol5`, `rvol15`, `rvol30` (desviación típica de cierres, PIP),
   `rng15` (max high − min low de 15 velas, PIP), `rng15_atr`, `body_atr`
   (\|close−open\|/ATR), `bar_rng_atr` ((high−low)/ATR), `vol_rel20` (volumen /
   media de 20).

   Las tres `rvol` con sumas acumuladas, para no volver O(N·30) — mismo criterio
   de eficiencia que se aplicó a los cuellos O(N²) de la Fase 2 del proyecto.

4. **Añadir los 17 nombres a `@header`** después de `dist_weekly` y antes de los
   bloques `tf*_`, dejando los `target_*` al final.

### Verificación (bloqueante)

Regenerar ambos CSV y confirmar **10422 y 3242 filas**, con lista de `ts` y
valores `target_*` **idénticos** a los actuales. Si cambian, la Fase 1 alteró la
detección y hay que parar.

> **Commitear los CSV actuales antes de sobrescribirlos.**

**Coste:** dos corridas completas de `ghost_dataset.pl` (train y test).

### Log

**Implementado con 3 desviaciones respecto al plan, todas documentadas abajo.**
Resultado: **19 columnas nuevas** (no 17), CSV de **100 columnas** (antes 81).

Cambios en `ghost_dataset.pl`:

1. Helper `atr_ratio` (junto a `to_pip`) — devuelve `undef` si no hay ATR aún
   (warm-up), que se exporta vacío y el flag `has_` del entrenamiento marca
   como "no había dato".
2. `ghost_state_features($tr, $c, $idx, $atr_pip)` — 11 columnas de estado del
   proceso de récords, todas desde el rastro enriquecido de la Fase 1.
3. `bar_context_features($arr, $idx, $atr_pip)` — 8 columnas de volatilidad
   realizada y forma de la vela, ventanas inclusivas `[idx-N, idx]`.
4. `$arr_1m = $market->get_data->{'1m'}` cacheado tras el cálculo de los
   rastros; `@ghost_cols` / `@bar_cols` insertadas en `@header` después de
   `dist_weekly`, dejando los `target_*` al final.

#### Desviaciones respecto al plan

- **`ghost_broke` se desdobló en dos features (de ahí 19 y no 17).** El plan
  definía `ghost_broke` = \|`price` − `prev_price`\| (por cuánto se batió el
  récord), pero lo que realmente se **midió** en la Fase 0 fue
  \|`prev_price` − `close`\| (dónde quedó el récord anterior respecto al cierre).
  Son cosas distintas y solo la segunda estaba validada, así que se exportan las
  dos: `ghost_broke`/`ghost_broke_atr` (definición del plan) y
  `ghost_gap_prev`/`ghost_gap_prev_atr` (la medida validada). Coste: 2 columnas
  de 100, dilución despreciable.
- **Sin sumas acumuladas para las `rvol`.** El plan las pedía para evitar
  O(N·30), pero N son las **filas** (10422), no las velas (88736): el bucle
  directo son ~940k operaciones aritméticas, ruido frente a los 3 pipelines de
  SMC/Liquidez/ZigZag que dominan el tiempo. Se dejó el bucle simple, que es
  menos código y menos superficie de bug. Confirmado: la corrida completa tarda
  **192 s** (train) y **145 s** (test), en línea con lo que ya tardaba.
- **`ghost_bars_since_pivot` tiene mínimo 50, no 0**, porque `pivot_index` es el
  índice del *candidato* `c = i − length` y el pivote se confirma 50 velas
  después. Es correcto y esperado, no un bug.

#### Verificación (script `verify_f2.py` en el scratchpad)

Se generó primero a scratchpad y solo se promovieron los CSV **después** de
pasar todo:

| Comprobación | train | test |
|---|---|---|
| Filas | **10422** ✅ | **3242** ✅ |
| Columnas viejas ausentes | 0 | 0 |
| Columnas viejas con algún valor distinto | **0** | **0** |
| Columnas nuevas presentes / vacías | 19/19, 0.0% | 19/19, 0.0% |

Las 81 columnas originales (`ts`, `timestamp`, los 4 `target_*` y las 75 del
PDF) salieron **byte a byte idénticas** a las anteriores: la Fase 1 no alteró la
detección y el extractor no cambió nada de lo que ya funcionaba.

#### Señal medida sobre los CSV nuevos (ridge, train=abril-junio → test=julio)

| Conjunto | 3m | 5m | 10m | 15m |
|---|---|---|---|---|
| A) 75 del PDF, PIP crudo (estado previo) | +3.4% / R² −0.057 | +1.0% / −0.091 | −0.2% / −0.068 | −0.7% / −0.076 |
| B) 75 del PDF norm-ATR (anticipo Fase 3) | +3.4% / −0.057 | +3.0% / −0.027 | +0.8% / −0.009 | +1.1% / −0.006 |
| C) solo las 19 nuevas | +6.3% / **+0.133** | +7.6% / +0.094 | +4.3% / +0.050 | +2.8% / +0.032 |
| **D) 75 norm-ATR + 19 nuevas** | **+6.6% / +0.132** | **+7.3% / +0.092** | **+3.9% / +0.060** | **+3.4% / +0.049** |

**Todos los criterios de aceptación se cumplen** y reproducen las predicciones
de la Fase 0 casi exactamente (D vs. objetivo: 6.6 ≥ 6, 7.3 ≥ 7, 3.9 ≥ 3.5,
3.4 ≥ 3; R² 0.132 ≥ 0.12, 0.092 ≥ 0.09, 0.060 ≥ 0.04, 0.049 ≥ 0.02).

**Hallazgo para la Fase 4:** el redondeo a entero ≥0 mejora el MAE
(+7.8% / +10.0% / +4.4% / +3.5%) pero **hunde el R²** en el horizonte corto
(3m: 0.132 → **0.005**). O sea que redondear no es gratis: optimiza MAE a costa
del error cuadrático. En la Fase 4 hay que **reportar las dos versiones** y no
dejar la redondeada como única salida.

---

## FASE 3 — Normalizar las distancias por ATR en el entrenamiento

**Estado:** ✅ Completada (2026-07-26)
**Archivo:** `train_lstm_ghosts.pl`, en `impute_rows`

### Cambios

Para cada columna `dist_*`/`thick_*` de los bloques `tf1m_`/`tf10m_`/`tf1h_` y
para `dist_daily`/`dist_4h`/`dist_weekly`: dividir el valor por `atr_1m` de la
fila **antes** de estandarizar (con guarda si `atr_1m` es 0 o vacío). Se
mantienen los flags `has_*` y el resto del flujo intacto.

**Por qué en el entrenamiento y no en el extractor:** en la medición las
columnas norm-ATR **sustituían** a las crudas, no se sumaban. Añadirlas como
columnas nuevas duplicaría 69 features perfectamente colineales y diluiría la
señal. Haciéndolo aquí, el CSV conserva intactas las columnas en PIP que el PDF
exige y no hace falta regenerar datasets.

Convierte features que hoy **dañan** (−3.4% en `target_15m`) en neutras-positivas
(+0.8%); combinado con las nuevas sube `target_15m` de +0.7% a +3.4%. ~6 líneas.

### Log

**Implementado como estaba planeado.** Cambios en `train_lstm_ghosts.pl`:

1. Constante `PIP_SIZE => 0.25` (mismo valor que `ghost_dataset.pl`).
2. `is_atr_scaled($col)` — devuelve cierto para `/^(?:dist_|tf)/`, es decir
   `dist_daily`/`dist_4h`/`dist_weekly` y todo el bloque `tf1m_`/`tf10m_`/`tf1h_`
   (incluye `dist_*`, `thick_*` y `vwap_band1_width`). Las 19 columnas de la
   Fase 2 **no** entran: las que lo necesitan ya traen su propia variante `_atr`
   calculada en el extractor.
3. En `impute_rows`, división por el ATR de 1m de la propia fila, después de
   fijar el flag `has_` y antes de estandarizar.

#### Desviación respecto al plan

Se divide por el ATR **expresado en PIP** (`atr_1m / PIP_SIZE`), no por la
columna `atr_1m` cruda como en la medición de la Fase 0 (la columna viene en
unidades de precio y las distancias en PIP). La diferencia es un **factor
constante 1/0.25 por columna**, que la estandarización posterior absorbe
exactamente: los inputs estandarizados son idénticos. Se eligió la versión con
unidades coherentes para que el cociente signifique de verdad "cuántos ATR es
esta distancia" y no despiste a quien lea el código.

#### Resultado medido (LSTM real, no proxy)

Se corrió train+eval **antes** y **después** del cambio, con los mismos CSV de
la Fase 2, para aislar el efecto:

| | val_loss | 3m | 5m | 10m | 15m |
|---|---|---|---|---|---|
| Fases 1-2 (sin norm-ATR) | 2.1630 (época 12) | +3.2% | +4.6% | +2.6% | +1.3% |
| **+ Fase 3** | **2.0938 (época 6)** | **+3.9%** | **+4.9%** | **+3.8%** | **+2.6%** |

Mejora en los cuatro horizontes. El `val_loss` es comparable entre estas dos
corridas porque en ambas los targets están todavía sin estandarizar.

---

## FASE 4 — Loss y salida correctas para conteos

**Estado:** ✅ Completada (2026-07-26)
**Archivo:** `train_lstm_ghosts.pl`

### Cambios

1. **Estandarizar los targets.** Hoy `L2Loss` recibe 4 targets con varianzas
   1.02 / 1.94 / 4.41 / 7.03: `target_15m` pesa 7× en el gradiente y es el menos
   predecible. Calcular media/std de los 4 targets **solo con train**, aplicarlas
   antes de `make_sequences`, y guardarlas en `lstm_norm_params.json` junto a
   `target_mean` (que ya existe y sigue sirviendo de baseline).
2. **Des-estandarizar en `eval`** antes de calcular MAE/RMSE y antes de escribir
   `lstm_ghosts_predictions.csv`, para que las predicciones queden en unidades de
   "cantidad de rastros" — es lo que se demuestra en la exposición.
3. **Post-proceso de conteo:** recortar a ≥0 y redondear a entero (**+1 a +2 pp**
   medidos). Escribir en el CSV de predicciones la columna cruda y la redondeada.

### Log

**Implementado como estaba planeado.** Cambios en `train_lstm_ghosts.pl`:

1. `compute_norm_params` se reutiliza sobre `@TARGET_COLS` para obtener
   `target_mean` / `target_std` solo con train; ambos se guardan en
   `lstm_norm_params.json` (`save_norm_params` / `load_norm_params` ampliadas).
   `target_mean` cumple **dos papeles a la vez**: media de estandarización y
   baseline ingenuo. Consecuencia elegante: una predicción estandarizada de 0
   equivale exactamente al baseline.
2. `standardize_rows` se aplica también a los targets de train y val. Los
   targets de **test se dejan en unidades originales**; lo que se
   des-estandariza es la salida del modelo.
3. `eval` des-estandariza (`pred * target_std + target_mean`) y produce dos
   salidas: continua y recortada-a-≥0-redondeada. El CSV de predicciones ahora
   trae `pred_*`, `predint_*` y el etiquetado automático.

**Ojo con el `val_loss`:** desde esta fase está en unidades de σ², así que
**no es comparable** con las corridas anteriores a la Fase 4. Solo compara
corridas post-F4 entre sí.

#### Resultado medido

| | val_loss | 3m | 5m | 10m | 15m |
|---|---|---|---|---|---|
| Fase 3 | (escala vieja) | +3.9% | +4.9% | +3.8% | +2.6% |
| **+ Fase 4, salida continua** | **0.5203 (época 13)** | **+5.0%** | **+6.6%** | **+4.4%** | **+3.4%** |
| + Fase 4, salida entera ≥0 | (misma corrida) | +6.8% | +8.7% | +4.9% | +3.3% |

La salida continua **alcanza el techo lineal** que había medido con ridge en la
Fase 2 (+6.6 / +7.3 / +3.9 / +3.4), o sea que el LSTM ya extrae toda la señal
que el dataset tiene disponible de forma lineal.

#### El compromiso del redondeo, confirmado en el modelo real

Lo que la Fase 2 anticipó con ridge se reproduce en el LSTM: redondear **mejora
el MAE pero empeora el RMSE**.

| target_3m | MAE | RMSE |
|---|---|---|
| LSTM continuo | 0.829 | **0.976** |
| LSTM entero ≥0 | **0.813** | 1.034 |
| Baseline (media) | 0.872 | 1.045 |

Nótese que la versión **entera empeora el RMSE hasta casi el nivel del
baseline** (1.034 vs 1.045) aunque su MAE sea el mejor de los tres. Por eso el
script reporta y guarda **las dos** y no sustituye una por otra: cuál usar
depende de si al presentar se penaliza el error medio o el error grande.

---

## FASE 5 — Re-sintonizar la regularización

**Estado:** ✅ Cerrada (2026-07-26) — **hipótesis refutada, sin cambios de código**
**Archivo:** `train_lstm_ghosts.pl` — se verificó y se dejó **como estaba**

### Cambios

`dropout 0.5` / `HIDDEN_UNITS 16` / `WEIGHT_DECAY 0.01` se eligieron para
combatir un sobreajuste a puro ruido. Con señal real están por debajo de la
capacidad necesaria (la expansión cuadrática dio +1.4 pp sobre el lineal).

Barrido corto eligiendo por `val_loss` con el early stopping que ya existe:
`HIDDEN_UNITS` ∈ {16, 32, 64} × `dropout` ∈ {0.1, 0.2} ×
`WEIGHT_DECAY` ∈ {1e-4, 1e-3}. Son 12 corridas de pocos minutos.

**`SEQ_LEN` se queda en 3** (medido: seq_len 1/2/3/5 dan lo mismo).

### Log

> **RESULTADO: hipótesis REFUTADA. Fase cerrada SIN cambios de código.**
> La regularización actual (`hidden=16`, `dropout=0.5`, `wd=0.01`) ya está en el
> óptimo. El razonamiento del plan —"se eligió para combatir ruido, con señal
> real hará falta menos"— era **incorrecto**.

#### Vuelta 1: 12 configuraciones con regularización más débil

`hidden` ∈ {16,32,64} × `dropout` ∈ {0.1,0.2} × `wd` ∈ {1e-4,1e-3}.

| | val_loss |
|---|---|
| Configuración actual (`h16 d0.5 wd0.01`) | **0.5203** |
| Mejor de las 12 (`h16 d0.2 wd1e-4`) | 0.5592 |
| Peor de las 12 (`h64 d0.1 wd1e-4`) | 0.5762 |

**Ninguna de las 12 se acercó.** El eval de la ganadora en julio confirma:
+4.8 / +2.3 / +2.2 / +1.4 %, muy por debajo del +5.0 / +6.6 / +4.4 / +3.4 % de
la configuración actual.

#### Vuelta 2: descartar ruido y explorar hacia regularización más fuerte

Antes de aceptar la conclusión había que descartar dos explicaciones
alternativas.

**(1) ¿Es ruido de inicialización?** Tres repeticiones de la configuración
actual: `0.5234 / 0.5228 / 0.5220` → media **0.5227**, rango **0.0014**. El
ruido entre corridas es ~0.002; la brecha contra la vuelta 1 es ~0.04, o sea
**más de 20× el ruido**. La diferencia es real.

> Nota honesta: la corrida original de la Fase 4 dio 0.5203, *fuera* del rango
> de las 3 repeticiones (0.5220-0.5234). Fue una tirada afortunada. Con 3
> muestras el rango subestima la dispersión real, que está más cerca de ±0.003.
> Cualquier diferencia menor que eso entre configuraciones **no significa nada**.

**(2) ¿Está el óptimo en regularización aún más fuerte, o en otra parte?**

| Configuración | val_loss | ¿distinguible del actual? |
|---|---|---|
| `h16 d0.4 wd0.01` | 0.5206 | no (dentro del ruido) |
| `h8  d0.5 wd0.01` | 0.5208 | no |
| `h16 d0.5 wd0.01` (actual, media de 3) | 0.5227 | — |
| `h16 d0.3 wd0.01` | 0.5231 | no |
| `h32 d0.5 wd0.01` | 0.5233 | no |
| `h16 d0.6 wd0.01` | 0.5238 | no |
| `h16 d0.5 wd0.003` | 0.5303 | **sí, peor** |
| `h16 d0.5 wd0.03` | 0.5321 | **sí, peor** |

#### Qué se aprendió (esto sí importa para la exposición)

- **El `weight_decay` es el hiperparámetro que manda, no el dropout.** Con
  `wd=0.01` fijo, mover el dropout entre 0.3 y 0.6 no cambia nada
  (0.5206-0.5238, todo dentro del ruido). Pero mover el `wd` a 0.003 o a 0.03
  empeora claramente. El mal resultado de la vuelta 1 lo causó el `wd` débil
  (1e-4/1e-3), no el dropout bajo.
- **La capacidad no es la restricción activa.** `hidden` 8 / 16 / 32 dan
  prácticamente lo mismo (0.5208 / 0.5227 / 0.5233). Coherente con el
  diagnóstico de la Fase 0: la señal disponible es pequeña y casi toda lineal,
  así que más neuronas no tienen nada que capturar.
- **No se cambia nada por perseguir ruido.** `h16 d0.4 wd0.01` es nominalmente
  la #1 (0.5206), pero está dentro del ruido de inicialización y su eval en
  julio es indistinguible del actual (+4.7 / +6.4 / +4.3 / +3.4 vs
  +5.0 / +6.6 / +4.4 / +3.4). Cambiar los hiperparámetros para adoptarla sería
  sobreajustar a la partición de validación.

#### Advertencia metodológica

El barrido selecciona por `val_loss` sobre el último 10% de train (finales de
junio), **nunca** sobre julio. Es lo correcto —julio es el test y no debe influir
en la selección— pero implica que la configuración elegida por validación no
tiene por qué ser la mejor en julio. Los números de julio de esta sección se
reportan como *verificación a posteriori*, no como criterio de elección.

---

## FASE 6 — Métricas defendibles para la exposición

**Estado:** ✅ Completada (2026-07-26)
**Archivo:** `train_lstm_ghosts.pl`, modo `eval`

### Cambios

Al bloque de comparación vs etiquetado automático, añadir por target:

- **R²** — dice si el modelo explica varianza o solo replica la media. Es el
  número que delataba el estado anterior.
- **Segundo baseline "persistencia":** repetir el conteo observado en la ventana
  anterior.
- **Exactitud ±1 rastro** — la métrica más legible para la audiencia.

Mantener el baseline de la media que ya está. El número honesto a presentar es
*mejora sobre baseline*, no el MAE absoluto.

### Log

**Implementado como estaba planeado.** Se añadieron a `train_lstm_ghosts.pl`
las funciones `r2`, `hit_rates` y `persistence_preds`, más una segunda tabla en
el modo `eval`.

#### Decisión importante sobre el baseline de persistencia

El plan decía "repetir el conteo observado en la ventana anterior", que admite
dos lecturas, y **solo una es válida**:

- ❌ *Repetir la etiqueta del rastro anterior.* No sirve: la ventana de esa
  etiqueta se extiende hacia el **futuro** de `ts` (los rastros suelen estar a
  60 s y la ventana es de 180-900 s), así que ese baseline estaría mirando datos
  que todavía no existen. Sería un baseline artificialmente fuerte y tramposo.
- ✅ *Contar los rastros ocurridos en `(ts−W, ts]`.* Es causal: solo cuenta
  hechos ya ocurridos en el momento de predecir. Es la lectura implementada.

Limitación conocida y anotada en el código: para las primeras filas del CSV de
test la ventana hacia atrás cae fuera del archivo (los rastros de junio no están
en él), así que su conteo queda subestimado. Afecta como mucho a los rastros de
los primeros 900 s sobre 3240 filas.

#### Resultados (config de la Fase 4, evaluada en julio)

| | R² continuo | R² entero | exacto | ±1 rastro | Persistencia (MAE) | LSTM vs persistencia |
|---|---|---|---|---|---|---|
| `target_3m` | **+0.118** | +0.010 | 31.5% | **87.2%** | 1.033 | +19.8% |
| `target_5m` | +0.081 | +0.062 | 22.5% | 71.5% | 1.511 | +23.7% |
| `target_10m` | +0.062 | +0.042 | 15.6% | 45.9% | 2.445 | +27.5% |
| `target_15m` | +0.054 | +0.036 | 12.4% | 37.1% | 3.105 | +27.9% |

**El R² es la métrica que cierra el diagnóstico de la Fase 0:** antes del plan
estaba entre −0.01 y −0.11 (peor que predecir la media); ahora es positivo en
los cuatro horizontes. El modelo pasó de replicar la media a explicar varianza.

**Aviso para no exagerar en la exposición:** el baseline de persistencia es
**más débil** que el de la media (MAE 1.033 vs 0.872 en 3m), así que ese
"+27.9%" es el número fácil. El número honesto que hay que presentar es la
mejora sobre el baseline de la media, que es el rival duro: **+5.0 / +6.6 /
+4.4 / +3.4 %** (continuo).

El R² de la versión entera vuelve a confirmar el compromiso del redondeo
(+0.010 vs +0.118 en 3m): para R²/RMSE hay que usar la salida continua.

---

## Criterios de aceptación

Umbrales medidos con ridge (techo lineal del dataset). Si tras la Fase 5 el LSTM
queda muy por debajo, el problema es de optimización, no de features.

| Target | MAE vs baseline (antes) | Objetivo | R² objetivo |
|---|---|---|---|
| `target_3m` | −0.5% (peor que la media) | **≥ +6%** | ≥ +0.12 |
| `target_5m` | +0.2% | **≥ +7%** | ≥ +0.09 |
| `target_10m` | −2.0% | **≥ +3.5%** | ≥ +0.04 |
| `target_15m` | −3.4% | **≥ +3%** | ≥ +0.02 |

**Expectativa realista:** el techo del problema es bajo — predecir el conteo
exacto de récords futuros es intrínsecamente ruidoso — pero es la diferencia
entre "el modelo predice la media" y "el modelo predice".

### Cumplimiento final (medido, sin maquillar)

| Target | Objetivo MAE | LSTM continuo | LSTM entero | Objetivo R² | R² continuo |
|---|---|---|---|---|---|
| `target_3m` | ≥ +6% | +5.0% ⚠️ | +6.8% ✅ | ≥ +0.12 | +0.118 ⚠️ |
| `target_5m` | ≥ +7% | +6.6% ⚠️ | +8.7% ✅ | ≥ +0.09 | +0.081 ⚠️ |
| `target_10m` | ≥ +3.5% | +4.4% ✅ | +4.9% ✅ | ≥ +0.04 | +0.062 ✅ |
| `target_15m` | ≥ +3% | +3.4% ✅ | +3.3% ✅ | ≥ +0.02 | +0.054 ✅ |

**Lectura honesta:** con la salida continua, 2 de 4 horizontes cumplen el umbral
y los otros dos (3m y 5m) se quedan **ligeramente por debajo** (5.0 vs 6.0 y 6.6
vs 7.0; R² 0.118 vs 0.120 y 0.081 vs 0.090). Con la salida entera, los cuatro
cumplen el umbral de MAE.

Esto **no es un fallo**: los umbrales eran el techo de una *ridge* ajustada
sobre el mismo test, o sea el mejor caso lineal posible; que el LSTM aterrice
uno o dos puntos por debajo en los horizontes cortos es lo esperable, no un
síntoma de que quede optimización sin hacer. La Fase 5 ya descartó que sea
cuestión de hiperparámetros.

## Rollback

- Commit antes de la Fase 2 (los CSV se sobrescriben).
- Cada fase es independiente y revertible por separado.
- Las Fases 3-6 no tocan datos, solo el script de entrenamiento.

## Nota sobre git

El bloque de `git reset --hard upstream/main` sobre `feature/smc-unified-system`
que circuló en el grupo era seguro en el momento de escribir esto (`d1a90dd` ya
estaba en `upstream/main`, rama con 0 commits por delante). **Si se corre otra
vez después de implementar este plan y antes de mergear, borra el trabajo.**

---

# RESUMEN FINAL — qué se cambió, por qué, y con qué efecto

## El punto de partida

El modelo "no aprendía a predecir". La causa **no** era el entrenamiento: era
que las 75 features del dataset no contenían información sobre el objetivo.
Medido con ridge sobre julio, daban un R² **negativo** (−0.01 a −0.11): peor
que predecir siempre la media. Un modelo que colapsa a la media es el
comportamiento *óptimo* cuando no hay señal, así que no había nada que arreglar
en el LSTM mientras el dataset no cambiara.

El síntoma que se leyó como progreso ("ya llega a la época 20 en vez de la 2")
tampoco lo era: la sobre-regularización del commit `d1a90dd` hace que el modelo
converja **más lento** a esa media, así que el early stopping tarda más en
dispararse. Nada más.

## Las cinco mejoras

### 1. Exponer el estado del proceso de récords (Fase 1)

**Qué:** cada rastro ahora lleva `prev_price`, `prev_index`, `pivot_index`,
`pivot_price` y `n_in_leg`.

**Por qué:** un rastro es *"se batió el extremo trackeado desde el último
pivote"* — un proceso de récords. Lo que informa sobre cuántos récords vienen
después es el estado de ese proceso, y ese estado no se podía reconstruir desde
fuera a partir de `{index, ts, price, kind}`. Se comprobó además que **dos
piernas consecutivas pueden compartir el mismo `kind`**, así que tampoco se
podía deducir la pierna mirando los rastros desde fuera.

**Efecto:** habilitante; sin esto la Fase 2 era imposible.

### 2. Diecinueve features nuevas (Fase 2)

**Qué:** 11 columnas de estado del fantasma y 8 de volatilidad/forma de vela.
La dominante es `ghost_wick_atr` = |récord nuevo − cierre| / ATR (corr −0.22).

**Por qué:** si el precio quedó lejos del extremo que acaba de marcar, vienen
menos récords después. Es la mecánica del indicador convertida en feature.

**Efecto:** de R² −0.01…−0.11 a **+0.13** en `target_3m`. Es **la** mejora; el
resto son refinamientos sobre ella.

### 3. Normalizar las distancias por ATR (Fase 3)

**Qué:** las distancias del PDF se dividen por el ATR de 1m de su propia fila
antes de estandarizar (en el entrenamiento, no en el extractor).

**Por qué:** 200 pip no significan lo mismo en un día tranquilo que en uno
agitado. En PIP absolutos esas columnas llegaban a **empeorar** el MAE.

**Efecto:** `target_15m` de +1.3% a +2.6%. Se hizo en el entrenamiento para que
el CSV conserve las columnas en PIP que el PDF exige, y para no duplicar ~69
features colineales.

### 4. Targets estandarizados y salida en unidades de conteo (Fase 4)

**Qué:** los 4 targets se estandarizan para entrenar, la salida se
des-estandariza en `eval`, y se reportan dos versiones (continua y entera ≥0).

**Por qué:** `L2Loss` multi-salida repartía el gradiente según la varianza de
cada horizonte (1.02 / 1.94 / 4.41 / 7.03), así que `target_15m` pesaba ~7× que
`target_3m` **siendo el menos predecible de los cuatro**.

**Efecto:** +5.0 / +6.6 / +4.4 / +3.4 % (continuo). Es donde el modelo alcanza
prácticamente el techo lineal del dataset.

### 5. Métricas que permiten defender el resultado (Fase 6)

**Qué:** R², baseline de persistencia causal, y exactitud exacta / ±1 rastro.

**Por qué:** el MAE absoluto no dice si el modelo aprendió. El R² sí: es la
métrica que delataba el estado anterior (negativo) y la que demuestra el actual
(positivo en los cuatro horizontes).

## Lo que se decidió NO cambiar (y por qué)

Tan importante como lo anterior, porque evita que alguien lo reintente:

| Idea | Veredicto | Motivo medido |
|---|---|---|
| Bajar la regularización (Fase 5) | **Rechazada** | 22 entrenamientos: `wd=0.01` está en el óptimo; debilitarlo cuesta ~0.04 de `val_loss`, 20× el ruido entre corridas |
| Ampliar `SEQ_LEN` | Rechazada | `seq_len` 1/2/3/5 dan lo mismo (±0.1 pp): la recurrencia no aporta aquí |
| Más neuronas (`hidden` 32/64) | Rechazada | `hidden` 8/16/32 dan lo mismo: la capacidad no es la restricción activa |
| `log1p(target)` | Rechazada | Empeora 10m y 15m |
| Descartar el arranque en frío de abril | Rechazada | Se pierde más por tener menos datos que lo que se gana alineando distribuciones |
| Adoptar `h16 d0.4 wd0.01` (nominalmente #1) | Rechazada | Dentro del ruido de inicialización; adoptarla sería sobreajustar a la partición de validación |

## Qué presentar (y qué no)

- **El número honesto es la mejora sobre el baseline de la media:**
  **+5.0 / +6.6 / +4.4 / +3.4 %** (continuo) o **+6.8 / +8.7 / +4.9 / +3.3 %**
  (entero). Ese baseline es el rival duro.
- **No** presentar el "+27.9% sobre persistencia" como titular: ese baseline es
  más débil que el de la media (MAE 3.105 vs 2.316), así que es el número fácil.
- **El más legible para la audiencia:** acierta el número exacto de rastros el
  **31.5%** de las veces a 3 minutos, y se queda a ±1 rastro el **87.2%**.
- **Ser explícito con el techo:** predecir el conteo exacto de récords futuros
  es intrínsecamente ruidoso. Un R² de 0.118 es pequeño en absoluto, pero es la
  diferencia entre un modelo que replica la media y uno que predice.

---

# CÓMO COMPROBAR TODO ESTO

Los comandos se ejecutan desde la raíz del proyecto
(`/home/estudiante/Documents/IAA/trading_view_clone`).

## 1. Que nada se rompió (30 segundos)

```bash
perl -c -I. Market/Indicators/GhostSwings.pm
perl -c -I. Market/Overlays/GhostSwings.pm
perl -c -I. market.pl
perl -c -I. ghost_dataset.pl
perl -c -I. train_lstm_ghosts.pl
```

Los cinco deben decir `syntax OK`. Después, `perl market.pl` debe renderizar los
rastros del fantasma igual que antes (la Fase 1 solo **añadió** claves al
hashref; el overlay lee únicamente `price`/`ts`/`kind`).

## 2. Que el dataset es reproducible y no se alteró lo anterior (~6 minutos)

```bash
cp dataset_ghosts_train.csv /tmp/ref_train.csv
cp dataset_ghosts_test.csv  /tmp/ref_test.csv
perl ghost_dataset.pl 2026_Abril-Junio.csv dataset_ghosts_train.csv
perl ghost_dataset.pl 2026_07_24.csv       dataset_ghosts_test.csv
diff /tmp/ref_train.csv dataset_ghosts_train.csv && echo "train reproducible"
diff /tmp/ref_test.csv  dataset_ghosts_test.csv  && echo "test reproducible"
```

Debe salir **10422** filas en train y **3242** en test (más la cabecera), 100
columnas, y los `diff` vacíos.

Para comprobar que las **81 columnas originales** siguen intactas respecto al
estado anterior al plan:

```bash
git show 4b3581a:dataset_ghosts_train.csv > /tmp/viejo_train.csv
python3 -c "
import csv
v=list(csv.DictReader(open('/tmp/viejo_train.csv')))
n=list(csv.DictReader(open('dataset_ghosts_train.csv')))
cols=[c for c in v[0]]
print('filas', len(v), len(n))
print('columnas viejas con algun valor distinto:',
      sum(1 for c in cols if any(a[c]!=b[c] for a,b in zip(v,n))))
"
```

Debe imprimir `10422 10422` y **0** columnas distintas.

## 3. Que no hay fuga de futuro

Las tres garantías, verificables leyendo el código:

- `Market/Indicators/GhostSwings.pm` — las claves añadidas en
  `_update_live_tracking` se capturan **antes** de sobrescribir el récord y solo
  contienen hechos ya ocurridos.
- `ghost_dataset.pl` — `ghost_state_features` y `bar_context_features` solo
  reciben `$idx` y leen índices `≤ $idx`; `pipeline_catch_up` sigue siendo el
  único punto que decide hasta dónde ve cada temporalidad.
- `train_lstm_ghosts.pl` — media/std de features **y** de targets se calculan
  solo con `@train_rows` y se guardan en `lstm_norm_params.json`; el test las
  reaplica sin recalcular.

Comprobación empírica del último punto:

```bash
grep -n "compute_norm_params" train_lstm_ghosts.pl
```

Ambas llamadas deben recibir `\@train_rows`, nunca las filas de test.

## 4. Que el modelo entrena y rinde lo documentado (~4 minutos)

```bash
perl train_lstm_ghosts.pl train
perl train_lstm_ghosts.pl eval
```

Valores esperados (con `hidden=16`, `dropout=0.5`, `wd=0.01`, `SEQ_LEN=3`):

- **`val_loss` de la mejor época: ~0.520-0.524.** Si sale ~2.1, los targets no
  se están estandarizando (Fase 4 rota). Si sale ~0.56, la regularización se
  cambió.
- **Mejora sobre el baseline de la media (continuo):** ~+5% / +6.6% / +4.4% /
  +3.4%. Hay ±0.3 pp de variación entre corridas por la inicialización.
- **R² continuo:** positivo en los cuatro horizontes (~+0.118 / +0.081 / +0.062
  / +0.054). **Si algún R² sale negativo, algo se rompió**: es la señal de que
  el modelo volvió a replicar la media.
- **±1 rastro:** ~87% a 3 minutos.

## 5. Que el techo del dataset es el que se dice (opcional, ~2 minutos)

Reconstruir la medición con ridge (script en scratchpad, efímero): entrenar una
ridge sobre `dataset_ghosts_train.csv` estandarizando solo con train, evaluar en
`dataset_ghosts_test.csv`, y comparar contra predecir la media de train. Debe
dar ~+6.6 / +7.3 / +3.9 / +3.4 % de mejora de MAE. Ese es el techo lineal; el
LSTM debe aterrizar cerca, no muy por encima (si lo supera con holgura, revisar
que no haya fuga).

## 6. Historial de commits

```bash
git log --oneline d1a90dd..HEAD
```

| Commit | Contenido |
|---|---|
| `4b3581a` | Fase 1 — estado del proceso de récords en cada rastro |
| `6c4aa61` | Fase 2 — 19 features nuevas + CSV regenerados |
| `b982aaa` | Fases 3 y 4 — normalización por ATR y targets estandarizados |
| `5cff3ba` | Fase 5 — cierre sin cambios, hipótesis refutada |
| `d096e86` | Fase 6 — R², persistencia, exactitud ±1 |
