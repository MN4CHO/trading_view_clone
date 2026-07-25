package Market::Overlays::AnchoredVWAP;

# =============================================================================
# Market::Overlays::AnchoredVWAP  (2a fase)
# Dibuja las lineas VWAP ancladas ya calculadas por Indicators::AnchoredVWAP.
# La formula vive en el indicador (vwap_line); aqui solo se pide el tramo VISIBLE
# y se traza. Un color por tipo de ancla; sub-toggles independientes. No calcula.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_avwap';
my %COLOR = (
    session => '#26a69a',   # inicio de sesion (ETH)
    open    => '#42a5f5',   # apertura oficial (RTH)
    BOS     => '#2962ff',   # BOS confirmado
    CHoCH   => '#ab47bc',   # CHoCH confirmado
    POC     => '#ff9800',   # POC del Volume Profile
);
my %FLAGKEY = (
    session => 'show_session', open => 'show_open', BOS => 'show_bos',
    CHoCH   => 'show_choch',   POC  => 'show_poc',
);
# Colores del ancla MANUAL (identicos al Pine de referencia):
use constant {
    C_VWAP_MANUAL => '#2196f3',   # VWAP central  (33,150,243)  azul
    C_BAND1       => '#4caf50',   # Banda x1      (76,175,80)   verde
    C_BAND2       => '#ff9800',   # Banda x2      (255,152,0)   naranja
    C_BAND3       => '#f44336',   # Banda x3      (244,67,54)   rojo
    C_MARK        => '#2196f3',   # marcador del ancla
};

