#!/usr/bin/perl
# =============================================================================
# train_lstm_ghosts.pl
#
# Fase B del proyecto: LSTM (Perl + AI::MXNet/Gluon) que predice
# target_3m/5m/10m/15m (cantidad de rastros futuros del fantasma) a partir
# de las features que exporta ghost_dataset.pl en dataset_ghosts_train.csv /
# dataset_ghosts_test.csv. Arquitectura calcada del script de referencia del
# curso (LSTM/09_02_02-Concise_Implementation_of_LSTM.pl: standardize +
# make_sequences + LSTM->Dense + Trainer), adaptada de clasificacion binaria
# (softmax, 2 clases) a REGRESION multi-salida (4 targets numericos, salida
# lineal + L2Loss).
#
# ADEMAS (Fases 3 y 4 del plan de mejora, ver PLAN_MEJORA_MODELO_LSTM.md):
#   - Las distancias del PDF se dividen por el ATR de 1m de su propia fila
#     antes de estandarizar (ver is_atr_scaled): en PIP absolutos no son
#     comparables entre regimenes de volatilidad y llegaban a empeorar el MAE
#     respecto a predecir la media.
#   - Los 4 targets se estandarizan para entrenar y la salida se
#     des-estandariza en 'eval', para que L2Loss no reparta el gradiente segun
#     la varianza de cada horizonte (target_15m pesaba ~7x que target_3m).
#   - 'eval' reporta la salida continua Y la version recortada a >=0 y
#     redondeada, porque el redondeo mejora el MAE pero empeora el RMSE.
#
# DESVIACION DELIBERADA de la referencia: la referencia estandariza con
# media/std de train+test COMBINADOS (fuga de test hacia el scaler). Aqui la
# media/std se calculan SOLO con train y se guardan en NORM_FILE para
# reaplicarse tal cual sobre test, tal como pide el PDF de indicaciones
# ("guardar los parametros de normalizacion/estandarizacion para los
# testeos").
#
# NOTA API: en esta instalacion de AI::MXNet (1.6) el alias corto `nd` (de
# `use AI::MXNet qw(mx nd)`) no resuelve al paquete correcto (bug/quirk de
# esta version) -- se usa AI::MXNet::NDArray directo. `mx->...` si funciona
# normalmente. slice() no acepta ':' como en la referencia, usa 'X' (crop
# completo de esa dimension) segun AI::MXNet::NDArray::slice.
#
# USO:
#   perl train_lstm_ghosts.pl train   # entrena con dataset_ghosts_train.csv,
#                                      # guarda MODEL_FILE + NORM_FILE
#   perl train_lstm_ghosts.pl eval    # carga MODEL_FILE + NORM_FILE, evalua
#                                      # sobre dataset_ghosts_test.csv (MAE/
#                                      # RMSE por target vs etiquetado
#                                      # automatico), guarda predicciones
# =============================================================================

use strict;
use warnings;
use lib '.';
use AI::MXNet qw(mx);
$| = 1;
use JSON::PP;

my $ND = 'AI::MXNet::NDArray';

use constant {
    TRAIN_CSV    => 'dataset_ghosts_train.csv',
    TEST_CSV     => 'dataset_ghosts_test.csv',
    MODEL_FILE   => 'lstm_ghosts.params',
    NORM_FILE    => 'lstm_norm_params.json',
    PRED_FILE    => 'lstm_ghosts_predictions.csv',
    SEQ_LEN      => 3,      # antes 5 -- menos parametros de entrada por muestra
    HIDDEN_UNITS => 16,     # antes 32 -- menos capacidad para memorizar ruido
    NUM_EPOCHS   => 60,
    BATCH_SIZE   => 64,
    LEARN_RATE   => 0.001,
    VAL_FRAC     => 0.1,
    PATIENCE     => 10,
    WEIGHT_DECAY => 0.01,   # regularizacion L2 -- nueva
    PIP_SIZE     => 0.25,   # tick de NQ1!, mismo valor que en ghost_dataset.pl
};

my @TARGET_COLS = qw(target_3m target_5m target_10m target_15m);
my @META_COLS   = qw(ts timestamp);
# Estas nunca deberian venir vacias (siempre hay vela 1m con volumen/ATR) --
# se usan tal cual, sin flag has_X.
my @ALWAYS_COLS = qw(atr_1m volume_1m ema9_volume_1m);

