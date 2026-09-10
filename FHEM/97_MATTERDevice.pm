# $Id$
package main;

use strict;
use warnings;
use JSON;
use Scalar::Util qw(blessed);

# Zentrale Definition: Ein Cluster enthält Name, Attribute (mit ID & Feature-Zuordnung)
my %MATTER_CLUSTERS = (
    0x0006 => {
        name       => "OnOff",
        attributes => {
            0x0000 => { name => "state", feature => "has_onoff", is_reading => 0, is_attribute => 0},
            0xFFF9 => { name => "onoff_cmds_accepted", feature => undef, is_reading => 0, is_attribute => 0 }
        },
        commands   => {
            0x00   => { name => "Off",    set_list => "off:noArg", feature => "has_onoff" },
            0x01   => { name => "On",     set_list => "on:noArg", feature => "has_onoff" },
            0x02   => { name => "Toggle", set_list => "toggle:noArg", feature => "has_onoff" },
            0x40   => { name => "OffWithEffect", set_list => "off_with_effect:DelayedAllOff,DyingLight slider,0,1,8", feature => "has_lighting" },
            0x41   => { name => "OnWithRecallGlobalScene", set_list => "on_with_recall_global_scene:noArg", feature => "has_lighting" },
            0x42   => { name => "OnWithTimedOff", set_list => "on_with_timed_off:onOffControlBitmap textField textField", feature => "has_lighting" },
        },
    },
    0x0008 => {
        name       => "LevelControl",
        attributes => {
            0x0000 => { name => "brightness", feature => "has_level", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "min_brightness", feature => "has_level", is_reading => 0, is_attribute => 1 },
            0x0003 => { name => "max_brightness", feature => "has_level", is_reading => 0, is_attribute => 1 },
            0x0004 => { name => "frequency", feature => "has_frequency", is_reading => 1, is_attribute => 0 },
            0x0005 => { name => "min_frequency", feature => "has_frequency", is_reading => 0, is_attribute => 1 },
            0x0006 => { name => "max_frequency", feature => "has_frequency", is_reading => 0, is_attribute => 1 },
            0x4000 => { name => "max_level",  feature => "has_level", is_reading => 1, is_attribute => 0 },
            0xFFF9 => { name => "level_control_cmds_accepted", feature => undef, is_reading => 0, is_attribute => 0 }
        },
        commands   => {
            0x00   => { name => "MoveToLevel", set_list => "move_to_level:slider,0,1,254 textField", feature => "has_level" },
            0x01   => { name => "Move", set_list => "move:up,down slider,0,1,254 textField", feature => undef },
            0x02   => { name => "Step", set_list => "step:up, down slider,0,1,254 textField", feature => undef },
            0x03   => { name => "Stop", set_list => "stop:textField", feature => undef },
            0x04   => { name => "MoveToLevelWithOnOff", set_list => "move_to_level:slider,0,1,254 textField", feature => "has_level" },
            0x05   => { name => "MoveWithOnOff", set_list => "move:up,down slider,0,1,254 textField", feature => undef },
            0x06   => { name => "StepWithOnOff", set_list => "step:up, down slider,0,1,254 textField", feature => undef },
            0x07   => { name => "StopWithOnOff", set_list => "stop:textField", feature => undef },
            0x08   => { name => "MoveToClosestFrequency", set_list => "move_to_frequency:textField", feature => "has_frequency" },
        }
    },
    0x0028 => {
        name       => "BasicInformation",
        attributes => {
            0x0001 => { name => "producer",         feature => undef, is_reading => 1, is_attribute => 0 },
            0x0003 => { name => "model",            feature => undef, is_reading => 1, is_attribute => 0 },
            0x0004 => { name => "vendor_id",        feature => undef, is_reading => 1, is_attribute => 0 },
            0x0008 => { name => "hardware_version", feature => undef, is_reading => 1, is_attribute => 0 },
            0x000A => { name => "firmware_version", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0012 => { name => "serial_number",    feature => undef, is_reading => 1, is_attribute => 0 },
        },
    },
    0x002F => {
        name       => "PowerSource",
        attributes => {
            0x0000 => { name => "power_source_status",       feature => undef, is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "power_source_description",  feature => undef, is_reading => 1, is_attribute => 0 },
            0x000B => { name => "battery_voltage_mV",         feature => undef, is_reading => 1, is_attribute => 0 },
            0x000C => { name => "battery_percent",            feature => undef, is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 2 : undef } },
            0x000D => { name => "battery_time_remaining_s",   feature => undef, is_reading => 1, is_attribute => 0 },
            0x000E => { name => "battery_charge_level",       feature => undef, is_reading => 1, is_attribute => 0 },
            0x000F => { name => "battery_replacement_needed", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0010 => { name => "battery_replaceability",     feature => undef, is_reading => 1, is_attribute => 0 },
            0x0013 => { name => "battery_type",               feature => undef, is_reading => 1, is_attribute => 0 },
            0x0018 => { name => "battery_capacity_mAh",       feature => undef, is_reading => 1, is_attribute => 0 },
            0x0019 => { name => "battery_quantity",           feature => undef, is_reading => 1, is_attribute => 0 },
        },
    },
    0x005B => {
        name       => "Air Quality",
        attributes => {
            0x0000 => { name => "air_quality",   feature => undef, is_reading => 1, is_attribute => 0 },
        },
    },
    0x005C => {
        name       => "SmokeCoAlarm",
        attributes => {
            0x0000 => { name => "alarm_expressed_state",    feature => undef, is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "smoke_state",              feature => undef, is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "co_state",                 feature => undef, is_reading => 1, is_attribute => 0 },
            0x0003 => { name => "alarm_battery",            feature => undef, is_reading => 1, is_attribute => 0 },
            0x0004 => { name => "device_muted",             feature => undef, is_reading => 1, is_attribute => 0 },
            0x0005 => { name => "test_in_progress",         feature => undef, is_reading => 1, is_attribute => 0 },
            0x0006 => { name => "hardware_fault",           feature => undef, is_reading => 1, is_attribute => 0 },
            0x0007 => { name => "end_of_service",           feature => undef, is_reading => 1, is_attribute => 0 },
            0x0008 => { name => "interconnect_smoke_alarm", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0009 => { name => "interconnect_co_alarm",    feature => undef, is_reading => 1, is_attribute => 0 },
        },
    },
    0x040C => {
        name       => "CarbonMonoxideConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "co_concentration", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "co_minimum",       feature => undef, is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "co_maximum",       feature => undef, is_reading => 1, is_attribute => 0 },
            0x0008 => { name => "co_unit",          feature => undef, is_reading => 1, is_attribute => 0 },
            0x0009 => { name => "co_medium",        feature => undef, is_reading => 1, is_attribute => 0 },
        },
    },
    0x0101 => {
        name       => "Door Lock",
        attributes => {
            0x0000 => { name => "lock_state", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "lock_type", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "actuator_enabled", feature => "has_lock", is_reading => 1, is_attribute => 0},
            0x0003 => { name => "door_state", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0004 => { name => "door_open_events", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0005 => { name => "door_close_events", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0006 => { name => "open_period", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0011 => { name => "num_total_users_supported", feature => "has_user", is_reading => 1, is_attribute => 0 },
            0x0012 => { name => "num_pin_users_supported", feature => "has_pin", is_reading => 1, is_attribute => 0 },
            0x0013 => { name => "num_rfid_users_supported", feature => "has_rfid", is_reading => 1, is_attribute => 0 },
            0x0014 => { name => "num_week_day_schedule_per_user", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0015 => { name => "num_year_day_schedule_per_user", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0016 => { name => "num_holiday_schedules", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0017 => { name => "max_pin_code_length", feature => "has_pin", is_reading => 0, is_attribute => 1 },
            0x0018 => { name => "min_pin_code_length", feature => "has_pin", is_reading => 0, is_attribute => 1 },
            0x0019 => { name => "max_rfid_code_length", feature => "has_rfid", is_reading => 0, is_attribute => 1 },
            0x001A => { name => "min_rfid_code_length", feature => "has_rfid", is_reading => 0, is_attribute => 1 },
            0x001B => { name => "credential_rules_support", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x001C => { name => "num_credentials_per_user", feature => "has_lock", is_reading => 1, is_attribute => 0 },
            0x0021 => { name => "language", feature => "has_lock", is_reading => 1, is_attribute => 0 },
        },
        commands   => {
            0x00   => { name => "LockDoor",   set_list => "lock:noArg", feature => "has_lock" },
            0x01   => { name => "UnlockDoor", set_list => "unlock:noArg", feature => "has_lock" },
        },
    },
    0x0102 => {
        name       => "WindowCovering",
        attributes => {
            0x0000 => { name => "wc_type", feature => "has_wc", is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "physical_closed_limit_lift", feature => undef, is_reading => 0, is_attribute => 1 },
            0x0002 => { name => "physical_closed_limit_tilt", feature => undef, is_reading => 0, is_attribute => 1 },
            0x0003 => { name => "current_position_lift", feature => "has_position_lift", is_reading => 1, is_attribute => 0},
            0x0004 => { name => "current_position_tilt", feature => "has_position_tilt", is_reading => 1, is_attribute => 0},
            0x0005 => { name => "number_of_actuations_lift", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0006 => { name => "number_of_actuations_tilt", feature => undef, is_reading => 1, is_attribute => 0},
            0x0007 => { name => "ws_config_status", feature => undef, is_reading => 1, is_attribute => 0},
            0x0008 => { name => "current_position_lift_percentage", feature => "has_position_lift", is_reading => 1, is_attribute => 0 },
            0x0009 => { name => "current_position_tilt_percentage", feature => "has_position_tilt", is_reading => 1, is_attribute => 0 },
            0x000A => { name => "wc_operational_status", feature => undef, is_reading => 1, is_attribute => 0 },
            0x000B => { name => "target_position_lift_percent_100_ths", feature => undef, is_reading => 1, is_attribute => 0 },
            0x000C => { name => "target_position_tilt_percent_100_ths", feature => undef, is_reading => 1, is_attribute => 0 },
            0x000D => { name => "wc_end_product_type", feature => undef, is_reading => 1, is_attribute => 0},
            0x000E => { name => "current_position_lift_percent_100_ths", feature => "has_position_lift", is_reading => 1, is_attribute => 0 },
            0x000F => { name => "current_position_tilt_percent_100_ths", feature => "has_position_tilt", is_reading => 1, is_attribute => 0 },
            0x0010 => { name => "installed_open_limit_lift", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0011 => { name => "installed_closed_limit_lift", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0012 => { name => "installed_open_limit_tilt", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0013 => { name => "installed_closed_limit_tilt", feature => undef, is_reading => 1, is_attribute => 0 },
            0x0017 => { name => "wc_mode", feature => undef, is_reading => 1, is_attribute => 0 },
            0x001A => { name => "wc_safety_status", feature => undef, is_reading => 1, is_attribute => 0 },
            0xFFF9 => { name => "wc_cmds_accepted", feature => undef, is_reading => 0, is_attribute => 0 }

        },
        commands => {
            0x00   => { name => "UpOrOpen", set_list => "on:noArg", feature => "has_wc" },
            0x01   => { name => "DownOrClose", set_list => "off:noArg", feature => "has_wc" },
            0x02   => { name => "StopMotion", set_list => "stop:noArg", feature => "has_wc" },
            0x04   => { name => "GoToLiftValue", set_list => "lift_value:textField", feature => "has_position_lift" },
            0x05   => { name => "GoToLiftPercentage", set_list => "prc:slieder,0,1,100", feature => "has_position_lift" },
            0x07   => { name => "TiltValue", set_list => "tilt:textField", feature => "has_position_tilt" },
            0x08   => { name => "GoToTiltPercentage", set_list => "prc:slieder,0,1,100", feature => "has_position_tilt" },
        },
    },
    0x0300 => {
        name       => "ColorControl",
        attributes => {
            0x0000 => { name => "current_hue",        feature => "has_hue", is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "current_saturation", feature => "has_saturation", is_reading => 1, is_attribute => 0 },
            0x0003 => { name => "current_x",          feature => "has_xy", is_reading => 1, is_attribute => 0 },
            0x0004 => { name => "current_y",          feature => "has_xy", is_reading => 1, is_attribute => 0 },
            0x0007 => { name => "color_temperature_mireds", feature => "has_ct", is_reading => 1, is_attribute => 0 },
            0x0010 => { name => "color_modes",        feature => undef, is_reading => 1, is_attribute => 0 },
            0x400B => { name => "color_temp_min",     feature => "has_ct", is_reading => 0, is_attribute => 1 },
            0x400C => { name => "color_temp_max",     feature => "has_ct", is_reading => 0, is_attribute => 1 },
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
    $hash->{AttrList} = "has_onoff:0,1 " .
                        "has_level:0,1 " .
                        "has_ct:0,1 " .
                        "has_hue:0,1 " .
                        "has_saturation:0,1 " .
                        "has_xy:0,1 " .
                        "has_frequency:0,1 " .
                        "has_wc:0,1 " .
                        "has_position_lift:0,1 " .
                        "has_position_tilt:0,1 " .
                        "has_lock:0,1 " .
                        "has_pin:0,1 " .
                        "has_rfid:0,1 " .
                        "has_user:0,1 " .
                        "color_temp_min " .
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
    
    my $payload     = undef;
    my $node_id     = $hash->{node_id};
    my $endpoint_id = $hash->{endpoint_id} // 1;

    if ($cmd eq "on" || $cmd eq "off") {
        if (AttrVal($name, "has_wt", 0)) {
            if ($cmd eq "on") {
                $payload = {
                    message_id => int(rand(100000) + 1),
                    command    => "device_command",
                    args       => {
                        node_id      => $node_id,
                        endpoint_id  => int($endpoint_id),
                        cluster_id   => 0x0102,
                        command_name => "UpOrOpen"
                    }
                };
            } else {
                $payload = {
                    message_id => int(rand(100000) + 1),
                    command    => "device_command",
                    args       => {
                        node_id      => $node_id,
                        endpoint_id  => int($endpoint_id),
                        cluster_id   => 0x0102,
                        command_name => "DownOrClose"
                    }
                };
            }
        } else {
            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $node_id,
                    endpoint_id  => int($endpoint_id),
                    cluster_id   => 6,
                    command_name => $cmd
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
        $payload = {
            message_id => int(rand(100000) + 1),
            command    => "device_command",
            args       => {
                node_id      => $node_id,
                endpoint_id  => int($endpoint_id),
                cluster_id   => 8,
                command_name => "MoveToLevelWithOnOff",
                payload      => { level => int($args[0]), transitionTime => 0, optionsMask => 0, optionsOverride => 0 }
            }
        };
    }
    elsif ($cmd eq "pct") {
        if (AttrVal($name, "has_position_lift", 0)) {
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
            my $max_level = AttrVal($name, "max_brightness", 254);
            $payload = {
                message_id => int(rand(100000) + 1),
                command    => "device_command",
                args       => {
                    node_id      => $node_id,
                    endpoint_id  => int($endpoint_id),
                    cluster_id   => 8,
                    command_name => "MoveToLevelWithOnOff",
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
                    node_id      => $node_id,
                    endpoint_id  => int($endpoint_id),
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

        # 1. Für jeden definierten Cluster einfach ein Wildcard (*) setzen
        foreach my $cluster_key (keys %MATTER_CLUSTERS) {
            my $cluster_id = 0 + $cluster_key; 
            push @paths, "$endpoint_id/$cluster_id/*";
        }
        
        # 2. Falls Root-Device (Endpoint 0), auch die PartsList abfragen
        if ($endpoint_id == 0) {
            push @paths, "0/29/3";
        }

        # 3. Als Bulk-Array an den Server schicken
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
            Log3 $name, 3, "MATTERDevice: Wildcard getConfig triggered for node $node_id, endpoint $endpoint_id (" . scalar(@paths) . " clusters queried).";
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
                cluster_id   => 768,
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

    # Cluster-ID und Attribut-ID sicher als numerischen/hexadezimalen Wert behandeln
    $cluster_id = hex($cluster_id) if $cluster_id =~ /^0x/i;
    $attr_id    = hex($attr_id)    if $attr_id =~ /^0x/i;

    my $cluster = $MATTER_CLUSTERS{$cluster_id};
    return if !$cluster;

    my $attr_info = $cluster->{attributes}{$attr_id};
    return if !$attr_info;

    my $attr_name = $attr_info->{name};
    my $feature   = $attr_info->{feature};
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
    # Spezieller Fall: Commands Accepted (global für alle Cluster mit 0xFFF9)
    elsif ($attr_id == 0xFFF9 && ref($value) eq 'ARRAY') {
        for my $cmd_id (@{$value}) {
            my $cmd_info = $cluster->{commands}{$cmd_id};
            if ($cmd_info) {
                my $feature = $cmd_info->{feature};
                if (defined($feature)) {
                    MATTERDevice_SetAttributeIfNotExists($name, $feature, 1);
                }
            }
        }
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
            my $max_level = AttrVal($name, "max_brightness", 254);
            my $pct_value = int(int($value) * 100 / $max_level);
            readingsBulkUpdate($hash, "pct", $pct_value);
        }
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

    my $my_endpoint = $hash->{endpoint_id} // 0;
    
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
        while (my ($path, $value) = each %{$decoded->{result}}) {
            if ($path =~ m{^(\d+)/(\d+)/(\d+)$}) {
                $route_attribute->($1, $2, $3, $value);
            }
        }
        return;
    }

    # 2. LIVE UPDATES (event == 'attribute_updated')
    if (exists $decoded->{event} && $decoded->{event} eq 'attribute_updated' && ref($decoded->{data}) eq 'ARRAY') {
        my ($node_id, $attribute_path, $value) = @{$decoded->{data}};
        if ($attribute_path =~ m{^(\d+)/(\d+)/(\d+)$}) {
            $route_attribute->($1, $2, $3, $value);
            Log3 $name, 4, "MATTERDevice: Live update ($attribute_path) = $value";
        }
        return;
    }

    # 3. INITIAL DISCOVER (node_id + attributes map)
    my $node_id    = $decoded->{node_id};
    my $attributes = $decoded->{attributes};
    
    if ($node_id && $attributes && $hash->{node_id} eq $node_id) {
        while (my ($path, $value) = each %{$attributes}) {
            if ($path =~ m{^(\d+)/(\d+)/(\d+)$}) {
                $route_attribute->($1, $2, $3, $value);
            }
        }
    }
}

sub MATTERDevice_GetSetList($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my @list;
    
    push(@list, "on:noArg", "off:noArg", "toggle:noArg") if (AttrVal($name, "has_onoff", 0));
    
    if (AttrVal($name, "has_level", 0)) {
        my $max_level = AttrVal($name, "max_brightness", 254);
        push(@list, "brightness:slider,0,1,$max_level");
        push(@list, "pct:slider,0,1,100");
    }
    
    if (AttrVal($name, "has_ct", 0)) {
        my $min_mired = AttrVal($name, "color_temp_min", 153);
        my $max_mired = AttrVal($name, "color_temp_max", 500);
        push(@list, "ct:colorpicker,CT,$min_mired,1,$max_mired");
    }

    if (AttrVal($name, "has_frequency", 0)) {
        my $min_freq = AttrVal($name, "min_frequency", 50);
        my $max_freq = AttrVal($name, "max_frequency", 60);
        push(@list, "frequency:slider,$min_freq,1,$max_freq");
    }

    if (AttrVal($name, "has_lighting",0)) {
        push(@list, $MATTER_CLUSTERS{0x0006}{commands}{0x40}{set_list});
        push(@list, $MATTER_CLUSTERS{0x0006}{commands}{0x41}{set_list});
        push(@list, $MATTER_CLUSTERS{0x0006}{commands}{0x42}{set_list});
    }
    
    if (AttrVal($name, "has_wt", 0)) {
        push(@list, "on:noArg", "off:noArg", "stop:noArg");
    }

    if (AttrVal($name, "has_position_lift", 0)) {
        push(@list, "pct:slider,0,1,100");
    }
    if (AttrVal($name, "has_position_tilt", 0)) {
        push(@list, "tilt:slider,0,1,100");
    }

    if (AttrVal($name, "has_lock", 0)) {
        push(@list, "lock:noArg", "unlock:noArg");
    }

    push(@list, "rgb:colorpicker,RGB") if (AttrVal($name, "has_color", 0) || AttrVal($name, "has_xy", 0) || AttrVal($name, "has_hue", 0));
    push(@list, "getConfig:noArg");
    
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