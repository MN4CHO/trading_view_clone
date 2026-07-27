#!/usr/bin/env python3
# =============================================================================
# train_tsne_gmm_hmm.py
#
# Fase A (analisis y limpieza exploratoria) del proyecto: sobre la matriz de
# features ya escalada por preprocess.py (dataset_ml.csv -> una fila = una
# vela de 1m, abril-julio), corre:
#
#   1) t-SNE 2D: proyeccion visual de los vectores de features, coloreada por
#      'label' (SWEEP/GRAB/RUN/none), para mostrar como se agrupan.
#   2) GMM: barre n_components (2..12), elige el mejor por BIC, asigna un
#      "estado de mercado" (cluster) a cada fila. Ademas grafica BIC/AIC vs k
#      para poder ver si hay un codo real o si el minimo cae en el borde del
#      rango probado (diagnostico -- no cambia el criterio de seleccion).
#   3) HMM (GaussianHMM): mismo numero de estados que el GMM elegido, corrido
#      SOBRE LA SERIE EN SU ORDEN CRONOLOGICO ORIGINAL (el dataset ya es una
#      secuencia de velas de 1m, no hace falta reordenar) -- a diferencia del
#      GMM, modela la TRANSICION entre estados en el tiempo.
#
# Los estados de GMM/HMM quedan como material de ANALISIS/PRESENTACION
# (comparar como cada uno "ve" el mercado), no como filtro obligatorio de la
# Fase B (LSTM): no hay necesidad de mezclarlos con dataset_ghosts_train.csv,
# que es un dataset distinto (una fila = una aparicion del fantasma, no una
# vela).
#
# ENTRADA: features_scaled.parquet + labels.parquet (generados por
#          preprocess.py -- correrlo primero si no existen).
# SALIDA:
#   - tsne_2d.png                  (grafico 2D coloreado por label)
#   - bic_aic_vs_k.png             (diagnostico: BIC/AIC vs numero de estados)
#   - market_states.parquet/.csv   (ts, close, label, gmm_state, hmm_state)
#   - fase_a_resumen.txt           (BIC/AIC por K, conteo por estado, matriz
#                                    de transicion del HMM)
# =============================================================================

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from sklearn.manifold import TSNE
from sklearn.mixture import GaussianMixture
from sklearn.metrics import silhouette_score
from hmmlearn.hmm import GaussianHMM
import warnings

warnings.filterwarnings("ignore")

K_RANGE = range(2, 13)          # candidatos de n_components/n_states a barrer
TSNE_SAMPLE_N = 8000            # subset para el grafico (t-SNE es caro en 112k filas)
SILHOUETTE_SAMPLE_N = 5000      # subset para silhouette (necesita distancias par-a-par)
RANDOM_STATE = 42

print("Cargando features_scaled.parquet / labels.parquet ...")
X = pd.read_parquet("features_scaled.parquet")
labels_df = pd.read_parquet("labels.parquet")
assert len(X) == len(labels_df), "features y labels desalineados -- revisa preprocess.py"

report = []
report.append("=== FASE A: t-SNE + GMM + HMM sobre dataset_ml.csv ===\n")
report.append(f"Filas: {len(X)}  |  Features: {X.shape[1]}\n\n")

# -----------------------------------------------------------------------------
# 1) t-SNE 2D (sobre una muestra aleatoria -- 112k puntos son ilegibles en un
#    scatter y t-SNE completo tardaria demasiado; el subsample es practica
#    estandar para visualizacion, no afecta a GMM/HMM que corren sobre todo).
# -----------------------------------------------------------------------------
print(f"Corriendo t-SNE sobre una muestra de {TSNE_SAMPLE_N} filas ...")
rng = np.random.RandomState(RANDOM_STATE)
sample_idx = rng.choice(len(X), size=min(TSNE_SAMPLE_N, len(X)), replace=False)
sample_idx.sort()   # conserva el orden cronologico dentro de la muestra