my $mode = shift @ARGV // 'train';
die "Uso: perl train_lstm_ghosts.pl [train|eval]\n"
    unless $mode eq 'train' || $mode eq 'eval';

# =============================================================================
# 1. CARGA de CSV -> (\@header, \@rows) -- cada row es un hashref columna=>valor
#    (string, '' si vacio). Mismo formato que exporta ghost_dataset.pl.
# =============================================================================
sub read_csv {
    my ($path) = @_;
    open my $fh, '<', $path or die "No pude abrir '$path': $!\n";
    chomp(my $header_line = <$fh>);
    my @header = split /,/, $header_line, -1;
    my @rows;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my @vals = split /,/, $line, -1;
        my %row;
        @row{@header} = @vals;
        push @rows, \%row;
    }
    close $fh;
    return (\@header, \@rows);
}

# =============================================================================
# 2. Clasificar columnas: metadata / targets / siempre-definidas / "distancia"
#    (dist_*/thick_* -- NaN significa "no habia zona", no dato faltante random).
# =============================================================================
sub dist_cols_from_header {
    my ($header) = @_;
    my %exclude = map { $_ => 1 } (@META_COLS, @TARGET_COLS, @ALWAYS_COLS);
    return [ grep { !$exclude{$_} } @$header ];
}

# =============================================================================
# 3. Imputar: por cada columna "distancia", crear has_<col> (1 si habia dato,
#    0 si no) y rellenar el valor con 0 SOLO despues de fijar el flag -- para
#    que el modelo distinga "distancia 0 real" de "no habia zona" (mismo
#    principio que preprocess.py aplica al otro dataset).
#
#    NORMALIZACION POR ATR (Fase 3 del plan de mejora): las distancias del PDF
#    vienen en PIP absolutos, y en PIP no significan lo mismo en un dia
#    tranquilo que en uno agitado -- por eso, medidas con ridge sobre
#    train=abril-junio / test=julio, EMPEORABAN el MAE respecto a predecir la
#    media (-0.7% en target_15m). Dividiendolas por el ATR de 1m de su propia
#    fila pasan a aportar (+1.1%), y combinadas con las features de estado del
#    fantasma llevan target_15m a +3.4%.
#
#    Se hace aqui y NO en el extractor a proposito: el CSV conserva las
#    columnas en PIP que el PDF exige (es la tabla de features que se
#    presenta), y anadir las variantes normalizadas COMO COLUMNAS NUEVAS
#    duplicaria ~69 features perfectamente colineales, diluyendo la senal.
# =============================================================================

# is_atr_scaled: que columnas se dividen por el ATR. Son las distancias y
# espesores del PDF: dist_daily/dist_4h/dist_weekly y todo el bloque por
# temporalidad (tf1m_/tf10m_/tf1h_, que incluye dist_*, thick_* y
# vwap_band1_width). Las columnas de estado del fantasma y de volatilidad que
# anadio la Fase 2 NO entran: las que lo necesitan ya traen su propia variante
# _atr calculada en el extractor (ghost_wick_atr, rng15_atr, ...).
sub is_atr_scaled { return $_[0] =~ /^(?:dist_|tf)/ ? 1 : 0; }

sub impute_rows {
    my ($rows, $dist_cols) = @_;
    for my $row (@$rows) {
        # ATR de 1m de ESTA fila, expresado en PIP para que el cociente sea
        # "cuantos ATR es esta distancia" (la columna atr_1m viene en unidades
        # de precio; el factor 1/PIP_SIZE es constante y la estandarizacion
        # posterior lo absorberia igual, se hace explicito por claridad).
        my $atr_pip = ( defined($row->{atr_1m}) && $row->{atr_1m} ne ''
                        && $row->{atr_1m} > 0 )
            ? $row->{atr_1m} / PIP_SIZE : undef;

        for my $col (@$dist_cols) {
            my $has = ( defined($row->{$col}) && $row->{$col} ne '' ) ? 1 : 0;
            $row->{"has_$col"} = $has;
            $row->{$col} = $has ? $row->{$col} + 0 : 0;
            $row->{$col} /= $atr_pip
                if $has && defined($atr_pip) && is_atr_scaled($col);
        }
        for my $col (@ALWAYS_COLS) {
            $row->{$col} = ( defined($row->{$col}) && $row->{$col} ne '' ) ? $row->{$col} + 0 : 0;
        }
        for my $col (@TARGET_COLS) {
            $row->{$col} = $row->{$col} + 0;
        }
    }
}

