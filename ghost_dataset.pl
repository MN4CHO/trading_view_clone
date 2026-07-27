#!/usr/bin/perl
# =============================================================================
# extract_ghost_dataset.pl
#
# Extractor de features para el modelo predictivo de "rastros del fantasma"
# (Ghosts_in_swings). Por cada RASTRO (reubicacion del fantasma, detectado
# en 1m via Market::Indicators::GhostSwings) genera UNA fila con:
#
#   - Metadata (ts, timestamp) -- NO se usa para entrenar, solo para
#     validacion en testeo (segun indicacion del profesor).
#   - Contexto base de 1m: atr_1m, volume_1m, ema9_volume_1m.
#   - Por cada temporalidad tf en (1m, 10m, 1h) -- prefijo tf{1m,10m,1h}_:
#       dist_ob, thick_ob, dist_fvg, thick_fvg, dist_bsl, dist_ssl,
#       dist_eqh, dist_eql, dist_bos, dist_choch,
#       dist_sweep, dist_grab, dist_run,
#       dist_fib, dist_vwap, vwap_band1_width, dist_poc, dist_vah, dist_val,
#       dist_supply, thick_supply, dist_demand, thick_demand
#     (todas las distancias en PIP; ver PIP_SIZE mas abajo)
#   - Soportes/Resistencias 4h/Diario/Semanal: dist_daily, dist_4h,
#     dist_weekly (Indicators::DailyLevels).
#   - 4 ETIQUETAS (unico lugar del script que mira al futuro, a proposito):
#       target_3m, target_5m, target_10m, target_15m
#     = cantidad de rastros nuevos del fantasma en la ventana de tiempo
#     real (no velas) inmediatamente posterior a esta aparicion.
#
# WARM-UP: el archivo de ENTRADA se procesa siempre con el contexto historico
# de CONTEXT_CSV (2026_Abril-Junio.csv) precargado por delante (ver
# load_market_with_context) para que zigzag externo / SMC / liquidez no
# arranquen en frio en archivos cortos (ej. el de test, solo 24 dias de
# julio) -- solo se EXPORTAN filas cuyo ts cae dentro del rango propio del
# archivo de entrada (ver primary_ts_bounds). Si el archivo de entrada YA es
# CONTEXT_CSV (caso del train), el contexto se omite (mismo archivo dos
# veces seria redundante) y el comportamiento es identico a antes.
#
# USO:
#   perl extract_ghost_dataset.pl <archivo.csv> <salida.csv>
#   ej: perl extract_ghost_dataset.pl 2026_Abril-Junio.csv dataset_ghosts_train.csv
#       perl extract_ghost_dataset.pl 2026_07_24.csv       dataset_ghosts_test.csv
# =============================================================================

use strict;
use warnings;
use lib '.';
use Time::Moment;

use Market::MarketData;
use Market::Indicators::ATR;
use Market::Indicators::Liquidity;
use Market::Indicators::ZigZag;
use Market::Indicators::SMC_Structures;
use Market::Indicators::GhostSwings;
use Market::Indicators::DailyLevels;
use Market::Indicators::Strategy_Builder;

use constant PIP_SIZE => 0.25;   # tick de NQ1!, ya usado como PRICE_TICK en ChartEngine.pm

# Niveles de Fibonacci -- identicos a Overlays::Fibonacci.pm
use constant RETRACE_LEVELS   => (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);
use constant EXTENSION_LEVELS => (1.272, 1.618);

my ($csv_in, $csv_out) = @ARGV;
die "Uso: perl extract_ghost_dataset.pl <entrada.csv> <salida.csv>\n"
    unless $csv_in && $csv_out;

# =============================================================================
# 1. CARGA de un CSV (formato: time,open,high,low,close,Volume) a un
#    Market::MarketData ya con las temporalidades derivadas construidas.
# =============================================================================

# Archivo de contexto usado para "calentar" cualquier entrada corta (ver
# nota de WARM-UP en la cabecera). Es el mismo dataset de entrenamiento
# (abril-junio), asi que precede cronologicamente a julio sin solaparse.
use constant CONTEXT_CSV => '2026_Abril-Junio.csv';

# primary_ts_bounds: primer y ultimo ts (epoch) de las filas PROPIAS del
# archivo de entrada (sin el contexto) -- define la ventana que se exporta.
sub primary_ts_bounds {
    my ($path) = @_;
    open my $fh, '<', $path or die "No pude abrir '$path': $!\n";
    <$fh>;   # cabecera
    my ($first_ts, $last_ts);
    while (<$fh>) {
        chomp;
        next unless /\S/;
        my ($time_str) = split /,/;
        my $ts = Time::Moment->from_string($time_str)->epoch;
        $first_ts //= $ts;
        $last_ts = $ts;
    }
    close $fh;
    return ($first_ts, $last_ts);
}