X_sample = X.iloc[sample_idx].to_numpy()
labels_sample = labels_df["label"].iloc[sample_idx].to_numpy()

tsne = TSNE(n_components=2, perplexity=30, random_state=RANDOM_STATE, init="pca")
X_2d = tsne.fit_transform(X_sample)

fig, ax = plt.subplots(figsize=(9, 7))
palette = {"none": "#b0b0b0", "SWEEP": "#e74c3c", "GRAB": "#3498db", "RUN": "#2ecc71"}
for lbl, color in palette.items():
    mask = labels_sample == lbl
    ax.scatter(X_2d[mask, 0], X_2d[mask, 1], s=6, alpha=0.6, label=lbl, color=color)
ax.set_title("t-SNE de features (dataset_ml.csv) coloreado por etiqueta automatica")
ax.set_xlabel("t-SNE 1")
ax.set_ylabel("t-SNE 2")
ax.legend(markerscale=3)
fig.tight_layout()
fig.savefig("tsne_2d.png", dpi=150)
plt.close(fig)
print("Guardado: tsne_2d.png")

# -----------------------------------------------------------------------------
# 2) GMM: barrido de n_components por BIC (sobre TODA la matriz, no la
#    muestra de t-SNE). Se registra tambien el AIC en el mismo loop (no
#    cuesta nada extra: gmm.aic() reusa el modelo ya entrenado) y se grafica
#    BIC/AIC vs k como diagnostico -- el criterio de seleccion sigue siendo
#    el minimo BIC dentro de K_RANGE, esto solo deja ver si ese minimo es un
#    codo real o si esta pegado al borde del rango probado.
# -----------------------------------------------------------------------------
print("Barriendo GMM (BIC/AIC/silhouette) ...")
X_full = X.to_numpy()

# Submuestra fija para silhouette (misma para los 12 valores de k, asi las
# curvas son comparables entre si -- si cambiara por k, una diferencia de
# silhouette podria deberse a la submuestra y no al k).
sil_rng = np.random.RandomState(RANDOM_STATE)
sil_idx = sil_rng.choice(len(X_full), size=min(SILHOUETTE_SAMPLE_N, len(X_full)), replace=False)
X_sil = X_full[sil_idx]

bic_scores = {}
aic_scores = {}
sil_scores = {}
gmm_models = {}
best_gmm, best_k, best_bic = None, None, np.inf
for k in K_RANGE:
    gmm = GaussianMixture(n_components=k, covariance_type="full", random_state=RANDOM_STATE)
    gmm.fit(X_full)
    gmm_models[k] = gmm
    bic = gmm.bic(X_full)
    aic = gmm.aic(X_full)
    # Silhouette sobre la MISMA submuestra fija, con las etiquetas que el
    # propio gmm le asigna a esos puntos (no hace falta reentrenar).
    sil_labels = gmm.predict(X_sil)
    n_labels_present = len(np.unique(sil_labels))
    if n_labels_present >= 2:
        sil = silhouette_score(X_sil, sil_labels)
    else:
        # Con covarianza full y k alto, a veces un componente no le "gana"
        # ningun punto en la submuestra -- silhouette no esta definido con
        # menos de 2 clusters presentes. Se deja como NaN y se documenta en
        # el reporte en vez de que el script reviente.
        sil = np.nan
    bic_scores[k] = bic
    aic_scores[k] = aic
    sil_scores[k] = sil
    sil_str = f"{sil:.3f}" if not np.isnan(sil) else "N/D (<2 clusters en la submuestra)"
    print(f"  GMM k={k}: BIC={bic:.1f}  AIC={aic:.1f}  silhouette={sil_str}")
    if bic < best_bic:
        best_bic, best_gmm, best_k = bic, gmm, k

