#!/usr/bin/perl
# =============================================================================
# export_ml_dataset.pl
#
# Exporta un dataset "una fila = una vela" para entrenar t-SNE / GMM / HMM en
# Python. NO usa Tk (headless): carga los mismos CSV que market.pl, corre los
# mismos indicadores en el MISMO ORDEN de registro (ATR -> Liquidity -> ZigZag
# -> SMC_Structures), pero en vez de renderizar, procesa vela por vela y
# consulta el estado de cada indicador EN ESE INSTANTE (no el estado final
# tras el rebuild completo) para que ninguna columna filtre informacion del
# futuro -- el mismo principio de "no fuga de futuro" que ya sigue el resto
# del proyecto (ver Market::Replay).
#
# Columnas exportadas (ver dataset_ml.csv):
#   ts, timestamp, open, high, low, close, volume,
#   atr, volatility_atr, trend_ext, zigzag_dir_int,
#   dist_swing_high, dist_swing_low, dist_ob, dist_fvg,
#   dist_bsl, dist_ssl, sweeps_recent_10, session, hour,
#   bos_internal, bos_external, choch_internal, choch_external,
#   label   (SWEEP | GRAB | RUN | none)
#
# USO:
#   perl export_ml_dataset.pl
#   -> genera dataset_ml.csv en el directorio actual.
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

# =============================================================================
# 1. CARGA DE DATOS (identico a market.pl: mismos grupos de CSV, mismo dedup
#    por timestamp exacto via hash -- el archivo mas nuevo en la lista gana
#    cualquier solape).
# =============================================================================
my $market = Market::MarketData->new;

my @csv_groups = (
    ['2026_04.csv'],
    ['2026_05.csv'],
    ['2026_06.csv'],
    ['2026_07_20.csv'],
);

my %by_ts;
for my $paths (@csv_groups) {
    my $csv_path;
    for my $cand (@$paths) {
        if (-f $cand) { $csv_path = $cand; last; }
    }
    unless ($csv_path) {
        my $name = (grep { !m{/\.\.} } @$paths)[0] // $paths->[0];
        warn "CSV no encontrado (se continua sin el): $name\n";
        next;
    }

    print "Cargando $csv_path...\n";
    open my $fh, '<', $csv_path or die "Error abriendo CSV '$csv_path': $!\n";
    <$fh>;   # saltar cabecera
    while (<$fh>) {
        chomp;
        my ($time_str, $open, $high, $low, $close, $volume) = split /,/;
        next unless defined $close && $close ne '';
        my $tm;
        eval { $tm = Time::Moment->from_string($time_str) };
        next if $@;
        my $ts = $tm->epoch;

        $by_ts{$ts} = {
            time   => $time_str,
            ts     => $ts,
            open   => $open  + 0,
            high   => $high  + 0,
            low    => $low   + 0,
            close  => $close + 0,
            volume => $volume + 0,
        };
    }
    close $fh;
}

my $count = 0;
for my $ts (sort { $a <=> $b } keys %by_ts) {
    $market->add_candle($by_ts{$ts});
    $count++;
}
printf "Cargadas %d velas de 1m\n", $count;
$market->build_timeframes;

# =============================================================================
# 2. INDICADORES -- misma construccion y mismo ORDEN que market.pl.
# =============================================================================
my $atr_ind = Market::Indicators::ATR->new(14);
my $liq_ind = Market::Indicators::Liquidity->new( atr => $atr_ind, k => 3 );
my $zz_ind  = Market::Indicators::ZigZag->new(
    int_period  => 2,
    int_tf_mins => 30,
    ext_length  => 150,
);
my $smc_ind = Market::Indicators::SMC_Structures->new(
    zigzag => $zz_ind, atr => $atr_ind, max_age => 50 );

my $total = $market->size;
die "No hay velas cargadas -- revisa las rutas de los CSV.\n" if $total == 0;

