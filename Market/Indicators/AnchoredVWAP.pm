package Market::Indicators::AnchoredVWAP;

# =============================================================================
# Market::Indicators::AnchoredVWAP   (2a fase -- Anchored VWAP unico re-anclable)
#
# UN solo VWAP anclado manualmente. El usuario ANCLA con un clic (_manual_ts) y
# las sumas acumuladas de volumen y precio ponderado REINICIAN estrictamente en
# la vela del ancla; la MARCA (rombo) y el NACIMIENTO de las lineas son siempre
# el mismo punto. Segun la FUENTE (_manual_source):
#   - Inicio de Sesion / Apertura de Mercado / POC: el ancla es EXACTAMENTE la
#     vela donde el usuario anclo ("donde yo ancle, desde ahi las lineas"),
#     cambiando solo el PRECIO BASE ('open'=APERTURA; el resto=HLC3).
#   - BOS / CHoCH Confirmado (excepcion): se BUSCA la ultima confirmacion SMC
#     EN o ANTES de la vela del usuario y el ancla (marca + lineas) se coloca
#     en esa vela exacta (sin futuro; se re-busca al mover el ancla).
# Solo el usuario mueve el ancla (clic o arrastre). Incremental, respeta Replay
# via MarketData. NO depende del Canvas. NO reimplementa BOS/CHoCH ni el Volume
# Profile: CONSUME sus salidas confirmadas.
#
# FORMULA (la aplica vwap_line desde el ancla efectiva): el precio base depende
#   de la FUENTE del ancla ('open'=apertura de la vela; session/BOS/CHoCH/POC=
#   HLC3); el primer valor del VWAP en la vela ancla ES el punto del rombo.
#   cum_pv += src*volume ; cum_v += volume ; vwap = cum_pv/cum_v. volumen 0 =>
#   suma 0; cum_v==0 => value=undef. Bandas: stdev ponderada por volumen =
#   sqrt(max(0, cum_pv2/cum_v - vwap^2)).
#
# EVENTOS (5 tipos) detectados en update_at_index y guardados en
#   _events{tipo}=[{idx,ts},...] (respetan el cutoff, sin futuro): 'session'
#   (apertura ETH = cambio de bucket de sesion), 'open' (apertura oficial RTH,
#   cruce del minuto local), 'BOS'/'CHoCH' (eventos CONFIRMADOS de SMC), 'POC'
#   (vela de control de cada perfil CERRADO del Volume Profile). Son los puntos
#   donde el VWAP REINICIALIZA sus sumas (get_manual_anchor elige el vigente).
#   reset() limpia _events (se re-registran en el rebuild); _manual_ts y
#   _manual_source PERSISTEN (solo cambian por accion del usuario).
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %a) = @_;
    my $self = {
        # Fuente de PRECIO del VWAP SEGUN la fuente del ancla (define la posicion
        # del rombo Y el nacimiento de las lineas): 'open' (Apertura de mercado)
        # usa la APERTURA de la vela; el resto (Inicio de Sesion/BOS/CHoCH/POC)
        # usa HLC3. El primer valor del VWAP en la vela ancla ES el punto del
        # rombo, asi las lineas nacen de el. Se puede forzar una fuente unica
        # pasando src => open|close|hl2|hlc3|ohlc4.
        src              => $a{src},   # undef => segun la fuente del ancla
        session_tf       => $a{session_tf}       // 'D',
        official_open_min=> $a{official_open_min}// 510,   # 08:30 local (-05:00) = RTH / cash open
        local_offset_sec => $a{local_offset_sec} // -5*3600,
        anchor_scope     => exists $a{anchor_scope} ? $a{anchor_scope} : 'external',
        smc              => $a{smc},
        vp               => $a{vp},

        _c            => [],
        _tf           => undef,
        _cur_skey     => undef,
        _seen_open    => 0,
        _prev_lmin    => undef,   # minuto local de la vela previa (deteccion por cruce)
        _smc_seen     => 0,
        _vp_seen      => 0,
        _market_data  => undef,
        _manual_ts     => undef,   # ts del ANCLA manual (clic del usuario); persiste
        # Fuente del ancla. 'session' (default) = anclar EXACTO en la vela clicada;
        # open/BOS/CHoCH/POC = reanclar al evento de ese tipo mas cercano al clic.
        _manual_source => $a{manual_source} // 'session',   # session|open|BOS|CHoCH|POC
        # Eventos detectados por tipo, para poder REANCLAR sin recalcular:
        #   { session=>[{idx,ts},...], open=>[...], BOS=>[...], CHoCH=>[...], POC=>[...] }
        _events        => {},
        # multiplicadores de banda (desv. estandar ponderada), igual que el Pine.
        band_mults     => $a{band_mults} // [ 1.0, 2.0, 3.0 ],
    };
    bless $self, $class;
    return $self;
}

