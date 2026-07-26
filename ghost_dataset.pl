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
#       dist_sweep, dist_grab, dist_run
#     (todas las distancias en PIP; ver PIP_SIZE mas abajo)
#     [PENDIENTE: dist_fib, dist_vwap_upper/lower, dist_poc/vah/val,
#      dist_supply, dist_demand -- requieren ver el codigo fuente de
#      AnchoredVWAP.pm / AnchoredProfile.pm / Fibonacci / Supply-Demand
#      DIY / Soportes-Resistencias 4h-D-W antes de integrarlos]
#   - 4 ETIQUETAS (unico lugar del script que mira al futuro, a proposito):
#       target_3m, target_5m, target_10m, target_15m
#     = cantidad de rastros nuevos del fantasma en la ventana de tiempo
#     real (no velas) inmediatamente posterior a esta aparicion.
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
sub load_market {
    my ($path) = @_;
    my $md = Market::MarketData->new;

    open my $fh, '<', $path or die "No pude abrir '$path': $!\n";
    <$fh>;   # cabecera
    while (<$fh>) {
        chomp;
        my ($time_str, $open, $high, $low, $close, $volume) = split /,/;
        next unless defined $close && $close ne '';
        my $tm = Time::Moment->from_string($time_str);
        $md->add_candle({
            time => $time_str, ts => $tm->epoch,
            open => $open+0, high => $high+0, low => $low+0,
            close => $close+0, volume => $volume+0,
        });
    }
    close $fh;
    $md->build_timeframes;
    return $md;
}

print "Cargando $csv_in ...\n";
my $market = load_market($csv_in);
printf "Velas 1m: %d | 10m: %d | 1h: %d\n",
    $market->size,
    scalar(@{ $market->get_data->{'10m'} }),
    scalar(@{ $market->get_data->{'1h'} });

# =============================================================================
# 2. GHOST: corre sobre TODA la serie de 1m de una vez (necesitamos la lista
#    COMPLETA de rastros -- pasado Y futuro -- para poder calcular las
#    etiquetas de conteo futuro en el paso 5). Esto NO es fuga de futuro: es
#    exactamente el mismo principio que ya usa el proyecto para separar
#    "calculo del indicador" de "extraccion del target" -- ver la nota en
#    la cabecera de GhostSwings.pm.
# =============================================================================
print "Calculando Ghost Swings (1m)...\n";
$market->set_timeframe('1m');
my $ghost_1m = Market::Indicators::GhostSwings->new(length => 50);
for my $i (0 .. $market->size - 1) {
    $ghost_1m->update_at_index($market, $i);
}
my $all_traces = $ghost_1m->get_traces;
printf "Rastros totales detectados: %d\n", scalar(@$all_traces);

