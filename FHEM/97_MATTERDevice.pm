# $Id$
package main;

use strict;
use warnings;
use utf8;
use JSON;
use List::Util qw(min max);
use Scalar::Util qw(blessed);

our $init_done; # FHEM startup: statefile and attributes are not yet restored
our $unicodeEncoding; # FHEM supports both unicode and legacy UTF-8 byte strings.

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

# Device Type IDs from the Matter Device Library; used for UI and FHEM groups.
# Descriptor.DeviceTypeList is authoritative when supplied by the server.
my %MATTER_DEVICE_TYPE_LABELS = (
    0x000A => "Door lock",
    0x000E => "Aggregator",
    0x000F => "Generic switch",
    0x0013 => "Bridged node",
    0x0015 => "Contact sensor",
    0x0043 => "Water leak detector",
    0x0044 => "Rain sensor",
    0x0016 => "Root node",
    0x002B => "Fan",
    0x002C => "Air quality sensor",
    0x0076 => "Smoke CO Alarm",
    0x0100 => "On/Off light",
    0x0101 => "Dimmable light",
    0x0103 => "On/Off light switch",
    0x0104 => "Dimmer switch",
    0x0105 => "Color dimmer switch",
    0x0106 => "Light sensor",
    0x0107 => "Occupancy sensor",
    0x010A => "On/Off plug-in unit",
    0x010B => "Dimmable plug-in unit",
    0x010C => "Color temperature light",
    0x010D => "Extended color light",
    0x0202 => "Window covering",
    0x0301 => "Thermostat",
    0x0302 => "Temperature sensor",
    0x0305 => "Pressure sensor",
    0x0306 => "Flow sensor",
    0x0307 => "Humidity sensor",
    0x0510 => "Electrical Sensor",
    0x0850 => "On/Off sensor",
);
# Structural types do not describe a separately usable function. Electrical Sensor
# (0x0510) is a Matter utility type too, but does represent a useful measurement endpoint.
my %MATTER_STRUCTURAL_DEVICE_TYPES = map { $_ => 1 } (0x000E, 0x0011, 0x0012, 0x0013, 0x0014, 0x0016);

# Ordered presentation policy, independent of report/Descriptor ordering.
# Every named functional type must occur here; structural types use the fallback.
my @MATTER_DISPLAY_TYPES = (
    [0x0076, 'alarm'], [0x0043, 'state'], [0x0044, 'state'],
    [0x000A, 'lock'], [0x0202, 'covering'], [0x0301, 'thermostat'],
    [0x002B, 'fan'],
    (map { [$_, 'state'] } (0x0100, 0x0101, 0x010C, 0x010D, 0x010A, 0x010B, 0x0015, 0x0107)),
    [0x0850, 'boolean'],
    (map { [$_, 'button'] } (0x000F, 0x0103, 0x0104, 0x0105)),
    [0x002C, 'air'], [0x0510, 'electrical'],
    [0x0302, 'temperature'], [0x0307, 'humidity'],
    [0x0305, 'pressure'], [0x0106, 'illuminance'],
    [0x0306, 'unsupported'], # Type label only; no FlowMeasurement parser.
);

# Matter 1.4 enum labels; raw readings retain their numeric protocol values.
my %MATTER_DISPLAY_ENUMS = (
    alarm_expressed_state => [qw(normal smoke_alarm co_alarm battery_alert testing
                                hardware_fault end_of_service interconnect_smoke interconnect_co)],
    lock_state => [qw(not_fully_locked locked unlocked unlatched)],
    air_quality => [qw(unknown good fair moderate poor very_poor extremely_poor)],
);