# Orden final y estable de columnas de features (se fija UNA VEZ a partir del
# header de train y se reutiliza igual para test).
sub feature_cols_from_dist {
    my ($dist_cols) = @_;
    my @out = @ALWAYS_COLS;
    for my $col (@$dist_cols) { push @out, $col, "has_$col"; }
    return \@out;
}

# =============================================================================
# 4. Estandarizar (media 0, var 1) -- media/std calculados SOLO sobre las
#    filas que se pasen (train), reaplicados sobre cualquier otro set.
# =============================================================================
sub compute_norm_params {
    my ($rows, $feature_cols) = @_;
    my (%mean, %std);
    my $n = scalar @$rows;
    for my $col (@$feature_cols) {
        my $sum = 0; $sum += $_->{$col} for @$rows;
        my $m = $sum / $n;
        my $sq = 0; $sq += ($_->{$col} - $m)**2 for @$rows;
        my $sd = sqrt($sq / $n);
        $mean{$col} = $m;
        $std{$col}  = $sd > 1e-9 ? $sd : 1;   # evita division por 0 en columnas constantes
    }
    return (\%mean, \%std);
}

sub standardize_rows {
    my ($rows, $feature_cols, $mean, $std) = @_;
    for my $row (@$rows) {
        for my $col (@$feature_cols) {
            $row->{$col} = ( $row->{$col} - $mean->{$col} ) / $std->{$col};
        }
    }
}

sub save_norm_params {
    my ($path, $feature_cols, $mean, $std, $target_mean, $target_std) = @_;
    open my $fh, '>', $path or die "No pude escribir '$path': $!\n";
    print $fh JSON::PP->new->canonical->pretty->encode({
        feature_cols => $feature_cols, mean => $mean, std => $std,
        target_mean => $target_mean, target_std => $target_std,
    });
    close $fh;
}

sub load_norm_params {
    my ($path) = @_;
    open my $fh, '<', $path or die "No pude abrir '$path': $!\n";
    local $/;
    my $data = JSON::PP->new->decode(<$fh>);
    close $fh;
    return ($data->{feature_cols}, $data->{mean}, $data->{std},
            $data->{target_mean}, $data->{target_std});
}

# =============================================================================
# 5. make_sequences: ventana deslizante de SEQ_LEN apariciones consecutivas
#    del fantasma -- predice los 4 targets de la ULTIMA aparicion de la
#    ventana usando las anteriores como contexto temporal (mismo patron que
#    make_sequences() en el script de referencia del curso).
# =============================================================================
sub make_sequences {
    my ($rows, $feature_cols, $seq_len) = @_;
    my $n = scalar @$rows;
    my (@X, @Y);
    for my $end ($seq_len - 1 .. $n - 1) {
        my @seq;
        for my $t ($end - $seq_len + 1 .. $end) {
            push @seq, [ map { $rows->[$t]{$_} } @$feature_cols ];
        }
        push @X, \@seq;
        push @Y, [ map { $rows->[$end]{$_} } @TARGET_COLS ];
    }
    return (\@X, \@Y);
}

# =============================================================================
# 6. Red: LSTM (NTC) -> Dense(4) lineal (sin activacion -- regresion).
# =============================================================================
package LSTMGhosts {
    use AI::MXNet qw(mx);
    use base 'AI::MXNet::Gluon::Block';

    sub new {
        my ($class, %args) = @_;
        my $self = $class->SUPER::new(%args);
        $self->{lstm} = mx->gluon->rnn->LSTM(
            hidden_size => $args{hidden_units}, layout => 'NTC');
        # Dropout entre el LSTM y la capa de salida -- el dataset es chico
        # (~10k filas) y sobreajusta rapido (ver early stopping en modo
        # train); mismo valor (0.2) que usa el script de referencia del
        # curso, aunque alli lo aplica dentro del LSTM (solo tiene efecto con
        # num_layers>1). Aqui se aplica explicitamente como capa aparte,
        # correcta para 1 sola capa de LSTM.
        $self->{drop}  = mx->gluon->nn->Dropout(0.5);   # antes 0.2 -- mas regularizacion
        $self->{dense} = mx->gluon->nn->Dense(units => $args{units}, flatten => 0);
        $self->register_child($self->{$_}) for ('lstm', 'drop', 'dense');
        return bless($self, $class);
    }

    sub forward {
        my ($self, $X) = @_;
        my $H = $self->{lstm}->forward($X);         # [batch, seq_len, hidden]
        $H = $H->slice('X', -1, 'X')->sever;         # ultimo paso: [batch, 1, hidden]
        $H = $H->reshape([0, -1]);                   # -> [batch, hidden]
        $H = $self->{drop}->forward($H);             # no-op fuera de autograd->record
        return $self->{dense}->forward($H);          # -> [batch, 4]
    }
    1;
}

