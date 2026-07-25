package Market::Overlays::GhostSwings;

# =============================================================================
# Market::Overlays::GhostSwings
#
# Capa visual de Indicators::GhostSwings. Tres sub-toggles independientes:
#   show_pivots -> triangulos de los pivotes REGULARES + linea zigzag que
#                  conecta TODOS los pivotes en orden cronologico (regulares
#                  y fantasma mezclados, para ver la alternancia forzada).
#   show_ghosts -> chip 'G' en los pivotes FANTASMA (los insertados para
#                  forzar alternancia).
#   show_traces -> puntos pequenos en cada evento de RASTRO (reubicacion del
#                  fantasma en vivo) + un marcador destacado en el rastro
#                  mas reciente visible (el "fantasma actual").
#
# Mismo patron de conversion ts->indice activo que Overlays::ZigZag, para
# que funcione en cualquier temporalidad (aunque el uso principal, segun
# las indicaciones del profesor, es validarlo en 1m).
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_ghost';

use constant {
    C_HIGH  => '#ef5350',   # rojo   -- pivote H (igual convencion que Liquidity/SMC)
    C_LOW   => '#26a69a',   # verde  -- pivote L
    C_GHOST => '#8e24aa',   # violeta -- distintivo para fantasma/rastro
};

sub new {
    my ($class, %args) = @_;
    bless {
        source       => $args{source},
        show_pivots  => $args{show_pivots} // 1,
        show_ghosts  => $args{show_ghosts} // 1,
        show_traces  => $args{show_traces} // 1,
    }, $class;
}

sub tag { return TAG; }

sub set_flag {
    my ($self, $flag, $val) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

sub render {
    my ($self, $canvas, $scale, $placer) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source} or return;
    my $md  = $src->get_market_data or return;

    my $active_arr = $md->get_data->{ $md->get_timeframe };
    return unless $active_arr && @$active_arr;
    my $last_visible = $md->last_index;
    return if $last_visible < 0;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    $self->_render_pivots_and_zigzag($canvas, $scale, $src, $active_arr, $last_visible, $placer)
        if $self->{show_pivots} || $self->{show_ghosts};

    $self->_render_traces($canvas, $scale, $src, $active_arr, $last_visible, $placer)
        if $self->{show_traces};
}

# -----------------------------------------------------------------------------
# _render_pivots_and_zigzag: linea que conecta TODOS los pivotes (regulares +
# fantasma) en orden cronologico -- asi se ve visualmente la alternancia
# forzada. Los pivotes fantasma se marcan con un chip 'G' violeta; los
# regulares con un triangulo (rojo arriba / verde abajo, igual convencion
# que el resto del proyecto).
# -----------------------------------------------------------------------------
sub _render_pivots_and_zigzag {
    my ($self, $canvas, $scale, $src, $active_arr, $last_vis, $placer) = @_;
    my $pivots = $src->get_pivots or return;
    return unless @$pivots;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    # --- Linea zigzag entre pivotes consecutivos ---
    for my $k (0 .. $#$pivots - 1) {
        my $a = $pivots->[$k];
        my $b = $pivots->[$k + 1];

        my $ia = $self->_ts_to_active_idx($a->{ts}, $active_arr, $last_vis);
        my $ib = $self->_ts_to_active_idx($b->{ts}, $active_arr, $last_vis);

        my ($idx_lo, $idx_hi) = $ia <= $ib ? ($ia, $ib) : ($ib, $ia);
        next if $idx_hi < $off || $idx_lo > $off + $vb;

        my $x1 = $scale->index_to_center_x($ia);
        my $y1 = $scale->value_to_y($a->{price});
        my $x2 = $scale->index_to_center_x($ib);
        my $y2 = $scale->value_to_y($b->{price});

        (my @clipped) = $scale->clip_line_x($x1, $y1, $x2, $y2);
        next unless @clipped;
        ($x1, $y1, $x2, $y2) = @clipped;

        my $any_ghost = ($a->{is_ghost} || $b->{is_ghost});
        my $color = ($a->{kind} eq 'H') ? C_LOW : C_HIGH;   # H->L baja(verde->?), igual criterio que ZigZag: color por direccion del tramo
        $color = ($a->{kind} eq 'H') ? C_HIGH : C_LOW if !$any_ghost;   # tramo regular: color por el pivote de origen

        $canvas->createLine($x1, $y1, $x2, $y2,
            -fill  => ($any_ghost ? C_GHOST : $color),
            -width => ($any_ghost ? 1 : 2),
            ($any_ghost ? (-dash => [3, 2]) : ()),
            -tags  => [TAG]);
    }

    # --- Marcadores de cada pivote ---
    for my $p (@$pivots) {
        next if $p->{is_ghost} && !$self->{show_ghosts};
        next if !$p->{is_ghost} && !$self->{show_pivots};

        my $idx = $self->_ts_to_active_idx($p->{ts}, $active_arr, $last_vis);
        next if $idx < $off || $idx > $off + $vb;
        next unless $scale->value_in_range($p->{price});

        my $x = $scale->index_to_center_x($idx);
        next if $x < 0 || $x > $plot_w;
        my $y = $scale->value_to_y($p->{price});
        my $up = ($p->{kind} eq 'H');

        if ($p->{is_ghost}) {
            $canvas->createOval($x-4, $y-4, $x+4, $y+4,
                -fill => '#ffffff', -outline => C_GHOST, -width => 2, -tags => [TAG]);
            $self->_label($placer, $canvas, $x, $y, 'G',
                color => C_GHOST, style => 'outline',
                side => ($up ? 'above' : 'below'),
                priority => 3, hideable => 1, font => 'TkDefaultFont 7 bold');
        } else {
            $canvas->createOval($x-3, $y-3, $x+3, $y+3,
                -fill => ($up ? C_HIGH : C_LOW), -outline => ($up ? C_HIGH : C_LOW),
                -tags => [TAG]);
        }
    }
}