# =============================================================================
# 3. HELPERS de features (todos leen SOLO el estado incremental vigente en el
#    instante $i -- nunca el estado final tras terminar el loop completo).
# =============================================================================

# Sesion aproximada en hora local UTC-5 (igual convencion que el resto del
# proyecto: gmtime($ts - 5*3600)). Ajustable si el profesor da rangos exactos.
sub session_for_hour {
    my ($h) = @_;
    return 'Overnight' if $h >= 17 && $h < 19;
    return 'Asia'      if $h >= 19 || $h < 3;
    return 'London'    if $h >= 3  && $h < 8;
    return 'New_York';   # 8..16
}

# Distancia con signo (precio - referencia) al item mas cercano de una lista
# de zonas [lo_key, hi_key] (Order Blocks / FVGs). undef si la lista esta vacia.
sub nearest_signed_dist_zone {
    my ($price, $items, $lo_key, $hi_key) = @_;
    my ($best, $best_abs);
    for my $it (@$items) {
        my $mid = ( $it->{$lo_key} + $it->{$hi_key} ) / 2;
        my $d   = $price - $mid;
        my $ad  = abs($d);
        if ( !defined($best_abs) || $ad < $best_abs ) { $best_abs = $ad; $best = $d; }
    }
    return $best;
}

# Igual, pero para niveles de liquidez (campo 'price' directo, sin zona).
sub nearest_signed_dist_level {
    my ($price, $items) = @_;
    my ($best, $best_abs);
    for my $it (@$items) {
        my $d  = $price - $it->{price};
        my $ad = abs($d);
        if ( !defined($best_abs) || $ad < $best_abs ) { $best_abs = $ad; $best = $d; }
    }
    return $best;
}

# Cuenta eventos de liquidez (SWEEP/GRAB/RUN) resueltos en los ultimos
# $window indices, recorriendo desde el final del array (cronologico) hasta
# que el indice cae fuera de la ventana.
sub count_recent_events {
    my ($events, $i, $window) = @_;
    my $c = 0;
    for ( my $k = $#$events; $k >= 0; $k-- ) {
        my $idx = $events->[$k]{index};
        last if $idx < $i - $window;
        $c++ if $idx <= $i;
    }
    return $c;
}

sub fmt { my ($v) = @_; return defined($v) ? $v : ''; }

# =============================================================================
# 4. LOOP PRINCIPAL -- procesa vela por vela, indicador por indicador, en el
#    mismo orden que Market::IndicatorManager::rebuild_all usaria.
# =============================================================================
my $out_path = 'dataset_ml.csv';
open my $out, '>', $out_path or die "No se pudo crear '$out_path': $!\n";

print $out join(',', qw(
    ts timestamp open high low close volume
    atr volatility_atr trend_ext zigzag_dir_int
    dist_swing_high dist_swing_low dist_ob dist_fvg
    dist_bsl dist_ssl sweeps_recent_10 session hour
    bos_internal bos_external choch_internal choch_external
    label
)), "\n";

my $start_time = time();