# load_market_with_context: identico a load_market, pero precarga CONTEXT_CSV
# (si existe y es distinto del archivo de entrada) ANTES del archivo de
# entrada, con el mismo dedup por ts exacto (el mas nuevo en la lista gana
# cualquier solape) que usan market.pl/dataset.pl. Se usa para $market, los
# 3 pipelines por temporalidad y $daily_md, para que ninguno arranque en
# frio -- ver nota de WARM-UP en la cabecera del script.
sub load_market_with_context {
    my ($primary_path) = @_;
    my @paths = (-f CONTEXT_CSV) ? (CONTEXT_CSV, $primary_path) : ($primary_path);
    @paths = ($primary_path) if @paths == 2 && $paths[0] eq $paths[1];

    my $md = Market::MarketData->new;
    my %by_ts;
    for my $path (@paths) {
        open my $fh, '<', $path or die "No pude abrir '$path': $!\n";
        <$fh>;   # cabecera
        while (<$fh>) {
            chomp;
            my ($time_str, $open, $high, $low, $close, $volume) = split /,/;
            next unless defined $close && $close ne '';
            my $tm = Time::Moment->from_string($time_str);
            $by_ts{ $tm->epoch } = {
                time => $time_str, ts => $tm->epoch,
                open => $open+0, high => $high+0, low => $low+0,
                close => $close+0, volume => $volume+0,
            };
        }
        close $fh;
    }
    $md->add_candle($by_ts{$_}) for sort { $a <=> $b } keys %by_ts;
    $md->build_timeframes;
    return $md;
}

print "Cargando $csv_in (con contexto de ", CONTEXT_CSV, " si aplica) ...\n";
my $market = load_market_with_context($csv_in);
my ($primary_min_ts, $primary_max_ts) = primary_ts_bounds($csv_in);
printf "Ventana exportada: %s -> %s\n",
    Time::Moment->from_epoch($primary_min_ts)->to_string,
    Time::Moment->from_epoch($primary_max_ts)->to_string;
printf "Velas 1m: %d | 10m: %d | 1h: %d\n",
    $market->size,
    scalar(@{ $market->get_data->{'10m'} }),
    scalar(@{ $market->get_data->{'1h'} });

# =============================================================================
# 2. GHOST: corre sobre TODA la serie de 1m (contexto + entrada) de una vez
#    (necesitamos la lista COMPLETA de rastros -- pasado Y futuro -- para
#    poder calcular las etiquetas de conteo futuro en el paso 5). Esto NO es
#    fuga de futuro: es exactamente el mismo principio que ya usa el proyecto
#    para separar "calculo del indicador" de "extraccion del target" -- ver
#    la nota en la cabecera de GhostSwings.pm. Los rastros del periodo de
#    CONTEXTO (si aplica) tambien se detectan aqui para que el conteo de
#    targets y el warm-up de los pipelines sean correctos, pero solo se
#    EXPORTAN los que caen dentro de primary_ts_bounds (ver paso 5).
# =============================================================================
print "Calculando Ghost Swings (1m)...\n";
$market->set_timeframe('1m');
my $ghost_1m = Market::Indicators::GhostSwings->new(length => 50);
for my $i (0 .. $market->size - 1) {
    $ghost_1m->update_at_index($market, $i);
}
my $all_traces = $ghost_1m->get_traces;
printf "Rastros totales detectados: %d\n", scalar(@$all_traces);

# Array crudo de 1m (contexto + entrada), indexado igual que $tr->{index} de
# cada rastro -- lo usa bar_context_features para las ventanas de volatilidad.
my $arr_1m = $market->get_data->{'1m'};

# =============================================================================
# 3. PIPELINES por temporalidad: cada una es un MarketData INDEPENDIENTE
#    (misma fuente de 1m, pero cada objeto fija su propia $tf activa) mas su
#    propio juego de indicadores con estado incremental (cursor propio).
#    Se avanzan en sincronia con el reloj de 1m via _pipeline_catch_up.
# =============================================================================
sub build_pipeline {
    my ($tf, $csv_path) = @_;
    my $md = load_market_with_context($csv_path);   # recarga liviana; simplicidad > compartir estado mutable
    $md->set_timeframe($tf);

    my $atr = Market::Indicators::ATR->new(14);
    my $liq = Market::Indicators::Liquidity->new( atr => $atr, k => 3 );
    my $zz  = Market::Indicators::ZigZag->new(
        int_period => 2, int_tf_mins => 30, ext_length => 150 );
    my $smc = Market::Indicators::SMC_Structures->new(
        zigzag => $zz, atr => $atr, max_age => 50 );

    # Supply/Demand (DIY) -- AUDITADO: revise _calc_supply_demand/_update_zones
    # en Strategy_Builder.pm (zona de origen del impulso validado por ATR(14)
    # + volumen vs SMA, estados active/mitigated/invalidated, sin duplicar
    # zonas activas solapadas). No encontre fuga de futuro ni bug de indices
    # -- es una implementacion DIY consistente consigo misma (el propio
    # modulo documenta que no reclama equivalencia con ningun script
    # protegido, que es justamente lo que pide el punto 10 del PDF: "Indicador
    # DIY"). Se deja integrada sin reservas.
    my $sb = Market::Indicators::Strategy_Builder->new;

    # tf_interval_seconds() de MarketData solo conoce temporalidades
    # DERIVADAS (5m,10m,15m,...); '1m' es la base y no esta en su tabla,
    # asi que hay que resolverla aparte aqui.
    my $interval = ($tf eq '1m') ? 60 : $md->tf_interval_seconds($tf);
    die "No se pudo resolver el intervalo en segundos para tf='$tf'\n"
        unless defined $interval;

    return {
        tf => $tf, md => $md,
        arr => $md->get_data->{$tf},
        interval => $interval,
        cursor => -1,
        atr => $atr, liq => $liq, zz => $zz, smc => $smc, sb => $sb,
    };
}

