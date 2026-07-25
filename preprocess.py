#!/usr/bin/env python3
# =============================================================================
# preprocess_ml.py
#
# Carga dataset_ml.csv (exportado por dataset.pl), hace limpieza + feature
# engineering minimo, y deja todo listo para t-SNE / GMM / HMM:
#   - Descarta el warm-up inicial (velas sin ATR/estructura aun formada).
#   - Para las columnas de "distancia a zona" (dist_ob, dist_fvg, dist_bsl,
#     dist_ssl, dist_swing_high, dist_swing_low): NaN NO significa "dato
#     faltante" random -- significa "en ese instante no habia ninguna zona
#     activa de ese tipo". Por eso NO se imputa con media/mediana (eso
#     inventaria una distancia falsa); en vez de eso se crea una columna
#     binaria has_X (1 si habia zona, 0 si no) y el NaN se rellena con 0
#     SOLO despues de crear el flag, para que el modelo pueda distinguir
#     "distancia 0 real" de "no habia zona".
#   - Categoricas (session, trend_ext) -> one-hot.
#   - Todo lo numerico -> estandarizado (media 0, var 1) con StandardScaler,
#     obligatorio para que t-SNE y GMM no queden dominados por las columnas
#     de mayor escala (ej. distancias en puntos de precio vs. flags 0/1).
#   - La columna 'label' (SWEEP/GRAB/RUN/none) se separa aparte: NO entra
#     como feature de entrenamiento (los 3 modelos son no supervisados),
#     se guarda solo para colorear graficas y comparar resultados despues.
#
# SALIDA:
#   - features_scaled.parquet  (matriz de features ya lista para modelar)
#   - features_scaled.csv      (misma info, por si prefieres inspeccionarla)
#   - labels.parquet           (timestamp + label real, mismo orden/indice)
#   - reporte_calidad.txt      (nulos por columna, conteo de labels, etc.)
# =============================================================================

import pandas as pd
import numpy as np
from sklearn.preprocessing import StandardScaler
import warnings

warnings.filterwarnings("ignore")

IN_PATH = "dataset_ml.csv"

# -----------------------------------------------------------------------------
# 1. Cargar
# -----------------------------------------------------------------------------
print(f"Cargando {IN_PATH} ...")
df = pd.read_csv(IN_PATH)
print(f"Filas originales: {len(df)}")

# -----------------------------------------------------------------------------
# 2. Reporte de calidad ANTES de tocar nada (para dejar evidencia de que las
#    columnas de tus compañeros -- SMC_Structures/ZigZag -- si estan vivas).
# -----------------------------------------------------------------------------
report_lines = []
report_lines.append("=== REPORTE DE CALIDAD: dataset_ml.csv ===\n")
report_lines.append(f"Filas totales: {len(df)}\n")
report_lines.append(f"Rango de fechas: {df['timestamp'].iloc[0]} -> {df['timestamp'].iloc[-1]}\n\n")

report_lines.append("--- % de nulos por columna ---\n")
null_pct = (df.isna().mean() * 100).round(2).sort_values(ascending=False)
for col, pct in null_pct.items():
    report_lines.append(f"  {col:20s} {pct:6.2f}%\n")

report_lines.append("\n--- Distribucion de 'label' ---\n")
label_counts = df["label"].value_counts()
for lbl, cnt in label_counts.items():
    report_lines.append(f"  {lbl:10s} {cnt:8d}  ({cnt/len(df)*100:.3f}%)\n")

report_lines.append("\n--- Distribucion de 'trend_ext' ---\n")
for val, cnt in df["trend_ext"].value_counts(dropna=False).items():
    report_lines.append(f"  {str(val):10s} {cnt:8d}\n")

# -----------------------------------------------------------------------------
# 3. Descartar warm-up: filas antes de que ATR y zigzag_dir_int tengan
#    valor valido (columna 'atr' NaN al principio, o zigzag_dir_int == 0
#    que es literalmente "sin direccion definida aun" segun ZigZag.pm).
# -----------------------------------------------------------------------------
before = len(df)
df = df[df["atr"].notna()].reset_index(drop=True)
after = len(df)
report_lines.append(f"\nFilas descartadas por warm-up (ATR aun no definido): {before - after}\n")
report_lines.append(f"Filas restantes: {after}\n")

# -----------------------------------------------------------------------------
# 4. Flags de "existe zona" + relleno de distancias
# -----------------------------------------------------------------------------
dist_cols = [
    "dist_swing_high", "dist_swing_low",
    "dist_ob", "dist_fvg", "dist_bsl", "dist_ssl",
]
for col in dist_cols:
    flag_col = f"has_{col.replace('dist_', '')}"
    df[flag_col] = df[col].notna().astype(int)
    df[col] = df[col].fillna(0.0)

# trend_ext: 'bull'/'bear'/NaN (NaN = aun no hubo ningun BOS/CHoCH externo).
# Se codifica como +1/-1/0 en vez de one-hot para no inflar dimensiones por
# una sola columna binaria de tendencia.
df["trend_ext_code"] = df["trend_ext"].map({"bull": 1, "bear": -1}).fillna(0)

# -----------------------------------------------------------------------------
# 5. One-hot de 'session' (categorica real, sin orden implicito)
# -----------------------------------------------------------------------------
session_dummies = pd.get_dummies(df["session"], prefix="session").astype(int)

# -----------------------------------------------------------------------------
# 6. Construir la matriz de features final
# -----------------------------------------------------------------------------
feature_cols = [
    "atr", "volatility_atr", "trend_ext_code", "zigzag_dir_int",
    "dist_swing_high", "dist_swing_low", "dist_ob", "dist_fvg",
    "dist_bsl", "dist_ssl",
    "has_swing_high", "has_swing_low", "has_ob", "has_fvg", "has_bsl", "has_ssl",
    "sweeps_recent_10", "hour",
    "bos_internal", "bos_external", "choch_internal", "choch_external",
]
X = pd.concat([df[feature_cols], session_dummies], axis=1)

report_lines.append(f"\nColumnas de features finales ({X.shape[1]}): {list(X.columns)}\n")

# -----------------------------------------------------------------------------
# 7. Estandarizar (media 0, var 1)
# -----------------------------------------------------------------------------
scaler = StandardScaler()
X_scaled = pd.DataFrame(
    scaler.fit_transform(X),
    columns=X.columns,
    index=X.index,
)

# -----------------------------------------------------------------------------
# 8. Guardar salidas
# -----------------------------------------------------------------------------
X_scaled.to_parquet("features_scaled.parquet", index=False)
X_scaled.to_csv("features_scaled.csv", index=False)

labels_df = df[["ts", "timestamp", "close", "label"]].copy()
labels_df.to_parquet("labels.parquet", index=False)

with open("reporte_calidad.txt", "w") as f:
    f.writelines(report_lines)

print("\nListo. Archivos generados:")
print("  - features_scaled.parquet / .csv  (matriz lista para t-SNE/GMM/HMM)")
print("  - labels.parquet                  (timestamp + close + label real)")
print("  - reporte_calidad.txt             (revisalo antes de seguir)")
print(f"\nShape final de features: {X_scaled.shape}")
