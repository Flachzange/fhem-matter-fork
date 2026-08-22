# $Id$
package main;

use strict;
use warnings;
use JSON;

# Zentrale Definition: Ein Cluster enthält Name, Attribute (mit ID & Feature-Zuordnung)
my %MATTER_CLUSTERS = (
    6 => {
        name       => "OnOff",
        attributes => {
            0 => { name => "state", feature => "has_onoff" },
        },
    },
    8 => {
        name       => "LevelControl",
        attributes => {
            0     => { name => "brightness", feature => "has_level" },
            16384 => { name => "max_level",  feature => "has_level" },
        },
    },
    40 => {
        name       => "BasicInformation",
        attributes => {
            1  => { name => "producer",         feature => undef },
            3  => { name => "model",            feature => undef },
            4  => { name => "vendor_id",        feature => undef },
            8  => { name => "firmware_version", feature => undef },
            18 => { name => "serial_number",    feature => undef },
        },
    },
    768 => {
        name       => "ColorControl",
        attributes => {
            0     => { name => "current_hue",        feature => "has_hue" },
            1     => { name => "current_saturation", feature => "has_saturation" },
            3     => { name => "current_x",          feature => "has_xy" },
            4     => { name => "current_y",          feature => "has_xy" },
            7     => { name => "color_temperature_mireds", feature => "has_ct" },
            16    => { name => "color_modes",        feature => undef },
            16395 => { name => "color_temp_min",     feature => "has_ct" },
            16396 => { name => "color_temp_max",     feature => "has_ct" },
        },
    },
);

sub MATTERDevice_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}    = "MATTERDevice_Define";
    $hash->{UndefFn}  = "MATTERDevice_Undef";
    $hash->{SetFn}    = "MATTERDevice_Set";
    $hash->{GetFn}    = "MATTERDevice_Get";
    $hash->{ParseFn}  = "MATTERDevice_Parse";
    $hash->{AttrList} = "locallog " .
                        "has_onoff:0,1 " .
                        "has_level:0,1 " .
                        "has_ct:0,1 " .
                        "has_hue:0,1 " .
                        "has_saturation:0,1 " .
                        "has_xy:0,1 " .
                        "color_temp_min " .
                        "color_temp_max " .
                        "max_level " .
                        $readingFnAttributes;
    $hash->{MatchList} = { "1" => ".*" };
}

sub MATTERDevice_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t]+", $def);

    return "wrong syntax: define <name> MATTERDevice <node_id>" if (@a < 3);

    my $name    = $a[0];
    my $node_id = $a[2];

    $hash->{node_id} = $node_id;
    $hash->{STATE}   = "Initialized";
    $modules{MATTERDevice}{defptr}{$node_id} = $hash;
    
    AssignIoPort($hash);
    Log3 $name, 3, "MATTERDevice: Defined node_id $node_id for $name";
    return undef;
}

sub MATTERDevice_Undef($$) {
    my ($hash, $arg) = @_;
    delete $modules{MATTERDevice}{defptr}{$hash->{node_id}} if $hash->{node_id};
    return undef;
}

# --- Hilfsfunktion zum sauberen Setzen von Attributen (überschreibt User-Werte nicht ungefragt) ---
sub MATTERDevice_SetAttributeIfNotExists($$$) {
    my ($name, $attr_name, $val) = @_;
    if (!defined(AttrVal($name, $attr_name, undef))) {
        CommandAttr(undef, "$name $attr_name $val");
        Log3 $name, 4, "MATTERDevice: Auto-set attribute $attr_name = $val for $name";
    }
}