sub mae_rmse {
    my ($pred, $actual) = @_;   # arrayrefs paralelos de numeros
    my $n = scalar @$pred;
    my ($sae, $sse) = (0, 0);
    for my $i (0 .. $n - 1) {
        my $d = $pred->[$i] - $actual->[$i];
        $sae += abs($d);
        $sse += $d * $d;
    }
    return ($sae / $n, sqrt($sse / $n));
}

# =============================================================================
# MODO train
# =============================================================================
if ($mode eq 'train') {
    print "Cargando ", TRAIN_CSV, " ...\n";
    my ($header, $rows) = read_csv(TRAIN_CSV);
    my $dist_cols    = dist_cols_from_header($header);
    my $feature_cols = feature_cols_from_dist($dist_cols);
    impute_rows($rows, $dist_cols);

    # split cronologico train/val (sin barajar -- son series de tiempo)
    my $n_val   = int(@$rows * VAL_FRAC);
    my $n_train = @$rows - $n_val;
    my @train_rows = @$rows[0 .. $n_train - 1];
    my @val_rows   = @$rows[$n_train .. $#$rows];
    printf "Filas: %d (train=%d, val=%d) | Features: %d\n",
        scalar(@$rows), scalar(@train_rows), scalar(@val_rows), scalar(@$feature_cols);

    my ($mean, $std) = compute_norm_params(\@train_rows, $feature_cols);

    # Media/desviacion de cada TARGET, calculadas SOLO con train (mismo
    # principio que la estandarizacion de features, sin fuga de test). Cumplen
    # DOS papeles:
    #
    #   1) Baseline ingenuo para contextualizar el MAE/RMSE en 'eval'
    #      (predecir siempre la media) -- ya estaba antes.
    #
    #   2) ESTANDARIZAR LOS TARGETS para entrenar (Fase 4 del plan de mejora).
    #      Sin esto, L2Loss multi-salida reparte el gradiente en proporcion a
    #      la varianza de cada target -- medidas en train: 1.02 / 1.94 / 4.41 /
    #      7.03 -- asi que target_15m pesaba ~7x mas que target_3m siendo el
    #      MENOS predecible de los cuatro (R2 alcanzable 0.05 vs 0.13). Con los
    #      4 targets estandarizados, los 4 pesan igual en la loss.
    #
    # Consecuencia util: como la media que estandariza ES la del baseline, una
    # prediccion estandarizada de 0 equivale exactamente al baseline ingenuo.
    my ($target_mean, $target_std) = compute_norm_params(\@train_rows, \@TARGET_COLS);

    save_norm_params(NORM_FILE, $feature_cols, $mean, $std, $target_mean, $target_std);
    standardize_rows(\@train_rows, $feature_cols, $mean, $std);
    standardize_rows(\@val_rows,   $feature_cols, $mean, $std);
    standardize_rows(\@train_rows, \@TARGET_COLS, $target_mean, $target_std);
    standardize_rows(\@val_rows,   \@TARGET_COLS, $target_mean, $target_std);
    print "Parametros de normalizacion guardados en ", NORM_FILE, "\n";

    my ($X_train, $Y_train) = make_sequences(\@train_rows, $feature_cols, SEQ_LEN);
    my ($X_val,   $Y_val)   = make_sequences(\@val_rows,   $feature_cols, SEQ_LEN);
    printf "Secuencias: train=%d, val=%d (seq_len=%d)\n",
        scalar(@$X_train), scalar(@$X_val), SEQ_LEN;

    my $X_train_nd = $ND->array($X_train);
    my $Y_train_nd = $ND->array($Y_train);
    my $X_val_nd   = $ND->array($X_val);
    my $Y_val_nd   = $ND->array($Y_val);

    my $net = LSTMGhosts->new(hidden_units => HIDDEN_UNITS, units => scalar(@TARGET_COLS));
    $net->collect_params->initialize(init => mx->init->Xavier(), force_reinit => 1);

    my $train_ds   = mx->gluon->data->ArrayDataset(data => $X_train_nd, label => $Y_train_nd);
    my $train_iter = mx->gluon->data->DataLoader($train_ds, batch_size => BATCH_SIZE,
        shuffle => 1, last_batch => 'discard');

    my $loss    = mx->gluon->loss->L2Loss();
    my $trainer = mx->gluon->Trainer($net->collect_params(),
        optimizer => 'adam',
        optimizer_params => { learning_rate => LEARN_RATE, wd => WEIGHT_DECAY });

    # Early stopping por val_loss: el train_loss baja monotonamente (se ve en
    # los logs) pero el val_loss empieza a SUBIR despues de pocas epocas
    # (sobreajuste) -- guardar solo la epoca 60 a ciegas guardaria un modelo
    # peor que uno mucho mas temprano. Se evalua val_loss TODAS las epocas,
    # se guarda el checkpoint cada vez que mejora, y se corta si no mejora en
    # PATIENCE epocas seguidas.
    print "Entrenando (maximo ", NUM_EPOCHS, " epocas, early stopping paciencia=", PATIENCE, ") ...\n";
    my ($best_val_loss, $best_epoch, $bad_epochs) = (9**9**9, 0, 0);
    for my $epoch (1 .. NUM_EPOCHS) {
        my ($total_loss, $nb) = (0, 0);
        while (my $batch = <$train_iter>) {
            my ($bx, $by) = @$batch;
            my ($yhat, $l);
            mx->autograd->record(sub {
                $yhat = $net->($bx);
                $l    = $loss->($yhat, $by);
            });
            $l->backward();
            $trainer->step($bx->shape->[0]);
            $total_loss += $l->mean->asscalar;
            $nb++;
        }
        my $val_pred = $net->($X_val_nd);
        my $val_loss = $loss->($val_pred, $Y_val_nd)->mean->asscalar;

        if ($val_loss < $best_val_loss) {
            $best_val_loss = $val_loss;
            $best_epoch    = $epoch;
            $bad_epochs    = 0;
            $net->save_parameters(MODEL_FILE);
        } else {
            $bad_epochs++;
        }

        if ($epoch % 5 == 0 || $epoch == 1 || $bad_epochs == 0) {
            printf "  epoca %3d/%d: train_loss=%.4f  val_loss=%.4f%s\n",
                $epoch, NUM_EPOCHS, $total_loss / $nb, $val_loss,
                ($bad_epochs == 0 ? '  <- mejor hasta ahora, guardado' : '');
        }
        if ($bad_epochs >= PATIENCE) {
            printf "Sin mejora en %d epocas -- corte anticipado en epoca %d.\n", PATIENCE, $epoch;
            last;
        }
    }

    printf "Mejor epoca: %d (val_loss=%.4f). Modelo de esa epoca guardado en %s\n",
        $best_epoch, $best_val_loss, MODEL_FILE;
}

# =============================================================================
# MODO eval
# =============================================================================
if ($mode eq 'eval') {
    die "No existe ", MODEL_FILE, " -- corre 'perl train_lstm_ghosts.pl train' primero\n"
        unless -f MODEL_FILE;
    die "No existe ", NORM_FILE, " -- corre 'perl train_lstm_ghosts.pl train' primero\n"
        unless -f NORM_FILE;

    print "Cargando ", TEST_CSV, " ...\n";
    my ($header, $rows) = read_csv(TEST_CSV);
    my $dist_cols = dist_cols_from_header($header);
    impute_rows($rows, $dist_cols);

    my ($feature_cols, $mean, $std, $target_mean, $target_std) = load_norm_params(NORM_FILE);
    standardize_rows($rows, $feature_cols, $mean, $std);
    # OJO: los targets de test se dejan en unidades ORIGINALES (cantidad de
    # rastros). Lo que se des-estandariza es la SALIDA del modelo, para que
    # MAE/RMSE y el CSV de predicciones esten en rastros y no en sigmas.

    my ($X_test, $Y_test) = make_sequences($rows, $feature_cols, SEQ_LEN);
    printf "Secuencias de test: %d (seq_len=%d)\n", scalar(@$X_test), SEQ_LEN;

    my $net = LSTMGhosts->new(hidden_units => HIDDEN_UNITS, units => scalar(@TARGET_COLS));
    $net->load_parameters(MODEL_FILE);

    my $X_test_nd = $ND->array($X_test);
    my $pred_nd   = $net->($X_test_nd);
    my $pred      = $pred_nd->aspdl->unpdl;   # [n][4], EN UNIDADES ESTANDARIZADAS

    open my $out, '>', PRED_FILE or die "No pude escribir '", PRED_FILE, "': $!\n";
    print $out join(',', qw(ts timestamp),
        (map { "pred_$_"    } @TARGET_COLS),   # salida continua, en rastros
        (map { "predint_$_" } @TARGET_COLS),   # recortada a >=0 y redondeada
        @TARGET_COLS), "\n";                   # etiquetado automatico

    my (@pred_by_target, @int_by_target, @actual_by_target);
    for my $i (0 .. $#$X_test) {
        # la fila "objetivo" de la secuencia $i es rows[$i + SEQ_LEN - 1]
        my $row = $rows->[ $i + SEQ_LEN - 1 ];
        my @a = @{ $Y_test->[$i] };
        my (@p, @pi);
        for my $k (0 .. $#TARGET_COLS) {
            my $col = $TARGET_COLS[$k];
            # Des-estandarizar: la red predice sigmas, aqui se vuelve a
            # "cantidad de rastros" con la media/std de train guardadas.
            my $v = $pred->[$i][$k] * $target_std->{$col} + $target_mean->{$col};
            push @p, $v;
            # Version de CONTEO: los rastros son enteros no negativos, asi que
            # recortar a >=0 y redondear es informacion de dominio gratis.
            # Medido (Fase 2 del plan): mejora el MAE ~1-2 pp, pero EMPEORA el
            # error cuadratico en el horizonte corto (R2 de target_3m 0.132 ->
            # 0.005), porque redondear mueve muchas predicciones medias justo
            # al otro lado del entero. Por eso se reportan y guardan LAS DOS y
            # no se sustituye una por otra.
            my $vi = $v < 0 ? 0 : int($v + 0.5);
            push @pi, $vi;
            push @{ $pred_by_target[$k] },   $v;
            push @{ $int_by_target[$k] },    $vi;
            push @{ $actual_by_target[$k] }, $a[$k];
        }
        print $out join(',', $row->{ts}, $row->{timestamp}, @p, @pi, @a), "\n";
    }
    close $out;

    print "\n=== Comparacion vs etiquetado automatico (target_*) ===\n";
    printf "  %-12s %-24s %-24s %-24s\n", '',
        'LSTM (continuo)', 'LSTM (entero >=0)', 'Baseline (promedio train)';
    for my $k (0 .. $#TARGET_COLS) {
        my $col = $TARGET_COLS[$k];
        my ($mae,  $rmse)  = mae_rmse($pred_by_target[$k], $actual_by_target[$k]);
        my ($imae, $irmse) = mae_rmse($int_by_target[$k],  $actual_by_target[$k]);

        # Baseline: predecir SIEMPRE el promedio de train para ese target.
        my $bmean = $target_mean->{$col};
        my @baseline_pred = ($bmean) x scalar(@{ $actual_by_target[$k] });
        my ($bmae, $brmse) = mae_rmse(\@baseline_pred, $actual_by_target[$k]);

        my $imp  = ($bmae > 0) ? (1 - $mae  / $bmae) * 100 : 0;
        my $iimp = ($bmae > 0) ? (1 - $imae / $bmae) * 100 : 0;
        printf "  %-12s MAE=%.3f RMSE=%.3f      MAE=%.3f RMSE=%.3f      MAE=%.3f RMSE=%.3f      (mejora: continuo %.1f%%, entero %.1f%%)\n",
            $col, $mae, $rmse, $imae, $irmse, $bmae, $brmse, $imp, $iimp;
    }

    print "\nPredicciones guardadas en ", PRED_FILE, "\n";
}