sub new {
    my ($class, %args) = @_;
    my $self = {
        source       => $args{source},
        show_session => $args{show_session} // 1,
        show_open    => $args{show_open}    // 1,
        show_bos     => $args{show_bos}     // 1,
        show_choch   => $args{show_choch}   // 1,
        show_poc     => $args{show_poc}     // 1,
        show_inactive=> $args{show_inactive}// 0,
        # ANCLA MANUAL + bandas (defaults del Pine: mult1/2 ON, mult3 OFF)
        show_manual  => $args{show_manual}  // 1,
        show_band1   => $args{show_band1}   // 1,
        show_band2   => $args{show_band2}   // 1,
        show_band3   => $args{show_band3}   // 0,
        # bandas tambien en las 5 anclas AUTO (off por defecto para no saturar)
        show_auto_bands => $args{show_auto_bands} // 0,
        _plot_w      => undef,
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub set_flag {
    my ($self, $flag, $val) = @_;
    $self->{$flag} = $val ? 1 : 0 if exists $self->{$flag};
}

sub render {
    my ($self, $canvas, $scale, $placer) = @_;
    my $src = $self->{source} or return;
    $self->{_plot_w} = $scale->_plot_w;
    my $plot_w = $scale->_plot_w;

    # IDEMPOTENCIA (contrato de OverlayManager, igual que SMC_Structures/Liquidity):
    # borrar los items del frame anterior por el tag general ANTES de redibujar.
    # Sin esto, cada zoom/pan/scroll/Replay acumulaba lineas VWAP encima de las
    # previas (duplicados). NO toca el estado matematico (las anclas viven en el
    # indicador); solo limpia el Canvas.
    $canvas->delete(TAG);

    # rango visible de indices
    my $off = $scale->{offset}; my $vb = $scale->{visible_bars};
    my $vfrom = int($off);        $vfrom = 0 if $vfrom < 0;
    my $vto   = int($off) + $vb + 1;

    # (1) ANCLAS AUTOMATICAS (sesion/apertura/BOS/CHoCH/POC): linea VWAP por tipo
    #     de ancla + (opcional) sus bandas en el mismo color.
    for my $a (@{ $src->get_anchors }) {
        next if $a->{state} ne 'active' && !$self->{show_inactive};
        my $fk = $FLAGKEY{ $a->{type} } or next;
        next unless $self->{$fk};

        my $line = $src->vwap_line($a, $vfrom, $vto);
        next unless $line && @$line >= 2;
        my $col  = $COLOR{ $a->{type} } // '#888888';
        my $dash = ($a->{state} eq 'active') ? undef : [3,3];
        my $wdt  = ($a->{state} eq 'active') ? 2 : 1;

        # VWAP central
        $self->_draw_series($canvas, $scale, $line, sub { $_[0]->{value} }, $col, $wdt, $dash);

        # bandas de las anclas auto (mismo color, punteadas) si estan activadas
        if ($self->{show_auto_bands}) {
            for my $b ($self->_band_specs) {
                my ($mi, undef, $on) = @$b; next unless $on;
                my $mu = $self->_mult($src, $mi); next unless $mu > 0;
                for my $sg (1, -1) {
                    $self->_draw_series($canvas, $scale, $line,
                        sub { my $p=$_[0]; (defined $p->{value} && defined $p->{stdev})
                                ? $p->{value} + $sg*$p->{stdev}*$mu : undef },
                        $col, 1, [2,2]);
                }
            }
        }

        # etiqueta en el extremo derecho visible del ancla
        my $liter = $line->[-1];
        if (defined $liter->{value} && $scale->value_in_range($liter->{value})) {
            my $x = $scale->index_to_center_x($liter->{idx});
            $x = $plot_w if $x > $plot_w;
            $self->_chip($canvas, $x, $scale->value_to_y($liter->{value}), 'VWAP:'.$a->{type}, $col);
        }
    }

    # (2) ANCLA MANUAL (clic del usuario): VWAP azul + 3 bandas (verde/naranja/rojo,
    #     defaults mult1/2 ON, mult3 OFF) + MARCADOR en la vela seleccionada.
    return unless $self->{show_manual} && $src->can('get_manual_anchor');
    my $ma = $src->get_manual_anchor or return;
    my $line = $src->vwap_line($ma, $vfrom, $vto);
    return unless $line && @$line >= 2;

    # bandas primero (detras), VWAP central despues (delante)
    for my $b ($self->_band_specs) {
        my ($mi, $bcol, $on) = @$b; next unless $on;
        my $mu = $self->_mult($src, $mi); next unless $mu > 0;
        for my $sg (1, -1) {
            $self->_draw_series($canvas, $scale, $line,
                sub { my $p=$_[0]; (defined $p->{value} && defined $p->{stdev})
                        ? $p->{value} + $sg*$p->{stdev}*$mu : undef },
                $bcol, 1, undef);
        }
    }
    $self->_draw_series($canvas, $scale, $line, sub { $_[0]->{value} }, C_VWAP_MANUAL, 2, undef);
    $self->_marker($canvas, $scale, $ma);

    my $liter = $line->[-1];
    if (defined $liter->{value} && $scale->value_in_range($liter->{value})) {
        my $x = $scale->index_to_center_x($liter->{idx}); $x = $plot_w if $x > $plot_w;
        $self->_chip($canvas, $x, $scale->value_to_y($liter->{value}), 'VWAP ancla', C_VWAP_MANUAL);
    }
}

# Especificacion de las 3 bandas: [indice_mult, color, activada?]
sub _band_specs {
    my ($self) = @_;
    return ([0, C_BAND1, $self->{show_band1}],
            [1, C_BAND2, $self->{show_band2}],
            [2, C_BAND3, $self->{show_band3}]);
}
sub _mult {
    my ($self, $src, $mi) = @_;
    my $mm = (ref $src && $src->{band_mults}) ? $src->{band_mults} : [1,2,3];
    return $mm->[$mi] // 0;
}

# _draw_series: polilinea de una serie {idx,...}, mapeando cada punto a su PRECIO
# via $val->($p). Rompe en undef o fuera del rango visible. UNA polilinea por
# tramo continuo. (La geometria/formula ya vino del indicador.)
sub _draw_series {
    my ($self, $canvas, $scale, $line, $val, $col, $wdt, $dash) = @_;
    my $plot_w = $self->{_plot_w};
    my @co;
    my $flush = sub {
        $canvas->createLine(@co, -fill=>$col, -width=>$wdt,
            ($dash ? (-dash=>$dash) : ()), -tags=>[TAG]) if @co >= 4;
        @co = ();
    };
    for my $p (@$line) {
        my $price = $val->($p);
        if (!defined $price) { $flush->(); next; }
        my $x = $scale->index_to_center_x($p->{idx});
        if ($x < -0.5 || $x > $plot_w + 0.5) { $flush->(); next; }
        push @co, $x, $scale->value_to_y($price);
    }
    $flush->();
}

# _marker: marca visual en la vela del ancla manual (linea vertical punteada +
# rombo). Es lo que el usuario "mueve" arrastrando (ChartEngine detecta el clic
# cerca de este x). Tag adicional 'avwap_anchor' para identificarlo.
sub _marker {
    my ($self, $canvas, $scale, $ma) = @_;
    my $plot_w = $self->{_plot_w};
    my $x = $scale->index_to_center_x($ma->{start_idx});
    return if $x < -0.5 || $x > $plot_w + 0.5;
    my $h = $scale->{canvas_h} // 600;
    $canvas->createLine($x, 0, $x, $h, -fill=>C_MARK, -width=>1, -dash=>[2,4],
        -tags=>[TAG, 'avwap_anchor']);
    # rombo en el precio del ancla
    my $y = $scale->value_in_range($ma->{anchor_price})
          ? $scale->value_to_y($ma->{anchor_price}) : 12;
    $canvas->createPolygon($x, $y-6, $x+6, $y, $x, $y+6, $x-6, $y,
        -fill=>C_MARK, -outline=>'#ffffff', -width=>1, -tags=>[TAG, 'avwap_anchor']);
}

sub _chip {
    my ($self, $canvas, $x, $y, $txt, $col) = @_;
    my $tx = $x - 4; $tx = ($self->{_plot_w} - 4) if defined $self->{_plot_w} && $tx > $self->{_plot_w} - 4;
    $tx = 30 if $tx < 30;
    $canvas->createText($tx, $y, -text=>$txt, -fill=>$col, -anchor=>'e',
        -font=>'TkDefaultFont 6 bold', -tags=>[TAG]);
}

1;