sub MATTERDevice_Set($$@) {
    my ($hash, $name, $cmd, @args) = @_;

    my @setList = MATTERDevice_GetSetList($hash);
    my $list_str = join(" ", @setList);
    my $valid = 0;

    if ($cmd eq "?") {
        my $list_str = join(" ", @setList);
        return "Unknown argument $cmd, choose one of $list_str";
    }

    foreach my $item (@setList) {
        my ($cmd_name) = split(':', $item);
        if ($cmd_name eq $cmd) {
            $valid = 1;
            last;
        }
    }

    unless ($valid) {
        my $list_str = join(" ", @setList);
        return "Unknown argument $cmd, choose one of $list_str";
    }
    my $payload = undef;

    if ($cmd eq "on" || $cmd eq "off") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $hash->{node_id},
                endpoint_id  => 1,
                cluster_id   => 6,
                command_name => $cmd
            }
        };
    }
    elsif ($cmd eq "brightness") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $hash->{node_id},
                endpoint_id  => 1,
                cluster_id   => 8,
                command_name => "MoveToLevelWithOnOff",
                payload      => { level => int($args[0]), transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
            }
        };
    }
    elsif ($cmd eq "rgb") {
        my $hex = $args[0];
        $hex =~ s/^#//;
        my ($r, $g, $b) = map { hex($_) } ($hex =~ /(..)(..)(..)/);

        if (AttrVal($name, "has_xy", 0) && !AttrVal($name, "has_hue", 0)) {
            my $red   = ($r > 0.04045) ? (($r / 255 + 0.055) / 1.055) ** 2.4 : ($r / 255) / 12.92;
            my $green = ($g > 0.04045) ? (($g / 255 + 0.055) / 1.055) ** 2.4 : ($g / 255) / 12.92;
            my $blue  = ($b > 0.04045) ? (($b / 255 + 0.055) / 1.055) ** 2.4 : ($b / 255) / 12.92;

            my $X = $red * 0.664511 + $green * 0.154324 + $blue * 0.162028;
            my $Y = $red * 0.283881 + $green * 0.668433 + $blue * 0.047685;
            my $Z = $red * 0.000088 + $green * 0.072310 + $blue * 0.986039;

            my $x = ($X + $Y + $Z) > 0 ? int(($X / ($X + $Y + $Z)) * 65535) : 0;
            my $y = ($X + $Y + $Z) > 0 ? int(($Y / ($X + $Y + $Z)) * 65535) : 0;

            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $hash->{node_id},
                    endpoint_id  => 1,
                    cluster_id   => 768,
                    command_name => "MoveToColor",
                    payload      => { colorX => int($x), colorY => int($y), transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
                }
            };
        } else {
            $r /= 255; $g /= 255; $b /= 255;
            my $max = ($r > $g && $r > $b) ? $r : ($g > $b ? $g : $b);
            my $min = ($r < $g && $r < $b) ? $r : ($g < $b ? $g : $b);
            my $diff = $max - $min;
            my $h = 0;
            my $s = ($max == 0) ? 0 : ($diff / $max);

            if ($diff != 0) {
                if ($max == $r) { $h = 60 * (($g - $b) / $diff); }
                elsif ($max == $g) { $h = 60 * (($b - $r) / $diff + 2); }
                else { $h = 60 * (($r - $g) / $diff + 4); }
            }
            $h += 360 if $h < 0;

            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $hash->{node_id},
                    endpoint_id  => 1,
                    cluster_id   => 768,
                    command_name => "MoveToHueAndSaturation",
                    payload      => { hue => int(($h / 360) * 254), saturation => int($s * 254), transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
                }
            };
        }
    }
    elsif ($cmd eq "ct") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $hash->{node_id},
                endpoint_id  => 1,
                cluster_id   => 768,
                command_name => "MoveToColorTemperature",
                payload      => { colorTemperatureMireds => int($args[0]), transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
            }
        };
    }
    elsif ($cmd eq "getConfig") {
        my $ioHash = $hash->{IODev};
        return "No IODev assigned to $name" if (!$ioHash || !$ioHash->{fhem}{helper}{sendWS});

        foreach my $cluster_id (keys %MATTER_CLUSTERS) {
            my $cluster = $MATTER_CLUSTERS{$cluster_id};
            foreach my $attr_id (keys %{$cluster->{attributes}}) {
                my $msg_id = int(rand(100000) + 1);
                $ioHash->{fhem}{helper}{pending_config}{$msg_id} = $hash->{node_id};

                my $config_payload = {
                    message_id   => $msg_id,
                    command      => "read_attribute",
                    args         => {
                        node_id        => int($hash->{node_id}),
                        attribute_path => "1/$cluster_id/$attr_id"
                    }
                };
                $ioHash->{fhem}{helper}{sendWS}->(encode_json($config_payload));
            }
        }
        Log3 $name, 3, "MATTERDevice: Generic getConfig triggered for node $hash->{node_id}";
        return undef;
    }

    return "No payload generated" if (!$payload);

    if ($hash->{IODev} && $hash->{IODev}{fhem}{helper}{sendWS}) {
        $hash->{IODev}{fhem}{helper}{sendWS}->(encode_json($payload));
    } else {
        return "No send function found in IODev for $name";
    }

    return undef;
}

sub MATTERDevice_Get($$@) { return undef; }

# --- Zentraler Parser für alle Attribut-Updates ---
sub MATTERDevice_ProcessAttributeValue($$$$) {
    my ($hash, $cluster_id, $attr_id, $value) = @_; # quick unpack
    my $name = $hash->{NAME};

    my $cluster = $MATTER_CLUSTERS{$cluster_id};
    return if !$cluster;

    my $attr_info = $cluster->{attributes}{$attr_id};
    return if !$attr_info;

    my $attr_name = $attr_info->{name};
    my $feature   = $attr_info->{feature};

    # Bool-Handling für JSON
    if (ref($value) && $value->isa('JSON::PP::Boolean')) {
        $value = $value ? 1 : 0;
    }

    readingsBeginUpdate($hash);

    # Spezieller Fall: OnOff State mappen
    if ($cluster_id == 6 && $attr_id == 0) {
        my $state_val = $value ? "on" : "off";
        readingsBulkUpdate($hash, "state", $state_val);
    } 
    # Alle anderen Werte direkt als Reading speichern
    elsif (defined($attr_name)) {
        readingsBulkUpdate($hash, $attr_name, $value);
    }

    # Wenn ein Feature mit diesem Attribut verknüpft ist -> Attribut setzen
    if (defined($feature)) {
        MATTERDevice_SetAttributeIfNotExists($name, $feature, 1);
    }

    readingsEndUpdate($hash, 1);
}