# Pure presentation of this endpoint's persisted readings. Never infer a
# physical value from an absent reading, a command echo or a sibling endpoint.
sub MATTERDevice_DefaultState {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $value = sub { return ReadingsVal($name, $_[0], 'unknown'); };
    my $number = sub {
        my ($reading) = @_;
        my $v = $value->($reading);
        return undef if ref($v) || $v !~ /\A-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?\z/;
        return $v;
    };
    my $quantity = sub {
        my ($reading, $unit) = @_;
        my $v = $number->($reading);
        utf8::encode($unit) unless $unicodeEncoding;
        return defined($v) ? "$v $unit" : 'unknown';
    };
    my $enum = sub {
        my ($reading) = @_;
        my $v = $value->($reading);
        my $labels = $MATTER_DISPLAY_ENUMS{$reading};
        return 'unknown' unless !ref($v) && $v =~ /\A\d+\z/ && $v < @$labels;
        return $labels->[$v];
    };
    my %types = map { $_ => 1 } MATTERDevice_DeviceTypeIds($hash);
    my ($kind) = map { $_->[1] } grep { $types{$_->[0]} } @MATTER_DISPLAY_TYPES;
    $kind //= 'state';
    return $value->('state') if $kind eq 'state' || ($hash->{endpoint_id} // 0) == 0;
    return 'unknown' if $kind eq 'unsupported';
    return $enum->('alarm_expressed_state') if $kind eq 'alarm';
    return $enum->('lock_state') if $kind eq 'lock';
    if ($kind eq 'boolean') {
        return $value->('state') if exists $hash->{READINGS}{state};
        my $v = $value->('boolean_state');
        return $v =~ /\A[01]\z/ ? $v : 'unknown';
    }
    if ($kind eq 'button') {
        return $value->('state') if !$types{0x000F} && exists $hash->{READINGS}{state};
        my $v = $value->('button');
        return $v =~ /\A(?:pressed|long|short|long_release|double|triple|\d+x)\z/
            ? "last: $v" : 'unknown';
    }
    if ($kind eq 'covering') {
        my @positions;
        for my $axis (qw(lift tilt)) {
            my $v = $number->("current_position_${axis}_percent_100_ths");
            $v = defined($v) ? $v / 100 : $number->("current_position_${axis}_percentage");
            if (defined($v) && $v >= 0 && $v <= 100) {
                push @positions, "$axis: $v %";
            } elsif (defined(my $raw = $number->("current_position_$axis"))) {
                push @positions, "$axis: $raw (raw)" if $raw >= 0 && $raw < 65535;
            }
        }
        return join(' / ', @positions) if @positions;
        my $status = $number->('wc_operational_status');
        return 'unknown' unless defined($status) && $status =~ /\A\d+\z/ && $status <= 63;
        return (qw(stopped opening closing unknown))[$status & 3];
    }
    if ($kind eq 'thermostat') {
        my $mode = $value->('mode');
        $mode = 'unknown' unless $mode =~ /\A(?:off|auto|cool|heat|emergency_heat)\z/;
        my @parts = ($mode, 'measured: ' . $quantity->('measured-temp', '°C'));
        push @parts, 'heat: ' . $quantity->('desired-temp', '°C')
            if $mode eq 'heat' || $mode eq 'emergency_heat' || $mode eq 'auto';
        push @parts, 'cool: ' . $quantity->('desired-temp-cool', '°C')
            if $mode eq 'cool' || $mode eq 'auto';
        return join('; ', @parts);
    }
    if ($kind eq 'fan') {
        my $mode = $value->('fan_mode');
        $mode = 'unknown' unless $mode =~ /\A(?:off|low|medium|high|on|auto)\z/;
        my $pct = $number->('fan_pct');
        return defined($pct) && $pct >= 0 && $pct <= 100 ? "$mode; $pct %" : $mode;
    }
    if ($kind eq 'air') {
        return $enum->('air_quality') if exists $hash->{READINGS}{air_quality};
        my @parts;
        for my $r (qw(co2 pm25 tvoc)) {
            my $v = $number->($r);
            next unless defined($v) && $v >= 0;
            my $unit = $value->("${r}_unit");
            # Only the units already recognized by the protocol converter.
            $unit = 'unknown' unless grep { $unit eq $_ }
                map { MATTERDevice_ConcentrationUnit($_) } (0..9);
            push @parts, "$r: $v $unit";
        }
        return @parts ? join(' / ', @parts) : 'unknown';
    }
    if ($kind eq 'electrical') {
        for my $r (qw(power energy voltage current)) {
            next unless defined($number->($r));
            my %units = (power => 'W', energy => 'kWh', voltage => 'V', current => 'A');
            return $quantity->($r, $units{$r});
        }
        return 'unknown';
    }
    return $quantity->('temperature', '°C') . ' / ' . $quantity->('humidity', '%')
        if ($kind eq 'temperature' || $kind eq 'humidity') && $types{0x0302} && $types{0x0307};
    my %units = (temperature => '°C', humidity => '%', pressure => 'hPa', illuminance => 'lx');
    return $quantity->($kind, $units{$kind});
}

sub MATTERDevice_UpdateDisplay {
    my ($hash) = @_;
    return unless $init_done && ($hash->{endpoint_id} // 0) > 0;
    return if defined AttrVal($hash->{NAME}, 'stateFormat', undef);
    $hash->{STATE} = ReplaceEventMap($hash->{NAME}, MATTERDevice_DefaultState($hash), 1);
}

# Core readingsEndUpdate computes userReadings/stateFormat before DoTrigger.
# Retain its event arrays while ending silently, then set the endpoint default
# before publishing those SAME events. No state reading or extra event is made.
sub MATTERDevice_ReadingsEndUpdate {
    my ($hash, $trigger) = @_;
    return readingsEndUpdate($hash, $trigger) if !$init_done ||
        ($hash->{endpoint_id} // 0) == 0 || defined AttrVal($hash->{NAME}, 'stateFormat', undef);
    my ($events, $times) = @{$hash}{qw(CHANGED CHANGETIME)};
    readingsEndUpdate($hash, 0);
    MATTERDevice_UpdateDisplay($hash);
    if ($trigger && $events) {
        $hash->{CHANGED} = $events;
        $hash->{CHANGETIME} = $times if defined $times;
        DoTrigger($hash->{NAME}, undef);
    }
}

sub MATTERDevice_ReadingsSingleUpdate {
    my ($hash, $reading, $value, $trigger) = @_;
    readingsBeginUpdate($hash);
    my $result = readingsBulkUpdate($hash, $reading, $value);
    MATTERDevice_ReadingsEndUpdate($hash, $trigger);
    return $result;
}

# Explicit Matter MeasurementUnitEnum values. Never assume that a
# concentration reading represents ppm without an accompanying unit.
sub MATTERDevice_ConcentrationUnit {
    my ($value) = @_;
    my %units = (0 => 'ppm', 1 => 'ppb', 2 => 'ppt', 3 => 'mg/m3',
                 4 => 'ug/m3', 5 => 'ng/m3', 6 => 'particles/m3',
                 7 => 'Bq/m3', 8 => 'dBpm', 9 => 'particles/ft3');
    return undef if !defined($value) || ref($value) ||
                    $value !~ /^\d+$/;
    return $units{$value};
}

# Zentrale Definition der vom FHEM-Modul fachlich unterstützten Cluster, Attribute und Commands
my %MATTER_CLUSTERS = (
    0x0003 => {
        name       => "Identify",
        commands   => {
            0x00 => { name => "Identify" },
        },
    },
    0x0006 => {
        name       => "OnOff",
        features   => {
            lighting            => 0,
            dead_front_behavior => 1,
            off_only            => 2,
        },
        attributes => {
            0x0000 => { name => "state", is_reading => 0},
        },
        commands   => {
            0x00   => { name => "Off" },
            0x01   => { name => "On", forbidden_features => ["off_only"] },
            0x02   => { name => "Toggle", forbidden_features => ["off_only"] },
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
            0x0000 => { name => "brightness", is_reading => 1 },
            0x0002 => { name => "min_brightness", is_reading => 1, limit_range => [0, 254] },
            0x0003 => { name => "max_brightness", is_reading => 1, limit_range => [0, 254] },
            0x0004 => { name => "frequency", is_reading => 1, required_features => ["frequency"] },
            0x0005 => { name => "min_frequency", is_reading => 1, limit_range => [0, 65535], required_features => ["frequency"] },
            0x0006 => { name => "max_frequency", is_reading => 1, limit_range => [0, 65535], required_features => ["frequency"] },
            0x4000 => { name => "startup_current_level", is_reading => 1, required_features => ["lighting"] },
        },
        commands   => {
            0x00   => { name => "MoveToLevel" },
            0x01   => { name => "Move" },
            0x02   => { name => "Step" },
            0x03   => { name => "Stop" },
            0x04   => { name => "MoveToLevelWithOnOff" },
            0x05   => { name => "MoveWithOnOff" },
            0x06   => { name => "StepWithOnOff" },
            0x07   => { name => "StopWithOnOff" },
            0x08   => { name => "MoveToClosestFrequency", required_features => ["frequency"] },
        }
    },
    0x0028 => {
        name       => "BasicInformation",
        attributes => {
            0x0001 => { name => "producer", is_reading => 1 },
            0x0002 => { name => "vendor_id", is_reading => 1 },
            0x0003 => { name => "model", is_reading => 1 },
            0x0008 => { name => "hardware_version", is_reading => 1 },
            0x000A => { name => "firmware_version", is_reading => 1 },
            0x0009 => { name => "software_version", is_reading => 1 },
            0x000F => { name => "serial_number", is_reading => 1 },
            0x0015 => { name => "specification_version", is_reading => 1 },
        },
    },
    0x002F => {
        name       => "PowerSource",
        attributes => {
            0x0000 => { name => "power_source_status", is_reading => 1 },
            0x0002 => { name => "power_source_description", is_reading => 1 },
            0x000B => { name => "battery_voltage_mV", is_reading => 1 },
            0x000C => { name => "battery_percent", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 2 : undef } },
            0x000D => { name => "battery_time_remaining_s", is_reading => 1 },
            0x000E => { name => "battery_charge_level", is_reading => 1 },
            0x000F => { name => "battery_replacement_needed", is_reading => 1 },
            0x0010 => { name => "battery_replaceability", is_reading => 1 },
            0x0013 => { name => "battery_replacement_description", is_reading => 1 },
            0x0014 => { name => "battery_common_designation", is_reading => 1 },
            0x0018 => { name => "battery_capacity_mAh", is_reading => 1 },
            0x0019 => { name => "battery_quantity", is_reading => 1 },
        },
    },
    0x002A => {
        name       => "OtaSoftwareUpdateRequestor",
        attributes => {
            0x0002 => { name => "ota_update_state", is_reading => 0, value_range => [0, 8] },
            0x0003 => { name => "ota_update_progress", is_reading => 1, value_range => [0, 100] },
        },
    },
    0x0046 => {
        name       => "IcdManagement",
        attributes => {
            0x0000 => { name => "icd_idle_mode_duration", is_reading => 1, value_range => [0, 4294967295] },
            0x0008 => { name => "icd_operating_mode", is_reading => 0, value_range => [0, 1] },
        },
    },
    0x0045 => {
        name       => "BooleanState",
        attributes => {
            0x0000 => { name => "boolean_state", is_reading => 1 },
        },
    },
    0x0400 => {
        name       => "IlluminanceMeasurement",
        attributes => {
            0x0000 => { name => "illuminance", is_reading => 1,
                        transform => sub {
                            my ($v) = @_;
                            return undef if $v != int($v) || $v < 0 || $v >= 65535;
                            return 0 if $v == 0;
                            return int(10 ** (($v - 1) / 10000) * 10 + 0.5) / 10;
                        } },
        },
    },
    0x0402 => {
        name       => "TemperatureMeasurement",
        attributes => {
            0x0000 => { name => "temperature", is_reading => 1,
                        transform => sub {
                            my ($v) = @_;
                            return undef if $v != int($v) || $v < -27315 || $v > 32767;
                            return $v / 100;
                        } },
        },
    },
    0x0403 => {
        name       => "PressureMeasurement",
        attributes => {
            # Matter MeasuredValue = 10 * pressure [kPa]; numeric value
            # therefore equals pressure in hPa (see Matter spec, 0x0403).
            0x0000 => { name => "pressure", is_reading => 1,
                        transform => sub {
                            my ($v) = @_;
                            return undef if $v != int($v) || $v < -32767 || $v > 32767;
                            return $v;
                        } },
        },
    },
    0x0405 => {
        name       => "RelativeHumidityMeasurement",
        attributes => {
            0x0000 => { name => "humidity", is_reading => 1,
                        transform => sub {
                            my ($v) = @_;
                            return undef if $v != int($v) || $v < 0 || $v > 10000;
                            return $v / 100;
                        } },
        },
    },
    0x0406 => {
        name       => "OccupancySensing",
        attributes => {
            0x0000 => { name => "motion", is_reading => 1,
                        transform => sub {
                            my ($v) = @_;
                            return undef if $v != int($v) || $v < 0 || $v > 255;
                            return ($v & 1) ? "motion" : "nomotion";
                        } },
        },
    },
    0x005B => {
        name       => "Air Quality",
        attributes => {
            0x0000 => { name => "air_quality", is_reading => 1, value_range => [0, 6] },
        },
    },
    0x005C => {
        name       => "SmokeCoAlarm",
        attributes => {
            0x0000 => { name => "alarm_expressed_state", is_reading => 1, value_range => [0, 8] },
            0x0001 => { name => "smoke_state", is_reading => 1 },
            0x0002 => { name => "co_state", is_reading => 1 },
            0x0003 => { name => "alarm_battery", is_reading => 1 },
            0x0004 => { name => "device_muted", is_reading => 1 },
            0x0005 => { name => "test_in_progress", is_reading => 1 },
            0x0006 => { name => "hardware_fault", is_reading => 1 },
            0x0007 => { name => "end_of_service", is_reading => 1 },
            0x0008 => { name => "interconnect_smoke_alarm", is_reading => 1 },
            0x0009 => { name => "interconnect_co_alarm", is_reading => 1 },
        },
    },
    0x0090 => {
        name       => "ElectricalPowerMeasurement",
        attributes => {
            0x0000 => { name => "power_mode", is_reading => 1 },
            0x0001 => { name => "number_of_measurement_types", is_reading => 1 },
            0x0004 => { name => "voltage", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0005 => { name => "current", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0006 => { name => "reactive_current", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0007 => { name => "apparent_current", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0008 => { name => "power", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0009 => { name => "reactive_power", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000A => { name => "apparent_power", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000B => { name => "rms_voltage", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000C => { name => "rms_current", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000D => { name => "rms_power", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000E => { name => "frequency", is_reading => 1 },
            0x0011 => { name => "power_factor", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 10000 : undef } },
            0x0012 => { name => "neutral_current", is_reading => 1,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
        },
    },
    0x0091 => {
        name       => "ElectricalEnergyMeasurement",
        attributes => {
            0x0001 => { name => "energy", is_reading => 1,
                        transform => sub {
                            my ($v) = @_;
                            return undef if !defined($v) || ref($v) ne 'HASH';
                            my $energy_mWh = exists($v->{"0"}) ? $v->{"0"} : $v->{energy};
                            return undef unless defined($energy_mWh) && !ref($energy_mWh) &&
                                $energy_mWh =~ /\A[0-9]+\z/;
                            # EnergyMeasurementStruct constrains Energy to 0..2^62 mWh.
                            # Compare decimal digits before numeric coercion, including
                            # on Perl builds whose native number would round the boundary.
                            $energy_mWh =~ s/^0+(?=\d)//;
                            return undef if length($energy_mWh) > 19 ||
                                (length($energy_mWh) == 19 && $energy_mWh gt '4611686018427387904');
                            return $energy_mWh / 1_000_000;
                        } },
        },
    },
    0x040C => {
        name       => "CarbonMonoxideConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "co_concentration", is_reading => 1 },
            0x0001 => { name => "co_minimum", is_reading => 1 },
            0x0002 => { name => "co_maximum", is_reading => 1 },
            0x0008 => { name => "co_unit", is_reading => 1 },
            0x0009 => { name => "co_medium", is_reading => 1 },
        },
    },
    0x040D => {
        name       => "CarbonDioxideConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "co2", is_reading => 1,
                        transform => sub { return $_[0] >= 0 ? $_[0] : undef; } },
            0x0008 => { name => "co2_unit", is_reading => 1,
                        transform => \&MATTERDevice_ConcentrationUnit },
        },
    },
    0x042A => {
        name       => "Pm25ConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "pm25", is_reading => 1,
                        transform => sub { return $_[0] >= 0 ? $_[0] : undef; } },
            0x0008 => { name => "pm25_unit", is_reading => 1,
                        transform => \&MATTERDevice_ConcentrationUnit },
        },
    },
    0x042E => {
        name       => "TotalVolatileOrganicCompoundsConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "tvoc", is_reading => 1,
                        transform => sub { return $_[0] >= 0 ? $_[0] : undef; } },
            0x0008 => { name => "tvoc_unit", is_reading => 1,
                        transform => \&MATTERDevice_ConcentrationUnit },
        },
    },
    0x0101 => {
        name       => "Door Lock",
        attributes => {
            0x0000 => { name => "lock_state", is_reading => 1, value_range => [0, 3] },
            0x0001 => { name => "lock_type", is_reading => 1 },
            0x0002 => { name => "actuator_enabled", is_reading => 1},
            0x0003 => { name => "door_state", is_reading => 1 },
            0x0004 => { name => "door_open_events", is_reading => 1 },
            0x0005 => { name => "door_close_events", is_reading => 1 },
            0x0006 => { name => "open_period", is_reading => 1 },
            0x0011 => { name => "num_total_users_supported", is_reading => 1 },
            0x0012 => { name => "num_pin_users_supported", is_reading => 1 },
            0x0013 => { name => "num_rfid_users_supported", is_reading => 1 },
            0x0014 => { name => "num_week_day_schedule_per_user", is_reading => 1 },
            0x0015 => { name => "num_year_day_schedule_per_user", is_reading => 1 },
            0x0016 => { name => "num_holiday_schedules", is_reading => 1 },
            0x0017 => { name => "max_pin_code_length", is_reading => 1, limit_range => [0, 255] },
            0x0018 => { name => "min_pin_code_length", is_reading => 1, limit_range => [0, 255] },
            0x0019 => { name => "max_rfid_code_length", is_reading => 1, limit_range => [0, 255] },
            0x001A => { name => "min_rfid_code_length", is_reading => 1, limit_range => [0, 255] },
            0x001B => { name => "credential_rules_support", is_reading => 1 },
            0x001C => { name => "num_credentials_per_user", is_reading => 1 },
            0x0021 => { name => "language", is_reading => 1 },
        },
        commands   => {
            0x00   => { name => "LockDoor" },
            0x01   => { name => "UnlockDoor" },
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
            0x0000 => { name => "wc_type", is_reading => 1 },
            0x0001 => { name => "physical_closed_limit_lift", is_reading => 1, limit_range => [0, 65535], required_features => ["lift", "position_aware_lift", "absolute_position"] },
            0x0002 => { name => "physical_closed_limit_tilt", is_reading => 1, limit_range => [0, 65535], required_features => ["tilt", "position_aware_tilt", "absolute_position"] },
            0x0003 => { name => "current_position_lift", is_reading => 1, value_range => [0, 65534], required_features => ["lift", "position_aware_lift", "absolute_position"] },
            0x0004 => { name => "current_position_tilt", is_reading => 1, value_range => [0, 65534], required_features => ["tilt", "position_aware_tilt", "absolute_position"] },
            0x0005 => { name => "number_of_actuations_lift", is_reading => 1 },
            0x0006 => { name => "number_of_actuations_tilt", is_reading => 1},
            0x0007 => { name => "ws_config_status", is_reading => 1},
            0x0008 => { name => "current_position_lift_percentage", is_reading => 1, value_range => [0, 100] },
            0x0009 => { name => "current_position_tilt_percentage", is_reading => 1, value_range => [0, 100] },
            0x000A => { name => "wc_operational_status", is_reading => 1, value_range => [0, 63],
                         transform => sub { return undef if grep { (($_[0] >> $_) & 3) == 3 } (0, 2, 4); return $_[0]; } },
            0x000B => { name => "target_position_lift_percent_100_ths", is_reading => 1 },
            0x000C => { name => "target_position_tilt_percent_100_ths", is_reading => 1 },
            0x000D => { name => "wc_end_product_type", is_reading => 1},
            0x000E => { name => "current_position_lift_percent_100_ths", is_reading => 1, value_range => [0, 10000] },
            0x000F => { name => "current_position_tilt_percent_100_ths", is_reading => 1, value_range => [0, 10000] },
            0x0010 => { name => "installed_open_limit_lift", is_reading => 1, required_features => ["lift", "position_aware_lift", "absolute_position"] },
            0x0011 => { name => "installed_closed_limit_lift", is_reading => 1, required_features => ["lift", "position_aware_lift", "absolute_position"] },
            0x0012 => { name => "installed_open_limit_tilt", is_reading => 1, required_features => ["tilt", "position_aware_tilt", "absolute_position"] },
            0x0013 => { name => "installed_closed_limit_tilt", is_reading => 1, required_features => ["tilt", "position_aware_tilt", "absolute_position"] },
            0x0017 => { name => "wc_mode", is_reading => 1 },
            0x001A => { name => "wc_safety_status", is_reading => 1 },

        },
        commands => {
            0x00   => { name => "UpOrOpen" },
            0x01   => { name => "DownOrClose" },
            0x02   => { name => "StopMotion" },
            0x05   => { name => "GoToLiftPercentage", required_features => ["lift"] },
            0x08   => { name => "GoToTiltPercentage", required_features => ["tilt"] },
        },
    },
    0x0201 => {
        name       => "Thermostat",
        features   => { heating => 0, cooling => 1, auto_mode => 5 },
        attributes => {
            0x0000 => { name => "measured-temp", is_reading => 1,
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < -27315 || $_[0] > 32767;
                            return $_[0] / 100;
                        } },
            0x0011 => { name => "desired-temp-cool", is_reading => 1,
                        writable => 1, required_features => ['cooling'],
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < -27315 || $_[0] > 32767;
                            return $_[0] / 100;
                        } },
            0x0012 => { name => "desired-temp", is_reading => 1,
                        writable => 1, required_features => ['heating'],
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < -27315 || $_[0] > 32767;
                            return $_[0] / 100;
                        } },
            0x001C => { name => "mode", is_reading => 1,
                        writable => 1,
                        transform => sub {
                            my %modes = (0 => 'off', 1 => 'auto', 3 => 'cool',
                                         4 => 'heat', 5 => 'emergency_heat');
                            return $modes{$_[0]};
                        } },
        },
    },
    0x0202 => {
        name       => "FanControl",
        features   => { auto_mode => 1 },
        attributes => {
            0x0000 => { name => "fan_mode", is_reading => 1,
                        writable => 1,
                        transform => sub {
                            my %modes = (0 => 'off', 1 => 'low', 2 => 'medium',
                                         3 => 'high', 4 => 'on', 5 => 'auto');
                            return $modes{$_[0]};
                        } },
            0x0002 => { name => "fan_pct_setting", is_reading => 1,
                        writable => 1,
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < 0 || $_[0] > 100;
                            return $_[0];
                        } },
            0x0003 => { name => "fan_pct", is_reading => 1,
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < 0 || $_[0] > 100;
                            return $_[0];
                        } },
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
            0x0000 => { name => "current_hue", is_reading => 1, required_features => ["hue_saturation"] },
            0x0001 => { name => "current_saturation", is_reading => 1, required_features => ["hue_saturation"] },
            0x0003 => { name => "current_x", is_reading => 1, required_features => ["xy"] },
            0x0004 => { name => "current_y", is_reading => 1, required_features => ["xy"] },
            0x0007 => { name => "color_temperature_mireds", is_reading => 1, required_features => ["color_temperature"] },
            0x0008 => { name => "color_mode", is_reading => 1 },
            0x400B => { name => "color_temp_min", is_reading => 1, limit_range => [1, 65279], required_features => ["color_temperature"] },
            0x400C => { name => "color_temp_max", is_reading => 1, limit_range => [0, 65279], required_features => ["color_temperature"] },
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
    $hash->{AttrFn}   = "MATTERDevice_Attr";
    $hash->{NotifyFn} = "MATTERDevice_Notify";
    $hash->{FW_detailFn} = "MATTERDevice_FWDetail";
    $hash->{FW_deviceOverview} = 1; # Keep FHEMWEB DeviceOverview above the endpoint links.
    $hash->{AttrList} = "IODev " .
                        "readOnly:0,1 " .
                        "disable:0,1 " .
                        "dimRate:slider,1,1,254 " .
                        "diagnostics:0,1 " .
                        "rawReadings:0,1 " .
                        $readingFnAttributes;
    $hash->{MatchList} = { "1" => ".*" };
}

# Root status is an interpreted node-wide reachability report, not an endpoint
# state or a copy of the last saved available value.
sub MATTERDevice_SetRootState($$) {
    my ($hash, $state) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0;
    MATTERDevice_ReadingsSingleUpdate($hash, 'state', $state, 1)
        if ReadingsVal($hash->{NAME}, 'state', '') ne $state;
}

# Current-session availability is runtime authority. The available reading
# retains the last server report, including values restored by FHEM.
# Invalidate before any synchronous IO/root reading event can reenter parsing.
sub MATTERDevice_InvalidateAvailability($) {
    my ($root) = @_;
    return unless ($root->{endpoint_id} // 0) == 0;
    delete $root->{helper}{available};
    ++$root->{helper}{availability_epoch};
    delete $root->{helper}{capability_refresh};
}

# Runtime permissions and outstanding operations belong to IO + Matter IDs,
# not to a mutable FHEM definition hash. Physical readings and local policy stay.
sub MATTERDevice_InvalidateIdentity {
    my ($hash) = @_;
    MATTERDevice_InvalidateAvailability($hash);
    delete @{$hash->{helper}}{qw(capabilities seen_clusters firmware_available
        firmware_update_in_flight latest_request enable_sync)};
    delete @{$hash}{grep { /^endpoint_\d+$/ } keys %$hash};
    # These saved metadata values also authorize controls, scaling or device
    # interpretation. They cannot describe a different Matter identity.
    readingsDelete($hash, $_) for qw(device_type_ids icd_supported
        icd_lit_supported software_version specification_version);
    for my $cluster (values %MATTER_CLUSTERS) {
        for my $attribute (values %{$cluster->{attributes} // {}}) {
            readingsDelete($hash, $attribute->{name}) if $attribute->{limit_range};
        }
    }
    MATTERDevice_CancelRequests($hash);
}

# Cancel owner requests and exclude an endpoint from older shared responses.
# Used for disable transitions, identity changes and Undef; no new generation.
sub MATTERDevice_CancelRequests {
    my ($hash) = @_;
    delete $hash->{helper}{latest_request};
    my $io = $hash->{IODev};
    return unless $io;
    my ($node, $ep) = @{$hash}{qw(node_id endpoint_id)};
    for my $id (keys %{$io->{helper}{pending_command} // {}}) {
        my $request = $io->{helper}{pending_command}{$id};
        if (ref($request) eq 'HASH') {
            delete $io->{helper}{pending_command}{$id}
                if ($request->{owner} // '') eq $hash;
        } elsif ($ep > 0 && ($request eq 'get_nodes' || $request eq 'start_listening')) {
            $io->{helper}{pending_snapshot_touched}{$id}{$node}{excluded_endpoints}{$ep} = 1;
        }
    }
    for my $id (keys %{$io->{helper}{pending_config} // {}}) {
        my $request = $io->{helper}{pending_config}{$id};
        next unless $request->{node_id} eq $node;
        if (($request->{owner} // '') eq $hash ||
            ($ep == 0 && ($request->{root_fuuid} // '') eq ($hash->{FUUID} // ''))) {
            $request->{cancelled} = 1 if $request->{processing};
            delete $io->{helper}{pending_config}{$id};
        } elsif ($ep > 0) {
            $request->{excluded_endpoints}{$ep} = 1;
        }
    }
}

# Only query when endpoint metadata used by FHEM controls is missing.
# A known empty AcceptedCommandList is valid: it must not be interpreted
# as a failed interview and must not enable old has_* fallbacks.
sub MATTERDevice_NeedsCapabilityRefresh($) {
    my ($root) = @_;
    return 0 unless $root && ($root->{endpoint_id} // 0) == 0;
    foreach my $device ($root, MATTERDevice_NodeChildren($root)) {
        next if MATTERDevice_IsDisabled($device);
        my %observed = map { $_ => 1 }
            keys %{$device->{helper}{seen_clusters} // {}};
        # GetSetList probes may autovivify empty capability hashes for other
        # known clusters; those are not evidence of device support.
        foreach my $cluster_id (keys %{$device->{helper}{capabilities} // {}}) {
            my $cap = $device->{helper}{capabilities}{$cluster_id};
            $observed{$cluster_id} = 1
                if ref($cap) eq 'HASH' && $cap->{present};
        }
        # An endpoint restored while offline has no runtime metadata at all.
        # Its persisted type label is not evidence that commands are supported.
        return 1 if ($device->{endpoint_id} // 0) > 0 && !%observed;

        foreach my $cluster_id (keys %observed) {
            my $model = $MATTER_CLUSTERS{$cluster_id};
            next unless $model;
            my $cap = $device->{helper}{capabilities}{$cluster_id} // {};
            my $commands = $model->{commands};
            if (ref($commands) eq 'HASH' && keys %$commands) {
                return 1 unless ref($cap->{accepted_commands}) eq 'HASH';
                # Some advertised commands are gated by FeatureMap. A missing
                # map would silently hide those controls even with the list.
                if (!defined($cap->{feature_map})) {
                    foreach my $command_id (keys %{$cap->{accepted_commands}}) {
                        my $command = $commands->{$command_id};
                        next unless $command;
                        return 1 if @{$command->{required_features} // []} ||
                                    @{$command->{forbidden_features} // []};
                    }
                }
            }
            # These supported setters write Matter attributes, not commands.
            if ($cluster_id == 0x0201 || $cluster_id == 0x0202) {
                return 1 unless ref($cap->{attribute_list}) eq 'HASH';
                my @feature_targets = $cluster_id == 0x0201 ? (17, 18, 28) : (0);
                return 1 if !defined($cap->{feature_map}) &&
                    grep { exists $cap->{attribute_list}{$_} } @feature_targets;
            }
        }
    }
    return 0;
}

# A targeted Matter Read, independent of snapshot-derived device states.
# Called only when missing metadata makes actual FHEM controls unavailable.
sub MATTERDevice_RequestCapabilityRefresh($) {
    my ($root) = @_;
    my $io = $root->{IODev};
    return (undef, 'No connected Matter IO') unless $io && $io->{CD} &&
        $io->{websocket} && ($io->{ws_status} // '') eq 'connected';
    my $pending = ($io->{helper}{pending_config} //= {});
    return (undef, 'Too many pending Matter reads')
        if scalar(keys %$pending) >= 128;
    my $id = MATTER_NextMessageId($io);
    return (undef, 'Cannot allocate Matter request ID') unless defined $id;
    $pending->{$id} = {
        node_id => $root->{node_id}, endpoint_id => -1,
        all_endpoints => 1, capability_only => 1,
        root_fuuid => $root->{FUUID},
        availability_epoch => $root->{helper}{availability_epoch} // 0,
        created_at => gettimeofday(),
    };
    # No physical OnOff, brightness or measurement values are requested.
    my $payload = {
        message_id => $id, command => 'read_attribute',
        args => {
            node_id => int($root->{node_id}),
            attribute_path => [
                '*/*/65529', # AcceptedCommandList
                '*/*/65531', # AttributeList
                '*/*/65532', # FeatureMap
                '*/*/65533', # ClusterRevision
            ],
        },
    };
    unless (MATTER_SendJsonCommand($io, $payload)) {
        delete $pending->{$id};
        return (undef, 'Unable to send Matter capability read');
    }
    return ($id, undef);
}

# Bounded and event-driven. A failed/empty reply is not success: a later
# relevant event can retry after the cooldown. No background timer or polling.
sub MATTERDevice_MaybeRefreshCapabilities($) {
    my ($root) = @_;
    return unless $root && ($root->{endpoint_id} // 0) == 0 &&
                  ref($root->{helper}{capability_refresh}) eq 'HASH' &&
                  $root->{helper}{available};

    unless (MATTERDevice_NeedsCapabilityRefresh($root)) {
        delete $root->{helper}{capability_refresh};
        return;
    }

    my $io = $root->{IODev};
    return unless $io && $io->{CD} && $io->{websocket} &&
                  ($io->{ws_status} // '') eq 'connected';

    my $recovery = $root->{helper}{capability_refresh};

    my $now = gettimeofday();
    if (defined(my $id = $recovery->{pending_id})) {
        my $pending = $io->{helper}{pending_config}{$id};
        if ($pending) {
            return if $now - ($pending->{created_at} // $now) < 120;
            # This read has timed out; never apply its eventual response.
            delete $io->{helper}{pending_config}{$id};
        }
        delete $recovery->{pending_id};
    }
    return if ($recovery->{attempts} // 0) >= 3;
    return if defined($recovery->{last_attempt}) &&
              $now - $recovery->{last_attempt} < 15;

    # Set ownership before sending: a synchronous notify/send callback must
    # not recursively issue another read for the same root.
    ++$recovery->{attempts};
    $recovery->{last_attempt} = $now;
    my ($id, $error) = MATTERDevice_RequestCapabilityRefresh($root);
    if (defined $id) {
        $recovery->{pending_id} = $id;
    } elsif (defined $error) {
        Log3 $root->{NAME}, 3,
            "MATTERDevice: Capability refresh for node $root->{node_id} " .
            "attempt $recovery->{attempts} failed: $error";
    }
}

sub MATTERDevice_UpdateAvailability($$) {
    my ($hash, $reported) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0;
    my $boolean = MATTERDevice_NormalizeBoolean($reported);
    return unless defined $boolean;
    my $previous = $hash->{helper}{available};
    # A saved false report may schedule missing-command recovery after a
    # restart, but never authorizes device data. Only this valid report does.
    my $was_offline = defined($previous) ? !$previous :
        ReadingsVal($hash->{NAME}, 'available', '') eq 'false';
    my $available = $boolean ? 'true' : 'false';
    # A reply from before another offline/online cycle is not current.
    ++$hash->{helper}{availability_epoch}
        if !defined($previous) || $previous != $boolean;
    $hash->{helper}{available} = $boolean;
    if ($boolean && $was_offline) {
        $hash->{helper}{capability_refresh} = {
            attempts => 0,
        };
    } elsif (!$boolean) {
        delete $hash->{helper}{capability_refresh};
    }
    my $state = $boolean ? 'online' : 'offline';
    my $change_available = ReadingsVal($hash->{NAME}, 'available', '') ne $available;
    my $change_state = ReadingsVal($hash->{NAME}, 'state', '') ne $state;
    if ($change_available || $change_state) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'available', $available) if $change_available;
        readingsBulkUpdate($hash, 'state', $state) if $change_state;
        MATTERDevice_ReadingsEndUpdate($hash, 1);
    }
    MATTERDevice_SyncNodeReadings($hash) if $change_available || $change_state;
}

# CommandAttr calls AttrFn before committing IODev. Reject collisions here;
# the global ATTR event below observes the pointer actually installed by FHEM.
sub MATTERDevice_Attr {
    my ($op, $name, $attr, $value) = @_;
    if ($init_done && $op eq 'del' && ($defs{$name}{endpoint_id} // 0) > 0 &&
        (!defined($attr) || 'stateFormat' =~ /^$attr$/)) {
        $defs{$name}{STATE} = ReplaceEventMap($name, MATTERDevice_DefaultState($defs{$name}), 1);
    }
    # FHEM deleteattr accepts a name pattern, or no name to clear all attrs.
    $attr = 'disable' if $op eq 'del' && (!defined($attr) || 'disable' =~ /^$attr$/);
    if ($attr eq 'readOnly' || $attr eq 'disable') {
        return "$attr is only supported on endpoints (endpoint_id > 0)"
            if $op eq 'set' && ($defs{$name}{endpoint_id} // 0) == 0;
        return "$attr must be 0 or 1"
            if $op eq 'set' && (!defined($value) || $value !~ /\A[01]\z/);
        return undef unless $attr eq 'disable' &&
            ($defs{$name}{endpoint_id} // 0) > 0;
        my $hash = $defs{$name};
        my $disabled = $op eq 'set' && $value eq '1';
        return undef if !!AttrVal($name, 'disable', 0) == !!$disabled;
        if (!$disabled) {
            # Consumed by Notify after FHEM commits the attribute change.
            $hash->{helper}{enable_sync} = 1;
        } else {
            delete $hash->{helper}{enable_sync};
        }
        # Cancel on both edges: shared reads may also have started while the
        # endpoint was disabled. No persistent request generation is needed.
        MATTERDevice_CancelRequests($hash);
        return undef;
    }
    return unless $op eq 'set' && $attr eq 'IODev';
    my $root = $defs{$name};
    my $io = $defs{$value};
    return if !$io && !$init_done; # Forward reference during config restoration.
    return "Unknown MATTER IODev $value" unless $io && ($io->{TYPE} // '') eq 'MATTER';
    if (($root->{endpoint_id} // 0) == 0) {
        my $owner = MATTERDevice_LookupRoot($io, $root->{node_id});
        return "Node $root->{node_id} on $value already belongs to $owner->{NAME}"
            if $owner && $owner ne $root;
    }
    MATTERDevice_InvalidateIdentity($root) if ($root->{IODev} // '') ne $io;
    return undef;
}

sub MATTERDevice_LookupRoot {
    my ($io, $node_id) = @_;
    return undef unless $io;
    my $key = "$io->{NAME}:$node_id";
    my $root = $modules{MATTERDevice}{defptr}{$key};
    return undef unless $root;
    return $root if ($defs{$root->{NAME}} // '') eq $root &&
        ($root->{TYPE} // '') eq 'MATTERDevice' && ($root->{node_id} // '') eq $node_id &&
        ($root->{endpoint_id} // -1) == 0 && ($root->{IODev} // '') eq $io;
    delete $modules{MATTERDevice}{defptr}{$key};
    return undef;
}

# Config and statefile restoration complete before INITIALIZED/REREADCFG.
# The former module created exactly 'stateFormat available' automatically.
# Migrate that legacy default once, without altering other user formatting.
sub MATTERDevice_Notify($$) {
    my ($hash, $dev) = @_;
    return unless ($dev->{NAME} // '') eq 'global';
    my $events = $dev->{CHANGED} // [];
    my $startup = grep { $_ eq 'INITIALIZED' || $_ eq 'REREADCFG' } @$events;
    if (($hash->{endpoint_id} // 0) > 0) {
        evalStateFormat($hash) if $startup && defined AttrVal($hash->{NAME}, 'stateFormat', undef);
        MATTERDevice_UpdateDisplay($hash) if $startup ||
            grep { /\A(?:ATTR|DELETEATTR) \Q$hash->{NAME}\E(?: |\z)/ } @$events;
        return if MATTERDevice_IsDisabled($hash) || !delete($hash->{helper}{enable_sync});
        return if $startup; # Root availability is invalidated during restoration.
        my $root = MATTERDevice_LookupRoot($hash->{IODev}, $hash->{node_id});
        my $io = $hash->{IODev};
        if ($root && $root->{helper}{available} && $io->{CD} &&
            $io->{websocket} && ($io->{ws_status} // '') eq 'connected') {
            MATTERDevice_SyncNodeReadings($root, $hash);
            my $status = ReadingsVal($root->{NAME}, 'matter_status', undef);
            MATTERDevice_ReadingsSingleUpdate($hash, 'matter_status', $status, 1)
                if defined($status) && !MATTERDevice_IsDisabled($hash) &&
                   ReadingsVal($hash->{NAME}, 'matter_status', '') ne $status;
            my $error = MATTERDevice_Set($hash, $hash->{NAME}, 'getConfig');
            Log3 $hash->{NAME}, 3, "MATTERDevice: Enable synchronization failed: $error"
                if defined $error;
        }
        return;
    }
    my $name = $hash->{NAME};
    my $io = $hash->{IODev};
    return unless $startup || ($io && grep { $_ eq "ATTR $name IODev $io->{NAME}" } @$events);
    if ($io) {
        my $index = $modules{MATTERDevice}{defptr};
        my $key = "$io->{NAME}:$hash->{node_id}";
        my $owner = MATTERDevice_LookupRoot($io, $hash->{node_id});
        return if !$startup && $owner && $owner eq $hash;
        for my $old (keys %$index) {
            delete $index->{$old} if $old ne $key && $index->{$old} eq $hash;
        }
        $index->{$key} = $hash unless $owner;
    }
    MATTERDevice_InvalidateAvailability($hash) if $startup;
    if ($startup && AttrVal($name, 'stateFormat', '') eq 'available' &&
        ReadingsVal($name, 'state', '') !~ /\A(?:online|offline|unknown|removed)\z/) {
        my $error = CommandDeleteAttr(undef, "$name stateFormat");
        Log3 $name, 3, "MATTERDevice: Cannot remove legacy stateFormat on $name: $error" if $error;
    }
    MATTERDevice_SetRootState($hash, 'unknown');
}

sub MATTERDevice_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t]+", $def);

    # Upgrade existing endpoint definitions in place. The old root name is a
    # mutable FHEM label, not part of the Matter node/endpoint identity.
    my $legacy_def = @a == 5 && ($a[4] // '') =~ /^[A-Za-z0-9_.-]+$/;
    return "wrong syntax: define <name> MATTERDevice <node_id> [<endpoint_id>]"
        unless (@a == 3 || @a == 4 || $legacy_def)
            && ($a[2] // '') =~ /^\d+$/
            && (@a == 3 || ($a[3] // '') =~ /^[1-9]\d*$/);

    my $name = $a[0];
    my $node_id = $a[2];
    my $endpoint_id = $a[3] // 0;

    my $changed = defined($hash->{node_id}) &&
        ($hash->{node_id} ne $node_id || ($hash->{endpoint_id} // 0) != $endpoint_id);
    if ($changed && $endpoint_id == 0) {
        my $owner = MATTERDevice_LookupRoot($hash->{IODev}, $node_id);
        return "Node $node_id already belongs to $owner->{NAME}"
            if $owner && $owner ne $hash;
    }
    MATTERDevice_InvalidateIdentity($hash) if $changed;

    if ($legacy_def) {
        $hash->{DEF} = "$node_id $endpoint_id";
        Log3 $name, 3, "MATTERDevice: Migrated endpoint DEF to '$hash->{DEF}'; use save to persist";
    }

    # CommandModify can reuse a root hash for a different identity.
    if (($hash->{endpoint_id} // -1) == 0 && defined $hash->{node_id}) {
        my $prior_io = $hash->{IODev} ? $hash->{IODev}{NAME} : 'no_io';
        my $key = "$prior_io:$hash->{node_id}";
        delete $modules{MATTERDevice}{defptr}{$key}
            if ($modules{MATTERDevice}{defptr}{$key} // '') eq $hash;
    }
    $hash->{node_id} = $node_id;
    $hash->{endpoint_id} = $endpoint_id;
    # The root name is derived from IODev + node ID, never from the DEF.
    delete $hash->{device};
    
    # NotifyFn is registered module-wide; limit all devices, including
    # endpoints, to global events rather than the entire FHEM event stream.
    $hash->{NOTIFYDEV} = 'global';
    if ($endpoint_id == 0) {
        AssignIoPort($hash) unless $hash->{IODev};
        my $io_name = $hash->{IODev} ? $hash->{IODev}{NAME} : 'no_io';
        # AssignIoPort may initially choose an IO which already owns this ID.
        $modules{MATTERDevice}{defptr}{"$io_name:$node_id"} = $hash
            unless MATTERDevice_LookupRoot($hash->{IODev}, $node_id);
        MATTERDevice_SetRootState($hash, 'unknown') if $init_done &&
            ($changed || !defined($hash->{READINGS}{state}));
    }
    MATTERDevice_UpdateDisplay($hash);
    Log3 $name, 3, "MATTERDevice: Defined node_id $node_id for $name";
    return undef;
}

sub MATTERDevice_Undef($$) {
my ($hash, $arg) = @_;
    MATTERDevice_CancelRequests($hash);
    if (($hash->{node_id}) && ($hash->{endpoint_id} == 0)) {
        my $io_name = $hash->{IODev} ? $hash->{IODev}{NAME} : 'no_io';
        my $key = "$io_name:$hash->{node_id}";
        delete $modules{MATTERDevice}{defptr}{$key}
            if ($modules{MATTERDevice}{defptr}{$key} // '') eq $hash;
    }
    return undef;
}

# Never interpret string "false" or malformed objects as Matter boolean true.
sub MATTERDevice_NormalizeBoolean {
    my ($value) = @_;
    return undef unless defined $value;
    return $value ? 1 : 0
        if blessed($value) && ($value->isa('JSON::PP::Boolean') ||
                               $value->isa('JSON::XS::Boolean'));
    return $value + 0 if !ref($value) && $value =~ /\A[01]\z/;
    return undef;
}

sub MATTERDevice_NormalizeMatterId($) {
    my ($value) = @_;
    return undef if (!defined($value) || ref($value));
    return hex($value) if ($value =~ /^0x[0-9a-f]+$/i);
    return int($value) if ($value =~ /^\d+$/);
    return undef;
}

# A valid empty list revokes all IDs. One malformed element invalidates
# the entire report, so it cannot partially revoke or grant capabilities.
sub MATTERDevice_IdSet {
    my ($value) = @_;
    return undef unless ref($value) eq 'ARRAY';
    my %ids;
    for my $raw (@$value) {
        my $id = MATTERDevice_NormalizeMatterId($raw);
        return undef unless defined($id) && $id <= 0xFFFFFFFF;
        $ids{$id} = 1;
    }
    return \%ids;
}

# Pure conversion shared by freshness tracking and attribute publication.
# undef means rejected; valid zero and empty ID sets remain valid values.
sub MATTERDevice_AttributeValue {
    my ($cluster, $attribute, $value, $endpoint) = @_;
    $endpoint //= 0;
    return undef unless defined $value;
    if (exists $MATTER_GLOBAL_ATTRIBUTES{$attribute}) {
        return $attribute <= 0xFFFB ? MATTERDevice_IdSet($value)
                                    : MATTERDevice_NormalizeMatterId($value);
    }
    return MATTERDevice_IdSet($value) if $cluster == 29 && $attribute == 1;
    if ($cluster == 29 && $attribute == 0) {
        return undef unless ref($value) eq 'ARRAY';
        my %types;
        for my $entry (@$value) {
            next unless ref($entry) eq 'HASH';
            my $id = MATTERDevice_NormalizeMatterId(
                $entry->{deviceType} // $entry->{device_type} // $entry->{'0'});
            $types{$id} = 1 if defined($id) && $id <= 0xFFFFFFFF;
        }
        return keys(%types) ? join(',', map { sprintf('0x%04X', $_) }
            sort {$a <=> $b} keys %types) : undef;
    }
    return MATTERDevice_NetworkType($value) if $endpoint == 0 && $cluster == 51 && $attribute == 0;
    return MATTERDevice_NetworkDiagnosticValues($cluster, $attribute, $value)
        if $endpoint == 0 && ($cluster == 53 || $cluster == 54);
    if (($cluster == 513 && $attribute == 27) || ($cluster == 514 && $attribute == 1)) {
        return !ref($value) && $value =~ /\A\d+\z/ && $value <= 5 ? 0 + $value : undef;
    }
    my $model = $MATTER_CLUSTERS{$cluster};
    my $info = $model && $model->{attributes} ? $model->{attributes}{$attribute} : undef;
    return $value unless $info; # Unmapped/raw values have no guessed schema.
    if (my $range = $info->{limit_range} // $info->{value_range}) {
        return undef unless !ref($value) && $value =~ /\A[0-9]+\z/ &&
            $value >= $range->[0] && $value <= $range->[1];
    }
    my $boolean = MATTERDevice_NormalizeBoolean($value);
    $value = $boolean if blessed($value) && defined($boolean);
    if (my $transform = $info->{transform}) {
        return undef if $cluster != 0x0091 &&
            (ref($value) || $value !~ /\A-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?\z/);
        $value = $transform->($value);
    }
    return undef if !defined($value) || ref($value);
    return MATTERDevice_NormalizeBoolean($value)
        if ($cluster == 6 || $cluster == 69) && $attribute == 0;
    return undef if $cluster == 8 && $attribute == 0 &&
        ($value !~ /\A\d+\z/ || $value > 254);
    return $value;
}

# Verarbeitet die globalen Matter-Attribute clusterunabhängig und speichert sie
# pro Endpoint/Cluster. Rückgabe ist der übernommene Wert, undef bei Ablehnung.
sub MATTERDevice_ProcessGlobalAttribute($$$$) {
    my ($hash, $cluster_id, $attr_id, $value) = @_;
    return undef if !exists($MATTER_GLOBAL_ATTRIBUTES{$attr_id}) || MATTERDevice_IsDisabled($hash);

    my $key = $MATTER_GLOBAL_ATTRIBUTES{$attr_id};
    my $parsed = MATTERDevice_AttributeValue($cluster_id, $attr_id, $value);
    return undef unless defined $parsed;
    $hash->{helper}{seen_clusters}{$cluster_id} = 1;
    my $cap = ($hash->{helper}{capabilities}{$cluster_id} //= {});
    $cap->{present} = 1;
    $cap->{$key} = $parsed;

    # A changed FeatureMap/AttributeList can change the usable brightness
    # scale without another CurrentLevel report (including metadata recovery).
    if ($cluster_id == 0x0008 && ($attr_id == 0xFFFB || $attr_id == 0xFFFC)) {
        my $pct = MATTERDevice_Percentage($hash);
        MATTERDevice_ReadingsSingleUpdate($hash, 'pct', $pct, 1)
            if defined($pct) && ReadingsVal($hash->{NAME}, 'pct', '') ne "$pct";
    }

    return $parsed;
}

# Automatic command recovery applies structural metadata only. Explicit
# getConfig replies instead use the normal online attribute parser.
# Only existing endpoints belonging to this root are eligible.
sub MATTERDevice_ApplyCapabilityMetadata($$;$) {
    my ($root, $values, $endpoint_only) = @_;
    return unless $root && ($root->{endpoint_id} // 0) == 0 &&
                  $root->{helper}{available} &&
                  ref($values) eq 'HASH';
    my %targets = (0 => $root);
    foreach my $child (MATTERDevice_NodeChildren($root)) {
        $targets{$child->{endpoint_id}} = $child;
    }
    for my $path (sort {
        ($a =~ m{/29/1$} ? 1 : 0) <=> ($b =~ m{/29/1$} ? 1 : 0)
    } keys %$values) {
        next unless $path =~ m{^(\d+)/(\d+)/(\d+)$};
        my ($ep, $cluster, $attr_id) = (0 + $1, 0 + $2, 0 + $3);
        next if defined($endpoint_only) && $ep != $endpoint_only;
        next unless $targets{$ep};
        # A newer live ServerList may have been reconciled into this reply.
        # Apply it last so older global metadata cannot revive removed clusters.
        if ($cluster == 29 && $attr_id == 1) {
            MATTERDevice_ProcessAttributeValue($targets{$ep}, $cluster, $attr_id, $values->{$path});
        } elsif (exists $MATTER_GLOBAL_ATTRIBUTES{$attr_id}) {
            MATTERDevice_ProcessGlobalAttribute($targets{$ep}, $cluster, $attr_id, $values->{$path});
        }
    }
}

sub MATTERDevice_CapabilityContains($$$$) {
    my ($hash, $cluster_id, $list_name, $id) = @_;
    my $list = $hash->{helper}{capabilities}{$cluster_id}{$list_name};
    return 0 if (ref($list) ne 'HASH');
    return exists($list->{$id}) ? 1 : 0;
}

sub MATTERDevice_CommandAccepted($$$) {
    my ($hash, $cluster_id, $command_id) = @_;
    return MATTERDevice_CapabilityContains($hash, $cluster_id, "accepted_commands", $command_id);
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

# AttributeList bestimmt die Präsenz. Bekannte Attribute können zusätzlich
# bestimmte Features in der FeatureMap voraussetzen.
sub MATTERDevice_AttributeUsable($$$) {
    my ($hash, $cluster_id, $attr_id) = @_;
    # A persisted device report remains usable before runtime AttributeList
    # metadata arrives. A received list takes precedence over the saved report.
    my $list = $hash->{helper}{capabilities}{$cluster_id}{attribute_list};
    return 1 if ref($list) ne 'HASH';
    return 0 if (!MATTERDevice_AttributeSupported($hash, $cluster_id, $attr_id));

    my $cluster = $MATTER_CLUSTERS{$cluster_id};
    return 1 if (!$cluster || ref($cluster->{attributes}) ne 'HASH');

    my $attribute = $cluster->{attributes}{$attr_id};
    return 1 if (!$attribute);

    foreach my $feature (@{$attribute->{required_features} // []}) {
        return 0 if (!MATTERDevice_FeatureSupported($hash, $cluster_id, $feature));
    }

    return 1;
}

# Only explicitly mapped standard write targets can authorize setters.
# The device still decides ACL permission and value acceptance on each write.
sub MATTERDevice_AttributeWritable($$$) {
    my ($hash, $cluster, $attribute) = @_;
    return $MATTER_CLUSTERS{$cluster}{attributes}{$attribute}{writable} &&
           MATTERDevice_AttributeSupported($hash, $cluster, $attribute) &&
           MATTERDevice_AttributeUsable($hash, $cluster, $attribute);
}

# Standard-compatible choices; optional enum support is still device-owned.
# Use one list for FHEMWEB and explicit SetFn calls.
sub MATTERDevice_HvacModes($$) {
    my ($hash, $cluster) = @_;
    my $thermostat = $cluster == 0x0201;
    return () unless MATTERDevice_AttributeWritable($hash, $cluster, $thermostat ? 28 : 0) &&
                     MATTERDevice_AttributeSupported($hash, $cluster, $thermostat ? 27 : 1);
    my $cap = $hash->{helper}{capabilities}{$cluster};
    return () unless defined($cap->{feature_map}) && defined($cap->{mode_sequence});
    my $sequence = $cap->{mode_sequence};
    if ($thermostat) {
        my $heat = $sequence >= 2 && MATTERDevice_FeatureSupported($hash, $cluster, 'heating');
        my $cool = ($sequence < 2 || $sequence >= 4) &&
                   MATTERDevice_FeatureSupported($hash, $cluster, 'cooling');
        return ('off', $heat ? ('heat') : (), $cool ? ('cool') : (),
                $heat && $cool && MATTERDevice_FeatureSupported($hash, $cluster, 'auto_mode') ? ('auto') : (),
                $heat ? ('emergency_heat') : ());
    }
    my @sequences = (
        [qw(off low medium high)], [qw(off low high)],
        [qw(off low medium high auto)], [qw(off low high auto)],
        [qw(off high auto)], [qw(off high)],
    );
    return grep { $_ ne 'auto' || MATTERDevice_FeatureSupported($hash, $cluster, 'auto_mode') }
           @{$sequences[$sequence]};
}

# Ein FHEM-Command gilt nur dann als verfügbar, wenn der Matter-Server ihn
# tatsächlich in AcceptedCommandList meldet und die für diesen Command
# hinterlegten FeatureMap-Bedingungen erfüllt sind.
# A device command is available only if the endpoint's actual Matter
# AcceptedCommandList advertises it. Reported values or retired has_* flags
# never constitute permission to send a command.
sub MATTERDevice_CommandSupported($$$) {
    my ($hash, $cluster_id, $command_id) = @_;
    return 0 unless MATTERDevice_CommandAccepted($hash, $cluster_id, $command_id);

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

# Read device-reported limits, including statefile-restored readings. Saved
# FHEM attributes are never evidence of a physical device limit.
sub MATTERDevice_ReportedLimit($$$) {
    my ($hash, $cluster_id, $attr_id) = @_;
    return undef unless MATTERDevice_AttributeUsable($hash, $cluster_id, $attr_id);
    my $attribute = $MATTER_CLUSTERS{$cluster_id}{attributes}{$attr_id};
    return undef unless $attribute && $attribute->{limit_range};
    my $value = ReadingsVal($hash->{NAME}, $attribute->{name}, undef);
    my ($min, $max) = @{$attribute->{limit_range}};
    return undef unless defined($value) && !ref($value) &&
        $value =~ /\A[0-9]+\z/ && $value >= $min && $value <= $max;
    return 0 + $value;
}

# Matter Lighting uses the standardized 1..254 level scale. The generic
# LevelControl MaxLevel report may narrow other devices' level ranges;
# 254 is the protocol fallback when no usable maximum was reported.
sub MATTERDevice_MaxBrightness {
    my ($hash) = @_;
    return 254 if MATTERDevice_FeatureSupported($hash, 0x0008, 'lighting');
    return MATTERDevice_ReportedLimit($hash, 0x0008, 0x0003) // 254;
}

# Recalculate derived percentage without manufacturing a CurrentLevel report.
sub MATTERDevice_Percentage($) {
    my ($hash) = @_;
    my $level = ReadingsVal($hash->{NAME}, 'brightness', undef);
    return undef unless defined($level) && !ref($level) &&
        $level =~ /\A[0-9]+\z/ && $level <= 254;
    my $max = MATTERDevice_MaxBrightness($hash);
    return undef unless $max > 0;
    my $pct = int($level * 100 / $max);
    return $pct > 100 ? 100 : $pct;
}

sub MATTERDevice_CommandRequest {
    my ($hash, $cluster, $command, $payload) = @_;
    my $args = {
        node_id => $hash->{node_id},
        endpoint_id => int($hash->{endpoint_id} // 1),
        cluster_id => $cluster,
        command_name => $command,
    };
    $args->{payload} = $payload if defined $payload;
    return { command => 'device_command', args => $args };
}

# Endpoint disable deliberately uses the attribute alone, not physical state
# or FHEM IsDisabled's unrelated inactive/interval conventions.
sub MATTERDevice_IsDisabled {
    my ($hash) = @_;
    return ($hash->{endpoint_id} // 0) > 0 && AttrVal($hash->{NAME}, 'disable', 0);
}

# Local policy, independent of reported Matter capabilities. Reads bypass
# readOnly, but are blocked along with control commands while disabled.
sub MATTERDevice_ControlError {
    my ($hash, $read) = @_;
    return "MATTER: $hash->{NAME} is disabled (disable=1)"
        if MATTERDevice_IsDisabled($hash);
    return undef if $read;
    return undef unless ($hash->{endpoint_id} // 0) > 0 &&
                        AttrVal($hash->{NAME}, 'readOnly', 0);
    return "MATTER: $hash->{NAME} is read-only (readOnly=1); control commands blocked";
}

sub MATTERDevice_Set($$@) {
    my ($hash, $name, $cmd, @args) = @_;

    if ($cmd ne '?') {
        my $error = MATTERDevice_ControlError($hash, $cmd eq 'getConfig');
        return $error if defined $error;
    }
    my @setList = MATTERDevice_GetSetList($hash);
    my $list_str = join(" ", @setList);
    my $valid = 0;

    if ($cmd eq "?") {
        return "Unknown argument $cmd, choose one of $list_str";
    }

    foreach my $item (@setList) {
        my ($cmd_name, $widget) = split(':', $item, 2);
        next unless $cmd_name eq $cmd;
        return "Usage: set $name $cmd (no arguments)" if @args && ($widget // '') eq 'noArg';
        $valid = 1;
        last;
    }

    unless ($valid) {
        return "Unknown argument $cmd, choose one of $list_str";
    }
    
    my $payload       = undef;
    my $level_payload = undef;
    my $node_id     = $hash->{node_id};
    my $endpoint_id = $hash->{endpoint_id} // 1;
    my $io_hash = $hash->{IODev};
    return "MATTER: No active WebSocket connection for $name"
        unless $io_hash && $io_hash->{CD} && $io_hash->{websocket} &&
            ($io_hash->{ws_status} // '') eq 'connected';

    # Direct FHEM commands must not coerce malformed numeric arguments to zero.
    if ($cmd =~ /^(?:brightness|pct|tilt|ct|frequency)$/) {
        return "Usage: set $name $cmd <non-negative integer>"
            unless @args == 1 && defined($args[0]) && $args[0] =~ /\A\d+\z/;
        return "$cmd must be between 0 and 100" if ($cmd eq 'pct' || $cmd eq 'tilt') && $args[0] > 100;
        return "Invalid brightness" if $cmd eq 'brightness' &&
            $args[0] > MATTERDevice_MaxBrightness($hash);
        return "Invalid color temperature" if $cmd eq 'ct' && (!$args[0] || $args[0] > 65534);
        return "Invalid frequency" if $cmd eq 'frequency' && (!$args[0] || $args[0] > 65535);
    }

    if ($cmd eq 'checkFirmwareUpdate' || $cmd eq 'updateFirmware') {
        my $op = $cmd eq 'checkFirmwareUpdate' ?
            'check_node_update' : 'update_node';
        my %args;
        $args{software_version} = $hash->{helper}{firmware_available}
            if $op eq 'update_node';
        my $error = MATTERDevice_SendNodeOperation(
            $hash, $op, \%args, $cmd eq 'updateFirmware' ? 300 : 120);
        return $error if defined($error);
        return wantarray ? (undef, 1) : undef;
    }
    if ($cmd =~ /^(?:icdRegister|icdUnregister|icdResync)$/) {
        return 'ICD administrative operation only allowed on an ICD root'
            unless ($hash->{endpoint_id} // 0) == 0 &&
                ReadingsVal($name, 'icd_supported', '') eq 'true';
        my %operations = (
            icdRegister => 'register_icd',
            icdUnregister => 'unregister_icd',
            icdResync => 'resync_icd',
        );
        my $error = MATTERDevice_SendNodeOperation(
            $hash, $operations{$cmd}, {}, 120);
        return $error if defined $error;
        return wantarray ? (undef, 1) : undef;
    }
    if ($cmd eq "on" || $cmd eq "off") {
        my $onoff_command_id = ($cmd eq "on") ? 0x01 : 0x00;
        my $wc_command_id    = ($cmd eq "on") ? 0x00 : 0x01;
        my $can_onoff = MATTERDevice_CommandSupported($hash, 0x0006, $onoff_command_id);
        my $can_wc    = MATTERDevice_CommandSupported($hash, 0x0102, $wc_command_id);

        if ($can_onoff) {
            $payload = MATTERDevice_CommandRequest($hash, 0x0006, ($cmd eq "on" ? "On" : "Off"));
        }
        elsif ($can_wc) {
            $payload = MATTERDevice_CommandRequest($hash, 0x0102, ($cmd eq "on" ? "UpOrOpen" : "DownOrClose"));
        }
    }
    elsif ($cmd eq "toggle") {
        $payload = MATTERDevice_CommandRequest($hash, 0x0006, "Toggle");
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

        $payload = MATTERDevice_CommandRequest($hash, 0x0006, "OffWithEffect", {
            effectIdentifier => $effect_identifier{$effect_name},
            effectVariant    => $effect_variant{$effect_name}{$variant_name}
        });
    }
    elsif ($cmd eq "on_with_recall_global_scene") {
        $payload = MATTERDevice_CommandRequest($hash, 0x0006, "OnWithRecallGlobalScene");
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

        $payload = MATTERDevice_CommandRequest($hash, 0x0006, "OnWithTimedOff", {
            onOffControl => $accept_only_when_on,
            onTime       => $on_time,
            offWaitTime  => $off_wait_time
        });
    }
    elsif ($cmd eq "stop") {
        $payload = MATTERDevice_CommandRequest($hash, 0x0102, "StopMotion");
    }
    elsif ($cmd eq "brightness") {
        my $use_with_onoff = MATTERDevice_CommandSupported($hash, 0x0008, 0x04);
        $payload = MATTERDevice_CommandRequest($hash, 0x0008, ($use_with_onoff ? "MoveToLevelWithOnOff" : "MoveToLevel"),
            { level => int($args[0]), transitionTime => 0, optionsMask => 0, optionsOverride => 0 });
    }
    elsif ($cmd eq "pct") {
        my $can_wc_pct = MATTERDevice_CommandSupported($hash, 0x0102, 0x05);
        if ($can_wc_pct) {
            my $position = $args[0] * 100;
            $payload = MATTERDevice_CommandRequest($hash, 0x0102, "GoToLiftPercentage",
                { liftPercent100thsValue => $position });
        } else {
            my $max_level = MATTERDevice_MaxBrightness($hash);
            my $use_with_onoff = MATTERDevice_CommandSupported($hash, 0x0008, 0x04);
            $payload = MATTERDevice_CommandRequest($hash, 0x0008, ($use_with_onoff ? "MoveToLevelWithOnOff" : "MoveToLevel"),
                { level => int($args[0] * $max_level / 100 + 0.5), transitionTime => 0, optionsMask => 0, optionsOverride => 0 });
        }
    }
    elsif ($cmd eq "tilt") {
        my $tilt = $args[0] * 100;
        $payload = MATTERDevice_CommandRequest($hash, 0x0102, "GoToTiltPercentage",
            { tiltPercent100thsValue => $tilt });
    }
    elsif ($cmd eq "rgb") {
        return "Usage: set $name rgb RRGGBB"
            unless @args == 1 && defined($args[0]) && $args[0] =~ /^#?[0-9a-fA-F]{6}$/;
        my $hex = $args[0];
        $hex =~ s/^#//;
        my ($r, $g, $b) = map { hex($_) } ($hex =~ /(..)(..)(..)/);

        my $intensity = max($r, $g, $b) / 255;
        my $with_onoff = MATTERDevice_CommandSupported($hash, 0x0008, 0x04);
        if ($with_onoff || MATTERDevice_CommandSupported($hash, 0x0008, 0x00)) {
            my $level = int($intensity * MATTERDevice_MaxBrightness($hash) + 0.5);
            $level_payload = MATTERDevice_CommandRequest($hash, 0x0008,
                $with_onoff ? "MoveToLevelWithOnOff" : "MoveToLevel",
                { level => $level, transitionTime => 0, optionsMask => 0, optionsOverride => 0 });
        }

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

                $payload = MATTERDevice_CommandRequest($hash, 0x0300, "MoveToColor",
                    { colorX => $x, colorY => $y, transitionTime => 0, optionsMask => 0, optionsOverride => 0 });
            }

        } else {
            $r /= 255; $g /= 255; $b /= 255;
            my $min = min($r, $g, $b);
            my $diff = $intensity - $min;
            my $h = 0;
            my $s = ($intensity == 0) ? 0 : ($diff / $intensity);

            if ($diff != 0) {
                if ($intensity == $r) { $h = 60 * (($g - $b) / $diff); }
                elsif ($intensity == $g) { $h = 60 * (($b - $r) / $diff + 2); }
                else { $h = 60 * (($r - $g) / $diff + 4); }
            }
            $h += 360 if $h < 0;

            $payload = MATTERDevice_CommandRequest($hash, 0x0300, "MoveToHueAndSaturation",
                { hue => int(($h / 360) * 254), saturation => int($s * 254), transitionTime => 0, optionsMask => 0, optionsOverride => 0 });
        }
    }
    elsif ($cmd eq "ct") {
        $payload = MATTERDevice_CommandRequest($hash, 0x0300, "MoveToColorTemperature",
            { colorTemperatureMireds => int($args[0]), transitionTime => 0, optionsMask => 0, optionsOverride => 0 });
    }
    elsif ($cmd =~ /^(?:dim_up|dim_down|dim_stop|dim_step_up|dim_step_down)$/) {
        # Use the device's native LevelControl transitions. Never simulate a
        # continuous dim by issuing repeated pct commands from FHEM.
        my ($regular, $with_onoff, $mode);
        if ($cmd eq 'dim_up' || $cmd eq 'dim_down') {
            ($regular, $with_onoff) = (0x01, 0x05);
            $mode = $cmd eq 'dim_up' ? 0 : 1;
        } elsif ($cmd eq 'dim_step_up' || $cmd eq 'dim_step_down') {
            ($regular, $with_onoff) = (0x02, 0x06);
            $mode = $cmd eq 'dim_step_up' ? 0 : 1;
        } else {
            ($regular, $with_onoff) = (0x03, 0x07);
        }
        my $accepted_regular = MATTERDevice_CommandSupported($hash, 0x0008, $regular);
        my $accepted_onoff = MATTERDevice_CommandSupported($hash, 0x0008, $with_onoff);
        return "Native dim command is not supported" unless $accepted_regular || $accepted_onoff;
        my $using_onoff = !$accepted_regular && $accepted_onoff;
        my $command_name =
            $regular == 0x01 ? ($using_onoff ? 'MoveWithOnOff' : 'Move') :
            $regular == 0x02 ? ($using_onoff ? 'StepWithOnOff' : 'Step') :
                               ($using_onoff ? 'StopWithOnOff' : 'Stop');
        my $arguments = { optionsMask => 0, optionsOverride => 0 };
        if ($regular == 0x01) {
            my $rate = AttrVal($name, 'dimRate', 30);
            return "dimRate must be an integer between 1 and 254"
                unless defined($rate) && !ref($rate) && $rate =~ /\A[0-9]+\z/ && $rate >= 1 && $rate <= 254;
            $arguments->{moveMode} = $mode;
            $arguments->{rate} = int($rate);
        } elsif ($regular == 0x02) {
            $arguments->{stepMode} = $mode;
            $arguments->{stepSize} = 20;
            $arguments->{transitionTime} = 0;
        }
        $payload = MATTERDevice_CommandRequest($hash, 0x0008, $command_name,
            $arguments);
    }
    elsif ($cmd eq 'identify') {
        return 'Identify not accepted by this endpoint'
            unless MATTERDevice_CommandSupported($hash, 0x0003, 0x00);
        $payload = MATTERDevice_CommandRequest($hash, 0x0003, 'Identify',
            { identifyTime => 15 });
    }
    elsif ($cmd =~ /^(?:desired-temp(?:-cool)?|mode|fan_mode|fan_pct)$/) {
        my ($cluster_id, $attr_id, $write_value);
        return "Usage: set $name $cmd <value>" if @args != 1 || !defined($args[0]);
        my $value = $args[0];
        if ($cmd eq 'desired-temp' || $cmd eq 'desired-temp-cool') {
            return "$cmd must be a valid temperature in degrees Celsius"
                unless $value =~ /^-?\d+(?:\.\d{1,2})?$/ &&
                       $value >= -273.15 && $value <= 327.67;
            ($cluster_id, $attr_id) = (0x0201, $cmd eq 'desired-temp' ? 0x0012 : 0x0011);
            $write_value = int($value * 100 + ($value >= 0 ? 0.5 : -0.5));
        } elsif ($cmd eq 'mode') {
            my @allowed = MATTERDevice_HvacModes($hash, 0x0201);
            return 'mode must be one of ' . join(', ', @allowed)
                unless grep { $_ eq $value } @allowed;
            my %modes = (off => 0, auto => 1, cool => 3, heat => 4,
                         emergency_heat => 5);
            ($cluster_id, $attr_id, $write_value) = (0x0201, 0x001C, $modes{$value});
        } elsif ($cmd eq 'fan_mode') {
            my @allowed = MATTERDevice_HvacModes($hash, 0x0202);
            return 'fan_mode must be one of ' . join(', ', @allowed)
                unless grep { $_ eq $value } @allowed;
            my %modes = (off => 0, low => 1, medium => 2, high => 3, auto => 5);
            ($cluster_id, $attr_id, $write_value) = (0x0202, 0x0000, $modes{$value});
        } else {
            return 'fan_pct must be between 0 and 100'
                unless $value =~ /^\d+$/ && $value <= 100;
            ($cluster_id, $attr_id, $write_value) = (0x0202, 0x0002, int($value));
        }
        return "Matter attribute for $cmd is not advertised"
            unless MATTERDevice_AttributeWritable($hash, $cluster_id, $attr_id);
        $payload = {
            command => 'write_attribute',
            args => {
                node_id => $node_id,
                attribute_path => "$endpoint_id/$cluster_id/$attr_id",
                value => $write_value
            }
        };
    }
    elsif ($cmd eq "getConfig") {
        my $ioHash = $io_hash; # Connection was already checked above.
        my $root = ($hash->{endpoint_id} // 0) == 0 ? $hash :
            MATTERDevice_LookupRoot($ioHash, $node_id);
        return "MATTER: Node $node_id is offline or availability is unknown; getConfig not sent"
            if !$root || !$root->{helper}{available};

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

        # Read the endpoint's advertised Matter device types, independently of
        # whether the module supports that endpoint's functional clusters.
        push @paths, "$endpoint_id/29/0";

        # ServerList is authoritative for cluster removal, unlike omitted
        # paths in a partially successful attribute read.
        push @paths, "$endpoint_id/29/1";
        # Root-Descriptor: PartsList mitlesen.
        if ($endpoint_id == 0) {
            push @paths, "0/29/3";
        }

        # Als Bulk-Array an den Server schicken.
        if (@paths) {
            my $pending_reads = ($ioHash->{helper}{pending_config} //= {});
            foreach my $id (keys %$pending_reads) {
                my $entry = $pending_reads->{$id};
                if (gettimeofday() - ($entry->{created_at} // 0) > 120) {
                    delete $pending_reads->{$id};
                    next;
                }
                # Do not allow a second request for this endpoint to return
                # an older configuration after a newer response was applied.
                return "MATTER: getConfig already in progress for $name"
                    if $entry->{node_id} eq $node_id &&
                       $entry->{endpoint_id} == $endpoint_id;
            }
            return "MATTER: Too many pending read requests"
                if scalar(keys %$pending_reads) >= 128;
            my $msg_id = MATTER_NextMessageId($ioHash);
            return "MATTER: Cannot allocate request ID" unless defined $msg_id;
            $pending_reads->{$msg_id} = {
                node_id => $node_id,
                endpoint_id => int($endpoint_id),
                owner => $hash, fuuid => $hash->{FUUID},
                root_fuuid => $root ? $root->{FUUID} : undef,
                availability_epoch => $root ?
                    ($root->{helper}{availability_epoch} // 0) : 0,
                created_at => gettimeofday()
            };

            my $config_payload = {
                message_id   => $msg_id,
                command      => "read_attribute",
                args         => {
                    node_id        => int($node_id),
                    attribute_path => \@paths
                }
            };
            
            unless (MATTER_SendJsonCommand($ioHash, $config_payload)) {
                delete $pending_reads->{$msg_id};
                return "MATTER: Unable to send getConfig on $name";
            }
            Log3 $name, 3, "MATTERDevice: Wildcard getConfig triggered for node $node_id, endpoint $endpoint_id (" . scalar(@paths) . " paths queried).";
        }

        return undef;
    }
    elsif ($cmd eq "frequency") {
        $payload = MATTERDevice_CommandRequest($hash, 0x0008, "MoveToClosestFrequency",
            { frequency => int($args[0]) });
    }
    elsif ($cmd eq "lock") {
        $payload = MATTERDevice_CommandRequest($hash, 0x0101, "LockDoor");
    }
    elsif ($cmd eq "unlock") {
        $payload = MATTERDevice_CommandRequest($hash, 0x0101, "UnlockDoor");
    }

    return "No payload generated" if (!$payload && !$level_payload);

    my @requests = grep { defined $_ } ($level_payload, $payload);
    my $error = MATTERDevice_SendRequests($hash, \@requests, 'lastError', 120);
    return $error if defined $error;
    return wantarray ? (undef, 1) : undef;
}

sub MATTERDevice_Get($$@) {
    my ($hash, $name, $cmd, @args) = @_;
    my $root = ($hash->{endpoint_id} // 0) == 0;
    my $icd = $root && ReadingsVal($name, 'icd_supported', '') eq 'true';
    my $io = $hash->{IODev};
    my $supported = $icd && $io && $io->{helper}{icd_api_supported};
    return 'Unknown argument, choose one of ' .
           ($supported ? 'icdState' : '') if !defined($cmd) || $cmd eq '?';
    return 'Unknown argument, choose one of ' .
           ($supported ? 'icdState' : '')
        unless $cmd eq 'icdState' && $supported && !@args;
    my $error = MATTERDevice_SendNodeOperation($hash, 'get_icd_state', {}, 120);
    return $error if defined $error;
    return 'ICD state requested; result will appear in icd_* readings';
}

# --- Zentraler Parser für alle Attribut-Updates ---

# GeneralDiagnostics.NetworkInterfaces (0/51/0): report operational interface
# types, not the route used by a particular Matter session. matterjs-server
# serializes struct fields as TLV tags; named fields are also accepted.
sub MATTERDevice_NetworkType {
    my ($value) = @_;
    return undef unless ref($value) eq 'ARRAY';
    my %labels = (0 => 'unknown', 1 => 'wifi', 2 => 'ethernet',
                  3 => 'cellular', 4 => 'thread');
    my %types;
    foreach my $interface (@$value) {
        return undef unless ref($interface) eq 'HASH';
        my $operational = MATTERDevice_NormalizeBoolean(
            exists($interface->{isOperational}) ? $interface->{isOperational}
                                               : $interface->{'1'});
        return undef unless defined $operational;
        next unless $operational;
        my $type = exists($interface->{type}) ? $interface->{type}
                                            : $interface->{'7'};
        return undef unless defined($type) && !ref($type) &&
                            $type =~ /\A[0-9]+\z/ && $type <= 255;
        $types{$labels{int($type)} // 'unknown'} = 1;
    }
    return keys(%types) ? join(',', sort keys %types) : 'unknown';
}

# Opt-in passive diagnostics: no additional server reads or polling.
sub MATTERDevice_NetworkDiagnosticValues {
    my ($cluster, $attr, $value) = @_;
    my %readings;
    if ($cluster == 53) {
        if ($attr == 0 && defined($value) && !ref($value) &&
            $value =~ /^\d+$/ && $value <= 255) {
            $readings{thread_channel} = int($value);
        } elsif ($attr == 1 && defined($value) && !ref($value) &&
                 $value =~ /^\d+$/) {
            my %roles = (0 => 'unspecified', 1 => 'unassigned',
                         2 => 'sleepy_end_device', 3 => 'end_device',
                         4 => 'reed', 5 => 'router', 6 => 'leader');
            $readings{thread_role} = $roles{$value} if exists $roles{$value};
            my %types = (2 => 'MTD', 3 => 'MTD or FTD',
                         4 => 'FTD', 5 => 'FTD', 6 => 'FTD');
            $readings{thread_device_type} = $types{$value}
                if exists $types{$value};
        } elsif ($attr == 2 && defined($value) && !ref($value) &&
                 length($value) <= 128) {
            $readings{thread_network} = $value;
        } elsif ($attr == 7 && ref($value) eq 'ARRAY' && @$value <= 256) {
            $readings{thread_neighbors} = scalar(@$value);
            my @neighbors;
            my ($best_rssi, $best_lqi);
            foreach my $n (@$value) {
                next unless ref($n) eq 'HASH';
                my $child = $n->{isChild} // $n->{'13'} // 0;
                my $rssi = $n->{averageRssi} // $n->{'6'} //
                           $n->{lastRssi} // $n->{'7'};
                next unless defined($rssi) && !ref($rssi) &&
                            $rssi =~ /^-?\d+$/ && $rssi >= -128 && $rssi <= 0;
                if (!$child && (!defined($best_rssi) || $rssi > $best_rssi)) {
                    $best_rssi = $rssi;
                    $best_lqi = $n->{lqi} // $n->{'5'};
                }
                my $id = $n->{extAddress} // $n->{'0'} // 'unknown';
                $id = 'unknown' if ref($id) || length("$id") > 24;
                push @neighbors, [$rssi,
                    "$id (" . ($child ? 'child' : 'router') . ", $rssi dBm)"];
            }
            $readings{rssi} = $best_rssi if defined $best_rssi;
            $readings{lqi} = $best_lqi if defined($best_lqi) &&
                               !ref($best_lqi) && $best_lqi =~ /^[0-3]$/;
            @neighbors = sort { $b->[0] <=> $a->[0] } @neighbors;
            splice(@neighbors, 16) if @neighbors > 16;
            $readings{thread_neighbor_list} = @neighbors ?
                substr(join(', ', map { $_->[1] } @neighbors), 0, 600) : 'none';
        }
    } elsif ($cluster == 54 && $attr == 4 && defined($value) &&
             !ref($value) && $value =~ /^-?\d+$/ &&
             $value >= -128 && $value <= 0) {
        $readings{wifi_rssi} = $value;
    }
    return keys(%readings) ? \%readings : undef;
}

sub MATTERDevice_UpdateNetworkDiagnostics {
    my ($hash, $readings) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0 &&
                  AttrVal($hash->{NAME}, 'diagnostics', 0);
    while (my ($reading, $val) = each %$readings) {
        MATTERDevice_ReadingsSingleUpdate($hash, $reading, $val, 1)
            if ReadingsVal($hash->{NAME}, $reading, '') ne "$val";
    }
}
sub MATTERDevice_RawDiagnostic {
    my ($hash, $cluster, $attr, $value) = @_;
    return unless AttrVal($hash->{NAME}, 'rawReadings', 0);
    return unless defined($value) && $attr < 0xFFF0;
    # Sensitive administration, fabric, key, and commissioning clusters.
    return if $cluster =~ /^(?:31|48|49|60|62|63|64|65)$/;
    my $str = ref($value) ? eval { encode_json($value) } : "$value";
    return if !defined($str) || length($str) > 512;
    my $reading = 'raw_' . ($hash->{endpoint_id} // 0) .
                  '_' . $cluster . '_' . $attr;
    MATTERDevice_ReadingsSingleUpdate($hash, $reading, $str, 1)
        if ReadingsVal($hash->{NAME}, $reading, '') ne $str;
}


# Passive ICD support belongs to the root only. A saved capability reading
# may survive a restart, while dynamic awake/registration must be refreshed
# explicitly through matterjs-server.
sub MATTERDevice_RefreshIcdCapability {
    my ($hash) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0;
    my $features = $hash->{helper}{capabilities}{70}{feature_map};
    my $spec = ReadingsVal($hash->{NAME}, 'specification_version', undef);
    return unless defined($features) && !ref($features) &&
                  $features =~ /^\d+$/ &&
                  defined($spec) && !ref($spec) && $spec =~ /^\d+$/;
    my $supported = ($features & 0x04) && $spec >= 0x01040000 ?
                    'true' : 'false';
    MATTERDevice_ReadingsSingleUpdate($hash, 'icd_lit_supported', $supported, 1)
        if ReadingsVal($hash->{NAME}, 'icd_lit_supported', '') ne $supported;
}
sub MATTERDevice_RootCapabilityReport {
    my ($hash, $cluster, $attr, $value) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0;
    if ($cluster == 29 && $attr == 1) {
        # ServerList is a complete list even in a partial node report.
        # An omitted list or any malformed entry cannot revoke support.
        return unless ref($value) eq 'HASH';
        my ($supported, $ota) = ($value->{70}, $value->{42});
        if ($ota) {
            $hash->{helper}{seen_clusters}{42} = 1;
        } else {
            delete $hash->{helper}{seen_clusters}{42};
            delete $hash->{helper}{firmware_available};
        }
        # Avoid adding negative ICD readings to every ordinary root.
        return if !$supported && !exists($hash->{READINGS}{icd_supported});
        unless ($supported) {
            delete $hash->{helper}{capabilities}{70};
            delete $hash->{helper}{seen_clusters}{70};
        }
        my $reported = $supported ? 'true' : 'false';
        MATTERDevice_ReadingsSingleUpdate($hash, 'icd_supported', $reported, 1)
            if ReadingsVal($hash->{NAME}, 'icd_supported', '') ne $reported;
        if (!$supported && exists($hash->{READINGS}{icd_lit_supported})) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_lit_supported', 'false', 1)
                if ReadingsVal($hash->{NAME}, 'icd_lit_supported', '') ne 'false';
        }
    } elsif ($cluster == 70 && defined($value) && !ref($value)) {
        if ($attr == 65532 && $value =~ /^\d+$/) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_supported', 'true', 1)
                if ReadingsVal($hash->{NAME}, 'icd_supported', '') ne 'true';
            MATTERDevice_RefreshIcdCapability($hash);
        } elsif ($attr == 8 && $value =~ /^(?:0|1)$/) {
            my $mode = $value == 1 ? 'LIT' : 'SIT';
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_operating_mode', $mode, 1)
                if ReadingsVal($hash->{NAME}, 'icd_operating_mode', '') ne $mode;
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_supported', 'true', 1)
                if ReadingsVal($hash->{NAME}, 'icd_supported', '') ne 'true';
        } elsif ($attr == 0 && $value =~ /^\d+$/ && $value <= 4294967295) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_idle_mode_duration', $value, 1)
                if ReadingsVal($hash->{NAME}, 'icd_idle_mode_duration', '') ne "$value";
        }
    } elsif ($cluster == 40 && $attr == 21 &&
             defined($value) && !ref($value) && $value =~ /^\d+$/) {
        MATTERDevice_ReadingsSingleUpdate($hash, 'specification_version', $value, 1)
            if ReadingsVal($hash->{NAME}, 'specification_version', '') ne "$value";
        MATTERDevice_RefreshIcdCapability($hash);
    }
}
# Transport correlation is independent of FHEM command names. One setter may
# emit several API requests (RGB); all belong to one diagnostic result.
sub MATTERDevice_SendRequests {
    my ($hash, $requests, $reading, $timeout) = @_;
    my $blocked = MATTERDevice_ControlError($hash);
    return $blocked if defined $blocked;
    my $io = $hash->{IODev};
    return "MATTER: No active WebSocket connection for $hash->{NAME}"
        unless $io && $io->{CD} && $io->{websocket} &&
               ($io->{ws_status} // '') eq 'connected';
    my $pending = ($io->{helper}{pending_command} //= {});
    # Bound unanswered requests without serializing ordinary commands.
    return 'MATTER: Too many pending device requests'
        if scalar(keys %$pending) + @$requests > 1024;
    my $group = { remaining => scalar @$requests };
    my @ids;
    for my $payload (@$requests) {
        my $id = MATTER_NextMessageId($io);
        unless (defined $id) {
            delete $pending->{$_} for @ids;
            return 'MATTER: No available request ID';
        }
        $payload->{message_id} = $id;
        push @ids, $id;
        $pending->{$id} = {
            type => 'node_operation', operation => $payload->{command},
            owner => $hash, fuuid => $hash->{FUUID},
            node_id => $hash->{node_id}, endpoint_id => $hash->{endpoint_id} // 0,
            attribute_path => $payload->{args}{attribute_path},
            reading => $reading, group => $group,
            started_at => gettimeofday(), timeout => $timeout,
        };
    }
    # Install ownership before send: a callback may complete or close the IO.
    $hash->{helper}{latest_request}{$reading} = $group;
    for my $i (0 .. $#$requests) {
        # A synchronous reply can trigger a notify which enables readOnly
        # between components of a compound setter. Do not send its remainder.
        $blocked = MATTERDevice_ControlError($hash);
        next if !defined($blocked) && MATTER_SendJsonCommand($io, $requests->[$i]);
        for my $unsent ($i .. $#ids) {
            my $request = delete $io->{helper}{pending_command}{$ids[$unsent]};
            MATTERDevice_CompleteRequest($io, $request, undef,
                defined($blocked) ? "failed: $blocked" :
                    'failed: unable to send device command') if $request;
        }
        return $blocked if defined $blocked;
        return "MATTER: Unable to send device command on $hash->{NAME}";
    }
    return undef;
}

# Stable ownership shared by command completion and explicit read replies.
sub MATTERDevice_RequestOwner {
    my ($io, $request) = @_;
    return undef if $request->{cancelled};
    my $owner = $request->{owner};
    return undef unless $owner && ($defs{$owner->{NAME}} // '') eq $owner &&
        ($owner->{TYPE} // '') eq 'MATTERDevice' &&
        ($owner->{FUUID} // '') eq ($request->{fuuid} // '') &&
        ($owner->{node_id} // '') eq ($request->{node_id} // '') &&
        ($owner->{endpoint_id} // 0) == $request->{endpoint_id} &&
        $owner->{IODev} && $owner->{IODev} eq $io;
    return $owner;
}

# One completion path for replies, timeout and disconnect. Every request is
# retired independently; only the latest setter may update its status reading.
sub MATTERDevice_CompleteRequest {
    my ($io, $request, $reply, $failure) = @_;
    my $owner = MATTERDevice_RequestOwner($io, $request);
    return unless $owner;
    if (defined $reply) {
        my $received = {};
        MATTERDevice_RecordReceive(MATTERDevice_LookupRoot($io, $request->{node_id}), $received);
        MATTERDevice_RecordReceive($owner, $received);
    }
    return if MATTERDevice_IsDisabled($owner);
    my $group = $request->{group};
    --$group->{remaining};
    my $reading = $request->{reading};
    my $error = defined($failure) ? $failure :
        $reading eq 'lastError' ? MATTERDevice_RequestError($request, $reply) : undef;
    $group->{error} //= $error if defined $error;
    return unless ($owner->{helper}{latest_request}{$reading} // '') eq $group;
    delete $owner->{helper}{latest_request}{$reading} unless $group->{remaining};
    delete $owner->{helper}{firmware_update_in_flight}
        if defined($failure) && $request->{operation} eq 'update_node';
    if ($reading eq 'lastError' || defined $failure) {
        return if !defined($group->{error}) && $group->{remaining};
        my $status = $group->{error} // 'none';
        MATTERDevice_ReadingsSingleUpdate($owner, $reading, $status, 1)
            if ReadingsVal($owner->{NAME}, $reading, '') ne $status;
    } else {
        MATTERDevice_HandleNodeOperation($owner, $request, $reply);
    }
}

# API envelopes and operation result types, not FHEM setter names.
sub MATTERDevice_RequestError {
    my ($request, $reply) = @_;
    if (exists($reply->{error_code}) || exists($reply->{error})) {
        my $error = ref($reply->{error}) eq 'HASH' ?
            $reply->{error}{message} : $reply->{details};
        $error = 'Matter server rejected the request' unless defined($error) && !ref($error);
        $error =~ s/[\x00-\x1f\x7f]/ /g;
        return 'failed: ' . substr($error, 0, 200);
    }
    if ($request->{operation} eq 'write_attribute') {
        my $error = MATTERDevice_WriteResponseError($request, $reply);
        return defined($error) ? "failed: $error" : undef;
    }
    if ($request->{operation} eq 'device_command' && !exists($reply->{result})) {
        return 'failed: invalid device command response';
    }
    return undef;
}

sub MATTERDevice_SendNodeOperation {
    my ($hash, $command, $args, $timeout) = @_;
    my $io = $hash->{IODev};
    return 'No active Matter server connection' unless $io;
    # Preserve the existing OTA/ICD administrative serialization, separately
    # from unrestricted everyday device commands and attribute writes.
    for my $pending (values %{$io->{helper}{pending_command} // {}}) {
        next unless ref($pending) eq 'HASH' &&
                    ($pending->{type} // '') eq 'node_operation' &&
                    ($pending->{reading} // '') ne 'lastError';
        return 'Another Matter operation is already pending for this node'
            if ($pending->{fuuid} // '') eq ($hash->{FUUID} // '') &&
               ($pending->{node_id} // '') eq $hash->{node_id};
    }
    my $reading = $command =~ /icd/ ? 'icd_request' : 'firmware_update';
    if ($reading eq 'firmware_update') {
        delete $hash->{helper}{firmware_available};
        $hash->{helper}{firmware_update_in_flight} = $args->{software_version}
            if $command eq 'update_node';
    }
    my $error = MATTERDevice_SendRequests($hash, [{command => $command,
        args => {node_id => 0 + $hash->{node_id}, %{$args // {}}}}],
        $reading, $timeout // 120);
    if (defined $error) {
        delete $hash->{helper}{firmware_update_in_flight} if $command eq 'update_node';
        return $error;
    }
    my $status = $command eq 'check_node_update' ? 'checking' : 'requested';
    MATTERDevice_ReadingsSingleUpdate($hash, $reading, $status, 1)
        if $hash->{helper}{latest_request}{$reading};
    return undef;
}
# null retains the existing API-ack contract. A unicast status list must
# answer the one requested path; empty, unrelated or malformed data is no ACK.
sub MATTERDevice_WriteResponseError($$) {
    my ($request, $reply) = @_;
    return 'invalid write response' unless exists($reply->{result});
    my $result = $reply->{result};
    return undef unless defined $result;
    return 'invalid write response' unless ref($result) eq 'ARRAY' && @$result == 1 &&
        ref($result->[0]) eq 'HASH' && ref($result->[0]{Path}) eq 'HASH';
    my $expected = $request->{attribute_path};
    return 'invalid write response' unless defined($expected) &&
        $expected =~ m{\A(\d+)/(\d+)/(\d+)\z};
    my @ids = ($1, $2, $3);
    my $entry = $result->[0];
    for my $key (qw(EndpointId ClusterId AttributeId)) {
        my $id = $entry->{Path}{$key};
        return 'write response path mismatch' unless defined($id) && !ref($id) &&
            $id =~ /\A\d+\z/ && $id == shift @ids;
    }
    for my $key (qw(Status ClusterStatus)) {
        next if $key eq 'ClusterStatus' && !exists($entry->{$key});
        return 'invalid write response' unless defined($entry->{$key}) && !ref($entry->{$key}) &&
            $entry->{$key} =~ /\A\d+\z/ && $entry->{$key} <= 255;
    }
    return undef if $entry->{Status} == 0;
    return 'Matter write status ' . (0 + $entry->{Status}) .
        (exists($entry->{ClusterStatus}) ? ' (cluster status ' . (0 + $entry->{ClusterStatus}) . ')' : '');
}

# The server returns a JSON unsigned integer. Encoding the scalar inside
# an array preserves the distinction between a number and a quoted string.
sub MATTERDevice_OtaVersion {
    my ($result) = @_;
    return unless ref($result) eq 'HASH';
    my $version = $result->{software_version};
    return unless defined($version) && !ref($version) &&
        encode_json([$version]) =~ /\A\[[0-9]{1,10}\]\z/ && $version <= 4294967295;
    return $version;
}

sub MATTERDevice_HandleNodeOperation {
    my ($hash, $request, $reply) = @_;
    my $cmd = $request->{operation};
    my $reading = $request->{reading};
    my $error = MATTERDevice_RequestError($request, $reply);
    if (defined $error) {
        delete $hash->{helper}{firmware_update_in_flight} if $cmd eq 'update_node';
        if ($cmd eq 'check_node_update') {
            delete $hash->{helper}{firmware_available};
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update_version', 'none', 1);
        }
        MATTERDevice_ReadingsSingleUpdate($hash, $reading, $error, 1);
        return;
    }
    if ($cmd =~ /icd/) {
        if ($cmd eq 'resync_icd' && exists($reply->{result}) &&
            !defined($reply->{result})) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_request', 'resync accepted', 1);
            return;
        }
        my $value = $reply->{result};
        unless (ref($value) eq 'HASH' && exists($value->{supported})) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_request', 'invalid response', 1);
            return;
        }
        my %fields = (
            supported => 'icd_controller_supported',
            lit_supported => 'icd_controller_lit_supported',
            registered => 'icd_registered',
            awake => 'icd_awake',
            available => 'icd_controller_available',
        );
        for my $key (keys %fields) {
            next unless exists($value->{$key});
            my $b = MATTERDevice_NormalizeBoolean($value->{$key});
            next unless defined $b;
            MATTERDevice_ReadingsSingleUpdate($hash, $fields{$key},
                                 $b ? 'true' : 'false', 1);
        }
        if (defined($value->{operating_mode}) && !ref($value->{operating_mode}) &&
            $value->{operating_mode} =~ /^(?:SIT|LIT)$/) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_controller_mode',
                                 $value->{operating_mode}, 1);
        }
        if (defined($value->{next_expected_checkin}) &&
            !ref($value->{next_expected_checkin}) &&
            $value->{next_expected_checkin} =~ /^\d+$/) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'icd_next_expected_checkin_ms',
                                 $value->{next_expected_checkin}, 1);
        }
        MATTERDevice_ReadingsSingleUpdate($hash, 'icd_request', 'completed', 1);
    } elsif ($cmd eq 'check_node_update') {
        my $update = $reply->{result};
        if (!defined($update) && exists($reply->{result})) {
            delete $hash->{helper}{firmware_available};
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update_version', 'none', 1);
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update', 'none reported', 1);
        } elsif ($hash->{helper}{seen_clusters}{42} &&
                 defined(MATTERDevice_OtaVersion($update))) {
            my $current = ReadingsVal($hash->{NAME}, 'software_version', undef);
            if (defined($current) && $current =~ /^\d+$/ &&
                $update->{software_version} <= $current) {
                delete $hash->{helper}{firmware_available};
                MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update_version', 'none', 1);
                MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update', 'up to date', 1);
                return;
            }
            $hash->{helper}{firmware_available} = $update->{software_version};
            my $label = $update->{software_version_string};
            $label = $update->{software_version}
                unless defined($label) && !ref($label) && length($label) <= 80;
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update_version', $label, 1);
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update', 'available', 1);
        } else {
            delete $hash->{helper}{firmware_available};
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update_version', 'none', 1);
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update', 'invalid response', 1);
        }
    } elsif ($cmd eq 'update_node') {
        my $result = $reply->{result};
        my $target = $hash->{helper}{firmware_update_in_flight};
        my $version = MATTERDevice_OtaVersion($result);
        if (defined($target) && exists($reply->{result}) &&
            (!defined($result) || (defined($version) && $version == $target))) {
            my $status = ReadingsVal($hash->{NAME}, 'firmware_update', '');
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update', 'update requested', 1)
                if $status eq 'requested' || $status eq 'available';
        } else {
            delete $hash->{helper}{firmware_update_in_flight};
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update', 'invalid response', 1);
        }
    }
}
sub MATTERDevice_ProcessAttributeValue($$$$) {
    my ($hash, $cluster_id, $attr_id, $value) = @_; # quick unpack
    return if MATTERDevice_IsDisabled($hash);
    my $name = $hash->{NAME};

    # Cluster-ID und Attribut-ID sicher als numerischen/hexadezimalen Wert behandeln
    $cluster_id = hex($cluster_id) if $cluster_id =~ /^0x/i;
    $attr_id    = hex($attr_id)    if $attr_id =~ /^0x/i;

    my $cluster = $MATTER_CLUSTERS{$cluster_id};

    if (exists $MATTER_GLOBAL_ATTRIBUTES{$attr_id}) {
        my $parsed = MATTERDevice_ProcessGlobalAttribute($hash, $cluster_id, $attr_id, $value);
        MATTERDevice_RootCapabilityReport($hash, $cluster_id, $attr_id, $parsed)
            if defined($parsed) && $cluster_id == 70;
        return;
    }
    $value = MATTERDevice_AttributeValue($cluster_id, $attr_id, $value, $hash->{endpoint_id} // 0);
    return unless defined $value;

    if ($cluster_id == 29 && $attr_id == 1) {
        my $servers = $value;
        if (defined $servers) {
            delete @{$hash->{helper}{capabilities}}{
                grep { !$servers->{$_} } keys %{$hash->{helper}{capabilities} // {}}
            };
            $hash->{helper}{seen_clusters} = { %$servers };
        }
    }

    # Remember cluster presence for conservative fallback labels in FHEMWEB,
    # including measurement clusters this module does not yet expose as readings.
    $hash->{helper}{seen_clusters}{$cluster_id} = 1 if defined($value);

    # Device mode constraints belong in the existing capability cache, not in
    # the current physical mode reading. Partial reports keep earlier data.
    if (($cluster_id == 0x0201 && $attr_id == 27) ||
        ($cluster_id == 0x0202 && $attr_id == 1)) {
        $hash->{helper}{capabilities}{$cluster_id}{mode_sequence} = $value;
        return;
    }

    # OTA Requestor status comes from the physical device, not from the
    # WebSocket command acknowledgement.
    if (($hash->{endpoint_id} // 0) == 0 &&
        $cluster_id == 42 && $attr_id == 2 &&
        defined($value) && !ref($value) && $value =~ /^\d+$/) {
        my %state = (0 => 'unknown', 1 => 'idle',
                     2 => 'checking', 3 => 'waiting for update',
                     4 => 'downloading', 5 => 'installing',
                     6 => 'waiting to install', 7 => 'rolling back',
                     8 => 'waiting for confirmation');
        if (exists($state{$value})) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'ota_update_state', $state{$value}, 1)
                if ReadingsVal($name, 'ota_update_state', '') ne $state{$value};
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update', $state{$value}, 1)
                if defined($hash->{helper}{firmware_update_in_flight}) && $value >= 2;
        }
    }
    if (($hash->{endpoint_id} // 0) == 0 && $cluster_id == 40 &&
        $attr_id == 9 && defined($value) && !ref($value) &&
        $value =~ /^\d+$/ && defined($hash->{helper}{firmware_update_in_flight})) {
        my $expected = $hash->{helper}{firmware_update_in_flight};
        if (defined($expected) && $expected eq $value) {
            delete $hash->{helper}{firmware_update_in_flight};
            # Keep correlation, but a later server reply must not overwrite
            # the physical confirmation for this installation.
            delete $hash->{helper}{latest_request}{firmware_update};
            MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update', 'installed', 1);
        }
    }

    if (($hash->{endpoint_id} // 0) == 0 &&
        $cluster_id == 42 && $attr_id == 3 &&
        defined($value) && !ref($value) &&
        $value =~ /^\d+$/ && $value <= 100 &&
        defined($hash->{helper}{firmware_update_in_flight})) {
        my $state = ReadingsVal($name, 'ota_update_state', '');
        MATTERDevice_ReadingsSingleUpdate($hash, 'firmware_update',
                             "$state $value%", 1)
            if $state eq 'downloading' || $state eq 'installing';
    }

    # ICD capability comes from endpoint-zero metadata, not a get_icd_state
    # probe during discovery. Do not conflate a sleeping ICD with offline.
    # Process shared global attributes once, then derive ICD properties from
    # the same authoritative feature-map cache rather than maintaining two.
    MATTERDevice_RootCapabilityReport($hash, $cluster_id, $attr_id, $value)
        if ($cluster_id == 70 || $cluster_id == 40 ||
            ($cluster_id == 29 && $attr_id == 1));

    # Descriptor cluster (0x001D), DeviceTypeList (0x0000).
    # Matter.js supplies an array of DeviceTypeStruct objects (deviceType, revision).
    # Persist the advertised IDs as a canonical reading. Unlike helper data,
    # regular FHEM readings survive a restart through the statefile/configDB.
    if ($cluster_id == 0x001D && $attr_id == 0x0000) {
        if (ReadingsVal($name, 'device_type_ids', '') ne $value) {
            MATTERDevice_ReadingsSingleUpdate($hash, 'device_type_ids', $value, 1);
            MATTERDevice_EnsureTypeGroup($hash);
        }
        return;
    }
    if (($hash->{endpoint_id} // 0) == 0 &&
        $cluster_id == 0x0033 && $attr_id == 0) {
        my $type = $value;
        MATTERDevice_ReadingsSingleUpdate($hash, 'networkType', $type, 1)
            if defined($type) && ReadingsVal($name, 'networkType', '') ne $type;
        return;
    }
    if ($cluster_id == 0x0035 || $cluster_id == 0x0036) {
        MATTERDevice_UpdateNetworkDiagnostics($hash, $value);
        return;
    }
    my $attr_info = $cluster ? $cluster->{attributes}{$attr_id} : undef;
    unless ($attr_info) {
        MATTERDevice_RawDiagnostic($hash, $cluster_id, $attr_id, $value);
        return;
    }

    my $attr_name = $attr_info->{name};
    my $is_reading = $attr_info->{is_reading} // 0;
    if ($cluster_id == 0x0045 && $attr_id == 0) {
        my $active = MATTERDevice_NormalizeBoolean($value);
        return unless defined $active;
        my %types = map { $_ => 1 } MATTERDevice_DeviceTypeIds($hash);
        if ($types{0x0015}) {
            ($attr_name, $value) = ('contact', $active ? 'closed' : 'open');
        } elsif ($types{0x0043}) {
            ($attr_name, $value) = ('water_leak', $active ? 'leak' : 'dry');
        } elsif ($types{0x0044}) {
            ($attr_name, $value) = ('rain', $active ? 'rain' : 'dry');
        } else {
            ($attr_name, $value) = ('boolean_state', $active);
        }
        $is_reading = 1;
    }
    my $model_changed = $cluster_id == 0x0028 && $attr_id == 3 &&
        ($hash->{endpoint_id} // 0) == 0 && (!defined($hash->{READINGS}{model}{VAL}) ||
        $hash->{READINGS}{model}{VAL} ne $value);
    readingsBeginUpdate($hash);

    # Spezieller Fall: OnOff State mappen
    if ($cluster_id == 6 && $attr_id == 0 && ($hash->{endpoint_id} // 0) > 0) {
        my $state_val = $value ? "on" : "off";
        readingsBulkUpdate($hash, "state", $state_val);
    }
    # Alle anderen Werte direkt als Reading speichern
    elsif (defined($attr_name)) {
        if ($is_reading) {
            readingsBulkUpdate($hash, $attr_name, $value);
            # FHEM's native state also represents standard binary sensor
            # endpoints. This is device telemetry, never a command echo.
            if (($hash->{endpoint_id} // 0) > 0 &&
                $attr_name =~ /^(?:contact|water_leak|rain|motion)$/) {
                readingsBulkUpdate($hash, 'state', $value);
            }
        }
        if ($cluster_id == 0x0008 && ($attr_id == 0 || $attr_id == 3)) {
            my $pct = MATTERDevice_Percentage($hash);
            readingsBulkUpdate($hash, 'pct', $pct) if defined $pct;
        }
    }


    MATTERDevice_ReadingsEndUpdate($hash, 1);
    # Model on endpoint 0 identifies the physical node, not a single function.
    MATTERDevice_SyncNodeReadings($hash) if $model_changed;
}

# Mirror fhem.pl Dispatch's receive internals. The context belongs to one
# incoming server message, including any root-to-endpoint forwarding.
# This records server reception, not proof of physical device contact.
sub MATTERDevice_RecordReceive {
    my ($hash, $received, $attributes) = @_;
    return unless $hash;
    my @targets = ($hash);
    # Stamp existing targets before any snapshot reading event (including
    # root model/availability mirrored to children) can reenter the module.
    if (ref($attributes) eq 'HASH') {
        my %endpoints;
        for my $path (keys %$attributes) {
            $endpoints{0 + $1} = 1 if $path =~ m{^(\d+)/\d+/\d+$};
        }
        push @targets, grep { $endpoints{$_->{endpoint_id}} }
            MATTERDevice_NodeChildren($hash);
    }
    for my $target (@targets) {
        next unless $target->{IODev};
        next if $received->{endpoints} && ($target->{endpoint_id} // 0) > 0 &&
                !$received->{endpoints}{$target->{endpoint_id}};
        next if $received->{devices}{$target}++;
        my $io_name = $target->{IODev}{NAME};
        $received->{time} //= TimeNow();
        ++$target->{MSGCNT};
        ++$target->{"${io_name}_MSGCNT"};
        $target->{"${io_name}_TIME"} = $received->{time};
        $target->{LASTInputDev} = $io_name;
    }
}

sub MATTERDevice_Parse($ $;$) {
    my ($hash, $data, $received) = @_;
    my $decoded = eval { decode_json($data) };
    if ($@ || ref($decoded) ne 'HASH') {
        Log3 $hash->{NAME}, 3, "MATTERDevice: Invalid JSON object";
        return;
    }
    return MATTERDevice_ProcessMessage($hash, $decoded, $received);
}

sub MATTERDevice_ProcessMessage {
    my ($hash, $decoded, $received) = @_;
    $received //= {};
    my $name = $hash->{NAME};

    my $my_endpoint = $hash->{endpoint_id} // 0;
    my $root = $my_endpoint == 0 ? $hash :
        MATTERDevice_LookupRoot($hash->{IODev}, $hash->{node_id});
    # The root owns availability for every child; an endpoint's local state
    # or old available reading is not a separate reachability report.
    my $allow_device_attr = sub {
        return 0 unless $root && $root->{helper}{available};
        return 1;
    };

    # Availability is node-wide; missing/invalid values are not state reports.
    my $update_available = sub { MATTERDevice_UpdateAvailability($hash, $_[0]) };
    
    # Hilfs-Subroutine zur internen Weiterleitung an Root oder Child
    my $route_attribute = sub {
        my ($ep, $cluster, $attr, $val) = @_;
        return if $received->{request} &&
            !MATTERDevice_RequestOwner(@{$received->{request}});
        MATTERDevice_RecordReceive($hash, $received) if $ep == $my_endpoint;
        # Offline snapshots can still tell us which endpoint IDs exist.
        # Preserve FHEM identity/association without importing device data.
        if (!$allow_device_attr->()) {
            if ($my_endpoint == 0 && $ep > 0) {
                my $child = MATTERDevice_GetOrCreateChild($hash, $ep);
                MATTERDevice_RecordReceive($child, $received);
            } elsif ($my_endpoint == 0 && $ep == 0 &&
                     $cluster == 0x001D && $attr == 3 &&
                     ref($val) eq 'ARRAY') {
                MATTERDevice_GetOrCreateChild($hash, $_)
                    for grep { defined($_) && !ref($_) && /^\d+$/ && $_ > 0 } @$val;
            }
            return;
        }
        if ($ep == $my_endpoint) {
            # Spezialbehandlung für PartsList (Cluster 0x001D / 29, Attribut 0x0003 / 3)
            if ($cluster == 0x001D && $attr == 0x0003 && ref($val) eq 'ARRAY') {
                Log3 $name, 3, "MATTERDevice: Found PartsList on node $hash->{node_id}, endpoints: " . join(", ", @{$val});
                foreach my $child_ep (@{$val}) {
                    next unless defined($child_ep) && !ref($child_ep) && $child_ep =~ /^\d+$/;
                    # Only root endpoints may create sibling endpoints.
                    if ($my_endpoint == 0 && $child_ep != $my_endpoint) {
                        MATTERDevice_GetOrCreateChild($hash, $child_ep);
                    }
                }
            }
            MATTERDevice_ProcessAttributeValue($hash, $cluster, $attr, $val);
        } else {
            return unless $my_endpoint == 0;
            my $childHash = MATTERDevice_GetOrCreateChild($hash, $ep);
            if ($childHash) {
                MATTERDevice_RecordReceive($childHash, $received);
                MATTERDevice_ProcessAttributeValue($childHash, $cluster, $attr, $val);
            }
        }
    };

    # 1. ANTWORT AUF GETCONFIG (enthält "result")
    if (exists $decoded->{result} && ref($decoded->{result}) eq 'HASH') {
        MATTERDevice_RecordReceive($hash, $received, $decoded->{result});
        # Never reset current capability metadata from a cached response
        # while the root is offline or current availability is unknown.
        if (!$allow_device_attr->()) {
            if ($my_endpoint == 0) {
                for my $path (keys %{$decoded->{result}}) {
                    if ($path =~ m{^([1-9]\d*)/\d+/\d+$}) {
                        my $child = MATTERDevice_GetOrCreateChild($hash, $1);
                        MATTERDevice_RecordReceive($child, $received);
                    }
                }
            }
            return;
        }
        # Missing paths can be individual read failures. Valid reports replace
        # metadata per path; only an explicit ServerList proves cluster removal.
        for my $path (sort {
            ($a =~ m{/29/1$} ? 2 : $a =~ m{/29/0$} ? 0 : 1) <=>
            ($b =~ m{/29/1$} ? 2 : $b =~ m{/29/0$} ? 0 : 1)
        } keys %{$decoded->{result}}) {
            my $value = $decoded->{result}->{$path};
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
        MATTERDevice_RecordReceive($hash, $received)
            if defined($node_id) && !ref($node_id) && $hash->{node_id} eq $node_id;
        if (defined($node_id) && $hash->{node_id} eq $node_id && exists($node->{available})) {
            $update_available->($node->{available});
            Log3 $name, 4, "MATTERDevice: Node $node_id availability = " . ($node->{available} ? "true" : "false");
        }
        MATTERDevice_MaybeRefreshCapabilities($hash) if $my_endpoint == 0;
        return;
    }

    # Switch events are not device state: one explicit event per occurrence,
    # including repeated values with event-on-change-reading.
    if (($decoded->{event} // '') eq 'node_event' &&
        ref($decoded->{data}) eq 'HASH') {
        return unless $my_endpoint == 0;
        my $event = $decoded->{data};
        return unless defined($event->{node_id}) && !ref($event->{node_id}) &&
                      "$event->{node_id}" eq "$hash->{node_id}";
        my ($ep, $cluster, $id) = @{$event}{qw(endpoint_id cluster_id event_id)};
        return unless defined($ep) && !ref($ep) && $ep =~ /^\d+$/ && $ep > 0 &&
                      defined($cluster) && !ref($cluster) && $cluster =~ /^\d+$/ &&
                      defined($id) && !ref($id) && $id =~ /^\d+$/;
        MATTERDevice_RecordReceive($hash, $received);
        # Unknown event endpoints cannot create devices. Discovery and the
        # Descriptor PartsList own endpoint identity, not transient events.
        my ($child) = grep {
            ($_->{endpoint_id} // 0) == $ep
        } MATTERDevice_NodeChildren($hash);
        return unless $child;
        MATTERDevice_RecordReceive($child, $received);
        return if MATTERDevice_IsDisabled($child);
        return unless $cluster == 0x003B;
        my %events = (1 => 'pressed', 2 => 'long',
                      3 => 'short', 4 => 'long_release');
        my $value = $events{$id};
        if ($id == 6) {
            my $count = ref($event->{data}) eq 'HASH'
                ? $event->{data}{totalNumberOfPressesCounted} : undef;
            return unless defined($count) && !ref($count) &&
                          $count =~ /^\d+$/ && $count >= 1 && $count <= 255;
            $value = $count == 1 ? 'short' :
                     $count == 2 ? 'double' :
                     $count == 3 ? 'triple' : $count . 'x';
        }
        return unless defined $value;
        MATTERDevice_ReadingsSingleUpdate($child, 'button', $value, 0);
        DoTrigger($child->{NAME}, "button: $value");
        return;
    }

    # 3. LIVE UPDATES (event == 'attribute_updated')
    if (exists $decoded->{event} && $decoded->{event} eq 'attribute_updated' && ref($decoded->{data}) eq 'ARRAY') {
        my ($node_id, $attribute_path, $value) = @{$decoded->{data}};
        return unless defined($node_id) && !ref($node_id) &&
            $hash->{node_id} eq $node_id;
        if (defined($attribute_path) && !ref($attribute_path) &&
            $attribute_path =~ m{^(\d+)/(\d+)/(\d+)$}) {
            MATTERDevice_RecordReceive($hash, $received);
            $route_attribute->($1, $2, $3, $value);
            Log3 $name, 4, "MATTERDevice: Live attribute update ($attribute_path)";
        }
        # Later device events may trigger a bounded retry if the initial
        # metadata read failed. Fresh reported values remain independent.
        MATTERDevice_MaybeRefreshCapabilities($hash) if $my_endpoint == 0;
        return;
    }

    # 4. INITIAL DISCOVER / START_LISTENING (node_id + attributes/availability)
    my $node_id    = $decoded->{node_id};
    my $attributes = $decoded->{attributes};
    
    if (defined($node_id) && $hash->{node_id} eq $node_id) {
        MATTERDevice_RecordReceive($hash, $received, $attributes);
        $update_available->($decoded->{available}) if exists($decoded->{available});

        if ($attributes && ref($attributes) eq 'HASH') {
            for my $path (sort {
                ($a =~ m{/29/1$} ? 2 : $a =~ m{/29/0$} ? 0 : 1) <=>
                ($b =~ m{/29/1$} ? 2 : $b =~ m{/29/0$} ? 0 : 1)
            } keys %{$attributes}) {
                my $value = $attributes->{$path};
                if ($path =~ m{^(\d+)/(\d+)/(\d+)$}) {
                    $route_attribute->($1, $2, $3, $value);
                }
            }
        }
        # The snapshot has been routed (or blocked offline); decide about a
        # targeted read only after observing available metadata and endpoints.
        MATTERDevice_MaybeRefreshCapabilities($hash) if $my_endpoint == 0;
    }
}

sub MATTERDevice_GetSetList($) {
    my ($hash) = @_;
    return () if MATTERDevice_IsDisabled($hash);
    return ('getConfig:noArg') if defined MATTERDevice_ControlError($hash);
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

    if (($hash->{endpoint_id} // 0) == 0 &&
        $hash->{IODev} && $hash->{IODev}{helper}{ota_api_supported} &&
        $hash->{helper}{seen_clusters}{42} &&
        !defined($hash->{helper}{firmware_update_in_flight})) {
        $add->("checkFirmwareUpdate:noArg");
        my $offer = $hash->{helper}{firmware_available};
        my $current = ReadingsVal($name, 'software_version', undef);
        $add->("updateFirmware:noArg") if defined($offer) &&
            (!defined($current) || $current !~ /\A[0-9]+\z/ || $offer > $current);
    }
    if (($hash->{endpoint_id} // 0) == 0 &&
        ReadingsVal($name, 'icd_supported', '') eq 'true') {
        my $io = $hash->{IODev};
        my $features = $hash->{helper}{capabilities}{70}{feature_map};
        if ($io && $io->{helper}{icd_api_supported} &&
            defined($features) && !ref($features) && $features =~ /^\d+$/ &&
            ($features & 1)) {
            $add->("icdRegister:noArg");
            $add->("icdUnregister:noArg");
            $add->("icdResync:noArg");
        }
    }
    $add->("identify:noArg")
        if MATTERDevice_CommandSupported($hash, 0x0003, 0x00);
    $add->("desired-temp:textField")
        if MATTERDevice_AttributeWritable($hash, 0x0201, 0x0012);
    $add->("desired-temp-cool:textField")
        if MATTERDevice_AttributeWritable($hash, 0x0201, 0x0011);
    my @modes = MATTERDevice_HvacModes($hash, 0x0201);
    $add->('mode:' . join(',', @modes)) if @modes;
    my @fan_modes = MATTERDevice_HvacModes($hash, 0x0202);
    $add->('fan_mode:' . join(',', @fan_modes)) if @fan_modes;
    $add->("fan_pct:slider,0,1,100")
        if MATTERDevice_AttributeWritable($hash, 0x0202, 0x0002);

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
        my $max_level = MATTERDevice_MaxBrightness($hash);
        $add->($max_level > 0 ? "brightness:slider,0,1,$max_level" : 'brightness:textField');
        $add->("pct:slider,0,1,100");
    }

    $add->("dim_up:noArg") if (
        MATTERDevice_CommandSupported($hash, 0x0008, 0x01) ||
        MATTERDevice_CommandSupported($hash, 0x0008, 0x05));
    $add->("dim_down:noArg") if (
        MATTERDevice_CommandSupported($hash, 0x0008, 0x01) ||
        MATTERDevice_CommandSupported($hash, 0x0008, 0x05));
    $add->("dim_stop:noArg") if (
        MATTERDevice_CommandSupported($hash, 0x0008, 0x03) ||
        MATTERDevice_CommandSupported($hash, 0x0008, 0x07));
    $add->("dim_step_up:noArg") if (
        MATTERDevice_CommandSupported($hash, 0x0008, 0x02) ||
        MATTERDevice_CommandSupported($hash, 0x0008, 0x06));
    $add->("dim_step_down:noArg") if (
        MATTERDevice_CommandSupported($hash, 0x0008, 0x02) ||
        MATTERDevice_CommandSupported($hash, 0x0008, 0x06));

    if (MATTERDevice_CommandSupported($hash, 0x0300, 0x0A)) {
        my $min = MATTERDevice_ReportedLimit($hash, 0x0300, 0x400B);
        my $max = MATTERDevice_ReportedLimit($hash, 0x0300, 0x400C);
        $add->(defined($min) && defined($max) && $min <= $max
            ? "ct:colorpicker,CT,$min,1,$max" : 'ct:textField');
    }

    if (MATTERDevice_CommandSupported($hash, 0x0008, 0x08)) {
        my $min = MATTERDevice_ReportedLimit($hash, 0x0008, 0x0005);
        my $max = MATTERDevice_ReportedLimit($hash, 0x0008, 0x0006);
        # Frequency zero means undefined, not a usable slider boundary.
        $add->(defined($min) && defined($max) && $min > 0 && $min <= $max
            ? "frequency:slider,$min,1,$max" : 'frequency:textField');
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

# Read canonical persisted Matter Descriptor IDs instead of transient helper data.
# Malformed or missing readings must never be interpreted as a valid device type.
sub MATTERDevice_DeviceTypeIds($) {
    my ($hash) = @_;
    my $ids = ReadingsVal($hash->{NAME}, 'device_type_ids', '');
    return () unless defined($ids)
        && $ids =~ /^0x[0-9A-Fa-f]{1,8}(?:,0x[0-9A-Fa-f]{1,8})*$/;
    return map { hex($_) } split(/,/, $ids);
}

# Root endpoints share one administrative FHEMWEB group; functional
# endpoints use their single non-utility Matter Descriptor device type.
# Replace only legacy node groups or uncustomized type groups.
sub MATTERDevice_EnsureTypeGroup($) {
    my ($device) = @_;
    return unless $device && defined($device->{NAME});
    my $name = $device->{NAME};
    my $node_id = $device->{node_id};
    my $io_name = $device->{IODev} ? $device->{IODev}{NAME} : AttrVal($name, 'IODev', '');
    return unless defined($node_id) && $node_id =~ /^\d+$/ && defined($io_name) && length($io_name);

    my $root = ($device->{endpoint_id} // 0) == 0;
    my $group;
    if ($root) {
        $group = 'Matter Nodes';
    } else {
        my @declared = MATTERDevice_DeviceTypeIds($device);
        my @types = grep { !$MATTER_STRUCTURAL_DEVICE_TYPES{$_} } @declared;
        # Never choose arbitrarily between multiple functional device types.
        return if @types > 1 || !@declared;
        $group = @types
            ? ($MATTER_DEVICE_TYPE_LABELS{$types[0]} // sprintf("0x%04X", $types[0]))
            : 'Matter Infrastruktur';
    }

    my $current = AttrVal($name, 'group', undef);
    return if defined($current) && $current eq $group;
    my $legacy = "Node $node_id ($io_name)";
    if (defined($current) && $current ne $legacy) {
        # Previously generated type labels can change when the Descriptor
        # changes. Other existing group values remain user-owned.
        my %type_labels = map { $_ => 1 } (values %MATTER_DEVICE_TYPE_LABELS, 'Matter Infrastruktur');
        return if $root || (!$type_labels{$current} && $current !~ /^0x[0-9A-F]{4,8}$/);
    }

    my $error = CommandAttr(undef, "$name group $group");
    Log3 $name, 3, "MATTERDevice: Cannot set type group for $name: $error" if $error;
}

# Resolve an existing root's children for both navigation and group migration.
sub MATTERDevice_NodeChildren($) {
    my ($root) = @_;
    return () unless $root && ($root->{TYPE} // '') eq 'MATTERDevice'
        && ($root->{endpoint_id} // 0) == 0;

    my $node_id = $root->{node_id};
    my $io_name = $root->{IODev} ? $root->{IODev}{NAME}
                                   : AttrVal($root->{NAME}, 'IODev', '');
    return () unless defined($node_id) && length($io_name // '');

    return sort {
        $a->{endpoint_id} <=> $b->{endpoint_id} || $a->{NAME} cmp $b->{NAME}
    } grep {
        ($_->{TYPE} // '') eq 'MATTERDevice'
            && ($_->{endpoint_id} // 0) > 0
            && ($_->{node_id} // '') eq $node_id
            && (($_->{IODev} && $_->{IODev}{NAME} eq $io_name)
                || (!$_->{IODev} && AttrVal($_->{NAME}, 'IODev', '') eq $io_name))
    } values %defs;
}

# Synchronize node-wide readings and the native FHEMWEB root association,
# using the same IODev/node membership as the endpoint link list. Newly
# created children can be updated individually. Missing or unchanged values
# must not create endpoint events.
sub MATTERDevice_SyncNodeReadings($;$) {
    my ($root, $only_child) = @_;
    return unless $root && ($root->{endpoint_id} // 0) == 0;
    my @children = $only_child ? ($only_child) : MATTERDevice_NodeChildren($root);

    foreach my $child (@children) {
        my @changes;
        foreach my $reading (qw(model available)) {
            next if MATTERDevice_IsDisabled($child);
            next if $reading eq 'model' &&
                !$root->{helper}{available};
            my $source = $root->{READINGS}{$reading};
            next unless ref($source) eq 'HASH';
            my $value = $source->{VAL};
            next unless defined($value) && !ref($value);
            my $previous = ReadingsVal($child->{NAME}, $reading, undef);
            next if defined($previous) && $previous eq $value;
            push @changes, [$reading, $value];
        }

        # FHEM's getPawList() uses the persistent associatedWith reading to
        # render "Probably associated with" links. Retain other user links.
        # FHEM CommandRename() updates these references when a root is renamed.
        my $links = ReadingsVal($child->{NAME}, 'associatedWith', '');
        my %linked = map { $_ => 1 } grep { length($_) } split(/[ ,]+/, $links);
        my $root_name = $root->{NAME};
        push @changes, ['associatedWith', length($links) ? "$links $root_name" : $root_name]
            unless $linked{$root_name};

        next unless @changes;
        readingsBeginUpdate($child);
        readingsBulkUpdate($child, $_->[0], $_->[1]) foreach @changes;
        MATTERDevice_ReadingsEndUpdate($child, 1);
    }
}

# Prefer the Descriptor's actual Matter device types. When unavailable, label
# only observed functions: an OnOff cluster alone cannot distinguish a plug
# from a switch or a light.
sub MATTERDevice_EndpointType($) {
    my ($hash) = @_;
    my @types = MATTERDevice_DeviceTypeIds($hash);
    if (@types) {
        my @specific = grep { !$MATTER_STRUCTURAL_DEVICE_TYPES{$_} } @types;
        @types = @specific if @specific;
        return join(", ", map {
            $MATTER_DEVICE_TYPE_LABELS{$_} // sprintf("0x%04X", $_)
        } @types);
    }

    my $clusters = $hash->{helper}{seen_clusters} // {};
    return "Temperature / humidity measurement"
        if $clusters->{0x0402} && $clusters->{0x0405};
    return "Temperature measurement" if $clusters->{0x0402};
    return "Humidity measurement" if $clusters->{0x0405};
    return "Smoke/CO alarm" if $clusters->{0x005C};
    return "Illuminance measurement" if $clusters->{0x0400};
    return "Occupancy sensing" if $clusters->{0x0406};
    return "Window covering" if $clusters->{0x0102};
    return "Door lock" if $clusters->{0x0101};
    return "Color control" if $clusters->{0x0300};
    return "Level control" if $clusters->{0x0008};
    return "On/Off" if $clusters->{0x0006};
    return "Power measurement" if $clusters->{0x0090};
    return "Unknown";
}

# Additional content for the existing root device (endpoint 0) in FHEMWEB.
sub MATTERDevice_FWDetail($) {
    my ($web, $name, $room) = @_;
    my @children = MATTERDevice_NodeChildren($defs{$name});
    return undef unless @children;

    # FHEMWEB themes style <th> prominently (e.g. large red bold text).
    # Use plain table cells for a quiet, compact heading row instead.
    my $html = '<div class="makeTable wide"><span class="mkTitle">Matter endpoints</span>'
             . '<table class="block wide"><tr><td>EP</td><td>Type</td><td>FHEM device</td></tr>';
    for my $child (@children) {
        my $endpoint = int($child->{endpoint_id});
        my $type = FW_htmlEscape(MATTERDevice_EndpointType($child));
        my $label = FW_htmlEscape($child->{NAME});
        my $target = '?detail=' . urlEncode($child->{NAME});
        $html .= qq(<tr><td>$endpoint</td><td>$type</td><td><a href="$target">$label</a></td></tr>);
    }
    return $html . '</table></div>';
}

sub MATTERDevice_GetOrCreateChild($$) {
    my ($root_hash, $ep_id) = @_;
    my $root_name = $root_hash->{NAME};
    my $node_id = $root_hash->{node_id};
    my $io_name = $root_hash->{IODev} ? $root_hash->{IODev}{NAME} : undef;
    return unless defined($ep_id) && !ref($ep_id) && $ep_id =~ /^\d+$/ && $ep_id != 0;
    unless ($io_name) {
        Log3 $root_name, 2, "MATTERDevice: Cannot resolve endpoint $ep_id without an IODev";
        return;
    }

    my $cache_key = "endpoint_$ep_id";
    my $child = $root_hash->{$cache_key};
    if ($child && (!$child->{NAME} || !$defs{$child->{NAME}} ||
                  $defs{$child->{NAME}} ne $child ||
                  ($child->{node_id} // '') ne $node_id ||
                  ($child->{endpoint_id} // -1) != $ep_id ||
                  !$child->{IODev} || $child->{IODev}{NAME} ne $io_name)) {
        delete $root_hash->{$cache_key};
        $child = undef;
    }

    if ($child) {
        $child->{device} = $root_name if ($child->{device} // '') ne $root_name;
        return $child;
    }
    foreach my $device (values %defs) {
        next unless ($device->{TYPE} // '') eq 'MATTERDevice';
        next unless ($device->{node_id} // '') eq $node_id;
        next unless ($device->{endpoint_id} // -1) == $ep_id;
        # Rebind an endpoint with a missing runtime IODev only to its
        # explicitly configured MATTER IO; names are not identities.
        if ($device->{IODev}) {
            next unless $device->{IODev}{NAME} eq $io_name;
        } else {
            next unless AttrVal($device->{NAME}, 'IODev', '') eq $io_name;
        }
        $child = $device;
        last;
    }

    unless ($child) {
        # Allow updates to existing endpoints, but do not define new ones while
        # the owning MATTER IO has autocreate disabled.
        return unless AttrVal($io_name, 'autocreate', 1);
        my $child_name = $root_name . "_EP" . $ep_id;
        if ($defs{$child_name}) {
            $child_name .= "_" . $node_id;
            my $base = $child_name;
            my $suffix = 2;
            while ($defs{$child_name}) {
                $child_name = $base . "_" . $suffix++;
            }
        }

        my $error = CommandDefine(undef, "$child_name MATTERDevice $node_id $ep_id");
        $child = $defs{$child_name};
        if ($error || !$child || ($child->{TYPE} // '') ne 'MATTERDevice' ||
            ($child->{node_id} // '') ne $node_id || ($child->{endpoint_id} // -1) != $ep_id) {
            Log3 $root_name, 2, "MATTERDevice: Cannot create endpoint $ep_id: " .
                ($error // 'invalid child definition');
            return;
        }

        my $io_error = CommandAttr(undef, "$child_name IODev $io_name");
        if ($io_error || !$child->{IODev} || $child->{IODev}{NAME} ne $io_name) {
            Log3 $root_name, 2, "MATTERDevice: IODev assignment failed for $child_name: " .
                ($io_error // 'wrong IODev after assignment');
            CommandDelete(undef, $child_name);
            return;
        }
        my $room_error = CommandAttr(undef, "$child_name room Matter");
        Log3 $root_name, 3, "MATTERDevice: Cannot set default room on $child_name: $room_error" if $room_error;
        Log3 $root_name, 3, "MATTERDevice: Created endpoint $ep_id as $child_name";
    }

    # An endpoint restored without a runtime IODev must be rebound through FHEM.
    unless ($child->{IODev}) {
        my $error = CommandAttr(undef, "$child->{NAME} IODev $io_name");
        if ($error || !$child->{IODev} || $child->{IODev}{NAME} ne $io_name) {
            Log3 $root_name, 2, "MATTERDevice: Cannot restore IODev of $child->{NAME}: " .
                ($error // 'wrong IODev after assignment');
            return;
        }
    }

    # User-assigned names and attributes are retained for existing endpoint devices.
    $child->{device} = $root_name;
    $root_hash->{$cache_key} = $child;
    MATTERDevice_EnsureTypeGroup($child);
    MATTERDevice_SyncNodeReadings($root_hash, $child);
    return $child;
}

1;

=pod
=item device
=item summary    Matter node or endpoint controlled through a MATTER IO device
=item summary_DE Matter-Knoten oder Endpunkt über ein MATTER-IO-Device

=begin html

<a id="MATTERDevice" name="MATTERDevice"></a>
<h3>MATTERDevice</h3>
<p>A MATTERDevice represents a Matter node (root endpoint 0) or one of its
additional endpoints. It uses the assigned MATTER IO device to receive attribute
updates and send supported commands. The module preserves existing FHEM names,
rooms and attributes during node synchronization. Device set commands
require an active IO WebSocket; a send failure is reported as an error. It does not override FHEM's
initial STATE, allowing the normal statefile restoration at startup.</p>
<ul>
  <li><b>Define:</b>
      <code>define &lt;name&gt; MATTERDevice &lt;node_id&gt; [endpoint_id]</code>.
      The endpoint's IODev attribute identifies the Matter server; the root
      name is not part of the DEF. On first load, legacy definitions with a
      root name are normalized automatically; save the FHEM configuration once
      after restarting to persist the shorter DEF.</li>
  <li><b>Set:</b> Depending on the reported capabilities:
      <code>on</code>, <code>off</code>, <code>brightness</code>, <code>ct</code>,
      <code>rgb</code>, <code>getConfig</code> and supported device-specific commands.</li>
  <li><b>Attributes:</b> <code>IODev</code>, endpoint <code>readOnly</code> / <code>disable</code>, opt-in
      <code>diagnostics</code> / <code>rawReadings</code>, dimming
      <code>dimRate</code>. Physical limits are reported readings.
      Retired <code>has_*</code> settings are ignored; they are neither
      generated nor automatically removed from stored FHEM configurations.
      Remove saved legacy flags manually before restarting with this version:
      FHEM may reject undeclared attribute lines when restoring a configuration.</li>
  <li><b>Offline attribute protection:</b> Device attributes and
<code>getConfig</code> require valid current-session <code>available=true</code>.
While offline or availability is unknown, preserve saved values and local
corrections; identity, endpoints and administrative status still synchronize.
IO loss, node removal and <code>INITIALIZED</code>/<code>REREADCFG</code>
invalidate runtime availability before disconnect events are published.
The saved <code>available</code> reading remains the last server report,
not permission to import data.
<p>A valid online report resumes normal snapshot and live-attribute processing,
including the attributes carried by that same <code>node_updated</code>.
No separate per-attribute report is required. Explicit <code>getConfig</code>
replies may update physical values and capability metadata while online.
Responses from earlier availability epochs or replaced roots are rejected. Explicit reads additionally verify the requesting FHEM instance and endpoint; a replacement cannot inherit its response, while rename remains supported.
Freshness tracking uses the same side-effect-free value conversion as reading publication; rejected values never suppress valid pending results.
Newer values from <code>attribute_updated</code> and <code>node_updated</code> take precedence per attribute path over older discovery/read results.</p>
<p>After a known offline/online transition, only missing command metadata may
trigger automatic recovery: at most three event-driven attempts, at least
15 seconds apart, without polling. These automatic requests apply only global
Matter metadata; a normal explicit <code>getConfig</code> is not restricted to
metadata. FHEM trusts the server's online data model; it does not establish an
independent freshness guarantee for every reported attribute.
Process restart/configDB integration is <strong>untested</strong>. The display
integration suite executes actual save/rereadcfg statefile loading; the
existing sensor lifecycle suite models restoration.</p></li>
  <li><b>Root state:</b> Without a <code>stateFormat</code> attribute, the root's
      <code>state</code> reading shows <code>online</code> or <code>offline</code>
      only after valid <code>available=true/false</code> from the server,
      <code>unknown</code> when no current report is known or the Matter IO loses
      its connection, and <code>removed</code> when the server removes the node
      or omits it from a complete snapshot. Root status is independent of
      endpoint states. No polling is used.</li>
  <li><b>Receive internals:</b> <code>&lt;IODev&gt;_TIME</code> records the last
      received server message as <code>YYYY-MM-DD HH:MM:SS</code> in FHEM local
      time; <code>LASTInputDev</code> identifies the IO. <code>MSGCNT</code>
      and <code>&lt;IODev&gt;_MSGCNT</code> count messages in the current runtime.
      Each message counts once for its root and once for each addressed
      endpoint, irrespective of attribute count or value changes. Availability
      mirroring alone does not count for children. Cached/blocked snapshots
      and correlated replies (including errors) count as server reception,
      not proof of recent physical device contact. These internals generate no
      additional reading events and are not restored after a FHEM restart.</li>
  <li><b>Legacy display migration:</b> On <code>INITIALIZED</code> or
      <code>REREADCFG</code>, the old autogenerated exact attribute
      <code>stateFormat available</code> is removed if the root has no
      new-style state reading yet. Other user-defined formats are retained.
      An identical, manually configured old value cannot be distinguished from
      that previous default; save the FHEM configuration after migration.</li>
  <li><b>Reading matter_status:</b> <code>present</code> means the node exists on
      the Matter server; <code>removed</code> means it was decommissioned or is
      missing from a complete server snapshot. Neither value is a reachability
      or availability indication.</li>
  <li><b>Reading device_type_ids:</b> The validated IDs from Matter
      <code>Descriptor.DeviceTypeList</code> are stored as comma-separated
      hexadecimal IDs (for example <code>0x010A</code>). FHEM restores this
      reading after a restart, so endpoint type labels and automatic grouping
      do not depend on a new server connection. Invalid or missing Descriptor
      updates do not overwrite known IDs.</li>
  <li><b>Readings model and available:</b> The root's <code>model</code> (from
      BasicInformation) and node-wide <code>available</code> are mirrored to
      its endpoints if reported. <code>available=true/false</code> describes
      node reachability, not individual endpoint functionality. Unchanged
      values do not generate repeated endpoint events.</li>
  <li><b>Reading associatedWith:</b> Endpoints reference their current root
      through FHEM's native <code>Probably associated with</code> navigation.
      User-added associations are preserved. FHEM updates the reference when
      the root device is renamed; no additional HTML navigation is needed.</li>
  <li>Set commands marked <code>noArg</code> reject additional arguments before sending.</li>
  <li><b>Capabilities:</b> Set commands require a matching endpoint
      <code>AcceptedCommandList</code> entry and applicable
      <code>FeatureMap</code> constraints. The module records the reported <code>ClusterRevision</code> as metadata.
      A malformed ID list preserves its last valid entries. An explicit empty list clears them. Missing paths in a partial getConfig reply retain metadata; a valid endpoint Descriptor.ServerList revokes absent clusters and is included in getConfig.
      Until command metadata arrives, controls are not inferred from values,
      cluster presence or retired <code>has_*</code> settings. A saved
      <code>has_*=0</code> no longer disables a reported command.</li>
  <li><b>New readings:</b> PowerSource, SmokeCO alarm, CO concentration, electrical
      power and cumulative energy clusters, where the server supplies the
      corresponding attributes.</li>
</ul>
<p>Changing the actual IO instance or Matter IDs invalidates old capabilities, firmware offers and control-relevant metadata (device types, ICD permissions, software/specification versions and limits). Other saved physical readings and local attributes remain. Rename and unchanged DEF confirmation preserve identity; an occupied root target is rejected before modification.</p>
<h4>Attributes</h4>
<p>Select an attribute in FHEMWEB to show its description. Active device
settings are <code>IODev</code>, <code>readOnly</code>, <code>disable</code>, <code>dimRate</code>, <code>diagnostics</code>
and <code>rawReadings</code>. Device limits are readings, not configurable
attributes. Remove saved limit attributes before restarting into V0.21,
as described below.</p>
<ul>
  <li><a id="MATTERDevice-attr-IODev"></a><b>IODev:</b> Name of the
      <code>MATTER</code> IO device providing the server connection for this
      node/endpoint. Autocreated devices receive the discovering IO; manually
      defined roots use FHEM's IO assignment when no IO is specified.
      With multiple servers, select the correct IO explicitly: node IDs are
      specific to their server. Moving a root to another IO resets its state to
      unknown until that server reports availability. An occupied target ID
      is rejected. Each endpoint retains its own IODev assignment.</li>
  <li><a id="MATTERDevice-attr-disable"></a><b>disable (0/1):</b>
      Default <code>0</code>, endpoints greater than 0 only. With <code>1</code>,
      block endpoint commands including getConfig, values, capability updates,
      mirrored status and button events. Existing readings and timestamps stay
      unchanged; no artificial disabled/off state is written. Identity and root
      association remain intact; receive internals still record server traffic.
      Pending endpoint requests are discarded locally; shared replies exclude
      this endpoint, including after re-enabling. Commands already sent cannot
      be recalled. Setting <code>0</code> or deleting the attribute resumes
      processing and reads getConfig once if the IO is connected and the root
      is online. Otherwise normal online synchronization resumes later, without
      polling or command replay. Repeated settings add no queries. Roots reject
      the attribute; siblings, the server and other controllers remain active.
      readOnly is independent and remains set. Hardware validation:
      <strong>untested</strong>.</li>
  <li><a id="MATTERDevice-attr-readOnly"></a><b>readOnly (0/1):</b>
      Default <code>0</code>. On endpoints greater than 0, <code>1</code>
      blocks all control commands and attribute writes from FHEM, including
      Identify and Stop. Only <code>getConfig</code> remains in the set list;
      direct control calls return an error, including calls from automations.
      Readings, events, receive internals and capability reads continue normally.
      Commands already sent retain their normal response handling and cannot
      be recalled. If enabled between components of a compound command, only
      the unsent remainder is blocked. Setting <code>0</code> or deleting the
      attribute restores controls without additional reads or command replay.
      The attribute is rejected on root nodes; it does not propagate to other
      endpoints. It does not block root administration, other controllers,
      direct server access or physical buttons and cannot guarantee that an
      actuator stays on. Hardware validation: <strong>untested</strong>.</li>
  <li><a id="MATTERDevice-attr-dimRate"></a><b>dimRate:</b> Integer
      <code>1</code>–<code>254</code>, default <code>30</code>. Native
      LevelControl move rate in level units per second for the next
      <code>dim_up</code> / <code>dim_down</code> command on this endpoint.
      Does not change the fixed step size of <code>dim_step_up/down</code>
      or add a FHEM timer. Native dimming hardware validation:
      <strong>untested</strong>.</li>
  <li><a id="MATTERDevice-attr-diagnostics"></a><b>diagnostics (0/1):</b>
      Default <code>0</code>. Set <code>1</code> on the root (endpoint 0)
      to process incoming Thread/Wi-Fi diagnostic reports, such as
      role, channel, neighbors and RSSI. Has no effect on child endpoints.
      Adds no polling or extra reads. Setting <code>0</code> or removing
      the attribute stops updates without deleting existing readings.
      Hardware validation: <strong>untested</strong>.</li>
  <li><a id="MATTERDevice-attr-rawReadings"></a><b>rawReadings (0/1):</b>
      Default <code>0</code>. Set <code>1</code> on the receiving root or
      endpoint to expose otherwise unmapped attributes as
      <code>raw_&lt;endpoint&gt;_&lt;cluster&gt;_&lt;attribute&gt;</code> readings.
      Null values, attribute IDs from 0xFFF0 upwards and clusters
      31, 48, 49, 60, 62, 63, 64 and 65 (decimal) are skipped.
      The limit per value is 512 characters for scalar text or 512 bytes
      for JSON-encoded structures. Other clusters, including vendor-specific
      ones, can expose private device data in readings and logs.
      Adds no polling; disabling retains existing readings. Hardware
      validation: <strong>untested</strong>.</li>
</ul>
<h4>Default endpoint display (hardware untested)</h4>
<p>Endpoints greater than 0 derive their <code>STATE</code> display from
persisted <code>device_type_ids</code> and their own existing readings. No
<code>stateFormat</code> attribute or redundant <code>state</code> reading is
created. An explicit <code>stateFormat</code> always wins; deleting it restores
the default. The default is recomputed after statefile restoration and on
module reading updates. Missing data is <code>unknown</code>, valid zero is
retained, and invalid reports preserve the last valid values. Offline/disable
retain existing values; root reachability remains separate. No polling or
extra Matter requests are used.</p>
<ul>
<li>Lights/plugs, contacts, motion, leaks and rain retain their physical
<code>state</code>. A plug's electrical readings do not replace its on/off display.</li>
<li>Temperature/humidity/pressure/illuminance use their existing readings and
units; a combined temperature/humidity endpoint shows both, for example
<code>22.34 °C / 48 %</code>, with <code>unknown</code> for missing components.</li>
<li>Door locks display <code>lock_state</code> as not_fully_locked, locked,
unlocked or unlatched, distinct from the door contact. Coverings show current
lift/tilt percentages in the reported Matter direction (0 open, 100 closed),
then raw absolute positions explicitly labelled raw if necessary, otherwise
reported stopped/opening/closing status. Targets are not current positions.</li>
<li>Thermostats show reported mode, measured temperature and the heating/cooling
setpoints appropriate to that mode; auto shows both. Fans show reported
fan_mode and actual fan_pct, never the requested percent as an actual value.</li>
<li>Smoke/CO alarms display the reported ExpressedState, including testing,
battery/fault/end-of-service and interconnect states. Air-quality sensors use
the reported qualitative value or CO2/PM2.5/TVOC readings with their reported
units; missing units remain unknown. No local alarm or air-quality evaluation
is inferred. Electrical sensors prefer power (W), then energy (kWh), voltage
(V) and current (A).</li>
<li>Switch/button endpoints show their own last event as <code>last: short</code>
etc.; repeats still emit separate button events. Controller types are not
assumed to be lamps. On/Off sensors use their own reported state or a neutral
boolean 0/1. Structural and unknown types retain an existing state or show
unknown; Flow Sensor 0x0306 currently has only a label and shows unknown.</li>
</ul>
<p>For multi-type endpoints priority is alarm, leak, rain, lock, covering,
thermostat, fan, lights/plugs, contact, occupancy, On/Off sensor, buttons,
air quality, electrical, temperature/humidity, pressure, illumination, flow.
Structural companions do not participate. Missing primary data never switches
to a lower-priority type. All new display classes remain <strong>hardware
untested</strong>; actual local FHEM/FHEMWEB tests use synthetic reports.</p>

<h4>Device-limit readings and upgrade from V0.20</h4>
<p>The following ordinary readings are populated from accepted device reports
or snapshots, independently for each endpoint. They survive normal FHEM
statefile/configDB restoration. No extra reads or polling are introduced.</p>
<table>
<tr><th>Readings</th><th>Source / unit</th></tr>
<tr><td><code>min_brightness</code>, <code>max_brightness</code></td><td>LevelControl MinLevel / MaxLevel, native level units.</td></tr>
<tr><td><code>min_frequency</code>, <code>max_frequency</code></td><td>LevelControl MinFrequency / MaxFrequency, unchanged Matter values. Zero means undefined.</td></tr>
<tr><td><code>color_temp_min</code>, <code>color_temp_max</code></td><td>ColorControl ColorTempPhysicalMinMireds / ColorTempPhysicalMaxMireds, mireds. Lower mireds mean higher Kelvin.</td></tr>
<tr><td><code>min_pin_code_length</code>, <code>max_pin_code_length</code></td><td>DoorLock MinPINCodeLength / MaxPINCodeLength, bytes. Informational; no PIN management is added.</td></tr>
<tr><td><code>min_rfid_code_length</code>, <code>max_rfid_code_length</code></td><td>DoorLock MinRFIDCodeLength / MaxRFIDCodeLength, bytes. Informational; no RFID management is added.</td></tr>
</table>
<p>Valid CT limits determine the colorpicker range. Valid positive frequency
limits determine the frequency slider range. Missing, undefined, reversed or
metadata-excluded boundaries leave the advertised command available with a
text field instead; no 153&ndash;500 or 50&ndash;60 device range is invented.
The Lighting feature uses the standardized level maximum 254. Other
LevelControl endpoints use a usable reported <code>max_brightness</code>,
otherwise the protocol fallback 254. The same maximum is used by the
brightness slider, command validation, percentage and RGB scaling.
A reported generic maximum of zero is retained; it permits no positive
brightness and cannot produce a derived percentage.
While offline or availability is unknown, reports cannot update limits or
derived percentages. Once online, accepted level, limit and metadata updates
may recalculate percentage from the reported brightness. Command availability still requires advertised Matter commands/features.</p>
<p><b>Transition:</b> These ten attribute names are removed from
<code>AttrList</code> in V0.21; there is no compatibility or automatic migration.
Review automation using <code>AttrVal</code> and save any old settings needed
for reference. Old overrides no longer affect controls or scaling. Before
restarting into V0.21, remove these attributes and save the configuration;
otherwise FHEM may reject saved attribute lines during startup. Execute each
line separately in the <b>FHEM command line</b>:</p>
<pre>deleteattr TYPE=MATTERDevice (color_temp_(min|max)|(min|max)_(brightness|frequency|pin_code_length|rfid_code_length))
save</pre>
<p>The command removes only these ten attributes from MATTERDevice devices,
not their readings. No values are automatically copied or deleted by the
module. Readings appear only when corresponding data is received. Invalid/null
reports preserve the last valid reading; offline protection also
applies to limits. Restored readings are cached information, not proof of
current reachability. Device-class hardware status remains
<strong>untested</strong>.</p>
<p>The energy reading accepts the inner EnergyMeasurementStruct field (named or TLV tag 0) only as an integer from 0 to 2^62 mWh, converted to kWh. Invalid/null data preserves the last reading; numeric zero remains valid.</p>
<h4>Hardware validation status</h4>
<p>The following classes are implemented but have no class-wide hardware validation
recorded in this repository. <strong>untested</strong> refers to missing documented
physical-device verification, not missing source or automated tests. Even testing
one model cannot establish support for all models sharing the cluster.</p>
<table><tr><th>Device class</th><th>Matter cluster</th><th>Hardware status</th></tr>
<tr><td>OnOff lights / on-off plugs</td><td>OnOff, LevelControl</td><td><strong>untested</strong></td></tr>
<tr><td>Color / color-temperature lights</td><td>ColorControl</td><td><strong>untested</strong></td></tr>
<tr><td>Window coverings / blinds</td><td>WindowCovering. Physical lift and tilt limits: <code>physical_closed_limit_lift</code>, <code>physical_closed_limit_tilt</code></td><td><strong>untested</strong></td></tr>
<tr><td>Thermostats / fans / Identify</td><td>Thermostat, FanControl, Identify</td><td><strong>untested</strong></td></tr>
<tr><td>Contact / water leak / rain sensors</td><td>BooleanState</td><td><strong>untested</strong></td></tr>
<tr><td>Temperature / humidity / pressure / illumination</td><td>TemperatureMeasurement, RelativeHumidityMeasurement, PressureMeasurement, IlluminanceMeasurement</td><td><strong>untested</strong></td></tr>
<tr><td>Occupancy and Matter buttons</td><td>OccupancySensing, Switch</td><td><strong>untested</strong></td></tr>
<tr><td>CO2 / PM2.5 / TVOC concentration</td><td>ConcentrationMeasurement family</td><td><strong>untested</strong></td></tr>
<tr><td>Thread / Wi-Fi diagnostics, ICD and OTA</td><td>ThreadNetworkDiagnostics, WiFiNetworkDiagnostics, IcdManagement, OTA Requestor</td><td><strong>untested</strong></td></tr>
<tr><td>Door locks</td><td>DoorLock</td><td><strong>untested</strong></td></tr>
<tr><td>Battery / power sources</td><td>PowerSource</td><td><strong>untested</strong></td></tr>
<tr><td>Smoke / carbon-monoxide alarms</td><td>SmokeCoAlarm</td><td><strong>untested</strong></td></tr>
<tr><td>Electrical metering</td><td>ElectricalPowerMeasurement, ElectricalEnergyMeasurement</td><td><strong>untested</strong></td></tr>
<tr><td>Air quality / CO concentration</td><td>AirQuality, CarbonMonoxideConcentrationMeasurement</td><td><strong>untested</strong></td></tr>
</table>
<p>Thermostat: <code>desired-temp</code> writes OccupiedHeatingSetpoint;
<code>desired-temp-cool</code> writes OccupiedCoolingSetpoint, in degrees Celsius
with at most two decimals. Each requires its advertised attribute and the
corresponding Heating/Cooling feature. Text inputs replace the arbitrary
5–30 °C slider; the device validates its own setpoint limits.</p>
<p><code>mode</code> choices follow Heating/Cooling/AutoMode and
ControlSequenceOfOperation. <code>fan_mode</code> follows FanModeSequence and
the Auto feature; the deprecated On mode is not offered. Mode controls require
AttributeList, FeatureMap and valid sequence metadata; missing metadata does
not get guessed from a current mode. Normal snapshots or the endpoint's explicit
<code>getConfig</code> supply this data, without extra probing. These are
standard-compatible choices, not a guarantee of optional enum support or ACL
permission. The server/device remains authoritative.</p>
<p><code>fan_pct</code> writes PercentSetting (0–100); readings
<code>fan_pct_setting</code> and <code>fan_pct</code> distinguish the target
from PercentCurrent. Only explicitly mapped writable standard attributes
authorize these setters. Identify (15 seconds) still requires its accepted
command. Correlated write status lists must match the requested path and report
Status 0; failures, malformed replies and path mismatches appear in
<code>lastError</code>. The existing null API acknowledgement is retained.
Neither acknowledgement updates physical setpoint/mode/speed readings;
device reports do. Thermostat, fan and Identify combinations are
<strong>untested</strong> on hardware.</p>
<p>Manual Matter OTA requires a root reporting the OTA Requestor
cluster (42) and a compatible current server connection (matterjs-server
schema 11+ or Python Matter Server schema 10+). The server decides whether
the request can proceed, including when FHEM shows the root as offline. <code>checkFirmwareUpdate</code>
asks that server for an offer. <code>none reported</code> means the server
returned none; a manufacturer app may have other updates. With an eligible
offer, <code>updateFirmware</code> requests the offered version once.
<code>update requested</code> acknowledges the request. The device's matching
SoftwareVersion confirms installation, even without progress reports.
After timeout or server disconnect, check again before installing.
The server handles image delivery. Hardware <strong>untested</strong>.</p>
<p>ICD Management: passive <code>icd_supported</code>,
<code>icd_lit_supported</code>, <code>icd_operating_mode</code> and
<code>icd_idle_mode_duration</code> readings. Positively recognized ICD
roots on compatible servers offer asynchronous <code>get icdState</code>,
plus conservative <code>icdRegister</code>, <code>icdUnregister</code> and
<code>icdResync</code> where Check-In support is advertised. These server
operations require the current connection's OHF matterjs-server identification
(<code>sdk_version=matter-server/... (matter.js/...)</code>) and schema 12 or
newer. Saved server readings alone do not enable them; other/unknown backends
retain passive ICD detection without these operations.</p>
<p>A valid root <code>Descriptor.ServerList</code> (<code>0/29/1</code>) without
cluster 70 revokes previously recognized ICD support and its commands.
An omitted list or malformed data cannot infer removal. Root
<code>getConfig</code> includes ServerList in its existing read. The list is
applied after other snapshot attributes, with newer live lists taking
precedence over older read/discovery replies. Historical mode/duration
readings are retained. Ordinary non-ICD roots receive no extra negative
ICD readings.</p>
<p>The server owns registration and availability; <code>awake=false</code>
is not offline. Controller-state readings are observations from the last
explicit query; their normal FHEM timestamps remain unchanged after reconnect.
Hardware validation: <strong>untested</strong>.</p>
<h4>Network type</h4>
<p>The root-only <code>networkType</code> reading uses the operational entries
in <code>GeneralDiagnostics.NetworkInterfaces</code> (path <code>0/51/0</code>).
Values are <code>wifi</code>, <code>thread</code>, <code>ethernet</code> or
<code>cellular</code>; multiple types are deduplicated and sorted, for example
<code>ethernet,wifi</code>. <code>unknown</code> means no operational interface,
an unspecified type or an unrecognized enum value in an otherwise usable
list. An unknown active type is retained alongside known types.</p>
<p>No attribute or extra request is required. Before the first usable list,
the reading is absent. Missing/null/malformed data preserves the earlier
reading. Only value changes write the reading; normal offline and snapshot
availability and response-ordering rules apply. Values persist through normal FHEM statefile handling
and may be cached. The reading describes reported operational interfaces,
not the route of a specific Matter session or device reachability. It stays
on endpoint 0: for a bridge it describes the bridge, never its bridged
devices' radio protocols. Commissioning feature flags alone do not create
this reading. Hardware status: <strong>untested</strong>.</p>
<p>Root <code>diagnostics=1</code> enables passive Thread/Wi-Fi diagnostics.
Device <code>rawReadings=1</code> exposes selected unmatched attributes,
which can include vendor-specific data. Both default to off, add no polling, retain existing readings
on disable, and are <strong>untested</strong> on hardware.</p>
<a name="MATTERDevice-diagnostic-readings"></a>
<h4>Diagnostic readings</h4>
<p>These readings are created only on the root (endpoint 0), with
<code>diagnostics=1</code> set on that root and suitable reported attributes.
They are not mirrored to child endpoints; setting <code>diagnostics</code>
on a child endpoint has no effect.</p>
<table>
<tr><th>Reading</th><th>Meaning / unit</th></tr>
<tr><td><code>thread_channel</code></td><td>Reported Thread radio channel.</td></tr>
<tr><td><code>thread_role</code></td><td>Reported routing role: <code>unspecified</code>, <code>unassigned</code>, <code>sleepy_end_device</code>, <code>end_device</code>, <code>reed</code>, <code>router</code> or <code>leader</code>.</td></tr>
<tr><td><code>thread_device_type</code></td><td>Derived from the role: <code>MTD</code> (Minimal Thread Device) for sleepy end devices; <code>MTD or FTD</code> for end devices; <code>FTD</code> (Full Thread Device) for REED, router and leader. This is not a separate device-type report.</td></tr>
<tr><td><code>thread_network</code></td><td>Reported Thread network name.</td></tr>
<tr><td><code>thread_neighbors</code></td><td>Number of entries in the reported neighbor table, including children. The displayed list can contain fewer entries.</td></tr>
<tr><td><code>thread_neighbor_list</code></td><td>Up to 16 neighbors with usable RSSI, strongest first, with extended address, child/router label and RSSI in dBm; at most 600 characters. <code>none</code> means no usable entries in that report. The module labels every non-child as <code>router</code>.</td></tr>
<tr><td><code>rssi</code></td><td>Strongest usable RSSI among neighbors not marked as children, in dBm. For each neighbor, average RSSI is preferred; last RSSI is used only if the average is absent/null. This does not identify the selected parent or the route used by a command.</td></tr>
<tr><td><code>lqi</code></td><td>Reported link quality of the same neighbor selected for <code>rssi</code>, if supplied as 0&ndash;3; higher values indicate better quality. It is not selected independently from the strongest RSSI.</td></tr>
<tr><td><code>wifi_rssi</code></td><td>Reported Wi-Fi RSSI in dBm, when Wi-Fi diagnostics are available.</td></tr>
</table>
<p>Enabling the attribute sends no request and does not replay previously
received data. Updates use subsequent accepted server reports or snapshots;
the device/server determines which attributes arrive and when. Normal offline
and availability protection also applies to diagnostic attributes.
Snapshots may contain cached values, so these readings do not prove fresh
physical-device contact. A reading is written only when its value changes;
its timestamp therefore records a value change, not every received report.
Missing or unusable values leave earlier readings unchanged, including old
RSSI/LQI when a new neighbor table has no eligible neighbor. Disabling
diagnostics preserves all existing readings.</p>
<h4>Shared command responses</h4>
<p>All device commands (including on/off, levels/colors, coverings, locks,
Identify and dimming) and attribute writes use the same request handling.
Each outgoing API request has its own message_id and device/IO ownership.
Pending commands and writes do not lock a following setter, including Stop.
All responses are correlated and retired, but only the latest setter changes
<code>lastError</code>. For a compound RGB setter, success requires both
level/color acknowledgements; success of one component never clears a failure
of the other. This ordering applies only to command diagnostics, not incoming
physical device reports.</p>
<p>A successful device command reply acknowledges the request regardless of
the value in its result field. Attribute writes validate the returned
path/status list; existing null API acknowledgements remain accepted.
<code>lastError=none</code> is not a physical state confirmation. Server
refusals and malformed results produce <code>failed: ...</code>. At the next
existing heartbeat after 120 seconds, an unanswered ordinary request reports
<code>timeout (outcome unknown)</code>; IO loss reports
<code>interrupted (outcome unknown)</code>. No replay, automatic Stop, polling,
readback or new timers. At most 1024 pending commands per IO are allowed;
excess requests return an explicit error. An immediate send failure is returned
to FHEM; an accepted compound setter can have partial delivery.</p>
<p>OTA/ICD use this same request lifecycle with their existing administrative
serialization, dedicated status readings and operation timeouts. Explicit
getConfig and capability reads retain their separate read reconciliation.
Asynchronous setters suppress FHEM's synthetic command event; physical readings
change only with device reports. Real-device/server integration of this shared
path is <strong>untested</strong>.</p>
<p>Native LevelControl dimming: <code>dim_up</code>, <code>dim_down</code>,
<code>dim_step_up</code>, <code>dim_step_down</code> and <code>dim_stop</code>
only when the corresponding commands are advertised. Optional per-device
<code>dimRate</code> (1–254, default 30) sets the speed for continuous dimming.
The commands take no arguments. Steps use 20 native level units with
transition time zero. Prefer the regular Move/Step/Stop command; use its
WithOnOff variant only when the regular variant is not advertised. WithOnOff
may also change on/off state. OptionsMask/Override are zero, leaving device
options in effect. These commands use the shared request handling described above.
No FHEM dimming loop. Physical device variants <strong>untested</strong>.</p>
<p>Additional environmental measurements: pressure (hPa), CO2, PM2.5 and TVOC
with separately reported measurement units. These classes are
<strong>untested</strong> on real devices.</p>
<p>Switch cluster (0x003B) emits button press/release events on the respective
endpoint; every press is a separate event. Hardware status:
<strong>untested</strong>.</p>
<p>Core sensor classes (contact, water leak, rain, temperature, humidity,
illuminance, occupancy) are implemented but <strong>untested</strong> on physical
hardware in this repository.</p>
<p>Actual hardware evidence must identify the model, firmware, endpoint, validated
readings and commands before a row can be narrowed or upgraded to tested.</p>
<p>Root nodes use the administrative FHEMWEB group <code>Matter Nodes</code>.
Functional endpoints are grouped by their single non-structural Matter
<code>Descriptor.DeviceTypeList</code> type (for example
<code>On/Off light</code>, <code>Electrical Sensor</code>, or
<code>Smoke CO Alarm</code>). Endpoints with only structural types (such as
Aggregator and Bridged Node) use <code>Matter Infrastruktur</code>.
Additional structural types such as Power Source and OTA Requestor are ignored
when a functional type is present. Unknown IDs use hexadecimal labels.
Multiple distinct functional types do not cause an arbitrary group choice.
Old generated <code>Node &lt;node_id&gt; (&lt;IODev&gt;)</code> groups are migrated;
custom groups are preserved. The root detail view links to its endpoints,
even after renaming.</p>
<p>Only newly autocreated nodes/endpoints are assigned to room <code>Matter</code>.
Decommissioned devices are retained in FHEM rather than automatically deleted.</p>

=end html

=begin html_DE

<a id="MATTERDevice" name="MATTERDevice"></a>
<h3>MATTERDevice</h3>
<p>Ein MATTERDevice repräsentiert einen Matter-Knoten (Root-Endpunkt 0) oder einen
seiner weiteren Endpunkte. Über das zugeordnete MATTER-IO-Device empfängt es
Attributänderungen und sendet unterstützte Befehle. Ein Set-Befehl setzt
eine aktive IO-WebSocket-Verbindung voraus; Sendefehler werden gemeldet.
Bei der Synchronisation bleiben bestehende Namen, Räume und Benutzerattribute erhalten. Der von FHEM
initial gesetzte STATE bleibt unverändert, damit das Statefile beim Neustart
den gespeicherten Anzeigestatus wiederherstellen kann.</p>
<ul>
  <li><b>Definition:</b>
      <code>define &lt;name&gt; MATTERDevice &lt;node_id&gt; [endpoint_id]</code>.
      Das IODev-Attribut bestimmt den Matter-Server; der Root-Name gehört nicht
      in die DEF. Bisherige dreiteilige Endpoint-Definitionen werden beim
      ersten Laden automatisch gekürzt. Anschließend die FHEM-Konfiguration
      einmal speichern, um die neue DEF dauerhaft zu übernehmen.</li>
  <li><b>Set:</b> Abhängig von den Fähigkeiten z. B. <code>on</code>,
      <code>off</code>, <code>brightness</code>, <code>ct</code>,
      <code>rgb</code>, <code>getConfig</code> und weitere Gerätebefehle.</li>
  <li><b>Attribute:</b> <code>IODev</code>, Endpunkt-<code>readOnly</code> / <code>disable</code>, optionale
      <code>diagnostics</code> / <code>rawReadings</code>,
      <code>dimRate</code>. Gerätegrenzwerte werden als Readings gemeldet.
      Alte <code>has_*</code>-Attribute werden ignoriert, nicht mehr erzeugt
      und nicht automatisch aus gespeicherten FHEM-Konfigurationen gelöscht.
      Vor dem Neustart mit dieser Version sollten gespeicherte Legacy-Attribute
      manuell entfernt werden, da FHEM unbekannte Attribute beim Laden der
      Konfiguration ablehnen kann.</li>
  <li><b>Offline-Attributsperre:</b> Geräteattribute und
<code>getConfig</code> erfordern ein gültiges aktuelles <code>available=true</code>.
Bei Offline-Status oder unbekannter Availability bleiben gespeicherte Werte
und lokale Korrekturen erhalten; Identität, Endpunkte und Verwaltungsstatus
werden weiter gepflegt. IO-Verlust, Node-Entfernung und
<code>INITIALIZED</code>/<code>REREADCFG</code> entwerten die interne Freigabe
vor Disconnect-Ereignissen. Das gespeicherte <code>available</code>-Reading
bleibt die letzte Servermeldung und gibt keine Geräteupdates frei.
<p>Eine gültige Online-Meldung erlaubt wieder reguläre Snapshots und Live-Attribute,
einschließlich der Werte derselben <code>node_updated</code>-Meldung. Ein
zusätzlicher Report pro Attribut ist nicht erforderlich. Explizites
<code>getConfig</code> darf online Gerätewerte und Capability-Metadaten aktualisieren.
Antworten aus früheren Availability-Zyklen oder für ersetzte Roots werden
verworfen. Explizite Reads prüfen zusätzlich die anfragende FHEM-Instanz und den Endpoint; Ersatzgeräte übernehmen deren Antworten nicht, Rename derselben Instanz bleibt unterstützt. Frischeabgleich und Reading-Übernahme verwenden dieselbe seiteneffektfreie Wertprüfung; verworfene Werte verdrängen keine gültigen ausstehenden Antworten. Neuere Werte aus <code>attribute_updated</code> und <code>node_updated</code> haben je Attributpfad Vorrang vor älteren Discovery-/Leseantworten.</p>
<p>Nach einem bekannten Offline-/Online-Wechsel kann ausschließlich fehlende
Befehlsmetadaten-Recovery automatisch ausgelöst werden: höchstens drei
ereignisgesteuerte Versuche mit mindestens 15 Sekunden Abstand, ohne Polling.
Diese automatischen Antworten übernehmen nur globale Matter-Metadaten;
ein normales explizites <code>getConfig</code> ist darauf nicht eingeschränkt.
FHEM übernimmt das Online-Datenmodell des Servers und behauptet keine eigene
Frischegarantie für jedes einzelne Attribut. Prozess-/configDB-Neustarts
sind <strong>ungetestet</strong>. Der Anzeige-Integrationstest führt echtes
save/rereadcfg mit Statefile aus; die bisherige Sensor-Lifecycle-Suite
modelliert die Wiederherstellung.</p></li>
  <li><b>Root-Status:</b> Ohne <code>stateFormat</code>-Attribut zeigt das
      <code>state</code>-Reading am Root <code>online</code> oder
      <code>offline</code> nur nach einer gültigen <code>available=true/false</code>-
      Meldung des Servers, <code>unknown</code> ohne bestätigte aktuelle Meldung
      oder bei Ausfall der Matter-IO-Verbindung und <code>removed</code> bei
      Entfernung aus dem Matter-Server oder einer vollständigen Node-Liste.
      Endpunkt-Zustände bleiben unverändert. Es erfolgt kein Polling.</li>
  <li><b>Empfangs-Internals:</b> <code>&lt;IODev&gt;_TIME</code> zeigt den letzten
      Empfang einer Servernachricht als <code>YYYY-MM-DD HH:MM:SS</code> in
      lokaler FHEM-Zeit; <code>LASTInputDev</code> nennt das IO.
      <code>MSGCNT</code> und <code>&lt;IODev&gt;_MSGCNT</code> zählen Nachrichten
      während der aktuellen Laufzeit. Jede Nachricht zählt einmal am Root
      und einmal pro konkret adressiertem Endpunkt, unabhängig von der Anzahl
      der Attribute oder Wertänderungen. Gespiegelte Availability zählt allein
      nicht als Endpoint-Empfang. Auch Cache-/gesperrte Snapshots und zugeordnete
      Antworten einschließlich Fehlern zählen als Serverempfang; sie beweisen
      keinen aktuellen Kontakt zum physischen Gerät. Die Internals erzeugen keine
      zusätzlichen Reading-Events und werden beim FHEM-Neustart nicht wiederhergestellt.</li>
  <li><b>Migration der alten Anzeige:</b> Nach <code>INITIALIZED</code> oder
      <code>REREADCFG</code> wird das bisher automatisch angelegte Attribut
      <code>stateFormat available</code> entfernt, sofern noch kein neuer
      Root-Status gespeichert ist. Andere benutzerdefinierte Formate bleiben
      erhalten. Ein absichtlich identisch gesetzter Altwert ist vom früheren
      Standard nicht unterscheidbar. Nach der Migration die Konfiguration speichern.</li>
  <li><b>Reading matter_status:</b> <code>present</code> bedeutet, dass der Knoten
      auf dem Matter-Server vorhanden ist; <code>removed</code> bedeutet, dass er
      dort entfernt wurde oder in einer vollständigen Node-Liste fehlt. Das Reading
      zeigt nicht die physische Erreichbarkeit oder Verfügbarkeit an.</li>
  <li><b>Reading device_type_ids:</b> Die validierten IDs aus
      <code>Descriptor.DeviceTypeList</code> werden als kommaseparierte
      Hexadezimalwerte (z. B. <code>0x010A</code>) gespeichert. FHEM stellt
      das Reading beim Neustart wieder her; die Typanzeige und die automatische
      Gruppierung benötigen dafür keine neue Serververbindung. Ungültige oder
      fehlende Descriptor-Updates überschreiben die gespeicherten IDs nicht.</li>
  <li><b>Readings model und available:</b> Das am Root über BasicInformation
      ermittelte <code>model</code> und die Node-weite Erreichbarkeit
      <code>available</code> werden bei bekannten Werten an die Endpunkte
      weitergegeben. <code>available=true/false</code> beschreibt die
      Erreichbarkeit des Knotens, nicht die Funktion einzelner Endpunkte.
      Unveränderte Werte erzeugen keine weiteren Endpoint-Events.</li>
  <li><b>Reading associatedWith:</b> Endpunkte verlinken ihren aktuellen
      Root-Knoten über FHEMs nativen Bereich <code>Probably associated with</code>.
      Manuell ergänzte Zuordnungen bleiben erhalten. Beim Umbenennen des Roots
      aktualisiert FHEM die Referenz automatisch; zusätzliches HTML ist nicht nötig.</li>
  <li>Set-Befehle mit <code>noArg</code> weisen zusätzliche Argumente vor dem Versand ab.</li>
  <li><b>Capabilities:</b> Set-Befehle erfordern einen passenden Eintrag in
      der <code>AcceptedCommandList</code> des jeweiligen Endpunkts sowie
      gegebenenfalls die in der <code>FeatureMap</code> geforderten Features.
      Das Modul erfasst die gemeldete <code>ClusterRevision</code> als Metadatum. Bei einer fehlerhaften ID-Liste bleiben die
      letzten gültigen Einträge erhalten. Eine ausdrücklich leere Liste löscht sie. Fehlende Pfade einer getConfig-Teilantwort erhalten Metadaten; eine gültige Descriptor.ServerList des Endpunkts widerruft fehlende Cluster und wird mit getConfig gelesen. Solange die Metadaten fehlen,
      werden keine Befehle aus Einzelwerten oder alten <code>has_*</code>-
      Einstellungen abgeleitet. Gespeicherte <code>has_*=0</code>-Werte
      sperren keine gemeldeten Befehle mehr.</li>
  <li><b>Weitere Readings:</b> PowerSource, SmokeCO-Alarm,
      Kohlenmonoxidkonzentration, elektrische Leistung und kumulierte Energie,
      soweit die Geräte die jeweiligen Attribute liefern.</li>
</ul>
<p>Ein Wechsel der IO-Instanz oder Matter-IDs entwertet alte Capabilities, Firmwareangebote und steuerungsrelevante Metadaten (Gerätetypen, ICD-Freigaben, Software-/Spezifikationsversion und Grenzen). Andere gespeicherte physische Readings und lokale Attribute bleiben erhalten. Rename und unveränderte DEF-Bestätigung erhalten die Identität; ein belegtes Root-Ziel wird vor der Änderung abgewiesen.</p>
<h4>Attribute</h4>
<p>Bei Auswahl eines Attributs in FHEMWEB erscheint dessen Beschreibung.
Aktive Geräteeinstellungen sind <code>IODev</code>, <code>readOnly</code>, <code>disable</code>, <code>dimRate</code>,
<code>diagnostics</code> und <code>rawReadings</code>. Gerätegrenzen sind
Readings und keine konfigurierbaren Attribute. Gespeicherte Grenzwertattribute
vor dem Neustart mit V0.21 wie unten beschrieben entfernen.</p>
<ul>
  <li><a id="MATTERDevice-attr-IODev"></a><b>IODev:</b> Name des
      <code>MATTER</code>-IO-Devices mit der Serververbindung für diesen
      Knoten/Endpunkt. Automatisch angelegte Geräte erhalten das erkennende IO;
      manuell definierte Roots verwenden ohne Angabe FHEMs IO-Zuordnung.
      Bei mehreren Servern das richtige IO ausdrücklich wählen: Node-IDs
      gelten jeweils nur innerhalb ihres Servers. Nach dem Wechsel eines Roots
      bleibt sein Zustand unknown, bis der neue Server die Erreichbarkeit meldet.
      Eine belegte Ziel-ID wird abgewiesen. Endpunkte behalten ihr eigenes IODev.</li>
  <li><a id="MATTERDevice-attr-disable"></a><b>disable (0/1):</b>
      Standard <code>0</code>, nur an Endpunkten größer 0. Mit <code>1</code>
      Endpunktbefehle einschließlich getConfig, Werte, Capability-Updates,
      gespiegelte Statuswerte und Tasterereignisse sperren. Vorhandene Readings
      und Zeitstempel bleiben erhalten; kein künstlicher disabled/off-Zustand.
      Identität und Root-Zuordnung bleiben bestehen; Empfangs-Internals erfassen
      weiterhin Servernachrichten. Ausstehende Endpunktanfragen werden lokal
      verworfen; Sammelantworten lassen diesen Endpunkt auch nach dem erneuten
      Aktivieren aus. Bereits versendete Befehle lassen sich nicht zurücknehmen.
      <code>0</code> oder Löschen des Attributs setzt die Verarbeitung fort und
      liest bei verbundenem IO und online gemeldetem Root einmalig getConfig.
      Andernfalls folgt die normale Online-Synchronisierung, ohne Polling oder
      Befehlswiederholung. Wiederholtes Setzen erzeugt keine weiteren Abfragen.
      Am Root abgewiesen; Geschwister, Server und andere Controller bleiben aktiv.
      readOnly bleibt unabhängig erhalten. Hardwarestatus:
      <strong>ungetestet</strong>.</li>
  <li><a id="MATTERDevice-attr-readOnly"></a><b>readOnly (0/1):</b>
      Standard <code>0</code>. Mit <code>1</code> an Endpunkten größer 0
      sämtliche Steuerbefehle und Attributschreibzugriffe aus FHEM sperren,
      einschließlich Identify und Stop. In der Set-Auswahl bleibt nur
      <code>getConfig</code>; direkte Steueraufrufe liefern auch aus
      Automatisierungen eine Fehlermeldung. Readings, Ereignisse,
      Empfangs-Internals und Capability-Abfragen laufen unverändert weiter.
      Bereits versendete Befehle werden regulär zugeordnet und lassen sich
      nicht zurücknehmen. Bei Aktivierung zwischen Teilen eines mehrteiligen
      Befehls wird nur der noch nicht versendete Rest gesperrt.
      <code>0</code> oder Löschen des Attributs gibt die Steuerung ohne
      zusätzliche Abfragen oder Befehlswiederholung frei. Am Root wird das
      Attribut abgewiesen; andere Endpunkte sind unabhängig. Root-Verwaltung,
      andere Controller, direkter Serverzugriff und physische Taster werden
      nicht gesperrt; ein dauerhaft eingeschalteter Aktor wird nicht garantiert.
      Hardwarestatus: <strong>ungetestet</strong>.</li>
  <li><a id="MATTERDevice-attr-dimRate"></a><b>dimRate:</b> Ganzzahl
      <code>1</code>–<code>254</code>, Standard <code>30</code>. Native
      LevelControl-Geschwindigkeit in Level-Einheiten pro Sekunde für den
      nächsten Befehl <code>dim_up</code> / <code>dim_down</code> dieses
      Endpunkts. Verändert weder die feste Schrittweite von
      <code>dim_step_up/down</code> noch erzeugt es einen FHEM-Timer.
      Hardwarestatus für natives Dimmen: <strong>ungetestet</strong>.</li>
  <li><a id="MATTERDevice-attr-diagnostics"></a><b>diagnostics (0/1):</b>
      Standard <code>0</code>. Mit <code>1</code> am Root (Endpunkt 0)
      eingehende Thread-/WLAN-Diagnosemeldungen verarbeiten,
      beispielsweise Rolle, Kanal, Nachbarn und RSSI. An untergeordneten
      Endpunkten ohne Wirkung. Keine zusätzlichen Abfragen und kein Polling.
      <code>0</code> oder das Löschen des Attributs beendet die Aktualisierung;
      vorhandene Readings bleiben erhalten. Hardwarestatus:
      <strong>ungetestet</strong>.</li>
  <li><a id="MATTERDevice-attr-rawReadings"></a><b>rawReadings (0/1):</b>
      Standard <code>0</code>. Mit <code>1</code> am empfangenden Root oder
      Endpunkt sonst nicht zugeordnete Attribute als
      <code>raw_&lt;Endpunkt&gt;_&lt;Cluster&gt;_&lt;Attribut&gt;</code>-Readings
      ausgeben. Null-Werte, Attribut-IDs ab 0xFFF0 und die Cluster
      31, 48, 49, 60, 62, 63, 64 und 65 (dezimal) werden übersprungen.
      Pro Wert gilt eine Grenze von 512 Zeichen für skalaren Text bzw.
      512 Bytes für JSON-kodierte Strukturen. Andere Cluster, auch
      herstellerspezifische, können private Gerätedaten in Readings und
      Logs sichtbar machen. Kein Polling; Abschalten erhält vorhandene Readings.
      Hardwarestatus: <strong>ungetestet</strong>.</li>
</ul>
<h4>Standardanzeige der Endpunkte (Hardware ungetestet)</h4>
<p>Endpunkte größer 0 leiten ihre <code>STATE</code>-Anzeige aus den gespeicherten
<code>device_type_ids</code> und ihren eigenen vorhandenen Readings ab. Es werden
weder ein <code>stateFormat</code>-Attribut noch redundante <code>state</code>-
Readings angelegt. Ein ausdrücklich gesetztes <code>stateFormat</code> hat
Vorrang; Löschen stellt den Standard wieder her. Die Anzeige wird nach der
Statefile-Wiederherstellung und bei Reading-Updates des Moduls berechnet.
Fehlende Daten bleiben <code>unknown</code>, eine gültige Null bleibt Null,
ungültige Meldungen erhalten die letzten gültigen Werte. Offline/disable
behalten vorhandene Werte; die Root-Erreichbarkeit bleibt getrennt. Kein
Polling und keine zusätzlichen Matter-Abfragen.</p>
<ul>
<li>Leuchten/Steckdosen, Kontakte, Bewegung, Wasserleck und Regen behalten ihr
physisches <code>state</code>. Elektrische Messwerte einer Steckdose verdrängen
nicht ihre on/off-Anzeige.</li>
<li>Temperatur/Feuchte/Druck/Helligkeit verwenden die bestehenden Readings mit
Einheiten. Ein kombinierter Temperatur-/Feuchte-Endpunkt zeigt beide Werte,
etwa <code>22.34 °C / 48 %</code>; fehlende Komponenten bleiben unknown.</li>
<li>Türschlösser zeigen <code>lock_state</code> als not_fully_locked, locked,
unlocked oder unlatched, getrennt vom Türkontakt. Jalousien zeigen gemeldete
aktuelle Lift-/Tilt-Prozentwerte in Matter-Richtung (0 offen, 100 geschlossen),
ersatzweise absolute Rohpositionen ausdrücklich mit raw, sonst den gemeldeten
Status stopped/opening/closing. Zielpositionen sind keine Istpositionen.</li>
<li>Thermostate zeigen gemeldeten Modus, Isttemperatur und die zum Modus passenden
Heiz-/Kühlsollwerte, bei auto beide. Lüfter zeigen fan_mode und gemeldetes
fan_pct; der angeforderte Soll-Prozentwert ersetzt keinen Istwert.</li>
<li>Rauch-/CO-Melder zeigen den gemeldeten ExpressedState einschließlich Test,
Batterie-/Fehler-/Lebensdauer- und Interconnect-Zuständen. Luftqualität verwendet
den gemeldeten qualitativen Wert, ersatzweise CO2/PM2.5/TVOC mit den gemeldeten
Einheiten; fehlende Einheiten bleiben unknown. Keine eigene Alarm- oder
Luftqualitätsbewertung. Elektrische Sensoren bevorzugen Leistung (W), danach
Energie (kWh), Spannung (V) und Strom (A).</li>
<li>Taster zeigen das eigene letzte Ereignis, z. B. <code>last: short</code>;
Wiederholungen bleiben separate button-Events. Steuergeräte werden nicht als
Leuchten behandelt. On/Off-Sensoren verwenden ihren eigenen gemeldeten state
oder neutral 0/1. Strukturelle und unbekannte Typen behalten vorhandenes state
oder zeigen unknown; Flow Sensor 0x0306 besitzt bisher nur einen Typnamen und
zeigt unknown.</li>
</ul>
<p>Bei mehreren Typen gilt: Alarm, Wasserleck, Regen, Schloss, Jalousie,
Thermostat, Lüfter, Leuchten/Steckdosen, Kontakt, Belegung, On/Off-Sensor,
Taster, Luftqualität, elektrisch, Temperatur/Feuchte, Druck, Helligkeit,
Durchfluss. Strukturelle Begleittypen zählen nicht. Fehlende Hauptdaten führen
nicht zur Anzeige eines niedriger priorisierten Typs. Alle neuen
Anzeigeklassen sind <strong>Hardware-ungetestet</strong>; die lokale Prüfung
mit echtem FHEM/FHEMWEB verwendet synthetische Meldungen.</p>

<h4>Gerätegrenzen als Readings und Umstieg von V0.20</h4>
<p>Die folgenden normalen Readings entstehen aus akzeptierten Gerätemeldungen
oder Snapshots, getrennt je Endpunkt. Sie überstehen die normale FHEM-
Wiederherstellung über Statefile/configDB. Es entstehen keine zusätzlichen
Abfragen und kein Polling.</p>
<table>
<tr><th>Readings</th><th>Quelle / Einheit</th></tr>
<tr><td><code>min_brightness</code>, <code>max_brightness</code></td><td>LevelControl MinLevel / MaxLevel, native Level-Einheiten.</td></tr>
<tr><td><code>min_frequency</code>, <code>max_frequency</code></td><td>LevelControl MinFrequency / MaxFrequency, unveränderte Matter-Werte. Null als Zahlenwert bedeutet undefiniert.</td></tr>
<tr><td><code>color_temp_min</code>, <code>color_temp_max</code></td><td>ColorControl ColorTempPhysicalMinMireds / ColorTempPhysicalMaxMireds, Mired. Kleinere Mired-Werte bedeuten höhere Kelvin-Werte.</td></tr>
<tr><td><code>min_pin_code_length</code>, <code>max_pin_code_length</code></td><td>DoorLock MinPINCodeLength / MaxPINCodeLength, Byte. Rein informativ; keine neue PIN-Verwaltung.</td></tr>
<tr><td><code>min_rfid_code_length</code>, <code>max_rfid_code_length</code></td><td>DoorLock MinRFIDCodeLength / MaxRFIDCodeLength, Byte. Rein informativ; keine neue RFID-Verwaltung.</td></tr>
</table>
<p>Gültige CT-Grenzen bestimmen den Farbwähler. Gültige positive
Frequenzgrenzen bestimmen den Frequenz-Slider. Bei fehlenden, undefinierten,
vertauschten oder durch Metadaten ausgeschlossenen Grenzen bleibt der
angebotene Befehl mit Texteingabe verfügbar. Es werden keine Gerätegrenzen
153&ndash;500 oder 50&ndash;60 angenommen. Beim Lighting-Feature gilt die
standardisierte maximale Level-Stufe 254. Andere LevelControl-Endpunkte
verwenden ein nutzbares gemeldetes <code>max_brightness</code>, andernfalls
den Protokoll-Ersatzwert 254. Dasselbe Maximum gilt für Helligkeits-Slider,
Befehlsprüfung sowie Prozent- und RGB-Skalierung. Ein gemeldetes generisches
Maximum null als Zahlenwert bleibt erhalten; es erlaubt keine positive
Helligkeit und keine abgeleitete Prozentberechnung. Befehle benötigen weiterhin
die angekündigten Matter-Befehle und Features. Bei unbekannter oder negativer
Availability werden Grenzen und abgeleitete Prozentwerte nicht aktualisiert.
Online dürfen akzeptierte Level-, Grenzwert- und Metadatenmeldungen den
Prozentwert aus der gemeldeten Helligkeit neu berechnen.</p>
<p><b>Übergang:</b> Diese zehn Attributnamen sind ab V0.21 aus der
<code>AttrList</code> entfernt; es gibt keine Kompatibilitäts- oder
Migrationslogik. Automationen mit <code>AttrVal</code> prüfen und noch benötigte
Altwerte sichern. Alte Übersteuerungen beeinflussen Bedienelemente und
Skalierung nicht mehr. Vor dem Neustart mit V0.21 die Attribute entfernen und
die Konfiguration speichern; andernfalls kann FHEM gespeicherte Attributzeilen
beim Start zurückweisen. Jede Zeile einzeln in der <b>FHEM-Kommandozeile</b>
ausführen:</p>
<pre>deleteattr TYPE=MATTERDevice (color_temp_(min|max)|(min|max)_(brightness|frequency|pin_code_length|rfid_code_length))
save</pre>
<p>Der Befehl entfernt nur diese zehn Attribute an MATTERDevice-Geräten,
keine Readings. Das Modul kopiert oder löscht keine Altwerte automatisch.
Readings entstehen erst beim Empfang passender Daten. Ungültige/null Meldungen
erhalten den letzten gültigen Reading-Wert;
Availability-Sperre und Antwortreihenfolge gelten auch für Grenzen. Wiederhergestellte
Readings sind gespeicherte Informationen und kein Beleg aktueller
Erreichbarkeit. Hardwarestatus der Geräteklassen weiterhin
<strong>ungetestet</strong>.</p>
<p>Das energy-Reading übernimmt das innere EnergyMeasurementStruct-Feld (benannt oder TLV-Tag 0) nur als Ganzzahl von 0 bis 2^62 mWh, umgerechnet in kWh. Ungültige/null Daten erhalten das letzte Reading; die Zahl null bleibt gültig.</p>
<h4>Hardware-Teststatus</h4>
<p>Die folgenden Geräteklassen sind implementiert, aber es liegt im Repository
kein klassenweiter Hardware-Nachweis vor. <strong>ungetestet</strong> bedeutet:
keine dokumentierte Prüfung am realen Gerät; es bedeutet nicht, dass Code oder
automatisierte Tests fehlen. Ein getestetes Modell belegt nicht alle Modelle
mit demselben Matter-Cluster.</p>
<table><tr><th>Geräteklasse</th><th>Matter-Cluster</th><th>Hardwarestatus</th></tr>
<tr><td>Schaltbare Leuchten / Steckdosen</td><td>OnOff, LevelControl</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Farb-/Farbtemperaturleuchten</td><td>ColorControl</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Rollläden / Jalousien</td><td>WindowCovering. Physische Schließgrenzen für Hub und Neigung: <code>physical_closed_limit_lift</code>, <code>physical_closed_limit_tilt</code></td><td><strong>ungetestet</strong></td></tr>
<tr><td>Thermostate / Lüfter / Identify</td><td>Thermostat, FanControl, Identify</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Kontakt-/Wasserleck-/Regensensoren</td><td>BooleanState</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Temperatur / Feuchte / Druck / Beleuchtungsstärke</td><td>TemperatureMeasurement, RelativeHumidityMeasurement, PressureMeasurement, IlluminanceMeasurement</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Bewegungs-/Präsenzsensoren und Matter-Taster</td><td>OccupancySensing, Switch</td><td><strong>ungetestet</strong></td></tr>
<tr><td>CO2 / PM2.5 / TVOC-Konzentration</td><td>ConcentrationMeasurement-Cluster</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Thread-/WLAN-Diagnose, ICD und OTA</td><td>ThreadNetworkDiagnostics, WiFiNetworkDiagnostics, IcdManagement, OTA Requestor</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Türschlösser</td><td>DoorLock</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Batterien / Stromversorgung</td><td>PowerSource</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Rauch-/CO-Warnmelder</td><td>SmokeCoAlarm</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Elektrische Messwerte</td><td>ElectricalPowerMeasurement, ElectricalEnergyMeasurement</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Luftqualität / CO-Konzentration</td><td>AirQuality, CarbonMonoxideConcentrationMeasurement</td><td><strong>ungetestet</strong></td></tr>
</table>
<p>Thermostat: <code>desired-temp</code> schreibt OccupiedHeatingSetpoint,
<code>desired-temp-cool</code> OccupiedCoolingSetpoint, in Grad Celsius mit
höchstens zwei Nachkommastellen. Erforderlich sind jeweils das angekündigte
Attribut und die passende Heating-/Cooling-Fähigkeit. Texteingaben ersetzen
den pauschalen 5–30-°C-Slider; eigene Sollwertgrenzen prüft das Gerät.</p>
<p>Die Auswahl für <code>mode</code> folgt Heating/Cooling/AutoMode und
ControlSequenceOfOperation. <code>fan_mode</code> folgt FanModeSequence und dem
Auto-Feature; der veraltete On-Modus wird nicht angeboten. Die Modusauswahl
benötigt AttributeList, FeatureMap und gültige Sequenzmetadaten. Fehlende Daten
werden nicht aus dem aktuellen Modus geraten. Normale Snapshots oder
<code>getConfig</code> am betreffenden Endpunkt liefern diese Daten, ohne zusätzliche Probeabfragen.
Die Auswahl ist standardkompatibel, garantiert aber weder optionale
Enum-Unterstützung noch ACL-Berechtigung. Server/Gerät bleiben maßgeblich.</p>
<p><code>fan_pct</code> schreibt PercentSetting (0–100); die Readings
<code>fan_pct_setting</code> und <code>fan_pct</code> trennen Sollwert und
PercentCurrent. Nur ausdrücklich als schreibbar abgebildete Standardattribute
geben diese Setter frei. Identify (15 Sekunden) benötigt weiterhin seinen
akzeptierten Befehl. Korrelierte Schreibstatuslisten müssen zum angefragten
Pfad passen und Status 0 melden. Ablehnungen, fehlerhafte Antworten und falsche
Pfade erscheinen in <code>lastError</code>. Die vorhandene null-API-Bestätigung
bleibt zulässig. Keine Bestätigung überschreibt physische Sollwert-/Modus-/
Geschwindigkeits-Readings; dafür sind Geräteberichte erforderlich. Thermostat-,
Lüfter- und Identify-Kombinationen sind an Hardware <strong>ungetestet</strong>.</p>
<p>Manuelles Matter-OTA erfordert einen Root mit gemeldetem
OTA-Requestor-Cluster (42) und eine kompatible aktuelle Serververbindung
(matterjs-server ab Schema 11 oder Python Matter Server ab Schema 10).
Auch wenn FHEM den Root als offline anzeigt, entscheidet der Server über den Auftrag.
<code>checkFirmwareUpdate</code> fragt nach einem Angebot.
<code>none reported</code> bedeutet, dass dieser Server kein Update meldet.
Die Hersteller-App kann weitere Updates anbieten. <code>updateFirmware</code>
fordert die freigegebene Version einmalig an. <code>update requested</code>
bestätigt den Auftrag. Die passende SoftwareVersion vom Gerät bestätigt die
Installation, auch ohne Fortschrittsmeldung. Nach Timeout oder Trennung vom
Server ist vor einer Installation eine neue Prüfung erforderlich. Der
Server übernimmt die Übertragung. An Hardware <strong>ungetestet</strong>.</p>
<p>ICD Management: passive Readings <code>icd_supported</code>,
<code>icd_lit_supported</code>, <code>icd_operating_mode</code> und
<code>icd_idle_mode_duration</code>. Für bestätigte ICD-Root-Knoten am
kompatiblen Matter-Server stehen asynchrones <code>get icdState</code> und
bei passender Check-In-Fähigkeit die konservativen Befehle
<code>icdRegister</code>, <code>icdUnregister</code>, <code>icdResync</code>
zur Verfügung. Diese Serverbefehle erfordern die OHF-matterjs-Serverkennung
der aktuellen Verbindung (<code>sdk_version=matter-server/... (matter.js/...)</code>)
und mindestens Schema 12. Gespeicherte Server-Readings allein geben sie nicht
frei. Andere/unbekannte Backends behalten die passive ICD-Erkennung ohne
diese Serverbefehle.</p>
<p>Eine gültige Root-<code>Descriptor.ServerList</code> (<code>0/29/1</code>) ohne
Cluster 70 nimmt eine zuvor erkannte ICD-Fähigkeit und ihre Befehle zurück.
Eine ausgelassene Liste oder fehlerhafte Daten erlauben diesen Rückschluss
nicht. Root-<code>getConfig</code> liest ServerList im vorhandenen Request mit.
Die Liste wird nach den übrigen Snapshot-Attributen verarbeitet; neuere
Live-Listen haben Vorrang vor älteren Discovery-/Leseantworten. Historische
Modus-/Dauer-Readings bleiben erhalten. Normale Nicht-ICD-Roots erhalten keine
zusätzlichen negativen ICD-Readings.</p>
<p>Der Server verwaltet die Registrierung; <code>awake=false</code> ist nicht
gleich offline. Controllerwerte stammen aus der letzten expliziten Abfrage.
Ihre normalen FHEM-Zeitstempel bleiben nach Reconnect unverändert. Hardwarestatus
<strong>ungetestet</strong>.</p>
<h4>Netzwerktyp</h4>
<p>Das Reading <code>networkType</code> am Root wertet die betriebsbereiten
Einträge aus <code>GeneralDiagnostics.NetworkInterfaces</code> aus
(Pfad <code>0/51/0</code>). Werte: <code>wifi</code>, <code>thread</code>,
<code>ethernet</code> oder <code>cellular</code>. Mehrere Typen erscheinen
sortiert und ohne Duplikate, etwa <code>ethernet,wifi</code>.
<code>unknown</code> bedeutet keine betriebsbereite Schnittstelle,
unspezifizierter Typ oder unbekannter Enum-Wert in einer ansonsten
verwertbaren Liste. Ein unbekannter aktiver Typ bleibt neben bekannten
Typen sichtbar.</p>
<p>Kein Attribut und keine zusätzliche Abfrage erforderlich. Vor der ersten
verwertbaren Liste fehlt das Reading. Fehlende/null/fehlerhafte Daten
erhalten den bisherigen Wert. Nur Wertänderungen schreiben das Reading;
die normale Availability-Sperre und Antwortreihenfolge gelten weiterhin.
Der Wert bleibt über die normale FHEM-Statefile-Verarbeitung erhalten und
kann zwischengespeichert sein. Er beschreibt gemeldete betriebsbereite
Schnittstellen, weder den Übertragungsweg einer bestimmten Matter-Sitzung
noch die Erreichbarkeit. Das Reading bleibt auf Endpoint 0: Bei einer Bridge
beschreibt es die Bridge, niemals die Funkprotokolle ihrer eingebundenen
Geräte. Commissioning-Feature-Flags allein erzeugen dieses Reading nicht.
Hardwarestatus: <strong>ungetestet</strong>.</p>
<p>Root-Attribut <code>diagnostics=1</code> aktiviert passive Thread-/WLAN-
Diagnose. <code>rawReadings=1</code> zeigt ausgewählte ungemappte
Attribute, darunter auch herstellerspezifische Daten. Beides ist standardmäßig aus, verursacht kein Polling,
löscht vorhandene Readings beim Abschalten nicht und ist an Hardware
<strong>ungetestet</strong>.</p>
<a name="MATTERDevice-diagnostic-readings_DE"></a>
<h4>Diagnose-Readings</h4>
<p>Diese Readings entstehen ausschließlich am Root (Endpoint 0), wenn dort
<code>diagnostics=1</code> gesetzt ist und passende Attribute gemeldet werden.
Sie werden nicht an die Kind-Endpunkte gespiegelt; <code>diagnostics</code>
an einem Kind-Endpunkt hat keine Wirkung.</p>
<table>
<tr><th>Reading</th><th>Bedeutung / Einheit</th></tr>
<tr><td><code>thread_channel</code></td><td>Gemeldeter Thread-Funkkanal.</td></tr>
<tr><td><code>thread_role</code></td><td>Gemeldete Routing-Rolle: <code>unspecified</code>, <code>unassigned</code>, <code>sleepy_end_device</code>, <code>end_device</code>, <code>reed</code>, <code>router</code> oder <code>leader</code>.</td></tr>
<tr><td><code>thread_device_type</code></td><td>Aus der Rolle abgeleitet: <code>MTD</code> (Minimal Thread Device) für Sleepy End Devices; <code>MTD or FTD</code> für End Devices; <code>FTD</code> (Full Thread Device) für REED, Router und Leader. Keine separate Gerätetypmeldung.</td></tr>
<tr><td><code>thread_network</code></td><td>Gemeldeter Name des Thread-Netzes.</td></tr>
<tr><td><code>thread_neighbors</code></td><td>Anzahl der Einträge in der gemeldeten Nachbartabelle einschließlich Children. Die dargestellte Liste kann weniger Einträge enthalten.</td></tr>
<tr><td><code>thread_neighbor_list</code></td><td>Bis zu 16 Nachbarn mit verwertbarem RSSI, absteigend nach Signalstärke, mit Extended Address, Child-/Router-Kennzeichnung und RSSI in dBm; höchstens 600 Zeichen. <code>none</code> bedeutet keine verwertbaren Einträge in dieser Meldung. Das Modul bezeichnet jeden Nicht-Child als <code>router</code>.</td></tr>
<tr><td><code>rssi</code></td><td>Stärkster verwertbarer RSSI unter den nicht als Child markierten Nachbarn, in dBm. Je Nachbar wird der Durchschnitts-RSSI bevorzugt; nur bei fehlendem/null Durchschnitt wird der letzte RSSI verwendet. Daraus lässt sich weder der gewählte Parent noch der Übertragungsweg eines Befehls bestimmen.</td></tr>
<tr><td><code>lqi</code></td><td>Gemeldete Verbindungsqualität desselben für <code>rssi</code> gewählten Nachbarn, sofern als 0&ndash;3 geliefert; höhere Werte bedeuten bessere Qualität. Keine vom stärksten RSSI unabhängige Auswahl.</td></tr>
<tr><td><code>wifi_rssi</code></td><td>Gemeldeter WLAN-RSSI in dBm, sofern WLAN-Diagnosedaten verfügbar sind.</td></tr>
</table>
<p>Das Einschalten sendet keine Abfrage und verarbeitet bereits empfangene
Daten nicht erneut. Aktualisierungen nutzen anschließend akzeptierte
Servermeldungen oder Snapshots; Gerät und Server bestimmen Datenumfang und
Zeitpunkt. Die normale Availability-Sperre und Antwortreihenfolge gelten auch für
Diagnoseattribute. Snapshots können zwischengespeicherte Werte enthalten;
diese Readings belegen deshalb keinen frischen Kontakt zum physischen Gerät.
Ein Reading wird nur bei einer Wertänderung geschrieben; sein Zeitstempel
zeigt daher eine Wertänderung und nicht jede empfangene Meldung an. Fehlende
oder unverwertbare Werte lassen ältere Readings unverändert, auch alte
RSSI-/LQI-Werte bei einer neuen Nachbartabelle ohne geeigneten Nachbarn.
Das Abschalten erhält alle vorhandenen Readings.</p>
<h4>Gemeinsame Antwortzuordnung</h4>
<p>Alle Gerätebefehle (auch on/off, Helligkeit/Farbe, Rollläden, Türschlösser,
Identify und Dimmen) sowie Attribut-Schreibzugriffe verwenden dieselbe
Anfrageverwaltung. Jede API-Anfrage hat eine eigene message_id und eine
geprüfte Geräte-/IO-Zuordnung. Ausstehende Befehle oder Schreibzugriffe sperren
keinen folgenden Setter, auch keinen Stop. Jede Antwort wird zugeordnet und
abgeschlossen; nur der letzte Setter verändert <code>lastError</code>.
Bei einem zusammengesetzten RGB-Setter müssen Helligkeit und Farbe bestätigt
sein: Eine erfolgreiche Teilantwort verdeckt keinen Fehler der anderen.
Diese Reihenfolge betrifft nur die Befehlsdiagnose, keine Gerätemeldungen.</p>
<p>Eine erfolgreiche Serverantwort bestätigt den Gerätebefehl unabhängig
vom Inhalt des Ergebnisfelds. Attribut-Schreibzugriffe prüfen die
zurückgemeldete Pfad-/Statusliste; vorhandene null-API-Bestätigungen bleiben
akzeptiert. <code>lastError=none</code> bestätigt keinen physischen Zustand.
Serverablehnungen und ungültige Antworten erzeugen <code>failed: ...</code>.
Die nächste vorhandene Heartbeat-Prüfung nach 120 Sekunden meldet für einen
unbeantworteten normalen Auftrag <code>timeout (outcome unknown)</code>,
IO-Verlust <code>interrupted (outcome unknown)</code>. Kein automatisches
Wiederholen oder Stoppen, Polling, Rücklesen oder zusätzlicher Timer.
Maximal 1024 offene Aufträge pro IO; weitere Anfragen liefern einen expliziten
Fehler. Unmittelbare Sendefehler werden an FHEM zurückgegeben; bei einem
zusammengesetzten Setter ist eine teilweise Übermittlung möglich.</p>
<p>OTA/ICD nutzen denselben Anfrage-Lebenszyklus mit ihrer bestehenden
Verwaltungssperre, eigenen Statusreadings und Operations-Timeouts. Explizites
getConfig und Capability-Abfragen behalten ihren gesonderten Leseabgleich.
Asynchrone Setter unterdrücken FHEMs synthetisches Befehlsereignis; physische
Readings ändern sich nur durch Gerätemeldungen. Die reale Geräte-/Serverintegration
dieses gemeinsamen Pfades ist <strong>ungetestet</strong>.</p>
<p>Natives LevelControl-Dimmen: <code>dim_up</code>, <code>dim_down</code>,
<code>dim_step_up</code>, <code>dim_step_down</code> und <code>dim_stop</code>
nur bei gemeldeten Befehlen. <code>dimRate</code> (1–254, Standard 30) legt
die Geschwindigkeit für kontinuierliches Dimmen pro Gerät fest. Keine
FHEM-Dimmschleife. Die Befehle nehmen keine Argumente an. Schritte verwenden
20 native Level-Einheiten mit Übergangszeit null. Move/Step/Stop werden
bevorzugt; die jeweilige WithOnOff-Variante wird nur verwendet, wenn die
normale Variante nicht gemeldet ist. WithOnOff kann auch den Schaltzustand
verändern. OptionsMask/Override bleiben null; die Geräteoptionen gelten.
Für diese Befehle gilt die oben beschriebene gemeinsame Antwortzuordnung.
Hardwarevarianten
<strong>ungetestet</strong>.</p>
<p>Weitere Umweltmesswerte: Luftdruck (hPa), CO2, PM2.5 und TVOC mit
separaten, geräteseitig angegebenen Einheiten. Hardwarestatus:
<strong>ungetestet</strong>.</p>
<p>Switch-Cluster (0x003B): Tastendrücke und Loslassen werden am zugehörigen
Endpunkt als eigene FHEM-Ereignisse verarbeitet. Hardwarestatus:
<strong>ungetestet</strong>.</p>
<p>Basissensoren (Kontakt, Wasserleck, Regen, Temperatur, Luftfeuchte,
Beleuchtungsstärke, Belegung) sind implementiert, aber an eigener Hardware
<strong>ungetestet</strong>.</p>
<p>Vor einer Änderung des Teststatus müssen Modell, Firmware, Endpunkt sowie
tatsächlich geprüfte Readings und Befehle nachvollziehbar dokumentiert sein.</p>
<p>Root-Knoten erhalten die Verwaltungsgruppe <code>Matter Nodes</code>.
Funktionale Endpunkte werden nach ihrem eindeutigen, nicht-strukturellen
Matter-Gerätetyp aus <code>Descriptor.DeviceTypeList</code> gruppiert
(z. B. <code>On/Off light</code>, <code>Electrical Sensor</code> oder
<code>Smoke CO Alarm</code>). Rein strukturelle Endpunkte wie
Aggregator und Bridged Node erhalten <code>Matter Infrastruktur</code>.
Zusätzliche strukturelle Typen wie Power Source oder OTA Requestor werden
bei vorhandener Gerätefunktion ignoriert. Unbekannte Typ-IDs erscheinen
hexadezimal. Bei mehreren funktionalen Typen wird keine willkürliche
Auswahl getroffen. Bisherige automatisch erzeugte
<code>Node &lt;node_id&gt; (&lt;IODev&gt;)</code>-Gruppen werden migriert;
eigene Gruppen bleiben erhalten. Die Root-Detailansicht verlinkt die Endpunkte.</p>
<p>Nur neu automatisch erzeugte Geräte werden dem Raum <code>Matter</code>
zugeordnet. Entfernte Geräte bleiben in FHEM erhalten.</p>

=end html_DE
=cut
