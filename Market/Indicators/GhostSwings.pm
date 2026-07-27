package Market::Indicators::GhostSwings;

# =============================================================================
# Market::Indicators::GhostSwings
#
# Puerto a Perl del indicador Pine "Dynamic Swing Anchored VWAP by Josafa"
# (Ghosts_in_swings.txt), en la parte que interesa para el entregable del
# profesor: la deteccion de pivotes swing + los pivotes "fantasma" (ghost)
# que fuerzan la alternancia H-L-H-L, y el "rastro" que el fantasma deja
# cada vez que se reubica.
#
# DECISION DE DISEÑO DOCUMENTADA (relevante para la presentacion):
#   El comentario del propio script Pine dice que el rastro ('1') se deja
#   "solo cuando la vela cierra y el fantasma cambia de lugar", pero el
#   codigo tal cual esta pegado dibuja un '1' en CADA vela cerrada sin
#   verificar cambio de posicion. Tomamos la intencion declarada en el
#   comentario (no el codigo literal), porque es la unica interpretacion
#   que hace que "contar rastros futuros" sea una cantidad no trivial:
#   un rastro = evento en el que el extremo trackeado por el fantasma se
#   actualiza a una posicion NUEVA ("reubicacion").
#
# MODELO CONCEPTUAL (equivalente simplificado y documentado del Pine):
#   1. PIVOTES REGULARES: misma ventana simetrica que ya usa el proyecto
#      en Indicators::Liquidity (candidato c = i - length, confirmado
#      cuando su high/low es estrictamente el extremo de TODA la ventana
#      [c-length, c+length]). Replica exacta de ta.pivothigh/pivotlow
#      (length, length) de Pine.
#   2. ALTERNANCIA FORZADA (fantasma historico): si el pivote regular que
#      se acaba de confirmar es del MISMO tipo (H o L) que el ultimo
#      pivote confirmado (sea regular o fantasma), se inserta primero un
#      pivote FANTASMA del tipo OPUESTO, usando el extremo trackeado
#      (ver 3) acumulado desde el pivote anterior -- el "extremo que se
#      salto la estructura" del Pine original.
#   3. TRACKING EN VIVO + RASTRO: desde el ultimo pivote confirmado (sea
#      regular o fantasma) de tipo X, se sigue el extremo OPUESTO (low
#      mas bajo si X=H, high mas alto si X=L) vela a vela. Cada vez que
#      ese extremo se actualiza a un valor mas extremo, se registra un
#      evento de RASTRO (la "reubicacion" del fantasma que menciona el
#      profesor) en ese indice.
#
# GARANTIA DE NO FUGA DE FUTURO:
#   - Los pivotes REGULARES se confirman con el mismo retraso de 'length'
#     velas que el Pine original (igual principio que Liquidity.pm): al
#     evaluar el candidato c=i-length en la vela i, solo se usan velas
#     hasta la i (nunca mas alla).
#   - El tracking en vivo (paso 3) usa unicamente velas ya vistas (desde
#     el ultimo pivote confirmado hasta la vela actual) -- ninguna mirada
#     al futuro.
#   - Las ETIQUETAS del modelo (conteo de rastros en ventanas de 3/5/10/15
#     min futuros) SI miran al futuro respecto al punto de aparicion --
#     eso es intencional y exclusivo del extractor de features/target,
#     NO de este indicador, que solo expone hechos ya ocurridos via
#     get_pivots()/get_traces().
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        length => $args{length} // 50,

        _c => [],   # velas procesadas, en orden

        _last_evaluated_index => -1,   # ultimo candidato c ya evaluado

        _last_pivot => undef,   # { kind:'H'|'L', index, price, ts, is_ghost }
        _pivots     => [],      # historico completo (regulares + fantasma), cronologico

        # Tracking en vivo del extremo opuesto desde _last_pivot
        _track_kind  => undef,   # 'H' | 'L' -- que tipo de extremo se busca ahora
        _track_price => undef,
        _track_index => undef,

        # Cuantos rastros se han emitido en la PIERNA actual (desde el ultimo
        # pivote confirmado). Se expone en cada rastro como n_in_leg -- ver
        # nota de ESTADO EXPUESTO en _update_live_tracking.
        _leg_trace_count => 0,

        _traces => [],   # eventos de rastro/reubicacion: ver _update_live_tracking

        _market_data => undef,   # referencia para que el overlay resuelva ts->indice
    };
    bless $self, $class;
    return $self;
}

