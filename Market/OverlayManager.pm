package Market::OverlayManager;

# =============================================================================
# Market::OverlayManager
# Responsabilidad: gestionar overlays graficos desacoplados del motor de
# render principal. Analogo a Market::IndicatorManager, pero para la capa
# visual: registro por nombre, orden deterministico, y visibilidad
# individual on/off por overlay completo.
#
# Cada overlay registrado debe implementar el contrato minimo:
#   - tag()                      -> string (tag unico de canvas)
#   - render($canvas, $scale)    -> dibuja (y se auto-limpia con su tag)
#
# La granularidad de visibilidad de OverlayManager es POR OVERLAY
# COMPLETO (ej. "Liquidity" entero on/off). Si un overlay necesita
# sub-toggles internos (ej. BSL si/no, SSL si/no dentro de Liquidity),
# esos flags viven dentro del propio overlay, no aqui.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class) = @_;
    bless {
        overlays => {},   # nombre => objeto overlay
        _order   => [],   # orden de registro (iteracion deterministica)
        _visible => {},   # nombre => 0|1
    }, $class;
}

# -----------------------------------------------------------------------------
# register
# Registra un overlay bajo un nombre clave (ej: 'liquidity', 'fvg').
# Por defecto nace visible, salvo que se pase visible => 0 explicitamente.
# -----------------------------------------------------------------------------
sub register {
    my ($self, $name, $overlay, %opts) = @_;
    $self->{overlays}{$name} = $overlay;
    push @{ $self->{_order} }, $name
        unless grep { $_ eq $name } @{ $self->{_order} };
    $self->{_visible}{$name} = (exists $opts{visible} && !$opts{visible}) ? 0 : 1;
}

# -----------------------------------------------------------------------------
# get / names
# -----------------------------------------------------------------------------
sub get {
    my ($self, $name) = @_;
    return $self->{overlays}{$name};
}

sub names {
    my ($self) = @_;
    return @{ $self->{_order} };
}

# -----------------------------------------------------------------------------
# is_visible / set_visible / toggle
# -----------------------------------------------------------------------------
sub is_visible {
    my ($self, $name) = @_;
    return $self->{_visible}{$name} ? 1 : 0;
}

# on_visibility_change: hook opcional que se dispara cuando cambia la visibilidad
# de un overlay (lo usa el Replay para reconstruir el indicador recien activado).
sub on_visibility_change { $_[0]->{_on_vis_change} = $_[1]; }
sub _fire_vis_change { $_[0]->{_on_vis_change}->() if $_[0]->{_on_vis_change}; }

sub set_visible {
    my ($self, $name, $visible) = @_;
    return unless exists $self->{overlays}{$name};
    my $new = $visible ? 1 : 0;
    my $changed = ($self->{_visible}{$name} // 0) != $new;
    $self->{_visible}{$name} = $new;
    $self->_fire_vis_change if $changed;
}

sub toggle {
    my ($self, $name) = @_;
    return unless exists $self->{overlays}{$name};
    $self->{_visible}{$name} = $self->{_visible}{$name} ? 0 : 1;
    $self->_fire_vis_change;
    return $self->{_visible}{$name};
}

# -----------------------------------------------------------------------------
# render_all
# Por cada overlay registrado, en orden deterministico:
#   - Si esta visible: delega render($canvas, $scale). El overlay se
#     auto-limpia internamente con su propio tag antes de redibujar.
#   - Si NO esta visible: borra directamente sus items via su tag, sin
#     llamar a render(). Esto evita "basura" grafica de un frame previo
#     cuando el usuario desactiva un overlay.
# -----------------------------------------------------------------------------
sub render_all {
    my ($self, $canvas, $scale, $placer) = @_;
    for my $name (@{ $self->{_order} }) {
        my $overlay = $self->{overlays}{$name};
        if ($self->{_visible}{$name}) {
            $overlay->render($canvas, $scale, $placer);
        } else {
            $canvas->delete($overlay->tag);
        }
    }
}

1;