# -----------------------------------------------------------------------------
# _pipeline_catch_up: alimenta los indicadores de $pl con TODAS las velas de
# su temporalidad que ya estan COMPLETAMENTE CERRADAS respecto a $ts_boundary
# (el ts de la vela de 1m actual). Una vela de tf con apertura en bucket_ts
# esta cerrada cuando su ULTIMA vela 1m constituyente (bucket_ts+interval-60)
# ya fue observada, es decir: bucket_ts + interval <= ts_boundary + 60.
# Este es el UNICO punto del script que decide "hasta donde puede ver" cada
# temporalidad -- analogo a _effective_last_index en MarketData, pero
# generalizado a temporalidades que no son la activa del reloj principal.
# -----------------------------------------------------------------------------
sub pipeline_catch_up {
    my ($pl, $ts_boundary) = @_;
    my $arr = $pl->{arr};
    my $itv = $pl->{interval};

    while ( $pl->{cursor} + 1 <= $#$arr
        && $arr->[ $pl->{cursor} + 1 ]{ts} + $itv <= $ts_boundary + 60 )
    {
        $pl->{cursor}++;
        # CRITICO: Indicators::ZigZag::update_at_index IGNORA el indice que
        # recibe -- usa $md->last_index() internamente (disenado para que
        # Market::Replay controle la frontera via set_replay_boundary en la
        # app real). Sin fijar esta frontera aqui, ZigZag ve TODO el dataset
        # cargado desde la primera llamada (fuga de futuro masiva: un pivote
        # de junio contaminando una fila de abril). Se fija la frontera del
        # MarketData de ESTE pipeline a la vela que se acaba de procesar,
        # exactamente el mismo patron que ya usa Market::Replay.pm.
        $pl->{md}->set_replay_boundary( $arr->[ $pl->{cursor} ]{ts} );
        $pl->{atr}->update_at_index( $pl->{md}, $pl->{cursor} );
        $pl->{liq}->update_at_index( $pl->{md}, $pl->{cursor} );
        $pl->{zz}->update_at_index( $pl->{md}, $pl->{cursor} );
        $pl->{smc}->update_at_index( $pl->{md}, $pl->{cursor} );
        $pl->{sb}->update_at_index( $pl->{md}, $pl->{cursor} );
    }
}

print "Preparando pipelines de 1m / 10m / 1h...\n";
my %PL = (
    '1m'  => build_pipeline('1m',  $csv_in),
    '10m' => build_pipeline('10m', $csv_in),
    '1h'  => build_pipeline('1h',  $csv_in),
);

# DailyLevels: MarketData INDEPENDIENTE (necesita set_replay_boundary por
# fila para no leer los arrays D/4h/W completos -- ver nota de no-fuga-de-
# futuro en la cabecera de Indicators::DailyLevels.pm). Soporta D, 4h y W
# (semanal).
print "Preparando DailyLevels (D/4h/W)...\n";
my $daily_md     = load_market_with_context($csv_in);
my $daily_levels = Market::Indicators::DailyLevels->new;

# =============================================================================
# 4. HELPERS de distancia (adaptados de dataset.pl, ahora devuelven tambien
#    el "espesor" para zonas, y todo ya convertido a PIP).
# =============================================================================
sub to_pip { my ($d) = @_; return defined($d) ? $d / PIP_SIZE : undef; }

# atr_ratio: convierte una distancia YA en PIP a "cuantos ATR de 1m es". Hace
# la feature comparable entre regimenes de volatilidad: 200 pip no significan
# lo mismo en un dia tranquilo que en uno agitado. undef si no hay ATR todavia
# (warm-up de las primeras velas) -- se exporta vacio y el flag has_ del script
# de entrenamiento lo marca como "no habia dato".
sub atr_ratio {
    my ($pip, $atr_pip) = @_;
    return undef unless defined($pip) && defined($atr_pip) && $atr_pip > 0;
    return $pip / $atr_pip;
}