sub get_values      { return []; }
sub get_market_data { return $_[0]->{_market_data}; }

sub reset {
    my ($self) = @_;
    $self->{_c} = [];
    $self->{_tf} = undef; $self->{_cur_skey} = undef; $self->{_seen_open} = 0;
    $self->{_prev_lmin} = undef;
    $self->{_smc_seen} = 0; $self->{_vp_seen} = 0; $self->{_market_data} = undef;
    $self->{_events} = {};   # se re-registran en el rebuild (respetan el cutoff)
    $self->{_ma_cache} = undef; $self->{_ma_cache_key} = undef;
    # OJO: _manual_ts y _manual_source PERSISTEN (el ancla del usuario y su fuente
    # sobreviven a rebuild/replay; solo cambian por accion explicita del usuario).
}

# _record_event: guarda cada evento detectado (idx de vela + ts) por tipo, en
# orden ascendente de ts. Sirve para REANCLAR el VWAP unico a la fuente elegida
# sin recalcular nada. Respeta el cutoff (solo se registran eventos ya vistos).
sub _record_event {
    my ($self, $type, $idx, $ts) = @_;
    push @{ $self->{_events}{$type} }, { idx => $idx, ts => $ts };
}

# Fuente/tipo de ancla del VWAP unico (session|open|BOS|CHoCH|POC). Al cambiarla,
# el VWAP se reancla al evento de ese tipo mas cercano al clic (get_manual_anchor).
sub set_manual_source {
    my ($self, $type) = @_;
    return unless defined $type && $type ne '';
    $self->{_manual_source} = $type;
    $self->{_ma_cache} = undef; $self->{_ma_cache_key} = undef;
    return;
}
sub get_manual_source { return $_[0]->{_manual_source}; }

sub update_last {
    my ($self, $md) = @_;
    my $i = $md->last_index; return if $i < 0;
    $self->update_at_index($md, $i);
}

# Desviacion estandar PONDERADA por volumen (igual que el Pine de referencia):
#   variance = max(0, Sum(src^2*vol)/Sum(vol) - vwap^2) ; stdev = sqrt(variance).
sub _stdev {
    my ($pv, $pv2, $v) = @_;
    return undef unless $v && $v > 0;
    my $mean = $pv / $v;
    my $var  = ($pv2 / $v) - ($mean * $mean);
    $var = 0 if $var < 0;
    return sqrt($var);
}

# Precio base por FUENTE del ancla: 'Apertura de mercado' = apertura de la vela;
# el resto (Inicio de Sesion / BOS / CHoCH / POC) = HLC3 (estandar del VWAP).
my %SRC_OF_SOURCE = ( session=>'hlc3', open=>'open', BOS=>'hlc3', CHoCH=>'hlc3', POC=>'hlc3' );