# -----------------------------------------------------------------------------
# _render_traces: puntos pequenos por cada rastro (reubicacion). Solo dibuja
# los que caen en la ventana visible -- con miles de eventos totales, iterar
# la lista completa por frame seria caro; se resuelve el rango de indices
# visibles primero por busqueda binaria sobre ts y solo se recorre ese tramo.
# -----------------------------------------------------------------------------
sub _render_traces {
    my ($self, $canvas, $scale, $src, $active_arr, $last_vis, $placer) = @_;
    my $traces = $src->get_traces or return;
    return unless @$traces;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    my $lo_idx = $off;
    my $hi_idx = $off + $vb;

    my ($lo_ts, $hi_ts) = (undef, undef);
    if ($lo_idx >= 0 && $lo_idx <= $last_vis) { $lo_ts = $active_arr->[$lo_idx]{ts}; }
    if ($hi_idx >= 0 && $hi_idx <= $last_vis) { $hi_ts = $active_arr->[$hi_idx]{ts}; }
    $lo_ts //= $active_arr->[0]{ts};
    $hi_ts //= $active_arr->[$last_vis]{ts};

    for my $t (@$traces) {
        next if $t->{ts} < $lo_ts || $t->{ts} > $hi_ts;
        next unless $scale->value_in_range($t->{price});

        my $idx = $self->_ts_to_active_idx($t->{ts}, $active_arr, $last_vis);
        my $x   = $scale->index_to_center_x($idx);
        next if $x < 0 || $x > $plot_w;
        my $y = $scale->value_to_y($t->{price});

        $canvas->createOval($x-1.5, $y-1.5, $x+1.5, $y+1.5,
            -fill => C_GHOST, -outline => C_GHOST, -tags => [TAG]);
    }

    # Fantasma "en vivo": el rastro mas reciente de todos (no solo el visible).
    my $last_trace = $traces->[-1];
    return unless $last_trace;
    return unless $scale->value_in_range($last_trace->{price});
    my $idx = $self->_ts_to_active_idx($last_trace->{ts}, $active_arr, $last_vis);
    return if $idx < $off || $idx > $off + $vb;
    my $x = $scale->index_to_center_x($idx);
    return if $x < 0 || $x > $plot_w;
    my $y = $scale->value_to_y($last_trace->{price});

    $canvas->createOval($x-5, $y-5, $x+5, $y+5,
        -fill => '', -outline => C_GHOST, -width => 2, -tags => [TAG]);
    $self->_label($placer, $canvas, $x, $y, 'GHOST',
        color => C_GHOST, style => 'solid',
        side => ($last_trace->{kind} eq 'H' ? 'above' : 'below'),
        priority => 1, hideable => 0, font => 'TkDefaultFont 7 bold');
}

# -----------------------------------------------------------------------------
# _label: encola en el LabelPlacer si esta disponible; si no, chip inmediato.
# -----------------------------------------------------------------------------
sub _label {
    my ($self, $placer, $canvas, $x, $y, $text, %o) = @_;
    if ($placer) {
        $placer->add(x => $x, y => $y, text => $text,
            color => $o{color}, style => $o{style}, side => $o{side},
            priority => $o{priority}, hideable => $o{hideable}, font => $o{font});
        return;
    }
    my $ty = $o{side} eq 'below' ? $y + 9 : $y - 9;
    my $tid = $canvas->createText($x, $ty, -text => $text, -anchor => 'center',
        -font => $o{font}, -fill => ($o{style} eq 'solid' ? '#ffffff' : $o{color}),
        -tags => [TAG]);
    my @bb = $canvas->bbox($tid);
    return unless @bb;
    my $rid = $canvas->createRectangle($bb[0]-2, $bb[1]-1, $bb[2]+2, $bb[3]+1,
        -fill => ($o{style} eq 'solid' ? $o{color} : '#ffffff'),
        -outline => $o{color}, -width => 1, -tags => [TAG]);
    $canvas->lower($rid, $tid);
}

# -----------------------------------------------------------------------------
# _ts_to_active_idx: identico al de Overlays::ZigZag.
# -----------------------------------------------------------------------------
sub _ts_to_active_idx {
    my ($self, $ts_target, $arr, $last_vis) = @_;
    my ($lo, $hi) = (0, $last_vis);
    return 0 if $hi < 0;
    return 0 if $arr->[0]{ts} > $ts_target;
    return $last_vis if $arr->[$last_vis]{ts} <= $ts_target;
    my $found = 0;
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        if ($arr->[$mid]{ts} <= $ts_target) { $found = $mid; $lo = $mid + 1; }
        else { $hi = $mid - 1; }
    }
    return $found;
}

1;