# -----------------------------------------------------------------------------
# ghost_state_features: describe el PROCESO DE RECORDS del que cada rastro es
# un evento (ver el bloque "ESTADO EXPUESTO" en Indicators::GhostSwings). Un
# rastro es "se batio el extremo trackeado desde el ultimo pivote", asi que lo
# que informa sobre cuantos rastros vienen despues es el estado de ese proceso:
# donde quedo el cierre respecto al record nuevo, por cuanto se batio el
# anterior, cuanto aguanto, y cuantos records van en la pierna.
#
# Todo sale de hechos YA OCURRIDOS ($tr y la vela $c del propio rastro): no hay
# fuga de futuro, igual que el resto del extractor.
#
# APERTURA DE PIERNA: el fantasma "aparece" sin batir nada, y ahi prev_price /
# prev_index son undef a proposito (1100 de los 10422 rastros del train). En
# ese caso broke/gap/prev_age valen 0 = "no habia record previo que batir",
# que es un valor con significado real, no un dato faltante.
# -----------------------------------------------------------------------------
sub ghost_state_features {
    my ($tr, $c, $idx, $atr_pip) = @_;
    my %f;

    $f{ghost_track_kind} = ( $tr->{kind} eq 'H' ) ? 1 : -1;

    # Distancia del cierre al record que se acaba de fijar. Es la feature mas
    # predictiva del dataset (corr -0.22 con target_15m): si el precio quedo
    # lejos del extremo que acaba de marcar, vienen MENOS records despues.
    my $wick = to_pip( abs( $tr->{price} - $c->{close} ) );
    $f{ghost_wick}     = $wick;
    $f{ghost_wick_atr} = atr_ratio($wick, $atr_pip);

    # Por cuanto se batio el record anterior (fuerza de la expansion).
    my $broke = defined $tr->{prev_price}
        ? to_pip( abs( $tr->{price} - $tr->{prev_price} ) ) : 0;
    $f{ghost_broke}     = $broke;
    $f{ghost_broke_atr} = atr_ratio($broke, $atr_pip);

    # Donde habia quedado el record ANTERIOR respecto al cierre actual.
    my $gap = defined $tr->{prev_price}
        ? to_pip( abs( $tr->{prev_price} - $c->{close} ) ) : 0;
    $f{ghost_gap_prev}     = $gap;
    $f{ghost_gap_prev_atr} = atr_ratio($gap, $atr_pip);

    # Cuantas velas aguanto el record anterior: en un proceso de records, mas
    # antiguedad del record = menos probable batirlo.
    $f{ghost_prev_age} = defined $tr->{prev_index} ? $idx - $tr->{prev_index} : 0;

    # Profundidad en la pierna actual. OJO: se usan pivot_index/n_in_leg tal
    # como los expone el rastro y NO se deduce la pierna comparando kind entre
    # rastros consecutivos -- dos piernas seguidas PUEDEN compartir kind
    # (verificado: rastro idx=44251 kind=H con pivote 44156, y el siguiente
    # idx=44265 kind=H con pivote 44215).
    $f{ghost_bars_since_pivot} = $idx - $tr->{pivot_index};
    $f{ghost_n_in_leg}         = $tr->{n_in_leg};
    $f{ghost_leg_extent_atr}   = atr_ratio(
        to_pip( abs( $tr->{price} - $tr->{pivot_price} ) ), $atr_pip );

    return \%f;
}