sub MATTERDevice_Parse($$) {
    my ($hash, $data) = @_;
    my $name = $hash->{NAME};

    my $decoded = eval { decode_json($data) };
    if ($@) {
        Log3 $name, 3, "MATTERDevice: Parse JSON error: $@";
        return;
    }

    # 1. ANTWORT AUF GETCONFIG (enthält "result")
    if (exists $decoded->{result} && ref($decoded->{result}) eq 'HASH') {
        while (my ($path, $value) = each %{$decoded->{result}}) {
            if ($path =~ m{^\d+/(\d+)/(\d+)$}) {
                MATTERDevice_ProcessAttributeValue($hash, $1, $2, $value);
            }
        }
        return;
    }

    # 2. LIVE UPDATES (event == 'attribute_updated')
    if (exists $decoded->{event} && $decoded->{event} eq 'attribute_updated' && ref($decoded->{data}) eq 'ARRAY') {
        my ($node_id, $attribute_path, $value) = @{$decoded->{data}};
        if ($attribute_path =~ m{^(\d+)/(\d+)/(\d+)$}) {
            MATTERDevice_ProcessAttributeValue($hash, $2, $3, $value);
            Log3 $name, 4, "MATTERDevice: Live update ($attribute_path) = $value";
        }
        return;
    }

    # 3. INITIAL DISCOVER (node_id + attributes map)
    my $node_id = $decoded->{node_id};
    my $attributes = $decoded->{attributes};
    
    if ($node_id && $attributes && $hash->{node_id} eq $node_id) {
        while (my ($path, $value) = each %{$attributes}) {
            if ($path =~ m{^\d+/(\d+)/(\d+)$}) {
                MATTERDevice_ProcessAttributeValue($hash, $1, $2, $value);
            }
        }
    }
}

sub MATTERDevice_GetSetList($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my @list;
    
    push(@list, "on:noArg", "off:noArg") if (AttrVal($name, "has_onoff", 0));
    
    if (AttrVal($name, "has_level", 0)) {
        my $max_level = AttrVal($name, "max_level", 254);
        push(@list, "brightness:slider,0,1,$max_level");
    }
    
    if (AttrVal($name, "has_ct", 0)) {
        my $min_mired = AttrVal($name, "color_temp_min", 153);
        my $max_mired = AttrVal($name, "color_temp_max", 500);
        push(@list, "ct:colorpicker,CT,$min_mired,1,$max_mired");
    }
    
    push(@list, "rgb:colorpicker,RGB") if (AttrVal($name, "has_color", 0) || AttrVal($name, "has_xy", 0) || AttrVal($name, "has_hue", 0));
    push(@list, "getConfig:noArg");
    
    return @list;
}

1;

=pod
=item device
=item summary    Child module for controlling individual Matter nodes
=item summary_DE Child-Modul zur Steuerung einzelner Matter-Knoten
=begin html

<a name="MATTERDevice"></a>
<h3>MATTERDevice</h3>
<ul>
  The MATTERDevice module represents an individual Matter node (e.g., light bulb, 
  switch) managed by a central MATTER IO-Device. It dynamically adapts its 
  functionality (available SET commands and UI elements) based on the 
  Matter clusters supported by the physical device.<br><br>

  <a name="MATTERDevice-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; MATTERDevice &lt;node_id&gt;</code><br><br>
    The <code>node_id</code> corresponds to the identifier assigned by the Matter-Server.
  </ul>
  <br>

  <a name="MATTERDevice-set"></a>
  <b>Set</b>
  <ul>
    <li><code>on</code>, <code>off</code><br>
        Switches the device state (requires attribute <code>has_onoff</code>).</li>
    <li><code>brightness &lt;val&gt;</code><br>
        Sets the brightness (requires attribute <code>has_level</code>).</li>
    <li><code>ct &lt;val&gt;</code><br>
        Sets the color temperature in mireds (requires attribute <code>has_ct</code>).</li>
    <li><code>rgb &lt;hex&gt;</code><br>
        Sets the color using hex code (requires <code>has_xy</code> or <code>has_hue</code>).</li>
    <li><code>getConfig</code><br>
        Forces a synchronization of all supported attributes from the Matter-Server.</li>
  </ul>
  <br>

  <a name="MATTERDevice-attr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>has_onoff</code>, <code>has_level</code>, <code>has_ct</code>, 
        <code>has_hue</code>, <code>has_saturation</code>, <code>has_xy</code><br>
        Boolean attributes (0/1) to enable/disable specific function sets. These are 
        usually set automatically during the initial discovery or via <code>getConfig</code>.</li>
    <li><code>max_level</code>, <code>color_temp_min</code>, <code>color_temp_max</code><br>
        Configuration parameters for sliders and pickers.</li>
  </ul>
</ul>

=end html
=cut