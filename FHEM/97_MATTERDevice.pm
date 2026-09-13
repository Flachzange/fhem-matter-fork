# $Id$
package main;

use strict;
use warnings;
use JSON;
use Scalar::Util qw(blessed);

# Globale Matter-Metadaten-IDs. Sie werden unabhängig von der clusterspezifischen
# Attributdefinition verarbeitet. EventList (0xFFFA) wird für ältere
# Matter-Versionen weiterhin unterstützt.
my %MATTER_GLOBAL_ATTRIBUTES = (
    0xFFF8 => "generated_commands",
    0xFFF9 => "accepted_commands",
    0xFFFA => "event_list",
    0xFFFB => "attribute_list",
    0xFFFC => "feature_map",
    0xFFFD => "cluster_revision",
);

# Zentrale Definition der vom FHEM-Modul fachlich unterstützten Cluster, Attribute und Commands
my %MATTER_CLUSTERS = (
    0x0006 => {
        name       => "OnOff",
        features   => {
            lighting            => 0,
            dead_front_behavior => 1,
            off_only            => 2,
        },
        attributes => {
            0x0000 => { name => "state", is_reading => 0, is_attribute => 0},
        },
        commands   => {
            0x00   => { name => "Off",    set_list => "off:noArg" },
            0x01   => { name => "On",     set_list => "on:noArg", forbidden_features => ["off_only"] },
            0x02   => { name => "Toggle", set_list => "toggle:noArg", forbidden_features => ["off_only"] },
            0x40   => { name => "OffWithEffect", set_list => "off_with_effect:textField", required_features => ["lighting"] },
            0x41   => { name => "OnWithRecallGlobalScene", set_list => "on_with_recall_global_scene:noArg", required_features => ["lighting"] },
            0x42   => { name => "OnWithTimedOff", set_list => "on_with_timed_off:textField", required_features => ["lighting"] },
        },
    },
    0x0008 => {
        name       => "LevelControl",
        features   => {
            on_off    => 0,
            lighting  => 1,
            frequency => 2,
        },
        attributes => {
            0x0000 => { name => "brightness", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "min_brightness", is_reading => 0, is_attribute => 1 },
            0x0003 => { name => "max_brightness", is_reading => 0, is_attribute => 1 },
            0x0004 => { name => "frequency", is_reading => 1, is_attribute => 0, required_features => ["frequency"] },
            0x0005 => { name => "min_frequency", is_reading => 0, is_attribute => 1, required_features => ["frequency"] },
            0x0006 => { name => "max_frequency", is_reading => 0, is_attribute => 1, required_features => ["frequency"] },
            0x4000 => { name => "startup_current_level", is_reading => 1, is_attribute => 0, required_features => ["lighting"] },
        },
        commands   => {
            0x00   => { name => "MoveToLevel", set_list => "move_to_level:slider,0,1,254 textField" },
            0x01   => { name => "Move", set_list => "move:up,down slider,0,1,254 textField" },
            0x02   => { name => "Step", set_list => "step:up, down slider,0,1,254 textField" },
            0x03   => { name => "Stop", set_list => "stop:textField" },
            0x04   => { name => "MoveToLevelWithOnOff", set_list => "move_to_level:slider,0,1,254 textField" },
            0x05   => { name => "MoveWithOnOff", set_list => "move:up,down slider,0,1,254 textField" },
            0x06   => { name => "StepWithOnOff", set_list => "step:up, down slider,0,1,254 textField" },
            0x07   => { name => "StopWithOnOff", set_list => "stop:textField" },
            0x08   => { name => "MoveToClosestFrequency", set_list => "move_to_frequency:textField", required_features => ["frequency"] },
        }
    },
    0x0028 => {
        name       => "BasicInformation",
        attributes => {
            0x0001 => { name => "producer", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "vendor_id", is_reading => 1, is_attribute => 0 },
            0x0003 => { name => "model", is_reading => 1, is_attribute => 0 },
            0x0008 => { name => "hardware_version", is_reading => 1, is_attribute => 0 },
            0x000A => { name => "firmware_version", is_reading => 1, is_attribute => 0 },
            0x000F => { name => "serial_number", is_reading => 1, is_attribute => 0 },
        },
    },
    0x002F => {
        name       => "PowerSource",
        attributes => {
            0x0000 => { name => "power_source_status", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "power_source_description", is_reading => 1, is_attribute => 0 },
            0x000B => { name => "battery_voltage_mV", is_reading => 1, is_attribute => 0 },
            0x000C => { name => "battery_percent", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 2 : undef } },
            0x000D => { name => "battery_time_remaining_s", is_reading => 1, is_attribute => 0 },
            0x000E => { name => "battery_charge_level", is_reading => 1, is_attribute => 0 },
            0x000F => { name => "battery_replacement_needed", is_reading => 1, is_attribute => 0 },
            0x0010 => { name => "battery_replaceability", is_reading => 1, is_attribute => 0 },
            0x0013 => { name => "battery_replacement_description", is_reading => 1, is_attribute => 0 },
            0x0014 => { name => "battery_common_designation", is_reading => 1, is_attribute => 0 },
            0x0018 => { name => "battery_capacity_mAh", is_reading => 1, is_attribute => 0 },
            0x0019 => { name => "battery_quantity", is_reading => 1, is_attribute => 0 },
        },
    },
    0x005B => {
        name       => "Air Quality",
        attributes => {
            0x0000 => { name => "air_quality", is_reading => 1, is_attribute => 0 },
        },
    },
    0x005C => {
        name       => "SmokeCoAlarm",
        attributes => {
            0x0000 => { name => "alarm_expressed_state", is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "smoke_state", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "co_state", is_reading => 1, is_attribute => 0 },
            0x0003 => { name => "alarm_battery", is_reading => 1, is_attribute => 0 },
            0x0004 => { name => "device_muted", is_reading => 1, is_attribute => 0 },
            0x0005 => { name => "test_in_progress", is_reading => 1, is_attribute => 0 },
            0x0006 => { name => "hardware_fault", is_reading => 1, is_attribute => 0 },
            0x0007 => { name => "end_of_service", is_reading => 1, is_attribute => 0 },
            0x0008 => { name => "interconnect_smoke_alarm", is_reading => 1, is_attribute => 0 },
            0x0009 => { name => "interconnect_co_alarm", is_reading => 1, is_attribute => 0 },
        },
    },
    0x040C => {
        name       => "CarbonMonoxideConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "co_concentration", is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "co_minimum", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "co_maximum", is_reading => 1, is_attribute => 0 },
            0x0008 => { name => "co_unit", is_reading => 1, is_attribute => 0 },
            0x0009 => { name => "co_medium", is_reading => 1, is_attribute => 0 },
        },
    },
    0x0101 => {
        name       => "Door Lock",
        attributes => {
            0x0000 => { name => "lock_state", is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "lock_type", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "actuator_enabled", is_reading => 1, is_attribute => 0},
            0x0003 => { name => "door_state", is_reading => 1, is_attribute => 0 },
            0x0004 => { name => "door_open_events", is_reading => 1, is_attribute => 0 },
            0x0005 => { name => "door_close_events", is_reading => 1, is_attribute => 0 },
            0x0006 => { name => "open_period", is_reading => 1, is_attribute => 0 },
            0x0011 => { name => "num_total_users_supported", is_reading => 1, is_attribute => 0 },
            0x0012 => { name => "num_pin_users_supported", is_reading => 1, is_attribute => 0 },
            0x0013 => { name => "num_rfid_users_supported", is_reading => 1, is_attribute => 0 },
            0x0014 => { name => "num_week_day_schedule_per_user", is_reading => 1, is_attribute => 0 },
            0x0015 => { name => "num_year_day_schedule_per_user", is_reading => 1, is_attribute => 0 },
            0x0016 => { name => "num_holiday_schedules", is_reading => 1, is_attribute => 0 },
            0x0017 => { name => "max_pin_code_length", is_reading => 0, is_attribute => 1 },
            0x0018 => { name => "min_pin_code_length", is_reading => 0, is_attribute => 1 },
            0x0019 => { name => "max_rfid_code_length", is_reading => 0, is_attribute => 1 },
            0x001A => { name => "min_rfid_code_length", is_reading => 0, is_attribute => 1 },
            0x001B => { name => "credential_rules_support", is_reading => 1, is_attribute => 0 },
            0x001C => { name => "num_credentials_per_user", is_reading => 1, is_attribute => 0 },
            0x0021 => { name => "language", is_reading => 1, is_attribute => 0 },
        },
        commands   => {
            0x00   => { name => "LockDoor",   set_list => "lock:noArg" },
            0x01   => { name => "UnlockDoor", set_list => "unlock:noArg" },
        },
    },
    0x0102 => {
        name       => "WindowCovering",
        features   => {
            lift                => 0,
            tilt                => 1,
            position_aware_lift => 2,
            absolute_position   => 3,
            position_aware_tilt => 4,
        },
        attributes => {
            0x0000 => { name => "wc_type", is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "physical_closed_limit_lift", is_reading => 0, is_attribute => 1, required_features => ["lift", "position_aware_lift", "absolute_position"] },
            0x0002 => { name => "physical_closed_limit_tilt", is_reading => 0, is_attribute => 1, required_features => ["tilt", "position_aware_tilt", "absolute_position"] },
            0x0003 => { name => "current_position_lift", is_reading => 1, is_attribute => 0, required_features => ["lift", "position_aware_lift", "absolute_position"] },
            0x0004 => { name => "current_position_tilt", is_reading => 1, is_attribute => 0, required_features => ["tilt", "position_aware_tilt", "absolute_position"] },
            0x0005 => { name => "number_of_actuations_lift", is_reading => 1, is_attribute => 0 },
            0x0006 => { name => "number_of_actuations_tilt", is_reading => 1, is_attribute => 0},
            0x0007 => { name => "ws_config_status", is_reading => 1, is_attribute => 0},
            0x0008 => { name => "current_position_lift_percentage", is_reading => 1, is_attribute => 0 },
            0x0009 => { name => "current_position_tilt_percentage", is_reading => 1, is_attribute => 0 },
            0x000A => { name => "wc_operational_status", is_reading => 1, is_attribute => 0 },
            0x000B => { name => "target_position_lift_percent_100_ths", is_reading => 1, is_attribute => 0 },
            0x000C => { name => "target_position_tilt_percent_100_ths", is_reading => 1, is_attribute => 0 },
            0x000D => { name => "wc_end_product_type", is_reading => 1, is_attribute => 0},
            0x000E => { name => "current_position_lift_percent_100_ths", is_reading => 1, is_attribute => 0 },
            0x000F => { name => "current_position_tilt_percent_100_ths", is_reading => 1, is_attribute => 0 },
            0x0010 => { name => "installed_open_limit_lift", is_reading => 1, is_attribute => 0, required_features => ["lift", "position_aware_lift", "absolute_position"] },
            0x0011 => { name => "installed_closed_limit_lift", is_reading => 1, is_attribute => 0, required_features => ["lift", "position_aware_lift", "absolute_position"] },
            0x0012 => { name => "installed_open_limit_tilt", is_reading => 1, is_attribute => 0, required_features => ["tilt", "position_aware_tilt", "absolute_position"] },
            0x0013 => { name => "installed_closed_limit_tilt", is_reading => 1, is_attribute => 0, required_features => ["tilt", "position_aware_tilt", "absolute_position"] },
            0x0017 => { name => "wc_mode", is_reading => 1, is_attribute => 0 },
            0x001A => { name => "wc_safety_status", is_reading => 1, is_attribute => 0 },

        },
        commands => {
            0x00   => { name => "UpOrOpen", set_list => "on:noArg" },
            0x01   => { name => "DownOrClose", set_list => "off:noArg" },
            0x02   => { name => "StopMotion", set_list => "stop:noArg" },
            0x05   => { name => "GoToLiftPercentage", set_list => "pct:slider,0,1,100", required_features => ["lift"] },
            0x08   => { name => "GoToTiltPercentage", set_list => "tilt:slider,0,1,100", required_features => ["tilt"] },
        },
    },
    0x0300 => {
        name       => "ColorControl",
        features   => {
            hue_saturation    => 0,
            enhanced_hue      => 1,
            color_loop        => 2,
            xy                => 3,
            color_temperature => 4,
        },
        attributes => {
            0x0000 => { name => "current_hue", is_reading => 1, is_attribute => 0, required_features => ["hue_saturation"] },
            0x0001 => { name => "current_saturation", is_reading => 1, is_attribute => 0, required_features => ["hue_saturation"] },
            0x0003 => { name => "current_x", is_reading => 1, is_attribute => 0, required_features => ["xy"] },
            0x0004 => { name => "current_y", is_reading => 1, is_attribute => 0, required_features => ["xy"] },
            0x0007 => { name => "color_temperature_mireds", is_reading => 1, is_attribute => 0, required_features => ["color_temperature"] },
            0x0008 => { name => "color_mode", is_reading => 1, is_attribute => 0 },
            0x400B => { name => "color_temp_min", is_reading => 0, is_attribute => 1, required_features => ["color_temperature"] },
            0x400C => { name => "color_temp_max", is_reading => 0, is_attribute => 1, required_features => ["color_temperature"] },
        },
        commands => {
            0x06 => { name => "MoveToHueAndSaturation", required_features => ["hue_saturation"] },
            0x07 => { name => "MoveToColor", required_features => ["xy"] },
            0x0A => { name => "MoveToColorTemperature", required_features => ["color_temperature"] },
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
    $hash->{AttrList} = "color_temp_min " .
                        "color_temp_max " .
                        "min_brightness " .
                        "max_brightness " .
                        "min_frequency " .
                        "max_frequency " .
                        "min_pin_code_length " .
                        "max_pin_code_length " .
                        "min_rfid_code_length " .
                        "max_rfid_code_length " .
                        $readingFnAttributes;
    $hash->{MatchList} = { "1" => ".*" };
}

sub MATTERDevice_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t]+", $def);

    return "wrong syntax: define <name> MATTERDevice <node_id> [<endpoint_id>, <root_device_name>]" if (@a < 3);

    my $name    = $a[0];
    my $node_id = $a[2];
    my $endpoint_id = $a[3] // 0;
    my $root_device_name = $a[4] // undef;

    $hash->{node_id} = $node_id;
    $hash->{endpoint_id} = $endpoint_id;
    $hash->{STATE}   = "Initialized";
    if ($root_device_name) {
        $hash->{device} = $root_device_name;
    }
    
    if ($endpoint_id == 0) {
        AssignIoPort($hash);
        my $io_name = $hash->{IODev} ? $hash->{IODev}{NAME} : 'no_io';
        $modules{MATTERDevice}{defptr}{"$io_name:$node_id"} = $hash;
    }
    Log3 $name, 3, "MATTERDevice: Defined node_id $node_id for $name";
    return undef;
}