gmm_states = best_gmm.predict(X_full)
print(f"GMM elegido (por BIC): k={best_k} (BIC={best_bic:.1f})")
best_k_sil = max((k for k in K_RANGE if not np.isnan(sil_scores[k])), key=lambda k: sil_scores[k])
print(f"k con mejor silhouette: k={best_k_sil} (silhouette={sil_scores[best_k_sil]:.3f})")

# --- Grafico de dos paneles: BIC/AIC vs k (izquierda) y silhouette vs k
#     (derecha) -- en paneles separados porque las escalas no son comparables
#     entre si (BIC/AIC son del orden de millones; silhouette va de -1 a 1). ---
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))
ks = list(K_RANGE)
ax1.plot(ks, [bic_scores[k] for k in ks], marker="o", label="BIC")
ax1.plot(ks, [aic_scores[k] for k in ks], marker="s", label="AIC")
ax1.set_xlabel("k (numero de estados)")
ax1.set_ylabel("Score (menor es mejor)")
ax1.set_title("GMM: BIC / AIC vs k")
ax1.legend()

ax2.plot(ks, [sil_scores[k] for k in ks], marker="o", color="#9b59b6")
ax2.axvline(best_k_sil, color="#9b59b6", linestyle="--", alpha=0.5,
            label=f"mejor: k={best_k_sil}")
ax2.set_xlabel("k (numero de estados)")
ax2.set_ylabel("Silhouette (mayor es mejor, rango -1 a 1)")
ax2.set_title(f"GMM: silhouette vs k (submuestra de {SILHOUETTE_SAMPLE_N})")
ax2.legend()

fig.tight_layout()
fig.savefig("bic_aic_vs_k.png", dpi=150)
plt.close(fig)
print("Guardado: bic_aic_vs_k.png")

report.append("--- GMM: BIC/AIC/silhouette por numero de estados ---\n")
for k in ks:
    marker_bic = " <- min BIC" if k == best_k else ""
    marker_sil = " <- max silhouette" if k == best_k_sil else ""
    sil_str = f"{sil_scores[k]:.3f}" if not np.isnan(sil_scores[k]) else "N/D"
    report.append(f"  k={k}: BIC={bic_scores[k]:.1f}{marker_bic}  "
                   f"AIC={aic_scores[k]:.1f}  silhouette={sil_str}{marker_sil}\n")
report.append(f"\nNota: BIC/AIC eligen k={best_k} (el borde del rango probado, sin codo "
               f"real -- ver bic_aic_vs_k.png). El silhouette, calculado sobre una "
               f"submuestra fija de {SILHOUETTE_SAMPLE_N} filas para que sea comparable "
               f"entre k, favorece k={best_k_sil}. Son criterios distintos (verosimilitud "
               f"penalizada vs. compacidad geometrica) y no tienen por que coincidir; "
               f"el k final para las graficas de la presentacion se decide con este "
               f"contraste en la mano, no automaticamente.\n")
report.append(f"\nGMM conteo de filas por estado (k={best_k}):\n")
for state, cnt in pd.Series(gmm_states).value_counts().sort_index().items():
    report.append(f"  estado {state}: {cnt} ({cnt/len(X)*100:.2f}%)\n")