for ( my $i = 0; $i < $total; $i++ ) {
    my $c = $market->get_candle($i);
    next unless $c;

    # --- 4.1 Actualizar indicadores EN ORDEN, exactamente este indice ---
    $atr_ind->update_at_index( $market, $i );

    my $liqev_before = scalar @{ $liq_ind->{events} };
    $liq_ind->update_at_index( $market, $i );
    my $liqev_after  = scalar @{ $liq_ind->{events} };

    $zz_ind->update_at_index( $market, $i );

    my $smcev_before = scalar @{ $smc_ind->{_events} };
    $smc_ind->update_at_index( $market, $i );
    my $smcev_after  = scalar @{ $smc_ind->{_events} };

    # --- 4.2 Features basicas de la vela ---
    my $atr_val = $atr_ind->get_values->[-1];
    my $vol_atr = ( defined($atr_val) && $atr_val > 0 )
        ? ( $c->{high} - $c->{low} ) / $atr_val
        : undef;

    # --- 4.3 Tendencia (BOS/CHoCH externo) y direccion del ZigZag interno ---
    my $trend_ext = $smc_ind->{_bos}{external}{trend};   # 'bull' | 'bear' | undef
    my $zz_dir    = $zz_ind->{_int_dir};                 # -1 | 0 | 1

    # --- 4.4 Distancias a estructura (swings / OB / FVG / liquidez) ---
    my $sw_hi = $liq_ind->last_swing_high;
    my $sw_lo = $liq_ind->last_swing_low;
    my $dist_swing_high = $sw_hi ? ( $c->{close} - $sw_hi->{price} ) : undef;
    my $dist_swing_low  = $sw_lo ? ( $c->{close} - $sw_lo->{price} ) : undef;

    my $dist_ob = nearest_signed_dist_zone(
        $c->{close}, $smc_ind->{_active_obs}, 'zone_low', 'zone_high' );
    my $dist_fvg = nearest_signed_dist_zone(
        $c->{close}, $smc_ind->{_active_fvgs}, 'bottom', 'top' );

    my @bsl_open = grep { $_->{side} eq 'buy'  && $_->{state} ne 'RESOLVED' }
        @{ $liq_ind->{_open_level_refs} };
    my @ssl_open = grep { $_->{side} eq 'sell' && $_->{state} ne 'RESOLVED' }
        @{ $liq_ind->{_open_level_refs} };
    my $dist_bsl = nearest_signed_dist_level( $c->{close}, \@bsl_open );
    my $dist_ssl = nearest_signed_dist_level( $c->{close}, \@ssl_open );

    my $sweeps_recent = count_recent_events( $liq_ind->{events}, $i, 10 );

    # --- 4.5 Sesion / hora (UTC-5, misma convencion que el resto del proyecto) ---
    my $hour    = ( gmtime( $c->{ts} - 5 * 3600 ) )[2];
    my $session = session_for_hour($hour);

    # --- 4.6 BOS / CHoCH generados EXACTAMENTE en este indice ---
    my ( $bos_int, $bos_ext, $choch_int, $choch_ext ) = ( 0, 0, 0, 0 );
    if ( $smcev_after > $smcev_before ) {
        for my $k ( $smcev_before .. $smcev_after - 1 ) {
            my $e = $smc_ind->{_events}[$k];
            next unless $e->{index} == $i;
            if ( $e->{scope} eq 'internal' ) {
                $bos_int   = 1 if $e->{type} eq 'BOS';
                $choch_int = 1 if $e->{type} eq 'CHoCH';
            } else {
                $bos_ext   = 1 if $e->{type} eq 'BOS';
                $choch_ext = 1 if $e->{type} eq 'CHoCH';
            }
        }
    }

    # --- 4.7 Etiqueta: SWEEP / GRAB / RUN resuelto EXACTAMENTE en este indice ---
    my $label = 'none';
    if ( $liqev_after > $liqev_before ) {
        $label = $liq_ind->{events}[$liqev_before]{type};
    }

    # --- 4.8 Escribir fila ---
    print $out join(',',
        $c->{ts}, $c->{time}, $c->{open}, $c->{high}, $c->{low}, $c->{close},
        $c->{volume}, fmt($atr_val), fmt($vol_atr), fmt($trend_ext), fmt($zz_dir),
        fmt($dist_swing_high), fmt($dist_swing_low), fmt($dist_ob), fmt($dist_fvg),
        fmt($dist_bsl), fmt($dist_ssl), $sweeps_recent, $session, $hour,
        $bos_int, $bos_ext, $choch_int, $choch_ext, $label,
    ), "\n";

    if ( $i % 20000 == 0 && $i > 0 ) {
        printf STDERR "  ... %d / %d velas procesadas (%.0fs)\n",
            $i, $total, time() - $start_time;
    }
}

close $out;
printf "Listo: %s (%d filas) en %.0fs\n", $out_path, $total, time() - $start_time;
