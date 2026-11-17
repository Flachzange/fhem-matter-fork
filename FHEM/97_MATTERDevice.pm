# $Id$
package main;

use strict;
use warnings;
use JSON;
use Scalar::Util qw(blessed);

our $init_done; # FHEM startup: statefile and attributes are not yet restored

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
            0x0000 => { name => "state", is_reading => 0, is_attribute => 0},
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
            0x0000 => { name => "brightness", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "min_brightness", is_reading => 0, is_attribute => 1 },
            0x0003 => { name => "max_brightness", is_reading => 0, is_attribute => 1 },
            0x0004 => { name => "frequency", is_reading => 1, is_attribute => 0, required_features => ["frequency"] },
            0x0005 => { name => "min_frequency", is_reading => 0, is_attribute => 1, required_features => ["frequency"] },
            0x0006 => { name => "max_frequency", is_reading => 0, is_attribute => 1, required_features => ["frequency"] },
            0x4000 => { name => "startup_current_level", is_reading => 1, is_attribute => 0, required_features => ["lighting"] },
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
            0x0001 => { name => "producer", is_reading => 1, is_attribute => 0 },
            0x0002 => { name => "vendor_id", is_reading => 1, is_attribute => 0 },
            0x0003 => { name => "model", is_reading => 1, is_attribute => 0 },
            0x0008 => { name => "hardware_version", is_reading => 1, is_attribute => 0 },
            0x000A => { name => "firmware_version", is_reading => 1, is_attribute => 0 },
            0x0009 => { name => "software_version", is_reading => 1, is_attribute => 0 },
            0x000F => { name => "serial_number", is_reading => 1, is_attribute => 0 },
            0x0015 => { name => "specification_version", is_reading => 1, is_attribute => 0 },
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
    0x002A => {
        name       => "OtaSoftwareUpdateRequestor",
        attributes => {
            0x0002 => { name => "ota_update_state", is_reading => 0, is_attribute => 0 },
            0x0003 => { name => "ota_update_progress", is_reading => 1, is_attribute => 0 },
        },
    },
    0x0046 => {
        name       => "IcdManagement",
        attributes => {
            0x0000 => { name => "icd_idle_mode_duration", is_reading => 1, is_attribute => 0 },
            0x0008 => { name => "icd_operating_mode", is_reading => 0, is_attribute => 0 },
        },
    },
    0x0045 => {
        name       => "BooleanState",
        attributes => {
            0x0000 => { name => "boolean_state", is_reading => 1, is_attribute => 0 },
        },
    },
    0x0400 => {
        name       => "IlluminanceMeasurement",
        attributes => {
            0x0000 => { name => "illuminance", is_reading => 1, is_attribute => 0,
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
            0x0000 => { name => "temperature", is_reading => 1, is_attribute => 0,
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
            0x0000 => { name => "pressure", is_reading => 1, is_attribute => 0,
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
            0x0000 => { name => "humidity", is_reading => 1, is_attribute => 0,
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
            0x0000 => { name => "motion", is_reading => 1, is_attribute => 0,
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
    0x0090 => {
        name       => "ElectricalPowerMeasurement",
        attributes => {
            0x0000 => { name => "power_mode", is_reading => 1, is_attribute => 0 },
            0x0001 => { name => "number_of_measurement_types", is_reading => 1, is_attribute => 0 },
            0x0004 => { name => "voltage", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0005 => { name => "current", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0006 => { name => "reactive_current", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0007 => { name => "apparent_current", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0008 => { name => "power", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x0009 => { name => "reactive_power", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000A => { name => "apparent_power", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000B => { name => "rms_voltage", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000C => { name => "rms_current", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000D => { name => "rms_power", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
            0x000E => { name => "frequency", is_reading => 1, is_attribute => 0 },
            0x0011 => { name => "power_factor", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 10000 : undef } },
            0x0012 => { name => "neutral_current", is_reading => 1, is_attribute => 0,
                        transform => sub { defined($_[0]) ? $_[0] / 1000 : undef } },
        },
    },
    0x0091 => {
        name       => "ElectricalEnergyMeasurement",
        attributes => {
            0x0001 => { name => "energy", is_reading => 1, is_attribute => 0,
                        transform => sub {
                            my ($v) = @_;
                            return undef if !defined($v) || ref($v) ne 'HASH';
                            my $energy_mWh = exists($v->{"0"}) ? $v->{"0"} : $v->{energy};
                            return defined($energy_mWh) ? $energy_mWh / 1_000_000 : undef;
                        } },
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
    0x040D => {
        name       => "CarbonDioxideConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "co2", is_reading => 1, is_attribute => 0,
                        transform => sub { return $_[0] >= 0 ? $_[0] : undef; } },
            0x0008 => { name => "co2_unit", is_reading => 1, is_attribute => 0,
                        transform => \&MATTERDevice_ConcentrationUnit },
        },
    },
    0x042A => {
        name       => "Pm25ConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "pm25", is_reading => 1, is_attribute => 0,
                        transform => sub { return $_[0] >= 0 ? $_[0] : undef; } },
            0x0008 => { name => "pm25_unit", is_reading => 1, is_attribute => 0,
                        transform => \&MATTERDevice_ConcentrationUnit },
        },
    },
    0x042E => {
        name       => "TotalVolatileOrganicCompoundsConcentrationMeasurement",
        attributes => {
            0x0000 => { name => "tvoc", is_reading => 1, is_attribute => 0,
                        transform => sub { return $_[0] >= 0 ? $_[0] : undef; } },
            0x0008 => { name => "tvoc_unit", is_reading => 1, is_attribute => 0,
                        transform => \&MATTERDevice_ConcentrationUnit },
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
            0x00   => { name => "UpOrOpen" },
            0x01   => { name => "DownOrClose" },
            0x02   => { name => "StopMotion" },
            0x05   => { name => "GoToLiftPercentage", required_features => ["lift"] },
            0x08   => { name => "GoToTiltPercentage", required_features => ["tilt"] },
        },
    },
    0x0201 => {
        name       => "Thermostat",
        attributes => {
            0x0000 => { name => "measured-temp", is_reading => 1, is_attribute => 0,
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < -27315 || $_[0] > 32767;
                            return $_[0] / 100;
                        } },
            0x0011 => { name => "desired-temp-cool", is_reading => 1, is_attribute => 0,
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < -27315 || $_[0] > 32767;
                            return $_[0] / 100;
                        } },
            0x0012 => { name => "desired-temp", is_reading => 1, is_attribute => 0,
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < -27315 || $_[0] > 32767;
                            return $_[0] / 100;
                        } },
            0x001C => { name => "mode", is_reading => 1, is_attribute => 0,
                        transform => sub {
                            my %modes = (0 => 'off', 1 => 'auto', 3 => 'cool',
                                         4 => 'heat', 5 => 'emergency_heat');
                            return $modes{$_[0]};
                        } },
        },
    },
    0x0202 => {
        name       => "FanControl",
        attributes => {
            0x0000 => { name => "fan_mode", is_reading => 1, is_attribute => 0,
                        transform => sub {
                            my %modes = (0 => 'off', 1 => 'low', 2 => 'medium',
                                         3 => 'high', 4 => 'on', 5 => 'auto');
                            return $modes{$_[0]};
                        } },
            0x0002 => { name => "fan_pct_setting", is_reading => 1, is_attribute => 0,
                        transform => sub {
                            return undef if $_[0] != int($_[0]) ||
                                            $_[0] < 0 || $_[0] > 100;
                            return $_[0];
                        } },
            0x0003 => { name => "fan_pct", is_reading => 1, is_attribute => 0,
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
    $hash->{NotifyFn} = "MATTERDevice_Notify";
    $hash->{FW_detailFn} = "MATTERDevice_FWDetail";
    $hash->{FW_deviceOverview} = 1; # Keep FHEMWEB DeviceOverview above the endpoint links.
    $hash->{AttrList} = "IODev " .
                        "has_lighting:0,1 " .
                        "has_color:0,1 " .
                        "has_onoff:0,1 " .
                        "has_level:0,1 " .
                        "dimRate:slider,1,1,254 " .
                        "diagnostics:0,1 " .
                        "rawReadings:0,1 " .
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

# Root status is an interpreted node-wide reachability report, not an endpoint
# state or a copy of the last saved available value.
sub MATTERDevice_SetRootState($$) {
    my ($hash, $state) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0;
    readingsSingleUpdate($hash, 'state', $state, 1)
        if ReadingsVal($hash->{NAME}, 'state', '') ne $state;
}

sub MATTERDevice_UpdateAvailability($$) {
    my ($hash, $reported) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0;
    my $boolean = MATTERDevice_NormalizeBoolean($reported);
    return unless defined $boolean;
    my $previous = ReadingsVal($hash->{NAME}, 'available', '');
    # Device attributes cached on the server must never overwrite local
    # readings while unavailable. On recovery, server snapshots may still
    # be stale: only subsequent individual live attribute reports are fresh
    # enough for release until a proven fresh interview is available.
    $hash->{helper}{quarantine_snapshots} = 1
        if !$boolean || $previous eq 'false';
    my $available = $boolean ? 'true' : 'false';
    my $state = $boolean ? 'online' : 'offline';
    my $change_available = ReadingsVal($hash->{NAME}, 'available', '') ne $available;
    my $change_state = ReadingsVal($hash->{NAME}, 'state', '') ne $state;
    if ($change_available || $change_state) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'available', $available) if $change_available;
        readingsBulkUpdate($hash, 'state', $state) if $change_state;
        readingsEndUpdate($hash, 1);
    }
    MATTERDevice_SyncNodeReadings($hash);
}

# Config and statefile restoration complete before INITIALIZED/REREADCFG.
# The former module created exactly 'stateFormat available' automatically.
# Migrate that legacy default once, without altering other user formatting.
sub MATTERDevice_Notify($$) {
    my ($hash, $dev) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0 &&
                  ($dev->{NAME} // '') eq 'global';
    return unless grep { $_ eq 'INITIALIZED' || $_ eq 'REREADCFG' }
                  @{$dev->{CHANGED} // []};
    my $name = $hash->{NAME};
    if (AttrVal($name, 'stateFormat', '') eq 'available' &&
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
        AssignIoPort($hash);
        my $io_name = $hash->{IODev} ? $hash->{IODev}{NAME} : 'no_io';
        $modules{MATTERDevice}{defptr}{"$io_name:$node_id"} = $hash;
        MATTERDevice_SetRootState($hash, 'unknown') if $init_done;
    }
    Log3 $name, 3, "MATTERDevice: Defined node_id $node_id for $name";
    return undef;
}

sub MATTERDevice_Undef($$) {
my ($hash, $arg) = @_;
    if (($hash->{node_id}) && ($hash->{endpoint_id} == 0)) {
        my $io_name = $hash->{IODev} ? $hash->{IODev}{NAME} : 'no_io';
        my $key = "$io_name:$hash->{node_id}";
        delete $modules{MATTERDevice}{defptr}{$key}
            if ($modules{MATTERDevice}{defptr}{$key} // '') eq $hash;
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
    # The legacy module permitted user-supplied max/min attributes without
    # an AttributeList. Keep that behavior until actual metadata is available.
    my $list = $hash->{helper}{capabilities}{$cluster_id}{attribute_list};
    return 1 if ref($list) ne 'HASH';
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
    my %legacy = (
        0x0006 => { 0x00 => 'has_onoff', 0x01 => 'has_onoff', 0x02 => 'has_onoff',
                    0x40 => 'has_lighting', 0x41 => 'has_lighting', 0x42 => 'has_lighting' },
        0x0008 => { 0x00 => 'has_level', 0x04 => 'has_level', 0x08 => 'has_frequency' },
        0x0101 => { 0x00 => 'has_lock', 0x01 => 'has_lock' },
        0x0102 => { 0x00 => 'has_wc', 0x01 => 'has_wc', 0x02 => 'has_wc',
                    0x05 => 'has_position_lift', 0x08 => 'has_position_tilt' },
        0x0300 => { 0x06 => 'has_hue', 0x07 => 'has_xy', 0x0A => 'has_ct' },
    );
    my $flag = $legacy{$cluster_id}{$command_id};
    my $override = $flag ? AttrVal($hash->{NAME}, $flag, undef) : undef;
    # Explicit has_*=0 remains authoritative even when the server advertises
    # a command. An explicit 1 alone never invents a missing advertised command.
    return 0 if defined($override) && $override eq '0';

    my $accepted = $hash->{helper}{capabilities}{$cluster_id}{accepted_commands};
    if (ref($accepted) ne 'HASH') {
        # Prior releases also allowed an explicit has_color flag for RGB.
        # Without hue/XY metadata, that flag selected hue/saturation unless XY
        # was explicitly enabled.
        if ($cluster_id == 0x0300 && $command_id == 0x06 &&
            !defined($override) && AttrVal($hash->{NAME}, 'has_color', 0) &&
            !AttrVal($hash->{NAME}, 'has_xy', 0)) {
            return 1;
        }
        return defined($override) && $override ? 1 : 0;
    }
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

# Keep brightness bounds consistent across controls, commands and readings.
sub MATTERDevice_MaxBrightness {
    my ($hash) = @_;
    my $max = MATTERDevice_AttributeUsable($hash, 0x0008, 0x0003)
        ? AttrVal($hash->{NAME}, 'max_brightness', 254) : 254;
    return 254 unless defined($max) && !ref($max) &&
        $max =~ /^\d+$/ && $max > 0 && $max <= 254;
    return $max;
}

sub MATTERDevice_Set($$@) {
    my ($hash, $name, $cmd, @args) = @_;

    my @setList = MATTERDevice_GetSetList($hash);
    my $list_str = join(" ", @setList);
    my $valid = 0;

    if ($cmd eq "?") {
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
        return "Unknown argument $cmd, choose one of $list_str";
    }
    
    my $payload       = undef;
    my $level_payload = undef;
    my $node_id     = $hash->{node_id};
    my $endpoint_id = $hash->{endpoint_id} // 1;
    my $io_hash = $hash->{IODev};
    return "MATTER: No active WebSocket connection for $name"
        unless $io_hash && $io_hash->{CD} && $io_hash->{websocket} &&
            ($io_hash->{ws_status} // '') eq 'connected' &&
            $io_hash->{fhem}{helper}{sendWS};

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
        return 'Firmware operations are only available on Matter root nodes'
            unless ($hash->{endpoint_id} // 0) == 0;
        my $op = $cmd eq 'checkFirmwareUpdate' ?
            'check_node_update' : 'update_node';
        my %args;
        if ($cmd eq 'updateFirmware') {
            return 'Firmware update already in progress'
                if $hash->{helper}{firmware_update_in_flight};
            my $version = $hash->{helper}{firmware_available};
            return 'Run checkFirmwareUpdate before installing'
                unless defined($version) && !ref($version) &&
                       $version =~ /^\d+$/;
            $args{software_version} = 0 + $version;
        }
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
            $payload = {
                message_id => MATTER_NextMessageId($io_hash),
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
                message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
                message_id => MATTER_NextMessageId($io_hash),
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
            my $max_level = MATTERDevice_MaxBrightness($hash);
            my $use_with_onoff = MATTERDevice_CommandSupported($hash, 0x0008, 0x04);
            $payload = {
                message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
        return "Usage: set $name rgb RRGGBB"
            unless @args == 1 && defined($args[0]) && $args[0] =~ /^#?[0-9a-fA-F]{6}$/;
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
                    message_id => MATTER_NextMessageId($io_hash),
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
                my $max_level = MATTERDevice_MaxBrightness($hash);
                my $level = int(($rgb_max / 255) * $max_level + 0.5);
                $level_payload = {
                    message_id => MATTER_NextMessageId($io_hash),
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
                my $max_level = MATTERDevice_MaxBrightness($hash);
                my $level = int($max * $max_level + 0.5);
                $level_payload = {
                    message_id => MATTER_NextMessageId($io_hash),
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
                message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
                unless defined($rate) && $rate =~ /^\d+$/ && $rate >= 1 && $rate <= 254;
            $arguments->{moveMode} = $mode;
            $arguments->{rate} = int($rate);
        } elsif ($regular == 0x02) {
            $arguments->{stepMode} = $mode;
            $arguments->{stepSize} = 20;
            $arguments->{transitionTime} = 0;
        }
        $payload = {
            message_id => MATTER_NextMessageId($io_hash),
            command    => 'device_command',
            args       => {
                node_id => $node_id, endpoint_id => int($endpoint_id),
                cluster_id => 0x0008, command_name => $command_name,
                payload => $arguments,
            },
        };
    }
    elsif ($cmd eq 'identify') {
        return 'Identify not accepted by this endpoint'
            unless MATTERDevice_CommandSupported($hash, 0x0003, 0x00);
        $payload = {
            message_id => MATTER_NextMessageId($io_hash),
            command => 'device_command',
            args => {
                node_id => $node_id, endpoint_id => int($endpoint_id),
                cluster_id => 0x0003, command_name => 'Identify',
                payload => { identifyTime => 15 },
            }
        };
    }
    elsif ($cmd =~ /^(?:desired-temp|mode|fan_mode|fan_pct)$/) {
        my ($cluster_id, $attr_id, $write_value);
        return "Usage: set $name $cmd <value>" if @args != 1 || !defined($args[0]);
        my $value = $args[0];
        if ($cmd eq 'desired-temp') {
            return 'desired-temp must be a valid temperature in degrees Celsius'
                unless $value =~ /^-?\d+(?:\.\d{1,2})?$/ &&
                       $value >= -273.15 && $value <= 327.67;
            ($cluster_id, $attr_id) = (0x0201, 0x0012);
            $write_value = int($value * 100 + ($value >= 0 ? 0.5 : -0.5));
        } elsif ($cmd eq 'mode') {
            my %modes = (off => 0, auto => 1, cool => 3, heat => 4,
                         emergency_heat => 5);
            return 'mode must be off, auto, cool, heat or emergency_heat'
                unless exists $modes{$value};
            ($cluster_id, $attr_id, $write_value) = (0x0201, 0x001C, $modes{$value});
        } elsif ($cmd eq 'fan_mode') {
            my %modes = (off => 0, low => 1, medium => 2, high => 3,
                         on => 4, auto => 5);
            return 'fan_mode must be off, low, medium, high, on or auto'
                unless exists $modes{$value};
            ($cluster_id, $attr_id, $write_value) = (0x0202, 0x0000, $modes{$value});
        } else {
            return 'fan_pct must be between 0 and 100'
                unless $value =~ /^\d+$/ && $value <= 100;
            ($cluster_id, $attr_id, $write_value) = (0x0202, 0x0002, int($value));
        }
        return "Matter attribute for $cmd is not advertised"
            unless MATTERDevice_AttributeSupported($hash, $cluster_id, $attr_id);
        $payload = {
            message_id => MATTER_NextMessageId($io_hash),
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

        # Falls Root-Device (Endpoint 0), auch die PartsList abfragen.
        if ($endpoint_id == 0) {
            push @paths, "0/29/3";
        }

        # Als Bulk-Array an den Server schicken.
        if (@paths) {
            my $pending_reads = ($ioHash->{helper}{pending_config} //= {});
            foreach my $id (keys %$pending_reads) {
                my $entry = $pending_reads->{$id};
                if (ref($entry) eq 'HASH' &&
                    gettimeofday() - ($entry->{created_at} // 0) > 120) {
                    delete $pending_reads->{$id};
                    next;
                }
                # Do not allow a second request for this endpoint to return
                # an older configuration after a newer response was applied.
                return "MATTER: getConfig already in progress for $name"
                    if ref($entry) eq 'HASH' &&
                       $entry->{node_id} eq $node_id &&
                       $entry->{endpoint_id} == $endpoint_id;
            }
            return "MATTER: Too many pending read requests"
                if scalar(keys %$pending_reads) >= 128;
            my $msg_id = MATTER_NextMessageId($ioHash);
            return "MATTER: Cannot allocate request ID" unless defined $msg_id;
            $pending_reads->{$msg_id} = {
                node_id => $node_id,
                endpoint_id => int($endpoint_id),
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
            
            unless ($ioHash->{fhem}{helper}{sendWS}->(encode_json($config_payload))) {
                delete $pending_reads->{$msg_id};
                return "MATTER: Unable to send getConfig on $name";
            }
            Log3 $name, 3, "MATTERDevice: Wildcard getConfig triggered for node $node_id, endpoint $endpoint_id (" . scalar(@paths) . " paths queried).";
        }

        return undef;
    }
    elsif ($cmd eq "frequency") {
        $payload = {
            message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
            message_id => MATTER_NextMessageId($io_hash),
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
        return "MATTER: Unable to send brightness command on $name"
            if $level_payload && !$sendWS->(encode_json($level_payload));
        # FHEM attribute writes are asynchronous. Track the correlated
        # server reply so a successful socket enqueue is never presented
        # as a confirmed Matter write.
        my $tracked_write = $payload && ($payload->{command} // '') eq 'write_attribute';
        my $id = $tracked_write ? $payload->{message_id} : undef;
        if ($tracked_write) {
            $hash->{IODev}{helper}{pending_command}{$id} = {
                type => 'node_operation', operation => 'write_attribute',
                name => $name, fuuid => $hash->{FUUID}, node_id => $node_id,
                started_at => gettimeofday(), timeout => 120,
            };
        }
        if ($payload && !$sendWS->(encode_json($payload))) {
            delete $hash->{IODev}{helper}{pending_command}{$id}
                if $tracked_write;
            return "MATTER: Unable to send device command on $name";
        }
        return wantarray ? (undef, 1) : undef if $tracked_write;
    } else {
        return "No send function found in IODev for $name";
    }

    return undef;
}

sub MATTERDevice_Get($$@) {
    my ($hash, $name, $cmd, @args) = @_;
    my $root = ($hash->{endpoint_id} // 0) == 0;
    my $icd = $root && ReadingsVal($name, 'icd_supported', '') eq 'true';
    my $io = $hash->{IODev};
    my $schema = $io ? ReadingsVal($io->{NAME}, 'schema_version', 0) : 0;
    my $supported = $icd && $schema =~ /^\d+$/ && $schema >= 12;
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

# Opt-in passive diagnostics: no additional server reads or polling.
sub MATTERDevice_UpdateNetworkDiagnostics {
    my ($hash, $cluster, $attr, $value) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0 &&
                  AttrVal($hash->{NAME}, 'diagnostics', 0);
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
    while (my ($reading, $val) = each %readings) {
        readingsSingleUpdate($hash, $reading, $val, 1)
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
    readingsSingleUpdate($hash, $reading, $str, 1)
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
    readingsSingleUpdate($hash, 'icd_lit_supported', $supported, 1)
        if ReadingsVal($hash->{NAME}, 'icd_lit_supported', '') ne $supported;
}
sub MATTERDevice_IcdCapabilityReport {
    my ($hash, $cluster, $attr, $value) = @_;
    return unless ($hash->{endpoint_id} // 0) == 0;
    if ($cluster == 70 && defined($value) && !ref($value)) {
        if ($attr == 65532 && $value =~ /^\d+$/) {
            readingsSingleUpdate($hash, 'icd_supported', 'true', 1)
                if ReadingsVal($hash->{NAME}, 'icd_supported', '') ne 'true';
            $hash->{helper}{capabilities}{70}{feature_map} = $value;
            MATTERDevice_RefreshIcdCapability($hash);
        } elsif ($attr == 8 && $value =~ /^(?:0|1)$/) {
            my $mode = $value == 1 ? 'LIT' : 'SIT';
            readingsSingleUpdate($hash, 'icd_operating_mode', $mode, 1)
                if ReadingsVal($hash->{NAME}, 'icd_operating_mode', '') ne $mode;
            readingsSingleUpdate($hash, 'icd_supported', 'true', 1)
                if ReadingsVal($hash->{NAME}, 'icd_supported', '') ne 'true';
        } elsif ($attr == 0 && $value =~ /^\d+$/ && $value <= 4294967295) {
            readingsSingleUpdate($hash, 'icd_idle_mode_duration', $value, 1)
                if ReadingsVal($hash->{NAME}, 'icd_idle_mode_duration', '') ne "$value";
        }
    } elsif ($cluster == 40 && $attr == 21 &&
             defined($value) && !ref($value) && $value =~ /^\d+$/) {
        readingsSingleUpdate($hash, 'specification_version', $value, 1)
            if ReadingsVal($hash->{NAME}, 'specification_version', '') ne "$value";
        MATTERDevice_RefreshIcdCapability($hash);
    }
}
sub MATTERDevice_SendNodeOperation {
    my ($hash, $command, $args, $timeout) = @_;
    my $name = $hash->{NAME};
    my $io = $hash->{IODev};
    return 'No active Matter server connection'
        unless $io && $io->{CD} && $io->{websocket} &&
               ($io->{ws_status} // '') eq 'connected' &&
               $io->{fhem}{helper}{sendWS};
    # Per-node serialization: a late response from an older operation must
    # never be mistaken for the result of a newer ICD/OTA operation.
    for my $pending (values %{$io->{helper}{pending_command} // {}}) {
        next unless ref($pending) eq 'HASH' &&
                    ($pending->{type} // '') eq 'node_operation';
        return 'Another Matter operation is already pending for this node'
            if ($pending->{node_id} // '') eq $hash->{node_id} &&
               ($pending->{fuuid} // '') eq ($hash->{FUUID} // '');
    }
    my $id = MATTER_NextMessageId($io);
    return 'No available Matter request ID' unless defined $id;
    my $pending = {
        type => 'node_operation', operation => $command,
        name => $name, fuuid => $hash->{FUUID}, node_id => $hash->{node_id},
        started_at => gettimeofday(), timeout => ($timeout // 120),
    };
    $io->{helper}{pending_command}{$id} = $pending;
    my $payload = {
        message_id => $id, command => $command,
        args => { node_id => 0 + $hash->{node_id}, %{$args // {}} }
    };
    unless ($io->{fhem}{helper}{sendWS}->(encode_json($payload))) {
        delete $io->{helper}{pending_command}{$id};
        return "Could not send $command";
    }
    my $reading = $command =~ /icd/ ? 'icd_request' : 'firmware_update';
    readingsSingleUpdate($hash, $reading, 'requested', 1);
    return undef;
}
sub MATTERDevice_HandleNodeOperation {
    my ($hash, $request, $reply) = @_;
    my $cmd = $request->{operation};
    my $reading = $cmd =~ /icd/ ? 'icd_request' :
                  $cmd eq 'write_attribute' ? 'lastError' : 'firmware_update';
    if (exists($reply->{error_code}) || exists($reply->{error})) {
        delete $hash->{helper}{firmware_available}
            if $cmd eq 'check_node_update';
        my $error = ref($reply->{error}) eq 'HASH'
            ? $reply->{error}{message} : $reply->{details};
        $error = 'Matter server rejected the request'
            unless defined($error) && !ref($error);
        $error =~ s/[\x00-\x1f\x7f]/ /g;
        readingsSingleUpdate($hash, $reading,
                             'failed: ' . substr($error, 0, 200), 1);
        return;
    }
    if ($cmd =~ /icd/) {
        if ($cmd eq 'resync_icd' && exists($reply->{result}) &&
            !defined($reply->{result})) {
            readingsSingleUpdate($hash, 'icd_request', 'resync accepted', 1);
            return;
        }
        my $value = $reply->{result};
        unless (ref($value) eq 'HASH' && exists($value->{supported})) {
            readingsSingleUpdate($hash, 'icd_request', 'invalid response', 1);
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
            readingsSingleUpdate($hash, $fields{$key},
                                 $b ? 'true' : 'false', 1);
        }
        if (defined($value->{operating_mode}) && !ref($value->{operating_mode}) &&
            $value->{operating_mode} =~ /^(?:SIT|LIT)$/) {
            readingsSingleUpdate($hash, 'icd_controller_mode',
                                 $value->{operating_mode}, 1);
        }
        if (defined($value->{next_expected_checkin}) &&
            !ref($value->{next_expected_checkin}) &&
            $value->{next_expected_checkin} =~ /^\d+$/) {
            readingsSingleUpdate($hash, 'icd_next_expected_checkin_ms',
                                 $value->{next_expected_checkin}, 1);
        }
        readingsSingleUpdate($hash, 'icd_request', 'completed', 1);
    } elsif ($cmd eq 'check_node_update') {
        my $update = $reply->{result};
        if (!defined($update) && exists($reply->{result})) {
            delete $hash->{helper}{firmware_available};
            readingsSingleUpdate($hash, 'firmware_update', 'none reported', 1);
        } elsif (ref($update) eq 'HASH' &&
                 defined($update->{software_version}) &&
                 !ref($update->{software_version}) &&
                 $update->{software_version} =~ /^\d+$/) {
            my $current = ReadingsVal($hash->{NAME}, 'software_version', undef);
            if (defined($current) && $current =~ /^\d+$/ &&
                $update->{software_version} <= $current) {
                delete $hash->{helper}{firmware_available};
                readingsSingleUpdate($hash, 'firmware_update', 'up to date', 1);
                return;
            }
            $hash->{helper}{firmware_available} = $update->{software_version};
            my $label = $update->{software_version_string};
            $label = $update->{software_version}
                unless defined($label) && !ref($label) && length($label) <= 80;
            readingsSingleUpdate($hash, 'firmware_update_version', $label, 1);
            readingsSingleUpdate($hash, 'firmware_update', 'available', 1);
        } else {
            readingsSingleUpdate($hash, 'firmware_update', 'invalid response', 1);
        }
    } elsif ($cmd eq 'write_attribute') {
        readingsSingleUpdate($hash, 'lastError', 'none', 1)
            if exists($reply->{result});
    } elsif ($cmd eq 'update_node') {
        if (exists($reply->{result}) && !defined($reply->{result})) {
            $hash->{helper}{firmware_update_in_flight} = 1;
            readingsSingleUpdate($hash, 'firmware_update', 'update requested', 1);
        } else {
            readingsSingleUpdate($hash, 'firmware_update', 'invalid response', 1);
        }
    }
}
sub MATTERDevice_ProcessAttributeValue($$$$) {
    my ($hash, $cluster_id, $attr_id, $value) = @_; # quick unpack
    my $name = $hash->{NAME};

    # Cluster-ID und Attribut-ID sicher als numerischen/hexadezimalen Wert behandeln
    $cluster_id = hex($cluster_id) if $cluster_id =~ /^0x/i;
    $attr_id    = hex($attr_id)    if $attr_id =~ /^0x/i;

    my $cluster = $MATTER_CLUSTERS{$cluster_id};

    # Remember cluster presence for conservative fallback labels in FHEMWEB,
    # including measurement clusters this module does not yet expose as readings.
    $hash->{helper}{seen_clusters}{$cluster_id} = 1 if defined($value);

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
            readingsSingleUpdate($hash, 'ota_update_state', $state{$value}, 1)
                if ReadingsVal($name, 'ota_update_state', '') ne $state{$value};
            readingsSingleUpdate($hash, 'firmware_update', $state{$value}, 1)
                if $hash->{helper}{firmware_update_in_flight} && $value >= 2;
        }
    }
    if (($hash->{endpoint_id} // 0) == 0 && $cluster_id == 40 &&
        $attr_id == 9 && defined($value) && !ref($value) &&
        $value =~ /^\d+$/ && $hash->{helper}{firmware_update_in_flight}) {
        my $expected = $hash->{helper}{firmware_available};
        if (defined($expected) && $expected eq $value) {
            readingsSingleUpdate($hash, 'firmware_update', 'installed', 1);
            delete $hash->{helper}{firmware_update_in_flight};
            delete $hash->{helper}{firmware_available};
        }
    }

    # ICD capability comes from endpoint-zero metadata, not a get_icd_state
    # probe during discovery. Do not conflate a sleeping ICD with offline.
    MATTERDevice_IcdCapabilityReport($hash, $cluster_id, $attr_id, $value)
        if ($cluster_id == 70 || $cluster_id == 40);

    # Globale Matter-Attribute gelten fuer jeden Cluster, auch wenn dessen
    # Nutzdaten im FHEM-Modul noch nicht abgebildet sind.
    return if (MATTERDevice_ProcessGlobalAttribute($hash, $cluster_id, $attr_id, $value));

    # Descriptor cluster (0x001D), DeviceTypeList (0x0000).
    # Matter.js supplies an array of DeviceTypeStruct objects (deviceType, revision).
    # Persist the advertised IDs as a canonical reading. Unlike helper data,
    # regular FHEM readings survive a restart through the statefile/configDB.
    if ($cluster_id == 0x001D && $attr_id == 0x0000) {
        if (ref($value) eq 'ARRAY') {
            my (@types, %seen);
            foreach my $entry (@{$value}) {
                next unless ref($entry) eq 'HASH';
                my $raw_id = $entry->{deviceType} // $entry->{device_type} // $entry->{'0'};
                my $type_id = MATTERDevice_NormalizeMatterId($raw_id);
                next unless defined($type_id) && $type_id <= 0xFFFFFFFF;
                push @types, $type_id unless $seen{$type_id}++;
            }
            if (@types) {
                my $ids = join(',', map { sprintf('0x%04X', $_) } sort { $a <=> $b } @types);
                readingsSingleUpdate($hash, 'device_type_ids', $ids, 1)
                    if ReadingsVal($name, 'device_type_ids', '') ne $ids;
                MATTERDevice_EnsureTypeGroup($hash);
            }
        }
        return;
    }
    if ($cluster_id == 0x0035 || $cluster_id == 0x0036) {
        MATTERDevice_UpdateNetworkDiagnostics($hash, $cluster_id, $attr_id, $value);
        return;
    }
    my $attr_info = $cluster ? $cluster->{attributes}{$attr_id} : undef;
    unless ($attr_info) {
        MATTERDevice_RawDiagnostic($hash, $cluster_id, $attr_id, $value);
        return;
    }

    my $attr_name = $attr_info->{name};
    my $is_reading = $attr_info->{is_reading} // 0;
    my $is_attribute = $attr_info->{is_attribute} // 0;
    my $transform = $attr_info->{transform};

    my $boolean = MATTERDevice_NormalizeBoolean($value);
    $value = $boolean if blessed($value) && defined($boolean);
    return if !defined($value);
    if ($transform && ref($transform) eq 'CODE') {
        # Numeric transformations must not turn malformed values into zero.
        if ($cluster_id != 0x0091) {
            return if ref($value) || $value !~ /^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/;
        }
        $value = $transform->($value);
        return if !defined($value);
    }
    return if ref($value);
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
    return if $cluster_id == 0x0006 && $attr_id == 0 &&
              !defined(MATTERDevice_NormalizeBoolean($value));
    return if $cluster_id == 0x0008 && $attr_id == 0 &&
              ($value !~ /^\d+$/ || $value > 254);

    # Existing installations may depend on manually managed has_* attributes.
    my %legacy_features = (
        '6/0'   => 'has_onoff', '8/0'   => 'has_level', '8/4'   => 'has_frequency',
        '258/0' => 'has_wc',    '258/3' => 'has_position_lift',
        '258/4' => 'has_position_tilt', '257/0' => 'has_lock',
        '768/0' => 'has_hue',   '768/1' => 'has_saturation',
        '768/3' => 'has_xy',    '768/4' => 'has_xy', '768/7' => 'has_ct',
    );
    my $legacy_flag = $legacy_features{"$cluster_id/$attr_id"};
    MATTERDevice_SetAttributeIfNotExists($name, $legacy_flag, 1) if $legacy_flag;

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
        }
        if ($is_attribute) {
            MATTERDevice_SetAttributeIfNotExists($name, $attr_name, $value);
        }
        if ($attr_name eq "brightness") {
            # Metadata and user overrides are interpreted consistently with
            # the set slider and outgoing LevelControl commands.
            my $max_level = MATTERDevice_MaxBrightness($hash);
            my $pct_value = int($value * 100 / $max_level);
            $pct_value = 100 if $pct_value > 100;
            readingsBulkUpdate($hash, "pct", $pct_value);
        }
    }


    readingsEndUpdate($hash, 1);
    # Model on endpoint 0 identifies the physical node, not a single function.
    MATTERDevice_SyncNodeReadings($hash)
        if $cluster_id == 0x0028 && $attr_id == 0x0003 && ($hash->{endpoint_id} // 0) == 0;
}

sub MATTERDevice_Parse($ $) {
    my ($hash, $data) = @_;
    my $name = $hash->{NAME};

    my $decoded = eval { decode_json($data) };
    if ($@ || ref($decoded) ne 'HASH') {
        Log3 $name, 3, "MATTERDevice: Invalid JSON object";
        return;
    }

    my $my_endpoint = $hash->{endpoint_id} // 0;
    my $io_name = $hash->{IODev} ? $hash->{IODev}{NAME} :
                  AttrVal($name, 'IODev', '');
    my $root = $my_endpoint == 0 ? $hash :
        $modules{MATTERDevice}{defptr}{"$io_name:$hash->{node_id}"};
    # The root owns availability for every child; an endpoint's local state
    # or old available reading is not a separate reachability report.
    my $allow_device_attr = sub {
        my ($live) = @_;
        return 1 unless $root;
        return 0 if ReadingsVal($root->{NAME}, 'available', '') eq 'false';
        return 0 if !$live && $root->{helper}{quarantine_snapshots};
        return 1;
    };

    # Availability is node-wide; missing/invalid values are not state reports.
    my $update_available = sub { MATTERDevice_UpdateAvailability($hash, $_[0]) };
    
    # Hilfs-Subroutine zur internen Weiterleitung an Root oder Child
    my $route_attribute = sub {
        my ($ep, $cluster, $attr, $val, $live) = @_;
        # Offline snapshots can still tell us which endpoint IDs exist.
        # Preserve FHEM identity/association without importing device data.
        if (!$allow_device_attr->($live)) {
            if ($my_endpoint == 0 && $ep > 0) {
                MATTERDevice_GetOrCreateChild($hash, $ep);
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
                MATTERDevice_ProcessAttributeValue($childHash, $cluster, $attr, $val);
            }
        }
    };

    # 1. ANTWORT AUF GETCONFIG (enthält "result")
    if (exists $decoded->{result} && ref($decoded->{result}) eq 'HASH') {
        # Never reset current capability metadata from a cached response
        # while the root is offline or still awaiting fresh live data.
        if (!$allow_device_attr->(0)) {
            if ($my_endpoint == 0) {
                for my $path (keys %{$decoded->{result}}) {
                    MATTERDevice_GetOrCreateChild($hash, $1)
                        if $path =~ m{^([1-9]\d*)/\d+/\d+$};
                }
            }
            return;
        }
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

        for my $path (sort {
            ($a =~ m{/29/0$} ? 0 : 1) <=> ($b =~ m{/29/0$} ? 0 : 1)
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
        if (defined($node_id) && $hash->{node_id} eq $node_id && exists($node->{available})) {
            $update_available->($node->{available});
            Log3 $name, 4, "MATTERDevice: Node $node_id availability = " . ($node->{available} ? "true" : "false");
        }
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
                      $cluster == 0x003B &&
                      defined($id) && !ref($id) && $id =~ /^\d+$/;
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
        my $child = MATTERDevice_GetOrCreateChild($hash, $ep);
        return unless $child;
        readingsSingleUpdate($child, 'button', $value, 0);
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
            $route_attribute->($1, $2, $3, $value, 1);
            Log3 $name, 4, "MATTERDevice: Live attribute update ($attribute_path)";
        }
        return;
    }

    # 4. INITIAL DISCOVER / START_LISTENING (node_id + attributes/availability)
    my $node_id    = $decoded->{node_id};
    my $attributes = $decoded->{attributes};
    
    if (defined($node_id) && $hash->{node_id} eq $node_id) {
        $update_available->($decoded->{available}) if exists($decoded->{available});

        if ($attributes && ref($attributes) eq 'HASH') {
            for my $path (sort {
                ($a =~ m{/29/0$} ? 0 : 1) <=> ($b =~ m{/29/0$} ? 0 : 1)
            } keys %{$attributes}) {
                my $value = $attributes->{$path};
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

    if (($hash->{endpoint_id} // 0) == 0 &&
        (ReadingsVal($name, 'ota_update_state', '') ne '' ||
         $hash->{helper}{seen_clusters}{42})) {
        $add->("checkFirmwareUpdate:noArg");
        $add->("updateFirmware:noArg")
            if defined($hash->{helper}{firmware_available});
    }
    if (($hash->{endpoint_id} // 0) == 0 &&
        ReadingsVal($name, 'icd_supported', '') eq 'true') {
        my $schema = $hash->{IODev} ?
            ReadingsVal($hash->{IODev}{NAME}, 'schema_version', 0) : 0;
        my $features = $hash->{helper}{capabilities}{70}{feature_map};
        if (defined($schema) && $schema =~ /^\d+$/ && $schema >= 12 &&
            defined($features) && !ref($features) && $features =~ /^\d+$/ &&
            ($features & 1)) {
            $add->("icdRegister:noArg");
            $add->("icdUnregister:noArg");
            $add->("icdResync:noArg");
        }
    }
    $add->("identify:noArg")
        if MATTERDevice_CommandSupported($hash, 0x0003, 0x00);
    $add->("desired-temp:slider,5,0.5,30,1")
        if MATTERDevice_AttributeSupported($hash, 0x0201, 0x0012);
    $add->("mode:off,heat,cool,auto,emergency_heat")
        if MATTERDevice_AttributeSupported($hash, 0x0201, 0x001C);
    $add->("fan_mode:off,low,medium,high,on,auto")
        if MATTERDevice_AttributeSupported($hash, 0x0202, 0x0000);
    $add->("fan_pct:slider,0,1,100")
        if MATTERDevice_AttributeSupported($hash, 0x0202, 0x0002);

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
        $add->("brightness:slider,0,1,$max_level");
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
            next if $reading eq 'model' &&
                (ReadingsVal($root->{NAME}, 'available', '') eq 'false' ||
                 $root->{helper}{quarantine_snapshots});
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
        readingsEndUpdate($child, 1);
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

    unless ($child) {
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

<a name="MATTERDevice"></a>
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
  <li><b>Attributes:</b> <code>has_onoff</code>, <code>has_level</code>,
      <code>has_ct</code>, <code>has_xy</code> and other capability flags;
      existing user overrides are respected.</li>
  <li><b>Offline attribute protection:</b> No cached device attributes or capability
metadata are imported when the root reports <code>available=false</code>.
After recovery, only new live attribute events are accepted while stale
snapshot freshness cannot be proven. Local manual reading changes remain
untouched. The Matter server cache is not modified.</li>
  <li><b>Root state:</b> Without a <code>stateFormat</code> attribute, the root's
      <code>state</code> reading shows <code>online</code> or <code>offline</code>
      only after valid <code>available=true/false</code> from the server,
      <code>unknown</code> when no current report is known or the Matter IO loses
      its connection, and <code>removed</code> when the server removes the node
      or omits it from a complete snapshot. Root status is independent of
      endpoint states. No polling is used.</li>
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
  <li><b>Capabilities:</b> Supported set commands use the Matter
      <code>AcceptedCommandList</code>, <code>FeatureMap</code> and other cluster
      metadata when available. Existing <code>has_*</code> values remain a fallback;
      manually setting a feature flag to <code>0</code> disables that control.</li>
  <li><b>New readings:</b> PowerSource, SmokeCO alarm, CO concentration, electrical
      power and cumulative energy clusters, where the server supplies the
      corresponding attributes.</li>
</ul>
<h4>Hardware validation status</h4>
<p>The following classes are implemented but have no class-wide hardware validation
recorded in this repository. <strong>untested</strong> refers to missing documented
physical-device verification, not missing source or automated tests. Even testing
one model cannot establish support for all models sharing the cluster.</p>
<table><tr><th>Device class</th><th>Matter cluster</th><th>Hardware status</th></tr>
<tr><td>OnOff lights / on-off plugs</td><td>OnOff, LevelControl</td><td><strong>untested</strong></td></tr>
<tr><td>Color / color-temperature lights</td><td>ColorControl</td><td><strong>untested</strong></td></tr>
<tr><td>Window coverings / blinds</td><td>WindowCovering</td><td><strong>untested</strong></td></tr>
<tr><td>Thermostats / fans / Identify</td><td>Thermostat, FanControl, Identify</td><td><strong>untested</strong></td></tr>
<tr><td>Door locks</td><td>DoorLock</td><td><strong>untested</strong></td></tr>
<tr><td>Battery / power sources</td><td>PowerSource</td><td><strong>untested</strong></td></tr>
<tr><td>Smoke / carbon-monoxide alarms</td><td>SmokeCoAlarm</td><td><strong>untested</strong></td></tr>
<tr><td>Electrical metering</td><td>ElectricalPowerMeasurement, ElectricalEnergyMeasurement</td><td><strong>untested</strong></td></tr>
<tr><td>Air quality / CO concentration</td><td>AirQuality, CarbonMonoxideConcentrationMeasurement</td><td><strong>untested</strong></td></tr>
</table>
<p>Thermostat (measured/desired temperature and system mode), FanControl
(mode and percent speed) and Identify (15 seconds) are supported when the
required Matter attributes/commands are advertised. Thermostat, fan and
Identify device combinations are <strong>untested</strong> in this repository.
Command acceptance does not assert that the physical state has changed.</p>
<p>Server-backed Matter OTA: root nodes with OTA Requestor support can
<code>checkFirmwareUpdate</code> and, after an update version is confirmed,
<code>updateFirmware</code>. Image download, hosting and installation remain
with matterjs-server; no firmware upload and no automatic update.
Server acknowledgement is not proof of installation. Hardware
<strong>untested</strong>.</p>
<p>ICD Management: passive <code>icd_supported</code>,
<code>icd_lit_supported</code>, <code>icd_operating_mode</code> and
<code>icd_idle_mode_duration</code> readings. Positively recognized ICD
roots on compatible servers offer asynchronous <code>get icdState</code>,
plus conservative <code>icdRegister</code>, <code>icdUnregister</code> and
<code>icdResync</code> where Check-In support is advertised. The server
owns registration and availability; <code>awake=false</code> is not offline.
Hardware validation: <strong>untested</strong>.</p>
<p>Root <code>diagnostics=1</code> enables passive Thread/Wi-Fi diagnostics.
Device <code>rawReadings=1</code> exposes limited non-sensitive unmatched
attributes. Both default to off, add no polling, retain existing readings
on disable, and are <strong>untested</strong> on hardware.</p>
<p>Native LevelControl dimming: <code>dim_up</code>, <code>dim_down</code>,
<code>dim_step_up</code>, <code>dim_step_down</code> and <code>dim_stop</code>
only when the corresponding commands are advertised. Optional per-device
<code>dimRate</code> (1–254, default 30) sets the speed for continuous dimming.
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

<a name="MATTERDevice"></a>
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
  <li><b>Attribute:</b> <code>has_onoff</code>, <code>has_level</code>,
      <code>has_ct</code>, <code>has_xy</code> und weitere Fähigkeitsattribute;
      vorhandene Benutzervorgaben werden nicht überschrieben.</li>
  <li><b>Offline-Attributsperre:</b> Bei <code>available=false</code> werden
keine zwischengespeicherten Geräteattribute oder Capability-Metadaten aus
Matter übernommen. Nach Wiederherstellung werden neue Live-Attribute
akzeptiert, solange die Frische eines Snapshots nicht nachweisbar ist.
Manuelle lokale Reading-Änderungen bleiben erhalten.</li>
  <li><b>Root-Status:</b> Ohne <code>stateFormat</code>-Attribut zeigt das
      <code>state</code>-Reading am Root <code>online</code> oder
      <code>offline</code> nur nach einer gültigen <code>available=true/false</code>-
      Meldung des Servers, <code>unknown</code> ohne bestätigte aktuelle Meldung
      oder bei Ausfall der Matter-IO-Verbindung und <code>removed</code> bei
      Entfernung aus dem Matter-Server oder einer vollständigen Node-Liste.
      Endpunkt-Zustände bleiben unverändert. Es erfolgt kein Polling.</li>
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
  <li><b>Capabilities:</b> Unterstützte Set-Befehle werden nach Möglichkeit
      anhand der Matter-Metadaten wie <code>AcceptedCommandList</code> und
      <code>FeatureMap</code> bestimmt. Vorhandene <code>has_*</code>-Attribute
      bleiben als Fallback erhalten; ein manuelles <code>0</code> deaktiviert
      die jeweilige Funktion.</li>
  <li><b>Weitere Readings:</b> PowerSource, SmokeCO-Alarm,
      Kohlenmonoxidkonzentration, elektrische Leistung und kumulierte Energie,
      soweit die Geräte die jeweiligen Attribute liefern.</li>
</ul>
<h4>Hardware-Teststatus</h4>
<p>Die folgenden Geräteklassen sind implementiert, aber es liegt im Repository
kein klassenweiter Hardware-Nachweis vor. <strong>ungetestet</strong> bedeutet:
keine dokumentierte Prüfung am realen Gerät; es bedeutet nicht, dass Code oder
automatisierte Tests fehlen. Ein getestetes Modell belegt nicht alle Modelle
mit demselben Matter-Cluster.</p>
<table><tr><th>Geräteklasse</th><th>Matter-Cluster</th><th>Hardwarestatus</th></tr>
<tr><td>Schaltbare Leuchten / Steckdosen</td><td>OnOff, LevelControl</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Farb-/Farbtemperaturleuchten</td><td>ColorControl</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Rollläden / Jalousien</td><td>WindowCovering</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Thermostate / Lüfter / Identify</td><td>Thermostat, FanControl, Identify</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Türschlösser</td><td>DoorLock</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Batterien / Stromversorgung</td><td>PowerSource</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Rauch-/CO-Warnmelder</td><td>SmokeCoAlarm</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Elektrische Messwerte</td><td>ElectricalPowerMeasurement, ElectricalEnergyMeasurement</td><td><strong>ungetestet</strong></td></tr>
<tr><td>Luftqualität / CO-Konzentration</td><td>AirQuality, CarbonMonoxideConcentrationMeasurement</td><td><strong>ungetestet</strong></td></tr>
</table>
<p>Thermostat (Ist-/Solltemperatur und Betriebsmodus), FanControl
(Modus und Prozentgeschwindigkeit) und Identify (15 Sekunden) sind nur bei
vorhandenen Matter-Attributen/Befehlen verfügbar. Thermostat-/Lüfter-
Geräte und Identify-Kombinationen sind <strong>ungetestet</strong>.
Ein angenommener Befehl bestätigt keine physische Zustandsänderung.</p>
<p>Servergestütztes Matter-OTA: Root-Knoten mit OTA Requestor bieten
<code>checkFirmwareUpdate</code> und nach nachgewiesener Versionsfreigabe
<code>updateFirmware</code>. Download, Hosting und Installation übernimmt
matterjs-server. Kein Upload und kein automatisches Update. Die Serverannahme
bestätigt noch keine erfolgreiche Installation. Hardware
<strong>ungetestet</strong>.</p>
<p>ICD Management: passive Readings <code>icd_supported</code>,
<code>icd_lit_supported</code>, <code>icd_operating_mode</code> und
<code>icd_idle_mode_duration</code>. Für bestätigte ICD-Root-Knoten am
kompatiblen Matter-Server stehen asynchrones <code>get icdState</code> und
bei passender Check-In-Fähigkeit die konservativen Befehle
<code>icdRegister</code>, <code>icdUnregister</code>, <code>icdResync</code>
zur Verfügung. Der Server verwaltet die Registrierung; 
<code>awake=false</code> ist nicht gleich offline. Hardwarestatus
<strong>ungetestet</strong>.</p>
<p>Root-Attribut <code>diagnostics=1</code> aktiviert passive Thread-/WLAN-
Diagnose. <code>rawReadings=1</code> zeigt begrenzte, nicht sensitive
unbekannte Attribute. Beides ist standardmäßig aus, verursacht kein Polling,
löscht vorhandene Readings beim Abschalten nicht und ist an Hardware
<strong>ungetestet</strong>.</p>
<p>Natives LevelControl-Dimmen: <code>dim_up</code>, <code>dim_down</code>,
<code>dim_step_up</code>, <code>dim_step_down</code> und <code>dim_stop</code>
nur bei gemeldeten Befehlen. <code>dimRate</code> (1–254, Standard 30) legt
die Geschwindigkeit für kontinuierliches Dimmen pro Gerät fest. Keine
FHEM-Dimmschleife; Hardwarevarianten <strong>ungetestet</strong>.</p>
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

=end html
=cut