sub get_market_data { return $_[0]->{_market_data}; }

sub reset {
    my ($self) = @_;
    $self->{_c} = [];
    $self->{_last_evaluated_index} = -1;
    $self->{_last_pivot} = undef;
    $self->{_pivots} = [];
    $self->{_track_kind}  = undef;
    $self->{_track_price} = undef;
    $self->{_track_index} = undef;
    $self->{_leg_trace_count} = 0;
    $self->{_traces} = [];
}

sub get_values     { return []; }
sub get_pivots     { return $_[0]->{_pivots}; }
sub get_traces     { return $_[0]->{_traces}; }
sub processed_last { return $#{ $_[0]->{_c} }; }

sub update_last {
    my ($self, $md) = @_;
    $self->{_market_data} = $md;
    my $c = $md->last_candle;
    return unless defined $c;
    $self->_process($c);
}

sub update_at_index {
    my ($self, $md, $idx) = @_;
    $self->{_market_data} = $md;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_process($c);
}

sub _process {
    my ($self, $c) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };

    # --- 1. Confirmar pivote regular en el candidato c = i - length ---
    my $len  = $self->{length};
    my $cand = $i - $len;
    if ($cand >= $len && $cand > $self->{_last_evaluated_index}) {
        $self->_evaluate_regular_pivot($cand, $len);
        $self->{_last_evaluated_index} = $cand;
    }

    # --- 2. Tracking en vivo del extremo opuesto + generacion de rastro ---
    $self->_update_live_tracking($i);
}

# -----------------------------------------------------------------------------
# _evaluate_regular_pivot: candidato c, ventana simetrica [c-len, c+len].
# Confirmado si su high/low es ESTRICTAMENTE el extremo de toda la ventana
# (mismo criterio que ta.pivothigh/pivotlow y que Liquidity.pm).
# -----------------------------------------------------------------------------
sub _evaluate_regular_pivot {
    my ($self, $c, $len) = @_;
    my $arr    = $self->{_c};
    my $candle = $arr->[$c];
    return unless $candle;

    my ($is_high, $is_low) = (1, 1);
    for my $j (($c - $len) .. ($c + $len)) {
        next if $j == $c;
        my $other = $arr->[$j];
        return unless $other;   # defensivo: no deberia faltar en este rango
        $is_high = 0 if $other->{high} >= $candle->{high};
        $is_low  = 0 if $other->{low}  <= $candle->{low};
        last if !$is_high && !$is_low;
    }

    $self->_confirm_pivot('H', $c, $candle->{high}, $candle->{ts}) if $is_high;
    $self->_confirm_pivot('L', $c, $candle->{low},  $candle->{ts}) if $is_low;
}

# -----------------------------------------------------------------------------
# _confirm_pivot: registra un pivote REGULAR nuevo en $index de tipo $kind.
# Si rompe la alternancia (mismo tipo que el ultimo pivote confirmado),
# inserta PRIMERO un pivote FANTASMA del tipo opuesto usando el extremo
# ya trackeado (ver _update_live_tracking) antes de confirmar este.
# -----------------------------------------------------------------------------
sub _confirm_pivot {
    my ($self, $kind, $index, $price, $ts) = @_;

    my $last = $self->{_last_pivot};

    if ($last && $last->{kind} eq $kind && defined $self->{_track_price}) {
        # Alternancia rota: falta un pivote del tipo opuesto entre medio.
        # Se inserta como FANTASMA usando el extremo ya trackeado desde
        # $last. (Si aun no se trackeo nada -- caso degenerado sin datos
        # entre medio -- se omite el fantasma y se confirma directo.)
        my $ghost_kind  = ($kind eq 'H') ? 'L' : 'H';
        my $ghost_index = $self->{_track_index};
        my $ghost_price = $self->{_track_price};
        my $ghost_ts    = $self->{_c}[$ghost_index]{ts};

        push @{ $self->{_pivots} }, {
            kind => $ghost_kind, index => $ghost_index, price => $ghost_price,
            ts => $ghost_ts, is_ghost => 1,
        };
        $self->{_last_pivot} = {
            kind => $ghost_kind, index => $ghost_index, price => $ghost_price,
            ts => $ghost_ts, is_ghost => 1,
        };
    }

    # Confirmar el pivote REGULAR (siempre, tras el fantasma si hubo uno).
    push @{ $self->{_pivots} }, {
        kind => $kind, index => $index, price => $price, ts => $ts, is_ghost => 0,
    };
    $self->{_last_pivot} = {
        kind => $kind, index => $index, price => $price, ts => $ts, is_ghost => 0,
    };
    $self->_reset_tracking($kind);
}