# -----------------------------------------------------------------------------
# 3) HMM: se corre para LOS DOS candidatos de k (el de BIC y el de silhouette),
#    sobre la serie completa EN ORDEN CRONOLOGICO (ya lo esta -- dataset_ml.csv
#    es una vela de 1m por fila en orden de tiempo). No se elige uno solo aqui
#    -- eso se decide en la presentacion con el contraste completo en mano.
#
#    CONVERGENCIA: hmmlearn a veces imprime "Model is not converging" por una
#    fluctuacion numerica minima del logprob entre iteraciones (no pasa por el
#    modulo warnings, por eso filterwarnings("ignore") no lo tapa). Ese mensaje
#    NO es el criterio real de convergencia -- el criterio real es
#    hmm.monitor_.converged, que se lee explicitamente aqui y se deja escrito
#    en el reporte, en vez de asumir por el mensaje de consola.
# -----------------------------------------------------------------------------
def run_hmm(n_states, label):
    hmm = GaussianHMM(n_components=n_states, covariance_type="diag",
                       n_iter=300, tol=1e-2, random_state=RANDOM_STATE)
    hmm.fit(X_full)
    states = hmm.predict(X_full)
    print(f"HMM ({label}, {n_states} estados): converged={hmm.monitor_.converged}  "
          f"iteraciones usadas={hmm.monitor_.iter}/{hmm.monitor_.n_iter}")

    lines = [f"\n--- HMM ({label}, n_states={n_states}) ---\n"]
    lines.append(f"Convergencia real (hmm.monitor_.converged): {hmm.monitor_.converged}  "
                 f"(iteraciones usadas: {hmm.monitor_.iter}/{hmm.monitor_.n_iter})\n")
    lines.append("Nota: hmmlearn puede imprimir en consola 'Model is not converging' por\n"
                 "una fluctuacion numerica del logprob de magnitud insignificante frente a\n"
                 "su escala (se observo delta ~0.2 sobre logprob de millones); ese mensaje\n"
                 "no es el criterio de convergencia real, que es el reportado arriba.\n")
    lines.append("Conteo de filas por estado:\n")
    for state, cnt in pd.Series(states).value_counts().sort_index().items():
        lines.append(f"  estado {state}: {cnt} ({cnt/len(X)*100:.2f}%)\n")
    lines.append("Matriz de transicion (fila=estado actual, col=siguiente):\n")
    trans = hmm.transmat_
    header_line = "        " + "".join(f"S{j:<8d}" for j in range(n_states))
    lines.append(header_line + "\n")
    for i in range(n_states):
        row = f"  S{i:<5d}" + "".join(f"{trans[i, j]:<9.3f}" for j in range(n_states))
        lines.append(row + "\n")
    return states, lines

print(f"Entrenando HMM para k={best_k} (elegido por BIC) ...")
hmm_states_bic, hmm_report_bic = run_hmm(best_k, "seleccion por BIC")
report.extend(hmm_report_bic)

if best_k_sil != best_k:
    print(f"Entrenando HMM para k={best_k_sil} (elegido por silhouette) ...")
    hmm_states_sil, hmm_report_sil = run_hmm(best_k_sil, "seleccion por silhouette")
    report.extend(hmm_report_sil)
else:
    hmm_states_sil = hmm_states_bic

# -----------------------------------------------------------------------------
# 4) Guardar salidas -- se guardan los estados de AMBOS candidatos de k (BIC y
#    silhouette) para que la comparacion quede lista sin tener que re-correr.
# -----------------------------------------------------------------------------
gmm_states_sil = gmm_models[best_k_sil].predict(X_full) if best_k_sil != best_k else gmm_states

out = labels_df.copy()
out["gmm_state_bic"] = gmm_states       # k=best_k (BIC/AIC, sin codo real)
out["hmm_state_bic"] = hmm_states_bic
out["gmm_state_sil"] = gmm_states_sil   # k=best_k_sil (silhouette, pico claro)
out["hmm_state_sil"] = hmm_states_sil
out.to_parquet("market_states.parquet", index=False)
out.to_csv("market_states.csv", index=False)

with open("fase_a_resumen.txt", "w") as f:
    f.writelines(report)

print("\nListo. Archivos generados:")
print("  - tsne_2d.png            (grafico 2D para la presentacion)")
print("  - bic_aic_vs_k.png       (diagnostico: BIC/AIC/silhouette vs numero de estados)")
print(f"  - market_states.parquet/.csv  (columnas *_bic para k={best_k}, *_sil para k={best_k_sil})")
print("  - fase_a_resumen.txt     (BIC/AIC/silhouette, convergencia HMM, conteos, transiciones)")