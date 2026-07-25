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
# Colores del VWAP unico + sus bandas (identicos al Pine de referencia):
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
        # VWAP unico re-anclable + bandas (defaults del Pine: mult1/2 ON, mult3 OFF)
        show_manual  => $args{show_manual}  // 1,
        show_band1   => $args{show_band1}   // 1,
        show_band2   => $args{show_band2}   // 1,
        show_band3   => $args{show_band3}   // 0,
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

    # VWAP UNICO re-anclable: el clic del usuario fija la referencia y la FUENTE
    # (session/open/BOS/CHoCH/POC) decide en que evento se ancla. El indicador
    # resuelve el ancla efectiva en get_manual_anchor; aqui solo dibujamos el VWAP
    # central (azul) + 3 bandas (verde/naranja/rojo, mult1/2 ON, mult3 OFF) +
    # MARCADOR en la vela anclada. (Las 5 lineas separadas por tipo se retiraron:
    # ahora es UN solo VWAP cuya fuente se cambia.)
    return unless $self->{show_manual} && $src->can('get_manual_anchor');
    my $ma = $src->get_manual_anchor or return;
    my $line = $src->vwap_line($ma, $vfrom, $vto);
    return unless $line && @$line >= 2;

    # PUNTO DE ANCLAJE UNICO (centro del rombo): anchorBar = ref_idx (vela de la
    # señal), anchorPrice = anchor_price (apertura de esa vela). Se calcula UNA
    # sola vez y lo comparten el ROMBO y el nacimiento de TODAS las lineas ->
    # cero separacion horizontal o vertical, a cualquier zoom/scroll.
    my $anchor_bar = $ma->{ref_idx} // $ma->{start_idx};
    my $ax = $scale->index_to_center_x($anchor_bar);
    my $ay = $scale->value_to_y($ma->{anchor_price});

    # Las lineas NACEN del rombo cuando el calculo arranca EN o DESPUES de su
    # barra (session = misma vela; evento posterior = primer segmento desde el
    # rombo hasta su nivel). Si el evento es ANTERIOR, la linea ya pasa por la
    # barra del rombo y no nace ahi. Fuera de la vista no se antepone nada.
    my $origin;
    $origin = [ $ax, $ay ]
        if @$line && $line->[0]{idx} >= $anchor_bar
        && $ax >= -0.5 && $ax <= $plot_w + 0.5;

    # bandas primero (detras), VWAP central despues (delante)
    for my $b ($self->_band_specs) {
        my ($mi, $bcol, $on) = @$b; next unless $on;
        my $mu = $self->_mult($src, $mi); next unless $mu > 0;
        for my $sg (1, -1) {
            $self->_draw_series($canvas, $scale, $line,
                sub { my $p=$_[0]; (defined $p->{value} && defined $p->{stdev})
                        ? $p->{value} + $sg*$p->{stdev}*$mu : undef },
                $bcol, 1, undef, $origin);
        }
    }
    $self->_draw_series($canvas, $scale, $line, sub { $_[0]->{value} }, C_VWAP_MANUAL, 2, undef, $origin);
    $self->_marker($canvas, $scale, $ax, $ay);   # MISMO punto (ax,ay) que las lineas

    my $liter = $line->[-1];
    if (defined $liter->{value} && $scale->value_in_range($liter->{value})) {
        my $x = $scale->index_to_center_x($liter->{idx}); $x = $plot_w if $x > $plot_w;
        my $lbl = 'VWAP ' . ($ma->{source} // 'ancla');   # muestra la fuente activa
        $self->_chip($canvas, $x, $scale->value_to_y($liter->{value}), $lbl, C_VWAP_MANUAL);
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
# tramo continuo. $origin (opcional, [x,y]) es el CENTRO DEL ROMBO: se une al
# PRIMER punto dibujable de la linea (no se pre-carga al buffer, para que un
# primer valor undef -- p.ej. volumen 0 en la vela ancla -- o un recorte de
# rango no lo descarte y la linea quede separada del rombo).
sub _draw_series {
    my ($self, $canvas, $scale, $line, $val, $col, $wdt, $dash, $origin) = @_;
    my $plot_w = $self->{_plot_w};
    my @co;
    my $pend = $origin ? [ @$origin ] : undef;   # origen pendiente de unir
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
        if ($pend) { push @co, @$pend; $pend = undef; }   # nace en el rombo
        push @co, $x, $scale->value_to_y($price);
    }
    $flush->();
}

# _marker: marca visual del ANCLA DEL USUARIO (linea vertical punteada + rombo).
# Recibe (x,y) = EL MISMO punto de anclaje que usan las lineas (calculado una
# sola vez en render): barra de la señal (ref_idx) al precio de APERTURA (como
# TradingView: vela verde -> lado inferior del cuerpo; roja -> superior). NO se
# mueve al cambiar la fuente: solo el usuario lo mueve (clic o arrastre;
# ChartEngine detecta el clic cerca de este x).
sub _marker {
    my ($self, $canvas, $scale, $x, $y) = @_;
    my $plot_w = $self->{_plot_w};
    return if $x < -0.5 || $x > $plot_w + 0.5;
    my $h = $scale->{canvas_h} // 600;
    $canvas->createLine($x, 0, $x, $h, -fill=>C_MARK, -width=>1, -dash=>[2,4],
        -tags=>[TAG, 'avwap_anchor']);
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