# -----------------------------------------------------------------------------
# bar_context_features: volatilidad realizada y forma de la vela del rastro,
# sobre las ultimas N velas de 1m hasta $idx (nunca mas alla -> sin fuga de
# futuro). Ventanas inclusivas [idx-N, idx].
# -----------------------------------------------------------------------------
sub bar_context_features {
    my ($arr, $idx, $atr_pip) = @_;
    my %f;
    my $c = $arr->[$idx];

    # Desviacion tipica (poblacional) de los cierres en 3 horizontes.
    for my $n (5, 15, 30) {
        my $lo = $idx - $n; $lo = 0 if $lo < 0;
        my ($sum, $cnt) = (0, 0);
        for my $j ($lo .. $idx) { $sum += $arr->[$j]{close}; $cnt++; }
        my $mean = $sum / $cnt;
        my $sq = 0;
        $sq += ( $arr->[$_]{close} - $mean ) ** 2 for $lo .. $idx;
        $f{"rvol$n"} = to_pip( sqrt( $sq / $cnt ) );
    }

    # Rango de las ultimas 15 velas (expansion/contraccion del rango).
    my $lo15 = $idx - 14; $lo15 = 0 if $lo15 < 0;
    my ($hi, $low) = ( $arr->[$lo15]{high}, $arr->[$lo15]{low} );
    for my $j ($lo15 .. $idx) {
        $hi  = $arr->[$j]{high} if $arr->[$j]{high} > $hi;
        $low = $arr->[$j]{low}  if $arr->[$j]{low}  < $low;
    }
    $f{rng15}     = to_pip( $hi - $low );
    $f{rng15_atr} = atr_ratio( $f{rng15}, $atr_pip );

    $f{body_atr}    = atr_ratio( to_pip( abs( $c->{close} - $c->{open} ) ), $atr_pip );
    $f{bar_rng_atr} = atr_ratio( to_pip( $c->{high} - $c->{low} ), $atr_pip );

    # Volumen relativo a su propia media de 20 velas.
    my $lo20 = $idx - 20; $lo20 = 0 if $lo20 < 0;
    my ($vsum, $vcnt) = (0, 0);
    for my $j ($lo20 .. $idx) { $vsum += $arr->[$j]{volume} // 0; $vcnt++; }
    my $vmean = $vsum / $vcnt;
    $f{vol_rel20} = $vmean > 0 ? ( ( $c->{volume} // 0 ) / $vmean ) : undef;

    return \%f;
}

# ts_to_idx: mismo criterio de busqueda binaria que Overlays::ZigZag/Fibonacci
# (_ts_to_active_idx), duplicado aqui a proposito -- mismo patron ya
# establecido en el proyecto de que cada consumidor es autosuficiente.
sub ts_to_idx {
    my ($arr, $ts_target) = @_;
    my ($lo, $hi) = (0, $#$arr);
    return 0 if $hi < 0;
    return 0 if $arr->[0]{ts} > $ts_target;
    return $hi if $arr->[$hi]{ts} <= $ts_target;
    my $found = 0;
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        if ($arr->[$mid]{ts} <= $ts_target) { $found = $mid; $lo = $mid + 1; }
        else { $hi = $mid - 1; }
    }
    return $found;
}

# -----------------------------------------------------------------------------
# fib_distance: replica Overlays::Fibonacci.pm -- proyecta sobre el tramo
# ESTABLE (los DOS ULTIMOS pivotes confirmados del ZigZag externo, segs[-2]
# y segs[-1]), nunca sobre la rama pendiente. Devuelve la distancia en PIP
# al nivel de Fibonacci (retroceso o extension) mas cercano a $avg_price.
# -----------------------------------------------------------------------------
sub fib_distance {
    my ($pl, $avg_price) = @_;
    my $segs = $pl->{zz}->get_segments('external');
    return undef unless $segs && @$segs >= 2;
    my $a = $segs->[-2];
    my $b = $segs->[-1];
    return undef if $a->{price} == $b->{price};

    my $up    = ($b->{kind} eq 'H');
    my $high  = $up ? $b->{price} : $a->{price};
    my $low   = $up ? $a->{price} : $b->{price};
    my $range = $high - $low;
    return undef if $range <= 0;

    my ($best_d, $best_abs);
    for my $p (RETRACE_LEVELS, EXTENSION_LEVELS) {
        my $level = $up ? ($high - $range * $p) : ($low + $range * $p);
        my $d  = $avg_price - $level;
        my $ad = abs($d);
        if (!defined($best_abs) || $ad < $best_abs) { $best_abs = $ad; $best_d = $d; }
    }
    return to_pip($best_d);
}

# -----------------------------------------------------------------------------
# vwap_pivot_distance: VWAP anclado automaticamente al PENULTIMO pivote
# confirmado del ZigZag externo (segs[-2]), corriendo hasta la vela actual
# ($cur_idx). Misma formula que Indicators::AnchoredVWAP::vwap_line (HLC3,
# stdev ponderada por volumen), replicada aqui en vez de instanciar el
# objeto completo porque este necesita un ancla "manual" via clic -- aqui
# el ancla es siempre automatica (el penultimo pivote), sin UI de por medio.
# Devuelve (dist_al_vwap_en_pip, ancho_banda_1sigma_en_pip).
# -----------------------------------------------------------------------------
sub vwap_pivot_distance {
    my ($pl, $avg_price, $cur_idx) = @_;
    my $segs = $pl->{zz}->get_segments('external');
    return (undef, undef) unless $segs && @$segs >= 2;
    my $ai = ts_to_idx($pl->{arr}, $segs->[-2]{ts});
    return (undef, undef) if $ai > $cur_idx;

    my ($pv, $pv2, $v) = (0, 0, 0);
    for my $j ($ai .. $cur_idx) {
        my $c = $pl->{arr}[$j] or next;
        my $vv = $c->{volume} // 0;
        my $sv = ($c->{high} + $c->{low} + $c->{close}) / 3;   # hlc3
        $pv += $sv * $vv; $pv2 += $sv * $sv * $vv; $v += $vv;
    }
    return (undef, undef) unless $v > 0;
    my $vwap = $pv / $v;
    my $var  = ($pv2 / $v) - ($vwap * $vwap); $var = 0 if $var < 0;
    return ( to_pip($avg_price - $vwap), to_pip(sqrt($var)) );
}

# -----------------------------------------------------------------------------
# segment_volume_profile: POC/VAH/VAL sobre el mismo tramo [segs[-2]..actual]
# -- replica el binning + Value Area de Indicators::VolumeProfile.pm
# (_finalize/_value_area), reescrito aqui porque sus modos 'session'/
# 'bos_choch' no cubren "anclado al impulso consolidado del zigzag externo"
# que pide el punto 5 de la especificacion. Devuelve distancias en PIP a
# (POC, VAH, VAL).
# -----------------------------------------------------------------------------
sub segment_volume_profile {
    my ($pl, $avg_price, $cur_idx, $nbins, $va_pct) = @_;
    $nbins  //= 50;
    $va_pct //= 0.70;

    my $segs = $pl->{zz}->get_segments('external');
    return (undef, undef, undef) unless $segs && @$segs >= 2;
    my $ai = ts_to_idx($pl->{arr}, $segs->[-2]{ts});
    return (undef, undef, undef) if $ai > $cur_idx;

    my ($pmin, $pmax) = (9e18, -9e18);
    for my $j ($ai .. $cur_idx) {
        my $c = $pl->{arr}[$j] or next;
        $pmin = $c->{low}  if $c->{low}  < $pmin;
        $pmax = $c->{high} if $c->{high} > $pmax;
    }
    return (undef, undef, undef) if $pmax <= $pmin;

    my $binsize = ($pmax - $pmin) / $nbins;
    my @bins = (0) x $nbins;
    my $total = 0;
    for my $j ($ai .. $cur_idx) {
        my $c = $pl->{arr}[$j] or next;
        next if !defined($c->{volume}) || $c->{volume} <= 0;
        my $blo = int(($c->{low}  - $pmin) / $binsize); $blo = 0 if $blo < 0; $blo = $nbins-1 if $blo > $nbins-1;
        my $bhi = int(($c->{high} - $pmin) / $binsize); $bhi = 0 if $bhi < 0; $bhi = $nbins-1 if $bhi > $nbins-1;
        my $n = $bhi - $blo + 1;
        my $share = $c->{volume} / $n;
        $bins[$_] += $share for $blo .. $bhi;
        $total += $c->{volume};
    }
    return (undef, undef, undef) if $total <= 0;

    my $poc = 0; my $best = $bins[0]; my $mid = ($nbins - 1) / 2;
    for my $b (1 .. $nbins - 1) {
        if ($bins[$b] > $best || ($bins[$b] == $best && abs($b - $mid) < abs($poc - $mid))) {
            $best = $bins[$b]; $poc = $b;
        }
    }
    my ($lo, $hi) = ($poc, $poc);
    my $va = $bins[$poc];
    my $target = $va_pct * $total;
    while ($va < $target && ($lo > 0 || $hi < $nbins - 1)) {
        my $up = ($hi < $nbins - 1) ? $bins[$hi + 1] : -1;
        my $dn = ($lo > 0)          ? $bins[$lo - 1] : -1;
        last if $up < 0 && $dn < 0;
        if ($up >= $dn) { $hi++; $va += $bins[$hi]; }
        else            { $lo--; $va += $bins[$lo]; }
    }

    my $poc_price = $pmin + ($poc + 0.5) * $binsize;
    my $val_price = $pmin + $lo * $binsize;
    my $vah_price = $pmin + ($hi + 1) * $binsize;

    return (
        to_pip($avg_price - $poc_price),
        to_pip($avg_price - $vah_price),
        to_pip($avg_price - $val_price),
    );
}

# Zona con [lo,hi]: devuelve (dist_signed_al_punto_medio, espesor) de la
# zona mas cercana por punto medio. undef si no hay ninguna.
sub nearest_zone {
    my ($price, $items, $lo_key, $hi_key) = @_;
    my ($best_d, $best_abs, $best_thick);
    for my $it (@$items) {
        next unless defined($it->{$lo_key}) && defined($it->{$hi_key});
        my $mid = ( $it->{$lo_key} + $it->{$hi_key} ) / 2;
        my $d   = $price - $mid;
        my $ad  = abs($d);
        if ( !defined($best_abs) || $ad < $best_abs ) {
            $best_abs = $ad; $best_d = $d;
            $best_thick = $it->{$hi_key} - $it->{$lo_key};
        }
    }
    return (undef, undef) unless defined $best_d;
    return ( to_pip($best_d), to_pip($best_thick) );
}

# Lista de precios sueltos (BSL/SSL abiertos): distancia con signo al mas cercano.
sub nearest_price_list {
    my ($price, $prices) = @_;
    my ($best_d, $best_abs);
    for my $p (@$prices) {
        my $d  = $price - $p;
        my $ad = abs($d);
        if ( !defined($best_abs) || $ad < $best_abs ) { $best_abs = $ad; $best_d = $d; }
    }
    return to_pip($best_d);
}

# Eventos (BOS/CHoCH o Sweep/Grab/Run) filtrados por tipo entre los ultimos
# $lookback, distancia con signo al de precio mas cercano.
sub nearest_event_dist {
    my ($price, $events, $type, $lookback) = @_;
    my $n = scalar @$events;
    my $start = $n - $lookback; $start = 0 if $start < 0;
    my @prices = map { $_->{price} } grep { $_->{type} eq $type } @{$events}[$start .. $n-1];
    return nearest_price_list($price, \@prices);
}

# EQH/EQL: distancia con signo al punto medio del PAR (Indicators::Liquidity
# los expone como {kind, points:[{index,ts,price}, {index,ts,price}], price,
# last_index} -- el punto medio de points[0].price/points[1].price representa
# la "zona" del par casi-igual, igual espiritu que el p1/p2 original pero
# adaptado al esquema real de la reescritura de EQH/EQL (paridad LuxAlgo).
sub nearest_equal_dist {
    my ($price, $equals, $kind) = @_;
    my @mids;
    for my $e (@$equals) {
        next unless $e->{kind} eq $kind;
        my $pts = $e->{points};
        next unless $pts && @$pts == 2
                 && defined($pts->[0]{price}) && defined($pts->[1]{price});
        push @mids, ( $pts->[0]{price} + $pts->[1]{price} ) / 2;
    }
    return nearest_price_list($price, \@mids);
}

# -----------------------------------------------------------------------------
# extract_tf_features: dado el pipeline YA sincronizado a $ts_boundary y el
# $avg_price de la vela del fantasma, arma el hashref de columnas prefijadas.
# -----------------------------------------------------------------------------
sub extract_tf_features {
    my ($pl, $avg_price, $cur_idx) = @_;
    my %f;

    my @obs = grep { $_->{state} eq 'active' } @{ $pl->{smc}{_order_blocks} };
    ($f{dist_ob}, $f{thick_ob}) = nearest_zone($avg_price, \@obs, 'zone_low', 'zone_high');

    my @fvgs = grep { $_->{state} eq 'active' && $_->{significant} } @{ $pl->{smc}{_fvgs} };
    ($f{dist_fvg}, $f{thick_fvg}) = nearest_zone($avg_price, \@fvgs, 'bottom', 'top');

    my @bsl = map { $_->{price} }
        grep { $_->{side} eq 'buy'  && $_->{state} ne 'RESOLVED' } @{ $pl->{liq}{_open_level_refs} };
    my @ssl = map { $_->{price} }
        grep { $_->{side} eq 'sell' && $_->{state} ne 'RESOLVED' } @{ $pl->{liq}{_open_level_refs} };
    $f{dist_bsl} = nearest_price_list($avg_price, \@bsl);
    $f{dist_ssl} = nearest_price_list($avg_price, \@ssl);

    $f{dist_eqh} = nearest_equal_dist($avg_price, $pl->{liq}{equals}, 'EQH');
    $f{dist_eql} = nearest_equal_dist($avg_price, $pl->{liq}{equals}, 'EQL');

    $f{dist_bos}   = nearest_event_dist($avg_price, $pl->{smc}{_events}, 'BOS',   50);
    $f{dist_choch} = nearest_event_dist($avg_price, $pl->{smc}{_events}, 'CHoCH', 50);

    $f{dist_sweep} = nearest_event_dist($avg_price, $pl->{liq}{events}, 'SWEEP', 50);
    $f{dist_grab}  = nearest_event_dist($avg_price, $pl->{liq}{events}, 'GRAB',  50);
    $f{dist_run}   = nearest_event_dist($avg_price, $pl->{liq}{events}, 'RUN',   50);

    $f{dist_fib} = fib_distance($pl, $avg_price);
    ($f{dist_vwap}, $f{vwap_band1_width}) = vwap_pivot_distance($pl, $avg_price, $cur_idx);
    ($f{dist_poc}, $f{dist_vah}, $f{dist_val}) = segment_volume_profile($pl, $avg_price, $cur_idx);

    # Supply/Demand (DIY) -- auditado, ver nota en build_pipeline
    my @supply = grep { $_->{state} eq 'active' } @{ $pl->{sb}->get_supply_zones };
    my @demand = grep { $_->{state} eq 'active' } @{ $pl->{sb}->get_demand_zones };
    ($f{dist_supply}, $f{thick_supply}) = nearest_zone($avg_price, \@supply, 'zone_low', 'zone_high');
    ($f{dist_demand}, $f{thick_demand}) = nearest_zone($avg_price, \@demand, 'zone_low', 'zone_high');

    return \%f;
}

# =============================================================================
# 5. ETIQUETAS: para cada rastro (indice $k en $all_traces), contar cuantos
#    rastros NUEVOS ocurren en (ts, ts+180], (ts,ts+300], (ts,ts+600],
#    (ts,ts+900] -- "a partir de la vela siguiente a cada aparicion", en
#    TIEMPO REAL (no conteo de velas), para no distorsionar el conteo si
#    hay un hueco de mercado (mantenimiento diario 16:00-17:00) justo
#    despues de la aparicion. Punteros monotonos (los traces ya vienen
#    ordenados cronologicamente) -> O(n) total en vez de O(n^2).
# =============================================================================
my @WINDOWS_SEC = (180, 300, 600, 900);   # 3, 5, 10, 15 minutos
my @ptr = (0, 0, 0, 0);   # un puntero de avance por ventana

sub compute_targets {
    my ($k) = @_;
    my $ts0 = $all_traces->[$k]{ts};
    my @counts;
    for my $w (0 .. $#WINDOWS_SEC) {
        my $limit = $ts0 + $WINDOWS_SEC[$w];
        $ptr[$w] = $k + 1 if $ptr[$w] < $k + 1;
        while ( $ptr[$w] <= $#$all_traces && $all_traces->[ $ptr[$w] ]{ts} <= $limit ) {
            $ptr[$w]++;
        }
        $counts[$w] = $ptr[$w] - ($k + 1);
    }
    return @counts;
}

# =============================================================================
# 6. LOOP PRINCIPAL: una fila por rastro. Se recorre en orden cronologico
#    (ya lo estan) para poder sincronizar los pipelines de 10m/1h de forma
#    incremental (nunca se retrocede el cursor de ningun pipeline).
# =============================================================================
open my $out, '>', $csv_out or die "No se pudo crear '$csv_out': $!\n";

my @tf_cols = qw(
    dist_ob thick_ob dist_fvg thick_fvg dist_bsl dist_ssl
    dist_eqh dist_eql dist_bos dist_choch dist_sweep dist_grab dist_run
    dist_fib dist_vwap vwap_band1_width dist_poc dist_vah dist_val
    dist_supply thick_supply dist_demand thick_demand
);
# Estado del proceso de records del fantasma (ghost_state_features) y contexto
# de volatilidad/forma de la vela (bar_context_features). Son las columnas
# "adicionales" que autoriza el PDF ("A anadir columnas con informacion
# adicional como ATR de 1 minuto, volumen de 1 minuto, EMA(9) del volumen,
# etc."); ninguna usa fecha/hora/minuto, que el PDF reserva como metadato de
# validacion y prohibe para entrenar.
my @ghost_cols = qw(
    ghost_track_kind ghost_wick ghost_wick_atr ghost_broke ghost_broke_atr
    ghost_gap_prev ghost_gap_prev_atr ghost_prev_age ghost_bars_since_pivot
    ghost_n_in_leg ghost_leg_extent_atr
);
my @bar_cols = qw(
    rvol5 rvol15 rvol30 rng15 rng15_atr body_atr bar_rng_atr vol_rel20
);

my @header = qw(ts timestamp atr_1m volume_1m ema9_volume_1m dist_daily dist_4h dist_weekly);
push @header, @ghost_cols, @bar_cols;
for my $tf (qw(1m 10m 1h)) {
    push @header, "tf${tf}_$_" for @tf_cols;
}
push @header, qw(target_3m target_5m target_10m target_15m);
print $out join(',', @header), "\n";

my $ema9_vol;
my $alpha = 2 / (9 + 1);
my $start_time = time();
my $exported = 0;

for my $k (0 .. $#$all_traces) {
    my $tr  = $all_traces->[$k];
    my $idx = $tr->{index};
    my $ts  = $tr->{ts};
    my $c   = $market->get_candle($idx);   # market sigue en tf='1m'
    next unless $c;

    # --- Filtro de exportacion: los rastros del periodo de CONTEXTO (antes
    #     de primary_ts_bounds) solo sirven para calentar pipelines/EMA/ATR
    #     y para que compute_targets cuente bien -- no se escriben al CSV. ---
    my $in_range = $ts >= $primary_min_ts && $ts <= $primary_max_ts;

    my $avg_price = ( $c->{open} + $c->{high} + $c->{low} + $c->{close} ) / 4;

    # --- Sincronizar los 3 pipelines hasta $ts PRIMERO -- nunca leer nada de
    #     un pipeline antes de sincronizarlo con la vela actual. ---
    pipeline_catch_up($PL{$_}, $ts) for qw(1m 10m 1h);

    # --- Contexto base de 1m (running, sobre TODA la serie hasta $idx) ---
    $ema9_vol = defined($ema9_vol)
        ? ( $c->{volume} * $alpha + $ema9_vol * (1 - $alpha) )
        : $c->{volume};
    my $atr_val_1m = $PL{'1m'}{atr}->get_values->[$idx];   # PL{'1m'} corre 1:1 con $market

    # Fuera de la ventana exportada (periodo de contexto): ya se hizo el
    # trabajo de calentamiento de arriba, no hace falta construir/imprimir
    # la fila.
    next unless $in_range;

    # --- Soportes/Resistencias Daily y 4H (independientes de la TF activa) ---
    $daily_md->set_replay_boundary($ts);
    $daily_levels->update_at_index($daily_md, 0);
    my $lv_d  = $daily_levels->get_level('D');
    my $lv_4h = $daily_levels->get_level('4h');
    my $lv_w  = $daily_levels->get_level('W');
    my $dist_daily  = $lv_d  ? to_pip($avg_price - $lv_d->{level})  : undef;
    my $dist_4h     = $lv_4h ? to_pip($avg_price - $lv_4h->{level}) : undef;
    my $dist_weekly = $lv_w  ? to_pip($avg_price - $lv_w->{level})  : undef;

    my %row = (
        ts => $ts, timestamp => $c->{time},
        atr_1m => $atr_val_1m // '', volume_1m => $c->{volume},
        ema9_volume_1m => $ema9_vol,
        dist_daily => $dist_daily // '', dist_4h => $dist_4h // '',
        dist_weekly => $dist_weekly // '',
    );
    # --- Estado del fantasma + contexto de la vela (columnas adicionales) ---
    my $atr_pip = defined($atr_val_1m) ? to_pip($atr_val_1m) : undef;
    my $gf = ghost_state_features($tr, $c, $idx, $atr_pip);
    my $bf = bar_context_features($arr_1m, $idx, $atr_pip);
    @row{ @ghost_cols } = @{$gf}{ @ghost_cols };
    @row{ @bar_cols }   = @{$bf}{ @bar_cols };

    for my $tf (qw(1m 10m 1h)) {
        my $feat = extract_tf_features($PL{$tf}, $avg_price, $PL{$tf}{cursor});
        $row{"tf${tf}_$_"} = $feat->{$_} for @tf_cols;
    }

    my @targets = compute_targets($k);
    @row{qw(target_3m target_5m target_10m target_15m)} = @targets;

    print $out join(',', map { defined($row{$_}) ? $row{$_} : '' } @header), "\n";
    $exported++;

    if ( $k % 500 == 0 && $k > 0 ) {
        printf STDERR "  ... %d / %d rastros procesados (%.0fs)\n",
            $k, scalar(@$all_traces), time() - $start_time;
    }
}

close $out;

for my $tf (qw(1m 10m 1h)) {
    my @eq = @{ $PL{$tf}{liq}{equals} };
    my %by_kind;
    $by_kind{$_->{kind}}++ for @eq;
    printf STDERR "[$tf] equals totales: %d | EQH: %d | EQL: %d\n",
        scalar(@eq), $by_kind{EQH}//0, $by_kind{EQL}//0;
}

printf "Listo: %s (%d filas exportadas de %d rastros totales) en %.0fs\n",
    $csv_out, $exported, scalar(@$all_traces), time() - $start_time;