# -----------------------------------------------------------------------------
# _reset_tracking: tras confirmar un pivote de tipo $kind, el fantasma en
# vivo empieza a buscar el extremo OPUESTO desde la proxima vela.
# -----------------------------------------------------------------------------
sub _reset_tracking {
    my ($self, $kind) = @_;
    $self->{_track_kind}  = ($kind eq 'H') ? 'L' : 'H';
    $self->{_track_price} = undef;
    $self->{_track_index} = undef;
    $self->{_leg_trace_count} = 0;   # empieza una pierna nueva
}

# -----------------------------------------------------------------------------
# _update_live_tracking: en la vela actual $i, si hay un pivote previo
# confirmado, actualiza el extremo opuesto trackeado. Si el extremo avanza
# a un valor mas extremo (el fantasma "se reubica"), registra un RASTRO.
# -----------------------------------------------------------------------------
sub _update_live_tracking {
    my ($self, $i) = @_;
    return unless $self->{_last_pivot};   # aun no hay pivote de referencia

    my $kind = $self->{_track_kind};
    return unless $kind;

    my $c = $self->{_c}[$i];
    my $candidate_price = ($kind eq 'H') ? $c->{high} : $c->{low};

    my $moved = 0;
    if (!defined $self->{_track_price}) {
        $moved = 1;   # primera vela desde el pivote: el fantasma "aparece" aqui
    } elsif ($kind eq 'H' && $candidate_price > $self->{_track_price}) {
        $moved = 1;
    } elsif ($kind eq 'L' && $candidate_price < $self->{_track_price}) {
        $moved = 1;
    }

    return unless $moved;

    # --- ESTADO EXPUESTO (para el extractor de features del modelo) ---
    # Un rastro es "se batio el record del extremo trackeado". El estado que
    # describe ESE proceso de records (donde estaba el record anterior, cuanto
    # aguanto, cuantos van en la pierna) no se puede reconstruir desde fuera a
    # partir de {index, ts, price, kind}, asi que se adjunta aqui. Se captura
    # ANTES de sobrescribir _track_price/_track_index, que es justo lo que
    # convierte estos campos en informacion util:
    #   prev_price  -- valor del record que se acaba de batir (undef en la
    #                  primera vela de la pierna: el fantasma "aparece", no
    #                  bate nada).
    #   prev_index  -- vela donde se habia fijado ese record ($i - prev_index
    #                  = cuantas velas aguanto).
    #   pivot_*     -- pivote confirmado que ancla la pierna actual.
    #   n_in_leg    -- rastros YA emitidos en esta pierna (0 para el primero).
    # Solo son hechos ya ocurridos: no rompen la garantia de no-fuga-de-futuro
    # de la cabecera. Son claves ADICIONALES -- los consumidores existentes
    # (Overlays::GhostSwings) leen unicamente price/ts/kind y no iteran claves.
    my $prev_price = $self->{_track_price};
    my $prev_index = $self->{_track_index};

    $self->{_track_price} = $candidate_price;
    $self->{_track_index} = $i;

    push @{ $self->{_traces} }, {
        index => $i, ts => $c->{ts}, price => $candidate_price, kind => $kind,
        prev_price  => $prev_price,
        prev_index  => $prev_index,
        pivot_index => $self->{_last_pivot}{index},
        pivot_price => $self->{_last_pivot}{price},
        n_in_leg    => $self->{_leg_trace_count},
    };
    $self->{_leg_trace_count}++;
}

1;