sub MATTERDevice_Undef($$) {
my ($hash, $arg) = @_;
    if (($hash->{node_id}) && ($hash->{endpoint_id} == 0)) {
        my $io_name = $hash->{IODev} ? $hash->{IODev}{NAME} : 'no_io';
        delete $modules{MATTERDevice}{defptr}{"$io_name:$hash->{node_id}"};
    }
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

sub MATTERDevice_NormalizeMatterId($) {
    my ($value) = @_;
    return undef if (!defined($value) || ref($value));
    return hex($value) if ($value =~ /^0x[0-9a-f]+$/i);
    return int($value) if ($value =~ /^\d+$/);
    return undef;
}

# Verarbeitet die globalen Matter-Attribute clusterunabhängig und speichert sie
# pro Endpoint-Device und Cluster. Rückgabe 1 bedeutet: globales Attribut wurde behandelt.
sub MATTERDevice_ProcessGlobalAttribute($$$$) {
    my ($hash, $cluster_id, $attr_id, $value) = @_;
    return 0 if (!exists($MATTER_GLOBAL_ATTRIBUTES{$attr_id}));

    my $key = $MATTER_GLOBAL_ATTRIBUTES{$attr_id};
    my $cap = ($hash->{helper}{capabilities}{$cluster_id} //= {});
    $cap->{present} = 1;

    # Die vier globalen Listen werden einheitlich als Sets gespeichert. Damit
    # sind AcceptedCommandList, GeneratedCommandList, EventList und AttributeList
    # über dieselbe generische Abfrage auswertbar.
    if ($attr_id >= 0xFFF8 && $attr_id <= 0xFFFB) {
        if (ref($value) eq 'ARRAY') {
            my %ids;
            foreach my $raw_id (@{$value}) {
                my $id = MATTERDevice_NormalizeMatterId($raw_id);
                $ids{$id} = 1 if (defined($id));
            }
            $cap->{$key} = \%ids;
        }
    }
    elsif ($attr_id == 0xFFFC) {
        my $feature_map = MATTERDevice_NormalizeMatterId($value);
        $cap->{$key} = $feature_map if (defined($feature_map));
    }
    elsif ($attr_id == 0xFFFD) {
        my $revision = MATTERDevice_NormalizeMatterId($value);
        $cap->{$key} = $revision if (defined($revision));
    }

    return 1;
}

sub MATTERDevice_CapabilityContains($$$$) {
    my ($hash, $cluster_id, $list_name, $id) = @_;
    my $list = $hash->{helper}{capabilities}{$cluster_id}{$list_name};
    return 0 if (ref($list) ne 'HASH');
    return exists($list->{$id}) ? 1 : 0;
}

sub MATTERDevice_CommandGenerated($$$) {
    my ($hash, $cluster_id, $command_id) = @_;
    return MATTERDevice_CapabilityContains($hash, $cluster_id, "generated_commands", $command_id);
}

sub MATTERDevice_CommandAccepted($$$) {
    my ($hash, $cluster_id, $command_id) = @_;
    return MATTERDevice_CapabilityContains($hash, $cluster_id, "accepted_commands", $command_id);
}

sub MATTERDevice_EventSupported($$$) {
    my ($hash, $cluster_id, $event_id) = @_;
    return MATTERDevice_CapabilityContains($hash, $cluster_id, "event_list", $event_id);
}

sub MATTERDevice_AttributeSupported($$$) {
    my ($hash, $cluster_id, $attr_id) = @_;
    return MATTERDevice_CapabilityContains($hash, $cluster_id, "attribute_list", $attr_id);
}

sub MATTERDevice_FeatureSupported($$$) {
    my ($hash, $cluster_id, $feature) = @_;
    my $feature_map = $hash->{helper}{capabilities}{$cluster_id}{feature_map};
    return 0 if (!defined($feature_map) || ref($feature_map));

    my $bit;
    if (defined($feature) && !ref($feature) && $feature =~ /^\d+$/) {
        $bit = int($feature);
    } else {
        my $cluster = $MATTER_CLUSTERS{$cluster_id};
        return 0 if (!$cluster || ref($cluster->{features}) ne 'HASH');
        return 0 if (!defined($feature) || !exists($cluster->{features}{$feature}));
        $bit = $cluster->{features}{$feature};
    }

    return (($feature_map & (1 << $bit)) != 0) ? 1 : 0;
}

sub MATTERDevice_ClusterRevision($$) {
    my ($hash, $cluster_id) = @_;
    my $revision = $hash->{helper}{capabilities}{$cluster_id}{cluster_revision};
    return undef if (!defined($revision) || ref($revision));
    return int($revision);
}

sub MATTERDevice_ClusterRevisionAtLeast($$$) {
    my ($hash, $cluster_id, $minimum) = @_;
    my $revision = MATTERDevice_ClusterRevision($hash, $cluster_id);
    return 0 if (!defined($revision));
    return $revision >= $minimum ? 1 : 0;
}

# AttributeList ist die Quelle für die tatsächliche Präsenz. Für bekannte
# Attribute werden zusätzlich FeatureMap- und ClusterRevision-Bedingungen
# aus der lokalen Matter-Abbildung geprüft.
sub MATTERDevice_AttributeUsable($$$) {
    my ($hash, $cluster_id, $attr_id) = @_;
    return 0 if (!MATTERDevice_AttributeSupported($hash, $cluster_id, $attr_id));

    my $cluster = $MATTER_CLUSTERS{$cluster_id};
    return 1 if (!$cluster || ref($cluster->{attributes}) ne 'HASH');

    my $attribute = $cluster->{attributes}{$attr_id};
    return 1 if (!$attribute);

    if (defined($attribute->{min_revision})) {
        return 0 if (!MATTERDevice_ClusterRevisionAtLeast($hash, $cluster_id, $attribute->{min_revision}));
    }
    foreach my $feature (@{$attribute->{required_features} // []}) {
        return 0 if (!MATTERDevice_FeatureSupported($hash, $cluster_id, $feature));
    }

    return 1;
}

# Ein FHEM-Command gilt nur dann als verfügbar, wenn der Matter-Server ihn
# tatsächlich in AcceptedCommandList meldet und die für diesen Command
# hinterlegten FeatureMap-Bedingungen erfüllt sind.
sub MATTERDevice_CommandSupported($$$) {
    my ($hash, $cluster_id, $command_id) = @_;
    return 0 if (!MATTERDevice_CommandAccepted($hash, $cluster_id, $command_id));

    my $cluster = $MATTER_CLUSTERS{$cluster_id};
    return 1 if (!$cluster || ref($cluster->{commands}) ne 'HASH');

    my $command = $cluster->{commands}{$command_id};
    return 1 if (!$command);

    foreach my $feature (@{$command->{required_features} // []}) {
        return 0 if (!MATTERDevice_FeatureSupported($hash, $cluster_id, $feature));
    }
    foreach my $feature (@{$command->{forbidden_features} // []}) {
        return 0 if (MATTERDevice_FeatureSupported($hash, $cluster_id, $feature));
    }

    return 1;
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
    
    my $payload       = undef;
    my $level_payload = undef;
    my $node_id     = $hash->{node_id};
    my $endpoint_id = $hash->{endpoint_id} // 1;

    if ($cmd eq "on" || $cmd eq "off") {
        my $onoff_command_id = ($cmd eq "on") ? 0x01 : 0x00;
        my $wc_command_id    = ($cmd eq "on") ? 0x00 : 0x01;
        my $can_onoff = MATTERDevice_CommandSupported($hash, 0x0006, $onoff_command_id);
        my $can_wc    = MATTERDevice_CommandSupported($hash, 0x0102, $wc_command_id);

        if ($can_onoff) {
            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $node_id,
                    endpoint_id  => int($endpoint_id),
                    cluster_id   => 0x0006,
                    command_name => ($cmd eq "on" ? "On" : "Off")
                }
            };
        }
        elsif ($can_wc) {
            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $node_id,
                    endpoint_id  => int($endpoint_id),
                    cluster_id   => 0x0102,
                    command_name => ($cmd eq "on" ? "UpOrOpen" : "DownOrClose")
                }
            };
        }
    }
    elsif ($cmd eq "toggle") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id     => $node_id,
                endpoint_id => int($endpoint_id),
                cluster_id  => 6,
                command_name => "Toggle"
            }
        };
    }
    elsif ($cmd eq "off_with_effect") {
        my $usage = "Usage: set $name off_with_effect <EffectIdentifier>,<EffectVariant> " .
                    "(DelayedAllOff: DelayedOffFastFade|NoFade|DelayedOffSlowFade; DyingLight: DyingLightFadeOff)";
        return $usage if (@args != 1);

        my ($effect_name, $variant_name, $extra) = split(/,/, $args[0], 3);
        return $usage if (!defined($effect_name) || !defined($variant_name) || defined($extra));

        my %effect_identifier = (
            DelayedAllOff => 0,
            DyingLight    => 1,
        );
        my %effect_variant = (
            DelayedAllOff => {
                DelayedOffFastFade => 0,
                NoFade             => 1,
                DelayedOffSlowFade => 2,
            },
            DyingLight => {
                DyingLightFadeOff => 0,
            },
        );

        return "Unknown EffectIdentifier '$effect_name'" if (!exists($effect_identifier{$effect_name}));
        return "Unknown EffectVariant '$variant_name' for $effect_name" if (!exists($effect_variant{$effect_name}{$variant_name}));

        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 0x0006,
                command_name => "OffWithEffect",
                payload      => {
                    effectIdentifier => $effect_identifier{$effect_name},
                    effectVariant    => $effect_variant{$effect_name}{$variant_name}
                }
            }
        };
    }
    elsif ($cmd eq "on_with_recall_global_scene") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 6,
                command_name => "OnWithRecallGlobalScene"
            }
        };
    }
    elsif ($cmd eq "on_with_timed_off") {
        my $usage = "Usage: set $name on_with_timed_off <acceptOnlyWhenOn>,<onTime>,<offWaitTime> (times in 0.1 s)";
        return $usage if (@args != 1);

        my @timed_args = split(/,/, $args[0], -1);
        return $usage if (@timed_args != 3);
        return $usage if (grep { !defined($_) || $_ !~ /^\d+$/ } @timed_args);

        my ($accept_only_when_on, $on_time, $off_wait_time) = map { int($_) } @timed_args;
        return "acceptOnlyWhenOn must be 0 or 1" if ($accept_only_when_on > 1);
        return "onTime must be between 0 and 65534 (0.1 s units)" if ($on_time > 65534);
        return "offWaitTime must be between 0 and 65534 (0.1 s units)" if ($off_wait_time > 65534);

        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 6,
                command_name => "OnWithTimedOff",
                payload      => {
                    onOffControl => $accept_only_when_on,
                    onTime       => $on_time,
                    offWaitTime  => $off_wait_time
                }
            }
        };
    }
    elsif ($cmd eq "stop") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 0x0102,
                command_name => "StopMotion"
            }
        };
    }
    elsif ($cmd eq "brightness") {
        my $use_with_onoff = MATTERDevice_CommandSupported($hash, 0x0008, 0x04);
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 0x0008,
                command_name => ($use_with_onoff ? "MoveToLevelWithOnOff" : "MoveToLevel"),
                payload      => { level => int($args[0]), transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
            }
        };
    }
    elsif ($cmd eq "pct") {
        my $can_wc_pct = MATTERDevice_CommandSupported($hash, 0x0102, 0x05);
        if ($can_wc_pct) {
            my $position = $args[0] * 100;
            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $node_id,
                    endpoint_id  => int($endpoint_id),
                    cluster_id   => 0x0102,
                    command_name => "GoToLiftPercentage",
                    payload      => { liftPercent100thsValue => $position }
                }
            };
        } else {
            my $max_level = MATTERDevice_AttributeUsable($hash, 0x0008, 0x0003)
            ? AttrVal($name, "max_brightness", 254)
            : 254;
            my $use_with_onoff = MATTERDevice_CommandSupported($hash, 0x0008, 0x04);
            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $node_id,
                    endpoint_id  => int($endpoint_id),
                    cluster_id   => 0x0008,
                    command_name => ($use_with_onoff ? "MoveToLevelWithOnOff" : "MoveToLevel"),
                    payload      => { level => int($args[0]) * $max_level / 100, transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
                }
            };
        }
    }
    elsif ($cmd eq "tilt") {
        my $tilt = $args[0] * 100;
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 0x0102,
                command_name => "GoToTiltPercentage",
                payload      => { tiltPercent100thsValue => $tilt }
            }
        };
    }
    elsif ($cmd eq "rgb") {
        my $hex = $args[0];
        $hex =~ s/^#//;
        my ($r, $g, $b) = map { hex($_) } ($hex =~ /(..)(..)(..)/);

        my $can_xy = MATTERDevice_CommandSupported($hash, 0x0300, 0x07);
        my $can_hs = MATTERDevice_CommandSupported($hash, 0x0300, 0x06);

        if ($can_xy && !$can_hs) {
            # Convert sRGB to linear RGB. The transfer-function threshold applies
            # to normalized components in the 0..1 range.
            my $sr = $r / 255;
            my $sg = $g / 255;
            my $sb = $b / 255;
            my $red   = ($sr > 0.04045) ? (($sr + 0.055) / 1.055) ** 2.4 : $sr / 12.92;
            my $green = ($sg > 0.04045) ? (($sg + 0.055) / 1.055) ** 2.4 : $sg / 12.92;
            my $blue  = ($sb > 0.04045) ? (($sb + 0.055) / 1.055) ** 2.4 : $sb / 12.92;

            # Standard sRGB / BT.709 primaries with D65 white point.
            my $X = $red * 0.4124564 + $green * 0.3575761 + $blue * 0.1804375;
            my $Y = $red * 0.2126729 + $green * 0.7151522 + $blue * 0.0721750;
            my $Z = $red * 0.0193339 + $green * 0.1191920 + $blue * 0.9503041;
            my $sum = $X + $Y + $Z;

            # Chromaticity is undefined for black. RGB 000000 is represented
            # through LevelControl only.
            if ($sum > 0) {
                my $x = int(($X / $sum) * 65536 + 0.5);
                my $y = int(($Y / $sum) * 65536 + 0.5);
                $x = 65279 if $x > 65279;
                $y = 65279 if $y > 65279;

                $payload = {
                    message_id => int(rand(100000) + 1),
                    command    => "device_command",
                    args       => {
                        node_id      => $node_id,
                        endpoint_id  => int($endpoint_id),
                        cluster_id   => 768,
                        command_name => "MoveToColor",
                        payload      => { colorX => $x, colorY => $y, transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
                    }
                };
            }

            # Preserve the intensity component of RGB via LevelControl.
            my $rgb_max = ($r > $g && $r > $b) ? $r : ($g > $b ? $g : $b);
            my $use_with_onoff = MATTERDevice_CommandSupported($hash, 0x0008, 0x04);
            my $can_level = $use_with_onoff || MATTERDevice_CommandSupported($hash, 0x0008, 0x00);
            if ($can_level) {
                my $max_level = MATTERDevice_AttributeUsable($hash, 0x0008, 0x0003)
                    ? AttrVal($name, "max_brightness", 254)
                    : 254;
                my $level = int(($rgb_max / 255) * $max_level + 0.5);
                $level_payload = {
                    message_id => int(rand(100000) + 1),
                    command    => "device_command",
                    args       => {
                        node_id      => $node_id,
                        endpoint_id  => int($endpoint_id),
                        cluster_id   => 0x0008,
                        command_name => ($use_with_onoff ? "MoveToLevelWithOnOff" : "MoveToLevel"),
                        payload      => { level => $level, transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
                    }
                };
            }
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

            # RGB contains a value/brightness component in addition to hue and
            # saturation. ColorControl does not carry that component, so map it
            # to LevelControl when the endpoint supports a suitable command.
            my $use_with_onoff = MATTERDevice_CommandSupported($hash, 0x0008, 0x04);
            my $can_level = $use_with_onoff || MATTERDevice_CommandSupported($hash, 0x0008, 0x00);
            if ($can_level) {
                my $max_level = MATTERDevice_AttributeUsable($hash, 0x0008, 0x0003)
                    ? AttrVal($name, "max_brightness", 254)
                    : 254;
                my $level = int($max * $max_level + 0.5);
                $level_payload = {
                    message_id => int(rand(100000) + 1),
                    command    => "device_command",
                    args       => {
                        node_id      => $node_id,
                        endpoint_id  => int($endpoint_id),
                        cluster_id   => 0x0008,
                        command_name => ($use_with_onoff ? "MoveToLevelWithOnOff" : "MoveToLevel"),
                        payload      => { level => $level, transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
                    }
                };
            }

            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $node_id,
                    endpoint_id  => int($endpoint_id),
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
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 768,
                command_name => "MoveToColorTemperature",
                payload      => { colorTemperatureMireds => int($args[0]), transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
            }
        };
    }
    elsif ($cmd eq "getConfig") {
        my $ioHash = $hash->{IODev};
        return "No IODev assigned to $name" if (!$ioHash || !$ioHash->{fhem}{helper}{sendWS});

        my @paths;

        # Fachlich unterstützte Cluster vollständig lesen.
        foreach my $cluster_key (keys %MATTER_CLUSTERS) {
            my $cluster_id = 0 + $cluster_key;
            push @paths, "$endpoint_id/$cluster_id/*";
        }

        # Globale Matter-Metadaten zusätzlich clusterübergreifend lesen. matter.js-server
        # unterstützt Wildcards für Cluster- und Attribut-IDs. Dadurch werden auch die
        # Capabilities bislang unbekannter Cluster erfasst, ohne deren Nutzdaten zu lesen.
        foreach my $attr_id (keys %MATTER_GLOBAL_ATTRIBUTES) {
            push @paths, "$endpoint_id/*/$attr_id";
        }

        # Falls Root-Device (Endpoint 0), auch die PartsList abfragen.
        if ($endpoint_id == 0) {
            push @paths, "0/29/3";
        }

        # Als Bulk-Array an den Server schicken.
        if (@paths) {
            my $msg_id = int(rand(100000) + 1);
            $ioHash->{helper}{pending_config}{$msg_id} = $node_id;

            my $config_payload = {
                message_id   => $msg_id,
                command      => "read_attribute",
                args         => {
                    node_id        => int($node_id),
                    attribute_path => \@paths
                }
            };
            
            $ioHash->{fhem}{helper}{sendWS}->(encode_json($config_payload));
            Log3 $name, 3, "MATTERDevice: Wildcard getConfig triggered for node $node_id, endpoint $endpoint_id (" . scalar(@paths) . " paths queried).";
        }

        return undef;
    }
    elsif ($cmd eq "frequency") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 0x0008,
                command_name => "MoveToClosestFrequency",
                payload      => { frequency => int($args[0]) }
            }
        };
    }
    elsif ($cmd eq "lock") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 257,
                command_name => "LockDoor",
            }
        };
    }
    elsif ($cmd eq "unlock") {
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 257,
                command_name => "UnlockDoor",
            }
        };
    }

    return "No payload generated" if (!$payload && !$level_payload);

    if ($hash->{IODev} && $hash->{IODev}{fhem}{helper}{sendWS}) {
        my $sendWS = $hash->{IODev}{fhem}{helper}{sendWS};
        $sendWS->(encode_json($level_payload)) if ($level_payload);
        $sendWS->(encode_json($payload)) if ($payload);
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

    # Cluster-ID und Attribut-ID sicher als numerischen/hexadezimalen Wert behandeln
    $cluster_id = hex($cluster_id) if $cluster_id =~ /^0x/i;
    $attr_id    = hex($attr_id)    if $attr_id =~ /^0x/i;

    my $cluster = $MATTER_CLUSTERS{$cluster_id};

    # Globale Matter-Attribute gelten für jeden Cluster, auch für Cluster, die das
    # FHEM-Modul noch nicht fachlich kennt.
    return if (MATTERDevice_ProcessGlobalAttribute($hash, $cluster_id, $attr_id, $value));
    return if !$cluster;

    my $attr_info = $cluster->{attributes}{$attr_id};
    return if !$attr_info;

    my $attr_name = $attr_info->{name};
    my $is_reading = $attr_info->{is_reading} // 0;
    my $is_attribute = $attr_info->{is_attribute} // 0;
    my $transform = $attr_info->{transform};

    # Bool-Handling für JSON (nur prüfen, wenn es überhaupt ein Objekt/Blessing ist)
    if (ref($value) && blessed($value) && $value->isa('JSON::PP::Boolean')) {
        $value = $value ? 1 : 0;
    }

    if ($transform && ref($transform) eq 'CODE') {
        $value = $transform->($value);
    }

    readingsBeginUpdate($hash);

    # Spezieller Fall: OnOff State mappen
    if ($cluster_id == 6 && $attr_id == 0) {
        my $state_val = $value ? "on" : "off";
        readingsBulkUpdate($hash, "state", $state_val);
    }
    # Alle anderen Werte direkt als Reading speichern
    elsif (defined($attr_name)) {
        if ($is_reading) {
            readingsBulkUpdate($hash, $attr_name, $value);
        }
        if ($is_attribute) {
            MATTERDevice_SetAttributeIfNotExists($name, $attr_name, $value);
        }
        if ($attr_name eq "brightness") {
            # Während getConfig wird der Capability-Cache vor dem Neuaufbau geleert.
            # Attribute aus dem Result-Hash haben keine garantierte Reihenfolge. Solange
            # AttributeList noch nicht verarbeitet wurde, den bereits bekannten Wert nutzen.
            my $attribute_list = $hash->{helper}{capabilities}{0x0008}{attribute_list};
            my $max_level = (
                ref($attribute_list) ne 'HASH' ||
                MATTERDevice_AttributeUsable($hash, 0x0008, 0x0003)
            ) ? AttrVal($name, "max_brightness", 254) : 254;
            my $pct_value = int(int($value) * 100 / $max_level);
            readingsBulkUpdate($hash, "pct", $pct_value);
        }
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

    my $my_endpoint = $hash->{endpoint_id} // 0;

    # Availability gehört zum Matter-Node und wird daher nur am Root-Device geführt.
    my $update_available = sub {
        my ($available) = @_;
        return if $my_endpoint != 0;
        my $available_value = $available ? "true" : "false";
        readingsSingleUpdate($hash, "available", $available_value, 1);
    };
    
    # Hilfs-Subroutine zur internen Weiterleitung an Root oder Child
    my $route_attribute = sub {
        my ($ep, $cluster, $attr, $val) = @_;
        if ($ep == $my_endpoint) {
            # Spezialbehandlung für PartsList (Cluster 0x001D / 29, Attribut 0x0003 / 3)
            if ($cluster == 0x001D && $attr == 0x0003 && ref($val) eq 'ARRAY') {
                Log3 $name, 3, "MATTERDevice: Found PartsList on node $hash->{node_id}, endpoints: " . join(", ", @{$val});
                foreach my $child_ep (@{$val}) {
                    # Nur Child anlegen, wenn es nicht der Root-Endpoint selbst ist
                    if ($child_ep != $my_endpoint) {
                        MATTERDevice_GetOrCreateChild($hash, $child_ep);
                    }
                }
            }
            MATTERDevice_ProcessAttributeValue($hash, $cluster, $attr, $val);
        } else {
            # Nur das Root-Device (oder valide Nodes) verteilen an Children weiter
            my $childHash = MATTERDevice_GetOrCreateChild($hash, $ep);
            if ($childHash) {
                MATTERDevice_ProcessAttributeValue($childHash, $cluster, $attr, $val);
            }
        }
    };

    # 1. ANTWORT AUF GETCONFIG (enthält "result")
    if (exists $decoded->{result} && ref($decoded->{result}) eq 'HASH') {
        # getConfig synchronisiert die Capability-Metadaten der in der Antwort
        # enthaltenen Endpoints vollständig. Alte Cluster-/Command-Daten dürfen
        # nicht erhalten bleiben, wenn sie im aktuellen Datenmodell verschwunden sind.
        my %result_endpoints;
        foreach my $path (keys %{$decoded->{result}}) {
            $result_endpoints{$1} = 1 if ($path =~ m{^(\d+)/(\d+)/(\d+)$});
        }
        foreach my $ep (keys %result_endpoints) {
            my $target_hash = ($ep == $my_endpoint) ? $hash : MATTERDevice_GetOrCreateChild($hash, $ep);
            delete $target_hash->{helper}{capabilities} if ($target_hash);
        }

        while (my ($path, $value) = each %{$decoded->{result}}) {
            if ($path =~ m{^(\d+)/(\d+)/(\d+)$}) {
                $route_attribute->($1, $2, $3, $value);
            }
        }
        return;
    }

    # 2. NODE UPDATES (u.a. Availability)
    if (exists $decoded->{event} && $decoded->{event} eq 'node_updated' && ref($decoded->{data}) eq 'HASH') {
        my $node = $decoded->{data};
        my $node_id = $node->{node_id};
        if (defined($node_id) && $hash->{node_id} eq $node_id && exists($node->{available})) {
            $update_available->($node->{available});
            Log3 $name, 4, "MATTERDevice: Node $node_id availability = " . ($node->{available} ? "true" : "false");
        }
        return;
    }

    # 3. LIVE UPDATES (event == 'attribute_updated')
    if (exists $decoded->{event} && $decoded->{event} eq 'attribute_updated' && ref($decoded->{data}) eq 'ARRAY') {
        my ($node_id, $attribute_path, $value) = @{$decoded->{data}};
        if ($attribute_path =~ m{^(\d+)/(\d+)/(\d+)$}) {
            $route_attribute->($1, $2, $3, $value);
            Log3 $name, 4, "MATTERDevice: Live update ($attribute_path) = $value";
        }
        return;
    }

    # 4. INITIAL DISCOVER / START_LISTENING (node_id + attributes/availability)
    my $node_id    = $decoded->{node_id};
    my $attributes = $decoded->{attributes};
    
    if (defined($node_id) && $hash->{node_id} eq $node_id) {
        $update_available->($decoded->{available}) if exists($decoded->{available});

        if ($attributes && ref($attributes) eq 'HASH') {
            while (my ($path, $value) = each %{$attributes}) {
                if ($path =~ m{^(\d+)/(\d+)/(\d+)$}) {
                    $route_attribute->($1, $2, $3, $value);
                }
            }
        }
    }
}

sub MATTERDevice_GetSetList($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my @list;
    my %seen;

    # Mehrere Matter-Cluster können dieselbe FHEM-Semantik anbieten (z.B. on/off).
    # Im Set-Dialog soll jeder FHEM-Befehl trotzdem nur einmal erscheinen.
    my $add = sub {
        my ($entry) = @_;
        my ($cmd_name) = split(':', $entry, 2);
        return if ($seen{$cmd_name}++);
        push @list, $entry;
    };

    $add->("on:noArg") if (
        MATTERDevice_CommandSupported($hash, 0x0006, 0x01) ||
        MATTERDevice_CommandSupported($hash, 0x0102, 0x00)
    );
    $add->("off:noArg") if (
        MATTERDevice_CommandSupported($hash, 0x0006, 0x00) ||
        MATTERDevice_CommandSupported($hash, 0x0102, 0x01)
    );
    $add->("toggle:noArg") if (MATTERDevice_CommandSupported($hash, 0x0006, 0x02));

    my $can_level =
        MATTERDevice_CommandSupported($hash, 0x0008, 0x04) ||
        MATTERDevice_CommandSupported($hash, 0x0008, 0x00);
    if ($can_level) {
        my $max_level = MATTERDevice_AttributeUsable($hash, 0x0008, 0x0003)
            ? AttrVal($name, "max_brightness", 254)
            : 254;
        $add->("brightness:slider,0,1,$max_level");
        $add->("pct:slider,0,1,100");
    }

    if (MATTERDevice_CommandSupported($hash, 0x0300, 0x0A)) {
        my $min_mired = MATTERDevice_AttributeUsable($hash, 0x0300, 0x400B)
            ? AttrVal($name, "color_temp_min", 153)
            : 153;
        my $max_mired = MATTERDevice_AttributeUsable($hash, 0x0300, 0x400C)
            ? AttrVal($name, "color_temp_max", 500)
            : 500;
        $add->("ct:colorpicker,CT,$min_mired,1,$max_mired");
    }

    if (MATTERDevice_CommandSupported($hash, 0x0008, 0x08)) {
        my $min_freq = MATTERDevice_AttributeUsable($hash, 0x0008, 0x0005)
            ? AttrVal($name, "min_frequency", 50)
            : 50;
        my $max_freq = MATTERDevice_AttributeUsable($hash, 0x0008, 0x0006)
            ? AttrVal($name, "max_frequency", 60)
            : 60;
        $add->("frequency:slider,$min_freq,1,$max_freq");
    }

    $add->($MATTER_CLUSTERS{0x0006}{commands}{0x40}{set_list})
        if (MATTERDevice_CommandSupported($hash, 0x0006, 0x40));
    $add->($MATTER_CLUSTERS{0x0006}{commands}{0x41}{set_list})
        if (MATTERDevice_CommandSupported($hash, 0x0006, 0x41));
    $add->($MATTER_CLUSTERS{0x0006}{commands}{0x42}{set_list})
        if (MATTERDevice_CommandSupported($hash, 0x0006, 0x42));

    $add->("stop:noArg")
        if (MATTERDevice_CommandSupported($hash, 0x0102, 0x02));
    $add->("pct:slider,0,1,100")
        if (MATTERDevice_CommandSupported($hash, 0x0102, 0x05));
    $add->("tilt:slider,0,1,100")
        if (MATTERDevice_CommandSupported($hash, 0x0102, 0x08));

    $add->("lock:noArg")
        if (MATTERDevice_CommandSupported($hash, 0x0101, 0x00));
    $add->("unlock:noArg")
        if (MATTERDevice_CommandSupported($hash, 0x0101, 0x01));

    if (
        MATTERDevice_CommandSupported($hash, 0x0300, 0x06) ||
        MATTERDevice_CommandSupported($hash, 0x0300, 0x07)
    ) {
        $add->("rgb:colorpicker,RGB");
    }

    $add->("getConfig:noArg");
    return @list;
}

sub MATTERDevice_GetOrCreateChild($$) {
    my ($root_hash, $ep_id) = @_;
    
    # 1. SCHNELLTEST: Ist das Child bereits im Root-Hash gecached?
    return $root_hash->{"endpoint_$ep_id"} if $root_hash->{"endpoint_$ep_id"};

    my $node_id   = $root_hash->{node_id};
    my $root_name = $root_hash->{NAME};
    my $target_io = $root_hash->{IODev} ? $root_hash->{IODev}{NAME} : undef;
    my $child_hash = undef;

    # 2. FALLBACK / START: Global in %defs suchen
    foreach my $d (keys %defs) {
        my $d_hash = $defs{$d};
        if ($d_hash && $d_hash->{TYPE} eq 'MATTERDevice' && 
            defined($d_hash->{node_id}) && $d_hash->{node_id} eq $node_id &&
            defined($d_hash->{endpoint_id}) && $d_hash->{endpoint_id} == $ep_id) {
            
            # Prüfen, ob das Child auch zu diesem Root-Device gehört (über den Namen im Hash)
            if ($d_hash->{device} && $d_hash->{device} eq $root_name) {
                $child_hash = $d_hash;
                last;
            }
            
            # Fallback, falls {device} noch leer ist, aber das IODev übereinstimmt
            my $d_io = $d_hash->{IODev} ? $d_hash->{IODev}{NAME} : undef;
            if ((!$d_hash->{device}) && (!$target_io || !$d_io || $target_io eq $d_io)) {
                $child_hash = $d_hash;
                last;
            }
        }
    }

    # 3. NEU ANLEGEN: Wenn es wirklich gar nicht existiert
    unless ($child_hash) {
        my $child_name = "${root_name}_EP${ep_id}";
        
        Log3 $root_hash, 3, "MATTERDevice: Auto-creating sub-device $child_name for Node ID $node_id, Endpoint $ep_id";
        
        # WICHTIG: Hier übergeben wir jetzt exakt die Parameter, die deine neue Define-Funktion erwartet!
        # Syntax: define <name> MATTERDevice <node_id> <endpoint_id> <root_device_name>
        CommandDefine(undef, "$child_name MATTERDevice $node_id $ep_id $root_name");
        
        $child_hash = $defs{$child_name};
    }

    # 4. INITIALISIEREN & IM ROOT-HASH CACHEN
    if ($child_hash) {
        $child_hash->{node_id}     = $node_id;
        $child_hash->{endpoint_id} = $ep_id;
        $child_hash->{device}      = $root_name;
        
        if ($root_hash->{IODev} && !$child_hash->{IODev}) {
            $child_hash->{IODev} = $root_hash->{IODev};
        }
        
        # Ab in den Cache damit für die Zukunft!
        $root_hash->{"endpoint_$ep_id"} = $child_hash;
    } else {
        Log3 $root_hash, 1, "MATTERDevice: ERROR - Could not get or create child device for Endpoint $ep_id!";
    }

    return $child_hash;
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
        Switches the endpoint when the corresponding command is present in the Matter <code>AcceptedCommandList</code>.</li>
    <li><code>brightness &lt;val&gt;</code><br>
        Sets the brightness when LevelControl exposes <code>MoveToLevel</code> or <code>MoveToLevelWithOnOff</code>.</li>
    <li><code>ct &lt;val&gt;</code><br>
        Sets the color temperature when ColorControl exposes <code>MoveToColorTemperature</code>.</li>
    <li><code>rgb &lt;hex&gt;</code><br>
        Sets the color when ColorControl exposes <code>MoveToHueAndSaturation</code> or <code>MoveToColor</code>.</li>
    <li><code>getConfig</code><br>
        Forces a synchronization of all supported attributes from the Matter-Server.</li>
  </ul>
  <br>

  <a name="MATTERDevice-attr"></a>
  <b>Attributes</b>
  <ul>
    <li>Command capabilities are derived exclusively from the Matter global cluster metadata,
        especially <code>AcceptedCommandList</code>. There are no manual <code>has_*</code> capability attributes.</li>
    <li><code>min_brightness</code>, <code>max_brightness</code>, <code>color_temp_min</code>, <code>color_temp_max</code><br>
        Configuration parameters for sliders and pickers.</li>
  </ul>
</ul>

=end html
=cut