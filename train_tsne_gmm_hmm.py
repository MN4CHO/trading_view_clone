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
#   2) GMM: barre n_components (2..8), elige el mejor por BIC, asigna un
#      "estado de mercado" (cluster) a cada fila.
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
#   - market_states.parquet/.csv   (ts, close, label, gmm_state, hmm_state)
#   - fase_a_resumen.txt           (BIC por K, conteo por estado, matriz de
#                                    transicion del HMM)
# =============================================================================

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from sklearn.manifold import TSNE
from sklearn.mixture import GaussianMixture
from hmmlearn.hmm import GaussianHMM
import warnings

warnings.filterwarnings("ignore")

K_RANGE = range(2, 9)          # candidatos de n_components/n_states a barrer
TSNE_SAMPLE_N = 8000            # subset para el grafico (t-SNE es caro en 112k filas)
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
#    muestra de t-SNE).
# -----------------------------------------------------------------------------
print("Barriendo GMM (BIC) ...")
X_full = X.to_numpy()
bic_scores = {}
best_gmm, best_k, best_bic = None, None, np.inf
for k in K_RANGE:
    gmm = GaussianMixture(n_components=k, covariance_type="full", random_state=RANDOM_STATE)
    gmm.fit(X_full)
    bic = gmm.bic(X_full)
    bic_scores[k] = bic
    print(f"  GMM k={k}: BIC={bic:.1f}")
    if bic < best_bic:
        best_bic, best_gmm, best_k = bic, gmm, k

gmm_states = best_gmm.predict(X_full)
print(f"GMM elegido: k={best_k} (BIC={best_bic:.1f})")

report.append("--- GMM: BIC por numero de estados ---\n")
for k, bic in bic_scores.items():
    marker = "  <- elegido" if k == best_k else ""
    report.append(f"  k={k}: BIC={bic:.1f}{marker}\n")
report.append(f"\nGMM conteo de filas por estado (k={best_k}):\n")
for state, cnt in pd.Series(gmm_states).value_counts().sort_index().items():
    report.append(f"  estado {state}: {cnt} ({cnt/len(X)*100:.2f}%)\n")

# -----------------------------------------------------------------------------
# 3) HMM: mismo numero de estados que el GMM elegido, sobre la serie completa
#    EN ORDEN CRONOLOGICO (ya lo esta -- dataset_ml.csv es una vela de 1m por
#    fila en orden de tiempo).
# -----------------------------------------------------------------------------
print(f"Entrenando HMM (GaussianHMM, {best_k} estados) ...")
hmm = GaussianHMM(n_components=best_k, covariance_type="diag",
                   n_iter=100, random_state=RANDOM_STATE)
hmm.fit(X_full)
hmm_states = hmm.predict(X_full)

report.append(f"\n--- HMM: conteo de filas por estado (n_states={best_k}) ---\n")
for state, cnt in pd.Series(hmm_states).value_counts().sort_index().items():
    report.append(f"  estado {state}: {cnt} ({cnt/len(X)*100:.2f}%)\n")

report.append("\n--- HMM: matriz de transicion (fila=estado actual, col=siguiente) ---\n")
trans = hmm.transmat_
header = "        " + "".join(f"S{j:<8d}" for j in range(best_k))
report.append(header + "\n")
for i in range(best_k):
    row = f"  S{i:<5d}" + "".join(f"{trans[i, j]:<9.3f}" for j in range(best_k))
    report.append(row + "\n")

# -----------------------------------------------------------------------------
# 4) Guardar salidas
# -----------------------------------------------------------------------------
out = labels_df.copy()
out["gmm_state"] = gmm_states
out["hmm_state"] = hmm_states
out.to_parquet("market_states.parquet", index=False)
out.to_csv("market_states.csv", index=False)

with open("fase_a_resumen.txt", "w") as f:
    f.writelines(report)

print("\nListo. Archivos generados:")
print("  - tsne_2d.png            (grafico 2D para la presentacion)")
print("  - market_states.parquet/.csv  (ts, close, label, gmm_state, hmm_state)")
print("  - fase_a_resumen.txt     (BIC, conteos, matriz de transicion)")