# =============================================================================
# 3. PIPELINES por temporalidad: cada una es un MarketData INDEPENDIENTE
#    (misma fuente de 1m, pero cada objeto fija su propia $tf activa) mas su
#    propio juego de indicadores con estado incremental (cursor propio).
#    Se avanzan en sincronia con el reloj de 1m via _pipeline_catch_up.
# =============================================================================
sub build_pipeline {
    my ($tf, $csv_path) = @_;
    my $md = load_market($csv_path);   # recarga liviana; simplicidad > compartir estado mutable
    $md->set_timeframe($tf);

    my $atr = Market::Indicators::ATR->new(14);
    my $liq = Market::Indicators::Liquidity->new( atr => $atr, k => 3 );
    my $zz  = Market::Indicators::ZigZag->new(
        int_period => 2, int_tf_mins => 30, ext_length => 150 );
    my $smc = Market::Indicators::SMC_Structures->new(
        zigzag => $zz, atr => $atr, max_age => 50 );

    # Supply/Demand (DIY) -- [PENDIENTE VALIDACION]: el usuario reporta que
    # este modulo puede no estar correctamente implementado (sus companeros
    # lo van a revisar). Se integra igual para no bloquear el resto del
    # pipeline, pero esta columna debe re-verificarse antes de usarse para
    # entrenar el modelo final.
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
# fila para no leer los arrays D/4h completos -- ver nota de no-fuga-de-
# futuro en la cabecera de Indicators::DailyLevels.pm). Soporta D y 4h;
# SEMANAL NO esta implementado en ese modulo todavia (pendiente de agregar
# por el equipo) -- dist_weekly queda fuera del dataset por ahora.
print "Preparando DailyLevels (D/4h)...\n";
my $daily_md     = load_market($csv_in);
my $daily_levels = Market::Indicators::DailyLevels->new;

# =============================================================================
# 4. HELPERS de distancia (adaptados de dataset.pl, ahora devuelven tambien
#    el "espesor" para zonas, y todo ya convertido a PIP).
# =============================================================================
sub to_pip { my ($d) = @_; return defined($d) ? $d / PIP_SIZE : undef; }

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

# EQH/EQL: distancia con signo al punto medio del par igual mas cercano de ese kind.
# Blindado contra entradas con p1/p2 indefinidos (no deberia pasar segun
# Liquidity.pm, pero se descartan en vez de propagar undef -- y se avisa
# una sola vez por corrida para poder diagnosticar la causa real si se repite).
my $warned_bad_equal = 0;
sub nearest_equal_dist {
    my ($price, $equals, $kind) = @_;
    my @mids;
    for my $e (@$equals) {
        next unless $e->{kind} eq $kind;
        if ( !defined($e->{p1}) || !defined($e->{p2}) ) {
            unless ($warned_bad_equal) {
                warn "AVISO: entrada 'equals' con p1/p2 indefinido -- kind=$e->{kind} i1=" .
                     (defined($e->{i1}) ? $e->{i1} : 'undef') . " i2=" .
                     (defined($e->{i2}) ? $e->{i2} : 'undef') . " (solo se avisa una vez)\n";
                $warned_bad_equal = 1;
            }
            next;
        }
        push @mids, ( $e->{p1} + $e->{p2} ) / 2;
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

    # Supply/Demand (DIY) -- [PENDIENTE VALIDACION, ver nota en build_pipeline]
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
my @header = qw(ts timestamp atr_1m volume_1m ema9_volume_1m dist_daily dist_4h);
for my $tf (qw(1m 10m 1h)) {
    push @header, "tf${tf}_$_" for @tf_cols;
}
push @header, qw(target_3m target_5m target_10m target_15m);
print $out join(',', @header), "\n";

my $ema9_vol;
my $alpha = 2 / (9 + 1);
my $start_time = time();

for my $k (0 .. $#$all_traces) {
    my $tr  = $all_traces->[$k];
    my $idx = $tr->{index};
    my $ts  = $tr->{ts};
    my $c   = $market->get_candle($idx);   # market sigue en tf='1m'
    next unless $c;

    my $avg_price = ( $c->{open} + $c->{high} + $c->{low} + $c->{close} ) / 4;

    # --- Sincronizar los 3 pipelines hasta $ts PRIMERO -- nunca leer nada de
    #     un pipeline antes de sincronizarlo con la vela actual. ---
    pipeline_catch_up($PL{$_}, $ts) for qw(1m 10m 1h);

    # --- Contexto base de 1m (running, sobre TODA la serie hasta $idx) ---
    $ema9_vol = defined($ema9_vol)
        ? ( $c->{volume} * $alpha + $ema9_vol * (1 - $alpha) )
        : $c->{volume};
    my $atr_val_1m = $PL{'1m'}{atr}->get_values->[$idx];   # PL{'1m'} corre 1:1 con $market

    # --- Soportes/Resistencias Daily y 4H (independientes de la TF activa) ---
    $daily_md->set_replay_boundary($ts);
    $daily_levels->update_at_index($daily_md, 0);
    my $lv_d  = $daily_levels->get_level('D');
    my $lv_4h = $daily_levels->get_level('4h');
    my $dist_daily = $lv_d  ? to_pip($avg_price - $lv_d->{level})  : undef;
    my $dist_4h    = $lv_4h ? to_pip($avg_price - $lv_4h->{level}) : undef;

    my %row = (
        ts => $ts, timestamp => $c->{time},
        atr_1m => $atr_val_1m // '', volume_1m => $c->{volume},
        ema9_volume_1m => $ema9_vol,
        dist_daily => $dist_daily // '', dist_4h => $dist_4h // '',
    );
    for my $tf (qw(1m 10m 1h)) {
        my $feat = extract_tf_features($PL{$tf}, $avg_price, $PL{$tf}{cursor});
        $row{"tf${tf}_$_"} = $feat->{$_} for @tf_cols;
    }

    my @targets = compute_targets($k);
    @row{qw(target_3m target_5m target_10m target_15m)} = @targets;

    print $out join(',', map { defined($row{$_}) ? $row{$_} : '' } @header), "\n";

    if ( $k % 500 == 0 && $k > 0 ) {
        printf STDERR "  ... %d / %d rastros procesados (%.0fs)\n",
            $k, scalar(@$all_traces), time() - $start_time;
    }
}

close $out;
printf "Listo: %s (%d filas) en %.0fs\n", $csv_out, scalar(@$all_traces), time() - $start_time;