sub _src {
    my ($self, $c) = @_;
    my $s = $self->{src}
         // $SRC_OF_SOURCE{ $self->{_manual_source} // 'session' } // 'hlc3';
    return $c->{open}                                           if $s eq 'open';
    return $c->{close}                                          if $s eq 'close';
    return ($c->{high}+$c->{low})/2                             if $s eq 'hl2';
    return ($c->{open}+$c->{high}+$c->{low}+$c->{close})/4      if $s eq 'ohlc4';
    return ($c->{high}+$c->{low}+$c->{close})/3;                # hlc3
}

sub _local_min {
    my ($self, $ts) = @_;
    my $loc = $ts + $self->{local_offset_sec};
    $loc %= 86400; $loc += 86400 if $loc < 0;
    return int($loc / 60);
}

sub _session_key {
    my ($self, $md, $ts) = @_;
    return $md->_bucket_ts_for($ts, $self->{session_tf}) if $md->can('_bucket_ts_for');
    return int(($ts + $self->{local_offset_sec} - 17*3600) / 86400);
}

sub update_at_index {
    my ($self, $md, $i) = @_;
    my $c = $md->get_candle($i); return unless defined $c;
    $self->{_market_data} = $md;
    $self->{_tf} = $md->get_timeframe;
    push @{ $self->{_c} }, $c;

    my $lm = $self->_local_min($c->{ts});

    # DETECTAR y REGISTRAR los eventos de cada tipo (sin futuro, respetando el
    # cutoff). Ya NO se crean anclas VWAP por tipo: hay UN solo VWAP re-anclable
    # (get_manual_anchor) que usa estos eventos para reanclarse a la fuente
    # elegida. La formula VWAP la aplica vwap_line desde el ancla efectiva.
    #   -- inicio de sesion (apertura ETH = cambio de bucket de sesion)
    my $skey = $self->_session_key($md, $c->{ts});
    if (!defined $self->{_cur_skey} || $self->{_cur_skey} != $skey) {
        $self->{_cur_skey} = $skey;
        $self->{_seen_open} = 0;   # nueva sesion: re-armar deteccion de apertura oficial
        $self->_record_event('session', $i, $c->{ts});
    }
    #   -- apertura oficial del mercado (distinta del inicio ETH): CRUCE hacia
    #      arriba del minuto de apertura (509->510), no un simple ">=". Asi no se
    #      dispara en la apertura ETH (17:00) que ya cumple ">=08:30".
    if (!$self->{_seen_open} && defined $self->{_prev_lmin}
        && $self->{_prev_lmin} < $self->{official_open_min}
        && $lm >= $self->{official_open_min}) {
        $self->{_seen_open} = 1;
        $self->_record_event('open', $i, $c->{ts});
    }
    #   -- BOS / CHoCH confirmados (cursor sobre eventos de SMC; e->ts == ts de i)
    if ($self->{smc}) {
        my $ev = $self->{smc}->get_events;
        while ($self->{_smc_seen} < scalar(@$ev)) {
            my $e = $ev->[ $self->{_smc_seen} ];
            last if $e->{ts} > $c->{ts};                        # sin futuro
            $self->{_smc_seen}++;
            next if defined $self->{anchor_scope} && ($e->{scope}//'') ne $self->{anchor_scope};
            next unless $e->{type} eq 'BOS' || $e->{type} eq 'CHoCH';
            $self->_record_event($e->{type}, $i, $c->{ts});
        }
    }
    #   -- POC confirmado: al cerrar un perfil del Volume Profile, evento en su
    #      vela de control (mayor volumen del perfil).
    if ($self->{vp}) {
        my $profs = $self->{vp}->{_profiles};   # perfiles CERRADOS (confirmados)
        while ($self->{_vp_seen} < scalar(@$profs)) {
            my $p = $profs->[ $self->{_vp_seen} ];
            $self->{_vp_seen}++;
            next if $p->{incomplete} || !$p->{_idxs} || !@{ $p->{_idxs} };
            my $pi = $self->_poc_control_index($p);
            next unless defined $pi && $pi <= $i;
            $self->_record_event('POC', $pi, $self->{_c}[$pi]{ts});
        }
    }

    $self->{_prev_lmin} = $lm;
}

# vela de control del perfil = la de mayor volumen (proxy del nodo POC).
sub _poc_control_index {
    my ($self, $p) = @_;
    my ($bk, $bv) = (undef, -1);
    my $cands = $p->{_candles}; my $idxs = $p->{_idxs};
    return undef unless $cands && $idxs;
    for my $k (0 .. $#$cands) {
        my $vv = $cands->[$k]{volume} // 0;
        if ($vv > $bv) { $bv = $vv; $bk = $k; }
    }
    return defined $bk ? $idxs->[$bk] : undef;
}

# vwap_line: serie {idx,value,stdev} del VWAP de un ancla en [i_from,i_to]
# (recortada a [start_idx, ultima procesada]). La FORMULA vive aqui (no en el
# overlay): el render solo pide el tramo visible y calcula las bandas value+-stdev*
# mult. El ultimo valor coincide con anchor->{value}/anchor->{stdev}.
sub vwap_line {
    my ($self, $a, $i_from, $i_to) = @_;
    my $s    = $a->{start_idx};
    my $last = $#{ $self->{_c} };
    # una ancla inactive quedo CONGELADA en su end_idx: la serie no la sobrepasa.
    my $cap  = defined $a->{end_idx} ? $a->{end_idx} : $last;
    $cap = $last if $cap > $last;
    $i_from = $s   if $i_from < $s;
    $i_to   = $cap if $i_to   > $cap;
    return [] if $i_to < $i_from || !defined $s;
    my ($pv, $pv2, $v) = (0, 0, 0);
    for my $j ($s .. $i_from - 1) {
        my $c = $self->{_c}[$j] or next; my $vv = $c->{volume} // 0;
        my $sv = $self->_src($c);
        $pv += $sv * $vv; $pv2 += $sv * $sv * $vv; $v += $vv;
    }
    my @out;
    for my $j ($i_from .. $i_to) {
        my $c = $self->{_c}[$j] or next; my $vv = $c->{volume} // 0;
        my $sv = $self->_src($c);
        $pv += $sv * $vv; $pv2 += $sv * $sv * $vv; $v += $vv;
        push @out, {
            idx   => $j,
            value => ($v > 0 ? $pv / $v : undef),
            stdev => _stdev($pv, $pv2, $v),
        };
    }
    return \@out;
}

# =============================================================================
# ANCLA MANUAL (clic del usuario). Se guarda por TIMESTAMP y se computa BAJO
# DEMANDA desde las velas cargadas: asi persiste ante zoom/pan/Replay/cambio de
# TF (el ts es independiente del indice) y no interfiere con las 5 anclas auto.
# =============================================================================
sub set_manual_anchor {
    my ($self, $ts) = @_;
    $self->{_manual_ts} = $ts;   # O(1): SOLO guarda el ts. El ancla se computa
    return;                      # bajo demanda en get_manual_anchor (1 vez por
                                 # render). Antes devolvia get_manual_anchor (O(N)
                                 # = recorre todas las velas) en CADA llamada, y al
                                 # arrastrar el marcador se llama por cada evento de
                                 # B1-Motion -> saturaba el hilo de Tk y el grafico
                                 # se congelaba ("las velas se escondian").
}
sub clear_manual_anchor { $_[0]->{_manual_ts} = undef; $_[0]->{_ma_cache} = undef; $_[0]->{_ma_cache_key} = undef; return; }
sub has_manual_anchor   { return defined $_[0]->{_manual_ts} ? 1 : 0; }

# get_manual_anchor: ancla EFECTIVA del VWAP unico, resuelta contra las velas
# ACTUALES (hasta el cutoff de Replay). Devuelve un objeto compatible con
# vwap_line, o undef.
#
# El clic del usuario fija una REFERENCIA (_manual_ts). La FUENTE (_manual_source:
# session|open|BOS|CHoCH|POC) decide en que EVENTO de ese tipo se ancla realmente
# el VWAP: el MAS CERCANO a la referencia (antes o despues). Si no hay eventos de
# ese tipo, cae al propio clic.
#
# CACHE: se recomputa solo si cambia la referencia, la fuente o el nº de velas
# (Replay/nuevas). Asi un render que no cambia nada es O(1).
sub get_manual_anchor {
    my ($self) = @_;
    my $ts = $self->{_manual_ts};
    return undef unless defined $ts;
    my $c = $self->{_c};
    my $n = scalar @$c;
    return undef unless $n;
    my $source = $self->{_manual_source} // 'session';
    my $key = "$ts:$source:$n";
    return $self->{_ma_cache} if ($self->{_ma_cache_key} // '') eq $key;

    # (1) vela de REFERENCIA = primera con ts >= _manual_ts (busqueda binaria,
    #     velas ordenadas por ts). Es el fallback si la fuente no tiene eventos.
    my $ref;
    if ($c->[$n-1]{ts} < $ts) {
        $ref = $n - 1;                       # el clic cae despues de todos los datos
    } else {
        my ($lo, $hi) = (0, $n - 1);
        while ($lo <= $hi) {
            my $mid = int(($lo + $hi) / 2);
            if ($c->[$mid]{ts} >= $ts) { $ref = $mid; $hi = $mid - 1; }
            else { $lo = $mid + 1; }
        }
    }
    $ref //= 0;

    # (2) VELA DEL ANCLA segun la FUENTE:
    #     - session / open / POC: EXACTAMENTE la vela donde el usuario anclo
    #       ("donde yo ancle, desde ahi se grafican las lineas y se mantienen").
    #     - BOS / CHoCH (excepcion): se BUSCA la ultima confirmacion SMC EN o
    #       ANTES de la vela del usuario y el ancla se coloca ahi (sin futuro;
    #       sin confirmaciones, cae a la vela del usuario).
    #     La MARCA (rombo) y el NACIMIENTO de las lineas son SIEMPRE el mismo
    #     punto (start_idx); las sumas del VWAP REINICIAN estrictamente ahi.
    my $ai = $ref;
    if ($source eq 'BOS' || $source eq 'CHoCH') {
        my $list = $self->{_events}{$source};
        if ($list && @$list) {
            for my $e (@$list) {          # registrados en orden ascendente
                last if $e->{idx} > $ref; # sin futuro
                $ai = $e->{idx};
            }
        }
    }

    # Objeto LIGERO: value/stdev/cum_* quedan undef a proposito. El overlay dibuja
    # el VWAP y las bandas del tramo VISIBLE con vwap_line (que reacumula desde
    # start_idx). Nadie fuera de aqui usa value/stdev/cum_* del ancla.
    my $anchor = {
        id => 'manual', type => 'manual', source => $source,
        ts => $c->[$ai]{ts}, tf => $self->{_tf},
        # ref_idx = vela del CLIC del usuario (referencia de busqueda para BOS/
        # CHoCH). El ROMBO se dibuja en start_idx (la vela del ancla) al PRECIO
        # BASE de la fuente ('open'=apertura; el resto=HLC3): coincide con el
        # primer valor del VWAP, asi la marca y las lineas nacen juntas.
        ref_idx      => $ref,
        anchor_price => $self->_src($c->[$ai]),
        value => undef, stdev => undef,
        state => 'active', origin => { manual_ts => $ts, source => $source },
        # start_idx = vela del ANCLA: ahi REINICIAN las sumas y nacen las lineas.
        start_idx => $ai, end_idx => $n - 1, end_ts => $c->[$n-1]{ts},
    };
    $self->{_ma_cache_key} = $key;
    $self->{_ma_cache}     = $anchor;
    return $anchor;
}

1;
