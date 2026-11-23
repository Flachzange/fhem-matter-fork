#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON qw(encode_json);
use IO::Socket::INET;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use vars qw(%defs %attr %modules %selectlist $readingFnAttributes $init_done);

BEGIN { $INC{'HttpUtils.pm'} = 1; } # No FHEM network stack is needed by these simulated callbacks.

my @log;
my @direct_events;
sub DoTrigger { push @direct_events, [@_]; }
my @timers;
my %bulk_writes;
my %single_writes;
my $preferred_io = 'ioA';
my $fail_io_for = '';
my $reading_event_hook;

sub Log3 { push @log, $_[2]; }
sub AttrVal { return exists $attr{$_[0]}{$_[1]} ? $attr{$_[0]}{$_[1]} : $_[2]; }
sub ReadingsVal {
    my ($name, $reading, $default) = @_;
    return $default unless exists($defs{$name}) &&
                           exists($defs{$name}{READINGS}) &&
                           exists($defs{$name}{READINGS}{$reading});
    return $defs{$name}{READINGS}{$reading}{VAL} // $default;
}
sub readingsSingleUpdate {
    my ($device, $reading, $value) = @_;
    $single_writes{$device->{NAME}}{$reading}++;
    $device->{READINGS}{$reading} = { VAL => $value, TIME => 'test-time' };
    $reading_event_hook->($device, $reading, $value) if $reading_event_hook;
}
sub readingsBeginUpdate { return; }
sub readingsBulkUpdate {
    $bulk_writes{$_[0]{NAME}}{$_[1]}++;
    readingsSingleUpdate($_[0], $_[1], $_[2]);
}
sub readingsEndUpdate { return; }
sub readingsDelete {
    my ($device, $reading) = @_;
    delete $device->{READINGS}{$reading};
}
sub RemoveInternalTimer {
    my ($owner, $callback) = @_;
    @timers = grep {
        !($_->{owner} eq $owner &&
          (!defined($callback) || $_->{callback} eq $callback))
    } @timers;
}
sub InternalTimer { push @timers, { at => $_[0], callback => $_[1], owner => $_[2] }; }
my $mock_time = 1;
sub gettimeofday { return $mock_time; }
# fhem.pl TimeNow returns local wall-clock time in this format. Keep the
# clock deterministic so repeated unchanged messages can advance reception.
sub TimeNow { return sprintf('2026-11-18 12:00:%02d', $mock_time % 60); }

# FHEMWEB URL and HTML helpers as used by FW_detailFn.
sub urlEncode {
    my ($value) = @_;
    $value =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/eg;
    return $value;
}
sub FW_htmlEscape {
    my ($value) = @_;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

# Model the relevant FHEM Define/Attr side effects, not just successful return values.
sub AssignIoPort {
    my ($device) = @_;
    return unless $defs{$preferred_io};
    $device->{IODev} = $defs{$preferred_io};
    readingsSingleUpdate($device, 'IODev', $preferred_io);
    return $device->{IODev};
}
sub CommandDefine {
    my (undef, $definition) = @_;
    my ($name, $type, @args) = split /\s+/, $definition;
    return "Device already exists" if $defs{$name};
    return "Only MATTERDevice is modeled" unless $type eq 'MATTERDevice';
    my $device = {
        NAME => $name, TYPE => $type, DEF => join(' ', @args),
        STATE => '???', READINGS => {}, FUUID => "uuid-$name",
    };
    $defs{$name} = $device;
    my $err = MATTERDevice_Define($device, "$name $type " . join(' ', @args));
    if ($err) { delete $defs{$name}; return $err; }
    return undef;
}
# Model fhem.pl CommandModify: update DEF, call DefFn again and roll back
# the definition on an error without replacing the existing device hash.
sub CommandModify {
    my (undef, $definition) = @_;
    my ($name, @args) = split /\s+/, $definition;
    return "Device missing" unless $defs{$name};
    my $device = $defs{$name};
    my $old_def = $device->{DEF};
    $device->{DEF} = join(' ', @args);
    my $err = MATTERDevice_Define($device, "$name MATTERDevice " . join(' ', @args));
    $device->{DEF} = $old_def if $err;
    return $err;
}
sub CommandAttr {
    my (undef, $command) = @_;
    my ($name, $key, $value) = split /\s+/, $command, 3;
    return "Device missing" unless $defs{$name};
    # Match fhem.pl CommandAttr -> getAllAttr: FHEM accepts global attrs and the
    # module-declared AttrList, rejecting undeclared device attributes.
    # The production failure was previously hidden by this permissive stub.
    my $global_attrs = 'alias comment:textField-long eventMap:textField-long ' .
                       'group room suppressReading userattr userReadings:textField-long ' .
                       'verbose:0,1,2,3,4,5';
    my $module_attrs = $modules{$defs{$name}{TYPE}}{AttrList} // '';
    my $known_attr = grep {
        my ($pattern) = split /:/, $_, 2;
        $key =~ /^(?:$pattern)$/
    } split /\s+/, "$global_attrs $module_attrs";
    return "$name: unknown attribute $key" unless $known_attr;
    return "Simulated IODev failure" if $key eq 'IODev' && $name eq $fail_io_for;
    if ($defs{$name}{TYPE} eq 'MATTERDevice' && $modules{MATTERDevice}{AttrFn}) {
        my $error = MATTERDevice_Attr('set', $name, $key, $value);
        return $error if defined $error;
    }
    if ($key eq 'IODev') {
        return "Unknown IODev" unless $defs{$value} && $defs{$value}{TYPE} eq 'MATTER';
        $defs{$name}{IODev} = $defs{$value};
        $defs{$name}{READINGS}{IODev} = { VAL => $value, TIME => 'test-time' };
    }
    # FHEM invokes AttrFn before updating the attribute map.
    if ($defs{$name}{TYPE} eq 'MATTER') {
        my $error = MATTER_Attr('set', $name, $key, $value);
        return $error if defined($error);
    }
    $attr{$name}{$key} = $value;
    # fhem.pl CommandAttr triggers global ATTR after fhem_setIoDev succeeds.
    MATTERDevice_Notify($defs{$name}, { NAME => 'global', CHANGED => ["ATTR $command"] })
        if $init_done && $defs{$name}{TYPE} eq 'MATTERDevice';
    return undef;
}
sub CommandDeleteAttr {
    my (undef, $command) = @_;
    my ($name, $key) = split /\s+/, $command, 2;
    return "Device missing" unless $defs{$name};
    if ($defs{$name}{TYPE} eq 'MATTER') {
        my $error = MATTER_Attr('del', $name, $key, undef);
        return $error if defined($error);
    }
    if ($defs{$name}{TYPE} eq 'MATTERDevice') {
        my $error = MATTERDevice_Attr('del', $name, $key, undef);
        return $error if defined($error);
    }
    if (defined $key) {
        delete $attr{$name}{$_} for grep { /^$key$/ } keys %{$attr{$name} // {}};
    } else {
        delete $attr{$name};
    }
    MATTERDevice_Notify($defs{$name}, { NAME => 'global', CHANGED => ["DELETEATTR $command"] })
        if $init_done && $defs{$name}{TYPE} eq 'MATTERDevice';
    return undef;
}
sub CommandDelete {
    my (undef, $name) = @_;
    return "Device missing" unless $defs{$name};
    MATTERDevice_Undef($defs{$name}, $name) if $defs{$name}{TYPE} eq 'MATTERDevice';
    delete $defs{$name};
    delete $attr{$name};
    return undef;
}

# Model the relevant fhem.pl CommandRename side effect: existing
# associatedWith readings automatically follow a renamed device.
sub CommandRename {
    my (undef, $command) = @_;
    my ($old, $new) = split /\s+/, $command;
    return 'Device missing' unless $defs{$old};
    return 'Name exists' if $defs{$new};
    $defs{$new} = delete $defs{$old};
    $defs{$new}{NAME} = $new;
    $attr{$new} = delete $attr{$old} if exists $attr{$old};
    # FHEM runs the device RenameFn before rewriting associatedWith references.
    my $rename_fn = $modules{$defs{$new}{TYPE}}{RenameFn};
    $rename_fn->($new, $old) if $rename_fn;
    for my $device (values %defs) {
        my $links = ReadingsVal($device->{NAME}, 'associatedWith', '');
        next unless $links =~ /\b\Q$old\E\b/;
        $links =~ s/\b\Q$old\E\b/$new/;
        # FHEM uses setReadingsVal here, which does not publish an event.
        $device->{READINGS}{associatedWith}{VAL} = $links;
    }
    return undef;
}

# FHEM exports stateFormat through readingFnAttributes, not the global list.
$readingFnAttributes = 'stateFormat:textField-long';
require './FHEM/97_MATTERDevice.pm';
require './FHEM/97_MATTER.pm';

# Capture or reject encoded messages only for fixtures that request it.
# Socket-based protocol tests keep the real WebSocket framing and writer.
my $write_text = \&MATTER_SendWebSocketText;
local *MATTER_SendWebSocketText = sub ($$) {
    my ($io, $text) = @_;
    return $io->{test_send_text}->($text) if $io->{test_send_text};
    return $write_text->($io, $text);
};

# FHEM calls Initialize before Define/CommandAttr; expose the real module AttrList.
MATTERDevice_Initialize($modules{MATTERDevice} ||= {});
MATTER_Initialize($modules{MATTER} ||= {});
ok(!$modules{MATTER}{GetFn}, 'IO registers no get callback');
is($modules{MATTERDevice}{GetFn}, 'MATTERDevice_Get', 'device get callback stays registered');
like($modules{MATTER}{AttrList}, qr/(?:^|\s)autocreate:0,1(?:\s|$)/,
     'MATTER IO exposes autocreate as a configurable 0/1 attribute');
like($modules{MATTER}{AttrList}, qr/(?:^|\s)commissionMode:network,auto(?:\s|$)/,
     'MATTER IO exposes the configurable default commissioning mode');
is(AttrVal('ioA', 'autocreate', 1), 1, 'autocreate defaults to enabled');
is($modules{MATTERDevice}{FW_detailFn}, 'MATTERDevice_FWDetail', 'FHEMWEB detail hook is registered');
ok($modules{MATTERDevice}{FW_deviceOverview}, 'FHEMWEB standard DeviceOverview remains visible');
like($modules{MATTERDevice}{AttrList}, qr/(?:^|\s)IODev(?:\s|$)/,
     'MATTERDevice declares IODev for FHEM CommandAttr');
for my $name (qw(ioA ioB)) {
    $defs{$name} = { NAME => $name, TYPE => 'MATTER', READINGS => {}, helper => {} };
}
my $unknown_attr_result = CommandAttr(undef, 'ioA unknown_attribute 1');
like($unknown_attr_result // '', qr/unknown attribute/,
     'CommandAttr stub rejects attributes absent from FHEM and module lists');

sub node {
    my ($id, $name) = @_;
    return { node_id => $id, name => $name, available => JSON::true,
             attributes => { '1/6/0' => JSON::true,
                             '1/29/0' => [{ '0' => 0x0100, '1' => 1 }] } };
}
sub matter_devices {
    return grep { ($_->{TYPE} // '') eq 'MATTERDevice' } values %defs;
}
sub count_devices { return scalar(matter_devices()); }

my $unknown_start = node(42, 'Hall Light');
delete $unknown_start->{available};
MATTER_ProcessNodeList($defs{ioA}, [$unknown_start], 'start_listening');
my $root = $defs{MATTER_Hall_Light};
my $child = $defs{MATTER_Hall_Light_EP1};
ok($root && $child, 'full snapshot creates root and endpoint');
is($modules{MATTERDevice}{NotifyFn}, 'MATTERDevice_Notify',
   'Matter devices register lifecycle notifications');
is($root->{NOTIFYDEV}, 'global', 'root listens only to FHEM global lifecycle events');
is($child->{NOTIFYDEV}, 'global', 'endpoint notification overhead is also limited to global events');
ok(!exists($attr{MATTER_Hall_Light}{stateFormat}),
   'new root does not need a stateFormat attribute');
ok(!exists($attr{MATTER_Hall_Light_EP1}{stateFormat}),
   'endpoint display format is not overridden');
ok(!exists($root->{READINGS}{available}),
   'missing availability is not fabricated by default');
ok(!exists($root->{READINGS}{state}),
   'root Define during startup leaves statefile restoration undisturbed');
is(CommandAttr(undef, 'MATTER_Hall_Light stateFormat Custom'), undef,
   'user can override root display');
MATTER_ProcessNode($defs{ioA}, node(42, 'Repeated after user format'));
is($attr{MATTER_Hall_Light}{stateFormat}, 'Custom',
   'reconciliation respects a custom root stateFormat');
is(CommandDeleteAttr(undef, 'MATTER_Hall_Light stateFormat'), undef,
   'user can remove custom root stateFormat');
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'Display default'});
ok(!exists($attr{MATTER_Hall_Light}{stateFormat}),
   'a missing root stateFormat stays absent during discovery');
is($root->{DEF}, '42', 'root definition contains only the node ID');
is($child->{DEF}, '42 1', 'endpoint definition contains no root FHEM name');
my $legacy_define = CommandDefine(undef, 'Legacy_Endpoint MATTERDevice 42 9 Former_Root');
is($legacy_define, undef, 'legacy three-argument endpoint DEF is accepted for migration');
is($defs{Legacy_Endpoint}{DEF}, '42 9', 'old root name is removed from persisted DEF at define');
is($defs{Legacy_Endpoint}{endpoint_id}, 9, 'migration retains endpoint identity');
is($defs{Legacy_Endpoint}{node_id}, 42, 'migration retains node identity');
ok(!exists $defs{Legacy_Endpoint}{device}, 'legacy root name is not retained as parent identity');
is(CommandDelete(undef, 'Legacy_Endpoint'), undef, 'temporary legacy test device is removed');
like(CommandDefine(undef, 'Invalid_Endpoint MATTERDevice 42 0') // '',
     qr/wrong syntax/, 'explicit endpoint zero is rejected; roots omit endpoint ID');
# FHEM's CommandDefine starts at STATE=???; its startup setstate restores a
# persisted display state only while that placeholder is untouched.
is($root->{STATE}, '???', 'root Define leaves default STATE for statefile restore');
is($child->{STATE}, '???', 'endpoint Define leaves default STATE for statefile restore');

# FHEM emits INITIALIZED only after config and statefile are both restored.
is(CommandAttr(undef, 'MATTER_Hall_Light stateFormat available'), undef,
   'old V0.15 root format can be restored from FHEM configuration');
delete $root->{READINGS}{state}; # Legacy statefile has no new-style root state.
$defs{global} = { NAME => 'global', CHANGED => ['INITIALIZED'] };
$init_done = 1;
MATTERDevice_Notify($root, $defs{global});
ok(!exists($attr{MATTER_Hall_Light}{stateFormat}),
   'INITIALIZED removes legacy auto stateFormat after config restoration');
is(ReadingsVal('MATTER_Hall_Light', 'state', ''), 'unknown',
   'INITIALIZED invalidates any stale root status');
is(CommandAttr(undef, 'MATTER_Hall_Light stateFormat Custom'), undef,
   'custom FHEM status formatting is supported');
$defs{global}{CHANGED} = ['REREADCFG'];
MATTERDevice_Notify($root, $defs{global});
is($attr{MATTER_Hall_Light}{stateFormat}, 'Custom',
   'REREADCFG leaves user-defined stateFormat intact');
is(CommandDeleteAttr(undef, 'MATTER_Hall_Light stateFormat'), undef,
   'custom display can be removed');
is(CommandAttr(undef, 'MATTER_Hall_Light stateFormat available'), undef,
   'user may explicitly restore available display after migration');
MATTERDevice_Notify($root, $defs{global});
is($attr{MATTER_Hall_Light}{stateFormat}, 'available',
   'post-migration user override is not removed again in the same process');
CommandDeleteAttr(undef, 'MATTER_Hall_Light stateFormat');

# The startup/migration scenario is complete. Use a separate initial-online
# scenario for the following grouping/autocreate/read tests. Real recovery
# is exercised explicitly in the lifecycle subtest.
MATTERDevice_UpdateAvailability($root, JSON::true);

is(CommandDefine(undef, 'Standalone_Root MATTERDevice 999'), undef,
   'manually defined root can be initialized without discovery');
is(ReadingsVal('Standalone_Root', 'state', ''), 'unknown',
   'root created after FHEM init displays unknown until a server report');
ok(!exists($attr{Standalone_Root}{stateFormat}),
   'manual root never auto-creates stateFormat');
ok(!exists($defs{Standalone_Root}{READINGS}{available}),
   'root Define does not invent physical availability');
is(CommandDelete(undef, 'Standalone_Root'), undef,
   'standalone root test device is cleaned up');
is($root->{IODev}{NAME}, 'ioA', 'root IODev is correct');
is($child->{IODev}{NAME}, 'ioA', 'endpoint IODev is correct');
is(ReadingsVal('MATTER_Hall_Light_EP1', 'associatedWith', ''), 'MATTER_Hall_Light',
   'new endpoint links to its root with FHEM native associatedWith reading');
ok(!exists($root->{READINGS}{associatedWith}),
   'root is not given an artificial self-association');
my $initial_association_writes = $bulk_writes{MATTER_Hall_Light_EP1}{associatedWith};
is($initial_association_writes, 1,
   'endpoint association is written once during its initial synchronization');
is($attr{MATTER_Hall_Light}{room}, 'Matter', 'new root gets default room');
is($attr{MATTER_Hall_Light_EP1}{room}, 'Matter', 'new endpoint gets default room');
is($attr{MATTER_Hall_Light}{group}, 'Matter Nodes', 'root gets shared administrative group');
is($attr{MATTER_Hall_Light_EP1}{group}, 'On/Off light', 'endpoint is grouped by the Descriptor device type');
my $initial_html = MATTERDevice_FWDetail('WEB', 'MATTER_Hall_Light', 'Matter');
like($initial_html, qr/href="\?detail=MATTER_Hall_Light_EP1"/,
    'root detail links to existing endpoint');
ok(!defined(MATTERDevice_FWDetail('WEB', 'MATTER_Hall_Light_EP1', 'Matter')),
    'endpoint detail does not show another endpoint overview');
is(ReadingsVal('MATTER_Hall_Light_EP1', 'state', ''), 'on', 'actual attribute path reaches endpoint');
is($modules{MATTERDevice}{defptr}{'ioA:42'}, $root, 'root registered for owning IO');

# Migrate only precisely matching legacy groups; preserve the existing room.
$attr{MATTER_Hall_Light}{group} = 'Node 42 (ioA)';
$attr{MATTER_Hall_Light_EP1}{group} = 'Node 42 (ioA)';
$attr{MATTER_Hall_Light_EP1}{room} = 'EG Wohnzimmer';
MATTER_ProcessNode($defs{ioA}, node(42, 'Hall Light'));
is($bulk_writes{MATTER_Hall_Light_EP1}{associatedWith},
   $initial_association_writes,
   'repeated snapshots do not emit duplicate root association events');
is($attr{MATTER_Hall_Light}{group}, 'Matter Nodes', 'legacy root group is migrated');
is($attr{MATTER_Hall_Light_EP1}{group}, 'On/Off light', 'legacy endpoint group is migrated');
is($attr{MATTER_Hall_Light_EP1}{room}, 'EG Wohnzimmer', 'type grouping does not move a device');

# Disabling autocreate must stop all new FHEM devices, without suppressing
# updates on existing nodes/endpoints or changing the Matter server itself.
is(CommandAttr(undef, 'ioA autocreate 0'), undef,
   'autocreate can be disabled on the MATTER IO device');
my $before_disabled = count_devices();
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_added',
    data => {node_id => 901, name => 'Commissioned while disabled',
             attributes => {'1/6/0' => JSON::true}},
}));
is(count_devices(), $before_disabled,
   'node_added does not create root or child when autocreate is disabled');
ok(!exists($modules{MATTERDevice}{defptr}{'ioA:901'}),
   'disabled autocreate does not register a new root');
MATTER_ProcessNode($defs{ioA}, {
    node_id => 42, name => 'Existing node update',
    attributes => {'1/6/0' => JSON::false, '2/6/0' => JSON::true,
                   '0/29/3' => [1, 2]},
});
is(ReadingsVal('MATTER_Hall_Light_EP1', 'state', ''), 'off',
   'already-defined endpoint still receives live values with autocreate disabled');
ok(!$defs{MATTER_Hall_Light_EP2},
   'unknown endpoint from attribute update and PartsList is not autocreated');
is(count_devices(), $before_disabled,
   'existing node updates do not create any new endpoint devices');
MATTERDevice_Parse($root, encode_json({
    result => {'1/6/0' => JSON::true, '3/6/0' => JSON::true},
}));
is(ReadingsVal('MATTER_Hall_Light_EP1', 'state', ''), 'on',
   'getConfig results still update already-defined endpoints');
ok(!exists($defs{MATTER_Hall_Light_EP3}),
   'getConfig cannot create unknown endpoints while autocreate is disabled');

# Both changing the attribute and deleting it restore the default policy.
is(CommandAttr(undef, 'ioA autocreate 1'), undef,
   'autocreate can be explicitly re-enabled');
MATTER_ProcessNode($defs{ioA}, {
    node_id => 901, name => 'Commissioned while disabled',
    attributes => {'1/6/0' => JSON::true},
});
ok($defs{MATTER_Commissioned_while_disabled} &&
   $defs{MATTER_Commissioned_while_disabled_EP1},
   'subsequent discovery creates missing node and endpoint after enabling');
CommandDelete(undef, 'MATTER_Commissioned_while_disabled_EP1');
CommandDelete(undef, 'MATTER_Commissioned_while_disabled');
delete $attr{ioA}{autocreate};
is(AttrVal('ioA', 'autocreate', 1), 1,
   'removing the autocreate attribute restores default on behavior');

# Different MATTER IO instances must have independent autocreate policies.
is(CommandAttr(undef, 'ioB autocreate 0'), undef,
   'autocreate can be controlled separately on another IO');
my $before_io_b = count_devices();
MATTER_ProcessNode($defs{ioB}, {
    node_id => 902, name => 'Suppressed on B', attributes => {'1/6/0' => JSON::true},
});
is(count_devices(), $before_io_b,
   'disabled autocreate on ioB does not add devices');
MATTER_ProcessNode($defs{ioA}, {
    node_id => 903, name => 'Enabled on A', attributes => {'1/6/0' => JSON::true},
});
ok($defs{MATTER_Enabled_on_A} && $defs{MATTER_Enabled_on_A_EP1},
   'default-enabled ioA still creates its own devices');
CommandDelete(undef, 'MATTER_Enabled_on_A_EP1');
CommandDelete(undef, 'MATTER_Enabled_on_A');
delete $attr{ioB}{autocreate};

$attr{MATTER_Hall_Light}{room} = 'LivingRoom';
$attr{MATTER_Hall_Light}{group} = 'My custom group';
$attr{MATTER_Hall_Light_EP1}{group} = 'My custom endpoint group';
my $count = count_devices();
MATTER_ProcessNodeList($defs{ioA}, [node(42, 'Different server label')], 'get_nodes');
is(count_devices(), $count, 'repeated snapshot does not duplicate devices');
is($attr{MATTER_Hall_Light}{room}, 'LivingRoom', 'existing room is preserved');
is($attr{MATTER_Hall_Light}{group}, 'My custom group', 'custom root group is not overwritten');
is($attr{MATTER_Hall_Light_EP1}{group}, 'My custom endpoint group',
    'custom endpoint group is not overwritten');
delete $attr{MATTER_Hall_Light_EP1}{group};
MATTER_ProcessNode($defs{ioA}, node(42, 'Still same node'));
is($attr{MATTER_Hall_Light_EP1}{group}, 'On/Off light',
    'discovery restores a missing type group on an existing endpoint');

# User-managed associations remain intact when the module links the root.
$child->{READINGS}{associatedWith}{VAL} = 'ExtraDevice,AnotherDevice';
MATTER_ProcessNode($defs{ioA}, node(42, 'Same node with user links'));
is(ReadingsVal($child->{NAME}, 'associatedWith', ''),
   'ExtraDevice,AnotherDevice MATTER_Hall_Light',
   'adding root association preserves existing comma-separated user references');
my $association_writes = $bulk_writes{$child->{NAME}}{associatedWith};
MATTER_ProcessNode($defs{ioA}, node(42, 'Repeated with user links'));
is($bulk_writes{$child->{NAME}}{associatedWith}, $association_writes,
   'multiple existing associatedWith entries do not trigger repeated events');
is(CommandRename(undef, 'MATTER_Hall_Light ManuallyRenamedRoot'), undef,
   'FHEM root rename succeeds without changing Matter IDs');
is(ReadingsVal($child->{NAME}, 'associatedWith', ''),
   'ExtraDevice,AnotherDevice ManuallyRenamedRoot',
   'FHEM automatically rewrites associatedWith when the root is renamed');
MATTER_ProcessNode($defs{ioA}, node(42, 'Yet another label'));
is($bulk_writes{$child->{NAME}}{associatedWith}, $association_writes,
   'discovery after rename does not re-add a stale root or duplicate the new one');
is($defs{ManuallyRenamedRoot}, $root, 'renamed root reused by identity');
is($defs{MATTER_Hall_Light_EP1}, $child, 'renamed root reuses existing endpoint');
is($child->{device}, 'ManuallyRenamedRoot', 'endpoint parent internal updated after rename');

# Confirming an unchanged DEF in FHEMWEB must not restore a stale parent name.
my $child_before_modify = $child->{DEF};
is(CommandModify(undef, "$child->{NAME} $child_before_modify"), undef,
   'confirming the endpoint DEF accepts the two-ID format');
is($child->{DEF}, '42 1', 'modify preserves the stable endpoint definition');
ok(!exists $child->{device}, 'modify clears any cached display-only parent name');
my $child_uuid = $child->{FUUID};
my $child_io = $child->{IODev};
my $child_readings = $child->{READINGS};
is(CommandModify(undef, "$child->{NAME} 42 1 MATTER_Hall_Light"), undef,
   'confirming a stale legacy DEF migrates it instead of reassigning the root');
is($child->{DEF}, '42 1', 'legacy modify is normalized to node ID and endpoint ID');
is($child->{FUUID}, $child_uuid, 'DEF migration preserves FUUID');
is($child->{IODev}, $child_io, 'DEF migration preserves IODev');
is($child->{READINGS}, $child_readings, 'DEF migration preserves readings');
ok(!exists $child->{device}, 'legacy root name does not restore display parent');
like(CommandModify(undef, "$child->{NAME} 42 1 MATTER_Hall_Light extra") // '',
     qr/wrong syntax/, 'unrecognized extra DEF arguments remain invalid');
is($child->{DEF}, $child_before_modify, 'invalid modify rolls back the DEF');
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'Metadata only'});
is($child->{device}, 'ManuallyRenamedRoot',
   'metadata-only discovery recovers display parent from node identity');
is(ReadingsVal($child->{NAME}, 'associatedWith', ''),
   'ExtraDevice,AnotherDevice ManuallyRenamedRoot',
   'metadata-only discovery retains native root association after endpoint modify');
is($defs{$child->{NAME}}, $child, 'reconfirmed endpoint does not get recreated');

# Migration must work without any fresh endpoint attributes.
delete $attr{MATTER_Hall_Light_EP1}{group};
my $prior_devices = count_devices();
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'Metadata only'});
is($attr{MATTER_Hall_Light_EP1}{group}, 'On/Off light',
   'cached Descriptor type restores a missing group without new attributes');
is(count_devices(), $prior_devices, 'group migration never recreates the endpoint');

# Persisted IODev identifies the endpoint even when its runtime pointer is missing.
delete $attr{MATTER_Hall_Light_EP1}{group};
delete $child->{IODev};
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'No endpoint attributes'});
is($attr{MATTER_Hall_Light_EP1}{group}, 'On/Off light',
   'configured IODev is sufficient to migrate an endpoint without runtime IODev');
like(MATTERDevice_FWDetail('WEB', 'ManuallyRenamedRoot', 'Matter'),
     qr/MATTER_Hall_Light_EP1/, 'root detail also finds endpoint with configured IODev');
is(CommandAttr(undef, 'MATTER_Hall_Light_EP1 IODev ioA'), undef,
   'runtime IODev is restored for subsequent test cases');

$defs{MATTER_Conflicted} = { NAME => 'MATTER_Conflicted', TYPE => 'dummy' };
$defs{MATTER_Conflicted_43_EP1} = { NAME => 'MATTER_Conflicted_43_EP1', TYPE => 'dummy' };
MATTER_ProcessNode($defs{ioA}, node(43, 'Conflicted'));
ok($defs{MATTER_Conflicted_43}, 'root name collision handled');
ok($defs{MATTER_Conflicted_43_EP1_43}, 'endpoint name collision handled');
is($defs{MATTER_Conflicted_43_EP1}{TYPE}, 'dummy', 'unrelated device is unchanged');

$preferred_io = 'ioA';
MATTER_ProcessNode($defs{ioB}, node(42, 'Other IO light'));
my $other_root = $defs{MATTER_Other_IO_light};
ok($other_root, 'same numeric node ID may exist on another IODev');
is(ReadingsVal('MATTER_Other_IO_light_EP1', 'associatedWith', ''),
   'MATTER_Other_IO_light', 'second IO endpoint links only to its own root');
is(ReadingsVal($child->{NAME}, 'associatedWith', ''),
   'ExtraDevice,AnotherDevice ManuallyRenamedRoot',
   'node with the same ID on another IO does not change existing root links');
is($modules{MATTERDevice}{defptr}{'ioA:42'}, $root, 'other IO root registry restored after temporary AssignIoPort');
is($modules{MATTERDevice}{defptr}{'ioB:42'}, $other_root, 'new IO root registry assigned');
# The endpoint has the same node ID as an endpoint on ioB. After losing
# its runtime IODev and parent display name, its persisted IODev attribute
# must prevent reassignment to the wrong MATTER server.
delete $child->{IODev};
$child->{device} = $other_root->{NAME};
MATTER_ProcessNode($defs{ioB}, node(42, 'Other IO light'));
ok(!$child->{IODev}, 'other IO discovery cannot steal a child with a different IODev attribute');
MATTER_ProcessNode($defs{ioA}, node(42, 'Hall Light'));
is($child->{IODev}{NAME}, 'ioA',
   'correct IO rebinds a child without trusting its previous root name');
is($defs{MATTER_Other_IO_light_EP1}{IODev}{NAME}, 'ioB', 'new endpoint binds to matching IO');
ok(!exists($attr{MATTER_Other_IO_light}{stateFormat}),
   'other Matter IO root uses its native state without stateFormat');
ok(!exists($attr{MATTER_Other_IO_light_EP1}{stateFormat}),
   'other Matter IO endpoint retains its own display');
is($attr{MATTER_Other_IO_light}{group}, 'Matter Nodes',
    'different IO root also joins the administrative root group');
is($attr{MATTER_Other_IO_light_EP1}{group}, 'On/Off light',
    'other IO endpoint has the same type group');
my $io_a_html = MATTERDevice_FWDetail('WEB', 'ManuallyRenamedRoot', 'Matter');
unlike($io_a_html, qr/MATTER_Other_IO_light_EP1/,
    'root details exclude endpoints belonging to another IO');

delete $attr{MATTER_Hall_Light_EP1}{group};
delete $attr{MATTER_Other_IO_light_EP1}{group};
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'Metadata only'});
is($attr{MATTER_Hall_Light_EP1}{group}, 'On/Off light',
   'only the matching IO endpoint is grouped during node reconciliation');
ok(!exists($attr{MATTER_Other_IO_light_EP1}{group}),
   'a same-ID endpoint belonging to another IO is not modified');
MATTER_ProcessNode($defs{ioB}, {node_id => 42, name => 'Metadata only'});
is($attr{MATTER_Other_IO_light_EP1}{group}, 'On/Off light',
   'second IO independently migrates its own endpoint');

MATTER_ProcessNodeList($defs{ioA}, [], 'get_nodes');
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'removed', 'missing node marked removed');
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'removed',
   'missing node receives removed as native root status');
ok($defs{ManuallyRenamedRoot}, 'removed node not deleted');
is(ReadingsVal('MATTER_Other_IO_light', 'matter_status', ''), 'present', 'other IO status untouched');
my $reappearing = node(42, 'Hall Light');
delete $reappearing->{available};
MATTER_ParseMessage($defs{ioA}, encode_json({event => 'node_added', data => $reappearing}));
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'present', 'node_added restores status');
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'unknown',
   'reappearing node without reported reachability is unknown');

MATTER_ProcessNodeList($defs{ioA}, [{ node_id => 'invalid' }], 'get_nodes');
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'present', 'malformed snapshot cannot mark devices removed');

MATTER_ProcessNode($defs{ioA}, {node_id => 42, available => JSON::true});
MATTER_ProcessNode($defs{ioB}, {node_id => 42, available => JSON::false});
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'online',
   'availability true before an IO failure means online');
is(ReadingsVal('MATTER_Other_IO_light', 'state', ''), 'offline',
   'same node ID may have a distinct state on another IO');
$defs{ioA}{helper}{pending_command}{17} = 'get_nodes';
$defs{ioA}{helper}{pending_config}{18} = { node_id => 42 };
my $child_state_before_close = ReadingsVal($child->{NAME}, 'state', '');
MATTER_Close($defs{ioA});
ok(!exists($defs{ioA}{helper}{pending_command}), 'close clears pending commands');
ok(!exists($defs{ioA}{helper}{pending_config}), 'close clears pending configuration reads');
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'unknown',
   'IO closure invalidates only the owning root status');
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'true',
   'IO closure preserves last Matter server availability report');
is(ReadingsVal($child->{NAME}, 'state', ''), $child_state_before_close,
   'IO closure does not overwrite endpoint physical state');
is(ReadingsVal('MATTER_Other_IO_light', 'state', ''), 'offline',
   'another Matter IO root is not changed by unrelated socket loss');
my $unknown_events = $single_writes{ManuallyRenamedRoot}{state} // 0;
MATTER_Close($defs{ioA});
is($single_writes{ManuallyRenamedRoot}{state} // 0, $unknown_events,
   'repeated IO close does not produce duplicate unknown state events');
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'No new reachability'});
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'unknown',
   'attribute-free reconnect snapshot cannot reuse stale available=true');
MATTER_ProcessNode($defs{ioA}, {node_id => 42, available => JSON::true});
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'online',
   'fresh availability after reconnect restores online');

# Restore logical ownership after losing runtime IODev pointers (rereadcfg/reload case).
delete $root->{IODev};
MATTER_ProcessNode($defs{ioA}, node(42, 'Hall Light'));
is($root->{IODev}{NAME}, 'ioA', 'existing root restores configured IODev');
is($defs{ManuallyRenamedRoot}, $root, 'rebind does not replace the root FUUID');
delete $child->{IODev};
$child->{device} = 'Nonexistent_Former_Root';
MATTER_ProcessNode($defs{ioA}, node(42, 'Hall Light'));
is($child->{IODev}{NAME}, 'ioA', 'existing endpoint restores configured IODev');
is($child->{device}, 'ManuallyRenamedRoot',
   'endpoint rebind ignores an obsolete display parent name');
is($defs{MATTER_Hall_Light_EP1}, $child, 'rebind does not replace endpoint');

# Failed FHEM IODev assignment must not leave a misbound autocreated device.
$fail_io_for = 'MATTER_IOFailure';
MATTER_ProcessNode($defs{ioB}, node(77, 'IOFailure'));
ok(!exists($defs{MATTER_IOFailure}), 'failed root IODev assignment rolls back new device');
ok(!exists($modules{MATTERDevice}{defptr}{'ioB:77'}), 'failed assignment does not claim target IO');
$fail_io_for = '';

# Multiple endpoints are sorted numerically; links use current names after rename.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 42, name => 'Multi Outlet',
    attributes => { '3/6/0' => JSON::true, '1/6/0' => JSON::true,
                    '2/6/0' => JSON::false,
                    '2/29/0' => [{ '0' => 0x010A, '1' => 1 }] },
});
my $multiple_html = MATTERDevice_FWDetail('WEB', 'ManuallyRenamedRoot', 'Matter');
like($multiple_html, qr/MATTER_Hall_Light_EP1.*ManuallyRenamedRoot_EP2.*ManuallyRenamedRoot_EP3/s,
    'endpoint links are ordered by numeric endpoint ID after root rename');
MATTER_ParseMessage($defs{ioA}, encode_json({event => 'attribute_updated',
    data => [42, '2/29/0', [{'0' => 0x010A, '1' => 1}]]}));
is($attr{ManuallyRenamedRoot_EP2}{group}, 'On/Off plug-in unit',
    'new endpoint receives its own Descriptor type group');

my $old_child_name = $child->{NAME};
delete $defs{$old_child_name};
my $new_child_name = 'Renamed&Endpoint';
$child->{NAME} = $new_child_name;
$defs{$new_child_name} = $child;
$attr{$new_child_name} = delete $attr{$old_child_name};
my $renamed_html = MATTERDevice_FWDetail('WEB', 'ManuallyRenamedRoot', 'Matter');
like($renamed_html, qr/Renamed&amp;Endpoint/, 'endpoint link label is HTML-escaped');
like($renamed_html, qr/\?detail=Renamed%26Endpoint/, 'endpoint link target is URL-encoded');
unlike($renamed_html, qr/\?detail=MATTER_Hall_Light_EP1/,
    'stale endpoint name is not linked');
MATTER_ProcessNode($defs{ioA}, node(42, 'Multi Outlet'));
is($defs{$new_child_name}, $child, 'renamed endpoint stays attached after discovery');
# Restore the original name for the existing capability/measurement regressions.
delete $defs{$new_child_name};
$child->{NAME} = $old_child_name;
$defs{$old_child_name} = $child;
$attr{$old_child_name} = delete $attr{$new_child_name};
MATTER_ProcessNode($defs{ioA}, node(42, 'Multi Outlet'));
is($defs{$old_child_name}, $child, 'endpoint retains identity after restoring its name');

# Real TCP byte-stream behavior: HTTP upgrade followed by a split >64 KiB WS frame.
my ($client, $server);
socketpair($client, $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $ws = { NAME => 'ioWS', TYPE => 'MATTER',
    helper => { ws_expected_accept => 'synthetic-valid-accept' },
    ws_status => 'handshake', websocket => 0, BUF => '', CD => $client,
    FD => fileno($client), READINGS => {} };
$defs{ioWS} = $ws;
my $big = { message_id => 'fhem_init_1',
    result => [{node_id => 99, name => 'LargeResponse', attributes => {},
                extra_test_padding => 'x' x 70000}] };
my $json = encode_json($big);
ok(length($json) > 65535, 'fixture exercises 64-bit frame length');
my $high = int(length($json) / 4294967296);
my $low = length($json) % 4294967296;
my $frame = pack('CCNN', 0x81, 127, $high, $low) . $json;
my $wire = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: synthetic-valid-accept\r\n\r\n" . $frame;
while (length($wire)) {
    my $part = substr($wire, 0, 8192, '');
    my $n = syswrite($server, $part);
    die "socketpair write failed" unless defined $n && $n == length($part);
    MATTER_Read($ws);
}
is($ws->{BUF}, '', 'large split frame consumed without leftover bytes');
ok($defs{MATTER_LargeResponse}, 'start_listening response is applied automatically');
is($defs{MATTER_LargeResponse}{IODev}{NAME}, 'ioWS', 'large-frame node uses the WS IODev');
ok(!exists($ws->{helper}{pending_command}{fhem_init_1}), 'start_listening response correlation cleared');

my $command_frame;
sysread($server, $command_frame, 1024);
ok(length($command_frame) > 2, 'start_listening was sent over WebSocket');
my $ping_frame = pack('CC', 0x89, 3) . 'abc';
syswrite($server, $ping_frame) == length($ping_frame) or die 'ping frame write failed';
MATTER_Read($ws);
my $pong_frame;
sysread($server, $pong_frame, 1024);
my ($pong_first, $pong_second) = unpack('CC', substr($pong_frame, 0, 2));
is($pong_first, 0x8A, 'server ping answered by Pong');
ok($pong_second & 0x80, 'client Pong is masked');
my $pong_len = $pong_second & 0x7F;
my $mask = substr($pong_frame, 2, 4);
my $masked_body = substr($pong_frame, 6, $pong_len);
my $unmasked_body = '';
for my $i (0 .. $pong_len - 1) {
    $unmasked_body .= chr(ord(substr($masked_body, $i, 1)) ^
                          ord(substr($mask, $i % 4, 1)));
}
is($unmasked_body, 'abc', 'Pong echoes original ping payload');

# TCP splitting and WebSocket fragmentation are different cases. A partial
# FIN=0 JSON text frame must not be parsed until the continuation arrives.
my $fragment_json = encode_json({
    schema_version => 7, sdk_version => 'fragmented-message',
    fabric_id => 'synthetic', bluetooth_enabled => JSON::false
});
my $half = int(length($fragment_json) / 2);
my $fragment_first = pack('CC', 0x01, $half) . substr($fragment_json, 0, $half);
my $fragment_last = pack('CC', 0x80, length($fragment_json) - $half)
                  . substr($fragment_json, $half);
syswrite($server, $fragment_first) == length($fragment_first) or die 'fragment first write failed';
MATTER_Read($ws);
is(ReadingsVal('ioWS', 'sdk_version', ''), '', 'partial WebSocket message does not publish telemetry');
syswrite($server, $fragment_last) == length($fragment_last) or die 'fragment last write failed';
MATTER_Read($ws);
is(ReadingsVal('ioWS', 'sdk_version', ''), 'fragmented-message',
   'continuation completes a fragmented WebSocket text message');

# After the upgrade, exactly one heartbeat timer is active.
is(scalar(grep { $_->{callback} eq 'MATTER_Heartbeat' && $_->{owner} eq $ws } @timers),
   1, 'WebSocket upgrade starts one heartbeat timer');
RemoveInternalTimer($ws, 'MATTER_Heartbeat'); # Simulate FHEM consuming the timer.
MATTER_Heartbeat($ws);
my $client_ping;
sysread($server, $client_ping, 128);
is(ord(substr($client_ping, 0, 1)), 0x89, 'heartbeat sends a WebSocket ping');
ok(ord(substr($client_ping, 1, 1)) & 0x80, 'client heartbeat ping is masked');
my $ping_mask = substr($client_ping, 2, 4);
my $ping_raw = substr($client_ping, 6, 4);
my $ping_token = '';
for my $i (0..3) {
    $ping_token .= chr(ord(substr($ping_raw, $i, 1)) ^
                       ord(substr($ping_mask, $i, 1)));
}
is($ws->{helper}{pending_pong}, $ping_token,
   'heartbeat expects the exact outstanding ping token');
my $wrong_pong = pack('CC', 0x8A, 4) . 'nope';
syswrite($server, $wrong_pong) == length($wrong_pong) or die 'wrong pong write failed';
MATTER_Read($ws);
is($ws->{helper}{pending_pong}, $ping_token, 'unmatched Pong does not clear watchdog');
my $valid_pong = pack('CC', 0x8A, 4) . $ping_token;
syswrite($server, $valid_pong) == length($valid_pong) or die 'valid pong write failed';
MATTER_Read($ws);
ok(!defined($ws->{helper}{pending_pong}), 'matching Pong clears outstanding heartbeat');
is(scalar(grep { $_->{callback} eq 'MATTER_Heartbeat' && $_->{owner} eq $ws } @timers),
   1, 'matching Pong schedules exactly one next heartbeat');

my $close_frame = pack('CC', 0x88, 0);
syswrite($server, $close_frame) == length($close_frame) or die 'close frame write failed';
MATTER_Read($ws);
is($ws->{ws_status}, 'disconnected', 'server close frame closes the WebSocket');
ok(!exists($ws->{FD}), 'close clears stale FD');
is(scalar(@timers), 1, 'server close schedules a single reconnect timer');
is($timers[0]{callback}, 'MATTER_Open', 'reconnect calls MATTER_Open');
close($server);

# Invalid WebSocket upgrades and oversized frame headers must not be accepted.
@timers = ();
socketpair(my $bad_client, my $bad_server, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $bad = { NAME => 'badWS', TYPE => 'MATTER', helper => {}, ws_status => 'handshake',
            websocket => 0, BUF => '', CD => $bad_client, FD => fileno($bad_client), READINGS => {} };
$defs{badWS} = $bad;
my $invalid_upgrade = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
syswrite($bad_server, $invalid_upgrade) == length($invalid_upgrade) or die 'HTTP write failed';
MATTER_Read($bad);
is($bad->{ws_status}, 'disconnected', 'rejected HTTP upgrade does not become connected');
is(scalar(@timers), 1, 'invalid upgrade schedules reconnect');
close($bad_server);

# A 101 status without a matching Sec-WebSocket-Accept is not authenticated
# as the response to this client's handshake nonce.
@timers = ();
socketpair(my $bad_accept_client, my $bad_accept_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die 'bad accept socketpair';
my $bad_accept = { NAME => 'badAccept', TYPE => 'MATTER',
    helper => { ws_expected_accept => 'synthetic-valid-accept' },
    ws_status => 'handshake', websocket => 0, BUF => '',
    CD => $bad_accept_client, FD => fileno($bad_accept_client), READINGS => {} };
$defs{badAccept} = $bad_accept;
my $forged_upgrade = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong-value\r\n\r\n";
syswrite($bad_accept_peer, $forged_upgrade) == length($forged_upgrade) or die 'bad accept write failed';
MATTER_Read($bad_accept);
is($bad_accept->{ws_status}, 'disconnected', 'mismatched WebSocket accept hash is rejected');
close($bad_accept_peer);

@timers = ();
socketpair(my $huge_client, my $huge_server, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $huge = { NAME => 'hugeWS', TYPE => 'MATTER', helper => {}, ws_status => 'connected',
             websocket => 1, BUF => '', CD => $huge_client, FD => fileno($huge_client), READINGS => {} };
$defs{hugeWS} = $huge;
my $huge_header = pack('CCNN', 0x81, 127, 0, 32 * 1024 * 1024 + 1);
syswrite($huge_server, $huge_header) == length($huge_header) or die 'large header write failed';
MATTER_Read($huge);
is($huge->{ws_status}, 'disconnected', 'oversized declared payload rejected immediately');
is($huge->{BUF}, '', 'oversized payload does not accumulate');
is(scalar(@timers), 1, 'oversized frame schedules reconnect');
close($huge_server);

@log = ();
MATTER_Set($ws, 'ioWS', 'setWifiCredentials', 'SyntheticSSID', 'SyntheticPassword');
ok(!grep(/SyntheticSSID|SyntheticPassword/, @log),
   'credential command does not log Wi-Fi SSID or password');


# A silent TCP connection is detected by a missing matching Pong.
@timers = ();
socketpair(my $silent_socket, my $silent_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $silent = {NAME => 'silentIO', TYPE => 'MATTER', READINGS => {},
    helper => {}, CD => $silent_socket, FD => fileno($silent_socket),
    websocket => 1, ws_status => 'connected', BUF => ''};
$defs{silentIO} = $silent;
$selectlist{silentIO} = $silent;
MATTER_Heartbeat($silent);
ok(defined($silent->{helper}{pending_pong}), 'heartbeat records a pending Pong');
is(scalar(@timers), 1, 'one timeout timer follows an outstanding Ping');
RemoveInternalTimer($silent, 'MATTER_Heartbeat'); # Simulated expiry
MATTER_Heartbeat($silent);
is($silent->{ws_status}, 'disconnected', 'Pong deadline detects silent connection');
like(join("\n", @log), qr/\[silentIO\] WebSocket pong timeout after 15 seconds; reconnecting/,
     'Pong timeout explains the failure in the FHEM log');
like(join("\n", @log), qr/\[silentIO\] Reconnect scheduled in 30 seconds/,
     'retry schedule is logged');
is(scalar(@timers), 1, 'Pong timeout leaves exactly one retry timer');
is($timers[0]{callback}, 'MATTER_Open', 'Pong timeout schedules TCP reconnect');
ok(!exists($selectlist{silentIO}), 'dead WebSocket is removed from FHEM selectlist');
close($silent_peer);

# A partial TCP/HTTP connection cannot remain in "connecting" indefinitely.
@timers = ();
socketpair(my $slow_socket, my $slow_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $slow = {NAME => 'slowIO', TYPE => 'MATTER', READINGS => {},
    helper => {}, CD => $slow_socket, FD => fileno($slow_socket),
    websocket => 0, ws_status => 'handshake', BUF => ''};
$defs{slowIO} = $slow;
$selectlist{slowIO} = $slow;
MATTER_ConnectTimeout($slow);
is($slow->{ws_status}, 'disconnected', 'incomplete handshake times out');
like(join("\n", @log), qr/\[slowIO\] WebSocket upgrade timed out after 10 seconds/,
     'handshake timeout is logged with phase and deadline');
is(scalar(@timers), 1, 'handshake timeout leaves only a reconnect timer');
close($slow_peer);

# Exercise the actual nonblocking connect against a local listening socket.
@timers = ();
my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', Listen => 2,
) or die "local TCP listener: $!";
my $async = {NAME => 'asyncIO', TYPE => 'MATTER', READINGS => {},
             helper => {}, ip => '127.0.0.1', port => $listener->sockport};
$defs{asyncIO} = $async;
MATTER_Open($async);
is($async->{ws_status}, 'tcp_connecting',
   'nonblocking connect enters a separate TCP completion phase');
ok($async->{directWriteFn}, 'TCP completion is registered for FHEM writable callbacks');
is(scalar(@timers), 1, 'only one connect/upgrade deadline is scheduled');
my $write_ready = '';
vec($write_ready, $async->{FD}, 1) = 1;
my $wout = $write_ready;
ok(select(undef, $wout, undef, 1) > 0,
   'nonblocking socket becomes writable when TCP connection completes');
$async->{directWriteFn}->($async);
is($async->{ws_status}, 'handshake', 'writable connect sends HTTP WebSocket upgrade');
like(join("\n", @log), qr/\[asyncIO\] TCP connect attempt 1 to 127\.0\.0\.1:/,
     'connect attempt is logged with attempt count and target');
my $accepted = $listener->accept() or die "accept local WebSocket: $!";
my $request;
sysread($accepted, $request, 2048);
like($request, qr{^GET /ws HTTP/1\.1\r\n}, 'nonblocking connect sent a complete HTTP upgrade');
my $http101 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $async->{helper}{ws_expected_accept}\r\n\r\n";
syswrite($accepted, $http101) == length($http101) or die 'HTTP 101 write failed';
MATTER_Read($async);
is($async->{ws_status}, 'connected', 'successful upgrade finishes the async handshake');
like(join("\n", @log), qr/\[asyncIO\] WebSocket connected \(attempt 1\); restarting node listening/,
     'successful WebSocket recovery is logged at connection completion');
ok(!grep($_->{callback} eq 'MATTER_ConnectTimeout', @timers),
   'successful handshake cancels its connect timeout');
is(scalar(grep { $_->{callback} eq 'MATTER_Heartbeat' } @timers), 1,
   'completed handshake starts one ping timer');
MATTER_Close($async);
is(scalar(@timers), 0, 'closing an active connection cancels heartbeat');
ok(!exists($selectlist{asyncIO}), 'closing removes the IO selectlist entry');
ok(!exists($async->{directWriteFn}), 'closing removes writable callback');
close($accepted);
close($listener);

# FHEM's AttrFn is invoked before the new disable value is stored.
@timers = ();
socketpair(my $disabled_socket, my $disabled_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $disabled = {NAME => 'disableIO', TYPE => 'MATTER', READINGS => {},
    helper => {}, CD => $disabled_socket, FD => fileno($disabled_socket),
    websocket => 1, ws_status => 'connected', BUF => ''};
$defs{disableIO} = $disabled;
$selectlist{disableIO} = $disabled;
InternalTimer(31, 'MATTER_Heartbeat', $disabled, 0);
my $reentered_connect = 0;
$reading_event_hook = sub {
    my ($device, $reading, $value) = @_;
    return unless $device eq $disabled && $reading eq 'state' && $value eq 'disconnected';
    ++$reentered_connect;
    MATTER_Set($disabled, 'disableIO', 'connect');
};
is(CommandAttr(undef, 'disableIO disable 1'), undef,
   'disable=1 is accepted on a running MATTER IO');
$reading_event_hook = undef;
is($reentered_connect, 1, 'synchronous FHEM event subscriber reentered set connect');
ok(!$disabled->{helper}{connect_attempts},
   'reentrant connect cannot defeat a pending disable transition');
like(join("\n", @log), qr/\[disableIO\] Disabled: connection closed, pending timers cancelled/,
     'disable transition and cleanup are logged');
ok(!$disabled->{CD} && !exists($selectlist{disableIO}),
   'disable=1 immediately closes its running connection');
is(scalar(@timers), 0, 'disable=1 cancels all pending IO timers');
is(CommandAttr(undef, 'disableIO disable 0'), undef,
   'disable=0 is accepted after shutdown');
like(join("\n", @log), qr/\[disableIO\] Enabled: connection attempt scheduled/,
     'enable transition and recovery attempt are logged');
is(scalar(@timers), 1, 're-enabling schedules one connection attempt');
is($timers[0]{callback}, 'MATTER_Open', 're-enable defers reconnect until AttrVal is updated');
is(CommandAttr(undef, 'disableIO disable 0'), undef, 'repeated enable is accepted');
is(scalar(@timers), 1, 'repeated enable cannot duplicate a reconnect timer');
MATTER_Undef($disabled, 'disableIO');
is(scalar(@timers), 0, 'undefine cancels pending retry on a deleted IO');
ok(!exists($disabled->{CD}), 'undefine leaves no socket');
close($disabled_peer);

@timers = ();
$attr{disableIO}{disable} = 1;
is(CommandDeleteAttr(undef, 'disableIO disable'), undef,
   'deleting disable attribute is accepted');
is(scalar(@timers), 1, 'removing disable schedules exactly one reconnect');
MATTER_Undef($disabled, 'disableIO');
is(scalar(@timers), 0, 'undefine cancels retry after del disable');


# The initial MATTER connect must be deferred until FHEM's timer event loop is
# running; starting its 10-second deadline inside Define can expire during
# a slow configuration load. FHEM's InternalTimer(1, ..., 0) is immediately
# due in the event loop, not a one-second sleep.
@timers = ();
my $startup_listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', Listen => 4,
) or die "startup TCP listener: $!";
my $startup_port = $startup_listener->sockport;
my $startup = { NAME => 'startupIO', TYPE => 'MATTER', READINGS => {},
                helper => {}, STATE => '???' };
$defs{startupIO} = $startup;
is(MATTER_Define($startup, "startupIO MATTER 127.0.0.1 $startup_port"),
   undef, 'Define schedules MATTER connection without opening a socket');
is(scalar(@timers), 1, 'Define leaves exactly one initial connect timer');
is($timers[0]{at}, 1, 'initial connect is due immediately after FHEM startup');
is($timers[0]{callback}, 'MATTER_Open', 'initial timer starts the existing connection path');
ok(!defined($startup->{CD}) && !exists($selectlist{startupIO}),
   'no TCP socket or selectlist entry is created during configuration loading');
ok(!grep(/\[startupIO\] TCP connect attempt/, @log),
   'no connection attempt is logged before the startup timer fires');

# Model FHEM's event loop consuming the one-shot timer.
my $startup_timer = shift @timers;
MATTER_Open($startup_timer->{owner});
is($startup->{ws_status}, 'tcp_connecting',
   'the event-loop timer starts the asynchronous TCP connection');
ok($startup->{CD} && exists($selectlist{startupIO}),
   'the active connection is registered with FHEM after timer dispatch');
is(scalar(@timers), 1, 'one TCP/WebSocket timeout replaces the startup timer');
is($timers[0]{callback}, 'MATTER_ConnectTimeout',
   'handshake timeout is scheduled only after the actual connection attempt');
is($timers[0]{at}, $mock_time + 10,
   'handshake deadline begins at connection time, not configuration load');

is(MATTER_Define($startup, "startupIO MATTER 127.0.0.1 $startup_port"),
   undef, 'modify closes an in-flight connection and schedules a fresh attempt');
ok(!defined($startup->{CD}) && !exists($selectlist{startupIO}),
   'modify removes the old socket and selectlist entry');
is(scalar(@timers), 1, 'modify replaces timeout with one immediate connect timer');
is($timers[0]{callback}, 'MATTER_Open',
   'modify does not leave the old handshake deadline behind');
is(MATTER_Define($startup, "startupIO MATTER 127.0.0.1 $startup_port"),
   undef, 'repeating modify before timer dispatch is safe');
is(scalar(@timers), 1, 'repeated modify never duplicates the initial timer');

is(MATTER_Set($startup, 'startupIO', 'connect'), undef,
   'manual set connect remains immediate while a startup timer is pending');
is($startup->{ws_status}, 'tcp_connecting',
   'manual connect does not wait for the deferred initial timer');
is(scalar(@timers), 1, 'manual connection removes the startup timer');
is($timers[0]{callback}, 'MATTER_ConnectTimeout',
   'manual connection has only its own handshake deadline');

# Persisted disable attributes are applied after Define during config loading.
is(CommandAttr(undef, 'startupIO disable 1'), undef,
   'disable=1 closes the pending manual connection');
ok(!defined($startup->{CD}) && !exists($selectlist{startupIO}),
   'disabled connection has no active socket');
is(scalar(@timers), 0, 'disable removes its pending handshake deadline');
is(MATTER_Define($startup, "startupIO MATTER 127.0.0.1 $startup_port"),
   undef, 'Define may schedule before the persisted disable attribute is known');
is(scalar(@timers), 1, 'disabled IO still has one deferred startup callback');
$startup_timer = shift @timers;
MATTER_Open($startup_timer->{owner});
ok(!defined($startup->{CD}) && !exists($selectlist{startupIO}),
   'deferred callback respects disable=1 and does not open a socket');
is(scalar(@timers), 0, 'disabled startup does not schedule reconnects');

is(MATTER_Define($startup, "startupIO MATTER 127.0.0.1 $startup_port"),
   undef, 'a pending startup timer can be cancelled by undefine');
MATTER_Undef($startup, 'startupIO');
is(scalar(@timers), 0, 'undefine cancels the initial connect timer');
ok(!exists($selectlist{startupIO}), 'undefine leaves no stale selectlist entry');
close($startup_listener);
delete $defs{startupIO};
delete $attr{startupIO};


# Regression coverage for the integrated legacy feature branches.
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated', data => { node_id => 42, available => JSON::false }
}));
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'false',
   'node_updated records physical unavailability on the root');
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'offline',
   'valid server unavailable report produces native offline state');
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'present',
   'availability is independent of server membership');
MATTER_ProcessNode($defs{ioA}, { node_id => 42, name => 'Hall Light', available => JSON::true });
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'true',
   'available flag is restored by a node snapshot');
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'online',
   'valid server availability report produces native online state');
MATTER_ProcessNode($defs{ioA}, { node_id => 42, name => 'No availability field' });
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'true',
   'missing availability in a snapshot does not overwrite the previous report');
MATTER_ProcessNode($defs{ioA}, { node_id => 42, name => 'Invalid availability',
                                available => 'unknown' });
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'true',
   'malformed availability is ignored');
is(ReadingsVal('ManuallyRenamedRoot', 'state', ''), 'online',
   'malformed availability never alters valid native root state');
is(ReadingsVal('MATTER_Hall_Light_EP1', 'available', ''), 'true',
   'node-level availability is mirrored to the existing endpoint');
# Subsequent online callback tests use the valid availability report above.
# Separate offline/unknown cases below verify the common update gate.

MATTERDevice_Parse($root, encode_json({
    node_id => 42,
    attributes => {
        '1/47/12' => 154,                      # PowerSource battery percent half-units
        '1/92/1'  => 2,                        # SmokeCO smoke state
        '1/144/8' => 2150,                     # ElectricalPowerMeasurement mW
        '1/145/1' => { energy => 1_250_000 }, # ElectricalEnergyMeasurement mWh
    },
}));
is(ReadingsVal('MATTER_Hall_Light_EP1', 'battery_percent', ''), 77,
   'PowerSource percentage is converted from half-units');
is(ReadingsVal('MATTER_Hall_Light_EP1', 'smoke_state', ''), 2,
   'SmokeCO cluster is mapped to a reading');
is(ReadingsVal('MATTER_Hall_Light_EP1', 'power', ''), 2.15,
   'electrical power is converted to watts');
is(ReadingsVal('MATTER_Hall_Light_EP1', 'energy', ''), 1.25,
   'cumulative electrical energy is converted to kWh');
my $old_state = ReadingsVal('MATTER_Hall_Light_EP1', 'state', '');
MATTERDevice_Parse($root, encode_json({node_id => 42, attributes => {'1/6/0' => undef}}));
is(ReadingsVal('MATTER_Hall_Light_EP1', 'state', ''), $old_state,
   'null OnOff state is not incorrectly published as off');

# The original tests depended on auto-created has_onoff=1 without advertised
# command metadata. Supply actual Matter AcceptedCommandList evidence instead.
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => { '1/6/65529' => [0, 1, 2] }
}));
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($child)),
   'On is supported by Matter metadata before transport failure tests');

my @sent_requests;
# Device commands require a connected transport; the stub simulates only
# the successful accepted-send contract, not delivery or device execution.
like(MATTERDevice_Set($child, $child->{NAME}, 'on') // '',
     qr/No active WebSocket/, 'device set rejects disconnected IO without claiming success');
socketpair(my $io_a_socket, my $io_a_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die 'connected IO test socketpair';
$defs{ioA}{CD} = $io_a_socket;
$defs{ioA}{FD} = fileno($io_a_socket);
$defs{ioA}{websocket} = 1;
$defs{ioA}{ws_status} = 'connected';
$defs{ioA}{test_send_text} = sub {
    push @sent_requests, JSON::decode_json($_[0]);
    return 1;
};
is(MATTERDevice_Set($child, $child->{NAME}, 'getConfig'), undef,
   'getConfig can be sent via current IODev');
my $read_request = $sent_requests[-1];
is($read_request->{command}, 'read_attribute', 'getConfig uses read_attribute');
ok(exists $defs{ioA}{helper}{pending_config}{$read_request->{message_id}},
   'getConfig pending request is recorded where MATTER_ParseMessage reads it');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $read_request->{message_id},
    result => {
        '1/47/12' => 110,
        '1/6/65529' => [0, 1, 2], # A complete getConfig also reads command metadata.
    },
}));
is(ReadingsVal('MATTER_Hall_Light_EP1', 'battery_percent', ''), 55,
   'read_attribute response is routed to the original endpoint');

# A connected IO whose send callback rejects a frame must not return success
# or leave a pending getConfig request behind.
my $previous_sender = $defs{ioA}{test_send_text};
$defs{ioA}{test_send_text} = sub { return 0 };
my $pending_before_send_failure = scalar keys %{$defs{ioA}{helper}{pending_config} // {}};
like(MATTERDevice_Set($child, $child->{NAME}, 'on') // '',
     qr/Unable to send device command/, 'failed device send returns a FHEM error');
like(MATTERDevice_Set($child, $child->{NAME}, 'getConfig') // '',
     qr/Unable to send getConfig/, 'failed read send returns a FHEM error');
is(scalar(keys %{$defs{ioA}{helper}{pending_config} // {}}),
   $pending_before_send_failure, 'failed read leaves no dangling pending request');
$defs{ioA}{test_send_text} = $previous_sender;

ok(!exists $defs{ioA}{helper}{pending_config}{$read_request->{message_id}},
   'matched getConfig pending request is cleared');

# Inspect decoded wire arguments in send order, including color-only endpoints.
for my $xy (0, 1) {
    for my $level_control (0, 1) {
        MATTERDevice_Parse($root, encode_json({
            node_id => 42, attributes => {
                '1/768/65529' => [$xy ? 7 : 6],
                '1/768/65532' => $xy ? 8 : 1,
                '1/8/65529' => $level_control ? [$xy ? 0 : 4] : [],
            },
        }));
        for my $black (0, 1) {
            my $rgb = $black ? '000000' : '800000';
            my @expected;
            my %options = (transitionTime => 0, optionsMask => 0, optionsOverride => 0);
            push @expected, {
                node_id => 42, endpoint_id => 1, cluster_id => 8,
                command_name => $xy ? 'MoveToLevel' : 'MoveToLevelWithOnOff',
                payload => { %options, level => $black ? 0 : 127 },
            } if $level_control;
            push @expected, {
                node_id => 42, endpoint_id => 1, cluster_id => 768,
                command_name => $xy ? 'MoveToColor' : 'MoveToHueAndSaturation',
                payload => { %options, $xy ? (colorX => 41943, colorY => 21627)
                                          : (hue => 0, saturation => $black ? 0 : 254) },
            } unless $xy && $black;

            @sent_requests = ();
            my $error = MATTERDevice_Set($child, $child->{NAME}, 'rgb', $rgb);
            my $case = "rgb $rgb, xy=$xy, levelControl=$level_control";
            is($error, @expected ? undef : 'No payload generated', "$case result");
            is_deeply([map { $_->{args} } @sent_requests], \@expected, "$case wire arguments and order");
        }
    }
}

MATTERDevice_Parse($root, encode_json({
    node_id => 42,
    attributes => {
        '1/768/65529' => [6], # ColorControl AcceptedCommandList: Hue/Saturation
        '1/768/65532' => 1,   # ColorControl FeatureMap: Hue/Saturation
        '1/8/65529' => [4],   # LevelControl: MoveToLevelWithOnOff
    },
}));
ok(grep(/^rgb:/, MATTERDevice_GetSetList($child)),
   'RGB command appears when supported by Matter command metadata');
@sent_requests = ();
is(MATTERDevice_Set($child, $child->{NAME}, 'rgb', '800000'), undef,
   'RGB hue/saturation command accepted');
is(scalar(@sent_requests), 2, 'RGB sends brightness and color commands separately');
is($sent_requests[0]{args}{command_name}, 'MoveToLevelWithOnOff',
   'RGB brightness is sent through LevelControl');
is($sent_requests[1]{args}{command_name}, 'MoveToHueAndSaturation',
   'RGB hue and saturation are sent through ColorControl');
@sent_requests = ();
like(MATTERDevice_Set($child, $child->{NAME}, 'rgb', 'GG0000'),
     qr/^Usage: set /, 'malformed RGB color is rejected');
is(scalar(@sent_requests), 0, 'invalid RGB sends no device command');
$attr{$child->{NAME}}{max_brightness} = 0;
is(MATTERDevice_MaxBrightness($child), 254,
   'obsolete zero maximum cannot change the protocol fallback');
$attr{$child->{NAME}}{max_brightness} = 200;
ok(MATTERDevice_AttributeUsable($child, 8, 3),
   'restored reports can be used until AttributeList arrives');
ok(grep(/^brightness:slider,0,1,254$/, MATTERDevice_GetSetList($child)),
   'obsolete max_brightness does not change the brightness slider');
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => { '1/8/0' => 254 }
}));
is(ReadingsVal($child->{NAME}, 'pct', ''), 100,
   'obsolete maximum cannot distort incoming percentage scaling');
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => { '1/8/65531' => [0] }
}));
ok(!MATTERDevice_AttributeUsable($child, 8, 3),
   'received AttributeList takes precedence over a stored report');

# Older saved has_* attributes are inert: they neither enable nor
# disable commands. Device capability metadata is the only authority.
unlike($modules{MATTERDevice}{AttrList}, qr/\bhas_[a-z_]+:/,
       'has_* flags are no longer offered as configurable device attributes');
$attr{$child->{NAME}}{has_hue} = 0;
ok(grep(/^rgb:/, MATTERDevice_GetSetList($child)),
   'stored has_hue=0 does not suppress an advertised hue command');
is($attr{$child->{NAME}}{has_hue}, 0,
   'stored legacy attribute is preserved without automatic deletion');
delete $attr{$child->{NAME}}{has_hue};

delete $child->{helper}{capabilities}{0x0300}{accepted_commands};
$attr{$child->{NAME}}{has_color} = 1;
ok(!grep(/^rgb:/, MATTERDevice_GetSetList($child)),
   'stored has_color=1 cannot invent an RGB command without metadata');
delete $attr{$child->{NAME}}{has_color};

# Matter attribute reports must never repopulate obsolete has_* settings.
delete @{$attr{$child->{NAME}}}{qw(has_onoff has_level has_hue)};
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => {
        '1/6/0' => JSON::true,
        '1/8/0' => 90,
        '1/768/0' => 10,
    },
}));
ok(!grep({ exists($attr{$child->{NAME}}{$_}) } qw(has_onoff has_level has_hue)),
   'device reports do not automatically create obsolete has_* attributes');
like(CommandAttr(undef, "$child->{NAME} has_onoff 1") // '',
     qr/unknown attribute/,
     'FHEM rejects new has_onoff attributes outside the module AttrList');

$attr{$child->{NAME}}{has_onoff} = 0;
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => { '1/6/65529' => [0, 1, 2] }
}));
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($child)),
   'advertised On remains available despite persisted has_onoff=0');
delete $attr{$child->{NAME}}{has_onoff};
delete $child->{helper}{capabilities}{0x0006}{accepted_commands};
$attr{$child->{NAME}}{has_onoff} = 1;
ok(!grep(/^on:noArg$/, MATTERDevice_GetSetList($child)),
   'persisted has_onoff=1 cannot enable On without AcceptedCommandList');
delete $attr{$child->{NAME}}{has_onoff};
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => { '1/6/65529' => [0, 1, 2] }
}));


# FHEMWEB endpoint type display: real Descriptor DeviceTypeList takes priority;
# cluster-only fallbacks intentionally describe functions, not assumed hardware.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 88, name => 'TypeDisplay', available => JSON::true,
    attributes => {
        '1/6/0'      => JSON::true,
        '10/1026/0'  => 2100,  # TemperatureMeasurement (0x0402)
        '11/1029/0'  => 4500,  # RelativeHumidityMeasurement (0x0405)
        '12/6/0'     => JSON::false,
        '12/8/0'     => 45,
        '12/768/0'   => 128,
    },
});
my $types_root = $defs{MATTER_TypeDisplay};
my $type_html = MATTERDevice_FWDetail('WEB', 'MATTER_TypeDisplay', 'Matter');
like($type_html, qr/<tr><td>EP<\/td><td>Type<\/td><td>FHEM device<\/td><\/tr>/,
     'compact column labels use regular table cells');
unlike($type_html, qr/<th(?:\s|>)/i, 'endpoint overview does not use styled header cells');
like($type_html, qr/<td>1<\/td><td>On\/Off<\/td>/,
     'OnOff alone is not misidentified as a light or plug');
like($type_html, qr/<td>10<\/td><td>Temperature measurement<\/td>/,
     'unknown temperature cluster is described as a measurement');
like($type_html, qr/<td>11<\/td><td>Humidity measurement<\/td>/,
     'unknown humidity cluster is described as a measurement');
like($type_html, qr/<td>12<\/td><td>Color control<\/td>/,
     'color cluster fallback describes the observed function');

# Snapshot: explicit Matter type distinguishes an actual plug from OnOff devices.
MATTERDevice_Parse($types_root, encode_json({
    node_id => 88, attributes => {
        '1/29/0'  => [{deviceType => 0x010A, revision => 1}],
        '10/29/0' => [{deviceType => 0x0302, revision => 1}],
        '11/29/0' => [{deviceType => 0x0307, revision => 1}],
    },
}));
$type_html = MATTERDevice_FWDetail('WEB', 'MATTER_TypeDisplay', 'Matter');
like($type_html, qr/<td>1<\/td><td>On\/Off plug-in unit<\/td>/,
     'Descriptor DeviceTypeList identifies a plug-in unit exactly');
like($type_html, qr/<td>10<\/td><td>Temperature sensor<\/td>/,
     'Descriptor DeviceTypeList identifies the temperature sensor');
like($type_html, qr/<td>11<\/td><td>Humidity sensor<\/td>/,
     'Descriptor DeviceTypeList identifies the humidity sensor');
is(ReadingsVal('MATTER_TypeDisplay_EP1', 'device_type_ids', ''), '0x010A',
   'DeviceTypeList is stored as a persistent canonical FHEM reading');
is(ReadingsVal('MATTER_TypeDisplay_EP10', 'device_type_ids', ''), '0x0302',
   'endpoint 10 stores its own DeviceTypeList independently');
is(ReadingsVal('MATTER_TypeDisplay_EP11', 'device_type_ids', ''), '0x0307',
   'endpoint 11 stores its own DeviceTypeList independently');
my $prior_type_events = $single_writes{MATTER_TypeDisplay_EP1}{device_type_ids};
MATTERDevice_Parse($types_root, encode_json({
    node_id => 88, attributes => {
        '1/29/0' => [{deviceType => 0x010A, revision => 1},
                     {deviceType => 0x010A, revision => 1}],
    },
}));
is($single_writes{MATTER_TypeDisplay_EP1}{device_type_ids}, $prior_type_events,
   'repeated equivalent Descriptor metadata does not generate another reading update');

# Per-endpoint getConfig reads DeviceTypeList explicitly.
@sent_requests = ();
is(MATTERDevice_Set($defs{MATTER_TypeDisplay_EP10}, 'MATTER_TypeDisplay_EP10', 'getConfig'),
   undef, 'getConfig works on the additional endpoint');
my $type_request = $sent_requests[-1];
ok(grep($_ eq '10/29/0', @{$type_request->{args}{attribute_path}}),
   'getConfig requests the endpoint DeviceTypeList');

# Live updates and read_attribute responses use the same endpoint routing.
MATTERDevice_Parse($types_root, encode_json({
    event => 'attribute_updated',
    data => [88, '11/29/0', [{deviceType => 0x0015, revision => 1}]],
}));
$type_html = MATTERDevice_FWDetail('WEB', 'MATTER_TypeDisplay', 'Matter');
like($type_html, qr/<td>11<\/td><td>Contact sensor<\/td>/,
     'live Descriptor update refreshes the endpoint type');
is($attr{MATTER_TypeDisplay_EP1}{group}, 'On/Off plug-in unit',
   'plug group uses its explicit Matter device type');
is($attr{MATTER_TypeDisplay_EP10}{group}, 'Temperature sensor',
   'temperature endpoint has its own type group');
is($attr{MATTER_TypeDisplay_EP11}{group}, 'Contact sensor',
   'live device type update adjusts an existing automatic group');

# A read started before a live update must not overwrite the newer endpoint
# state when the stale server response eventually arrives.
@sent_requests = ();
is(MATTERDevice_Set($child, $child->{NAME}, 'getConfig'), undef,
   'getConfig starts tracked request before live telemetry');
my $older_read = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [42, '1/6/0', JSON::false]
}));
is(ReadingsVal($child->{NAME}, 'state', ''), 'off', 'live state update applied');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $older_read, result => { '1/6/0' => JSON::true }
}));
is(ReadingsVal($child->{NAME}, 'state', ''), 'off',
   'late read_attribute snapshot cannot regress a newer live state');

# A batched node report can arrive while the same endpoint read is pending.
is(MATTERDevice_Set($child, $child->{NAME}, 'getConfig'), undef,
   'start endpoint read before node_updated');
my $before_node_update = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated', data => {node_id => 42, available => JSON::true}
}));
my $pending_read = $defs{ioA}{helper}{pending_config}{$before_node_update};
ok(!exists($pending_read->{live_values}),
   'availability-only node_updated does not supersede read paths');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated', data => {node_id => 42, attributes => {
        '1/6/0' => JSON::false, '1/8/0' => 27, '2/8/0' => 31
    }}
}));
ok(!exists($pending_read->{live_values}{'2/8/0'}),
   'sibling endpoint report is excluded from the endpoint read');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $before_node_update, result => {
        '1/6/0' => JSON::true, '1/8/0' => 15, '1/6/65529' => [0, 1]
    }
}));
is(ReadingsVal($child->{NAME}, 'state', ''), 'off',
   'node_updated OnOff survives the older read');
is(ReadingsVal($child->{NAME}, 'brightness', ''), 27,
   'second path from the same node_updated survives the older read');
ok(MATTERDevice_CommandAccepted($child, 6, 1),
   'untouched AcceptedCommandList from the read is applied');

# Inputs without valid Matter boolean/numeric representations are ignored.
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => {
        '1/6/0' => 'false',
        '1/8/0' => 'not-a-number'
    }
}));
is(ReadingsVal($child->{NAME}, 'state', ''), 'off',
   'string false is not interpreted as OnOff true');
my $pct_before_invalid = ReadingsVal($child->{NAME}, 'pct', '');
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => { '1/8/0' => 'invalid' }
}));
is(ReadingsVal($child->{NAME}, 'pct', ''), $pct_before_invalid,
   'malformed brightness cannot be converted to zero percent');
my $no_hash_error = eval { MATTER_ParseMessage($defs{ioA}, '[]'); 1 };
ok($no_hash_error, 'valid non-object JSON cannot crash the IO parser');

# An unrelated attribute in a delayed read must still be imported.
# A changed AcceptedCommandList must survive the full metadata reset, too.
@sent_requests = ();
is(MATTERDevice_Set($child, $child->{NAME}, 'getConfig'), undef,
   'begin complete read while waiting for live telemetry');
my $mixed_read = $sent_requests[-1]{message_id};
like(MATTERDevice_Set($child, $child->{NAME}, 'getConfig') // '',
     qr/getConfig already in progress/,
     'duplicate endpoint read is rejected while the first is pending');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [42, '1/6/0', JSON::false]
}));
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [42, '1/8/65529', [4]]
}));
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $mixed_read,
    result => {
        '1/6/0' => JSON::true,    # stale on/off
        '1/8/65529' => [0],      # stale command metadata
        '1/47/12' => 132,        # independent, useful snapshot attribute
    }
}));
is(ReadingsVal($child->{NAME}, 'state', ''), 'off',
   'new live on/off takes precedence over old read');
is(ReadingsVal($child->{NAME}, 'battery_percent', ''), 66,
   'independent battery attribute from late read still updates');
ok(MATTERDevice_CommandAccepted($child, 8, 4),
   'new live capability metadata survives rebuilding the read cache');
ok(!MATTERDevice_CommandAccepted($child, 8, 0),
   'stale command list cannot reintroduce an obsolete accepted command');
@sent_requests = ();
is(MATTERDevice_Set($child, $child->{NAME}, 'getConfig'), undef,
   'completed read releases the per-endpoint concurrency guard');
my $validity_read = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [42, '1/6/0', 'false']
}));
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $validity_read, result => { '1/6/0' => JSON::true }
}));
is(ReadingsVal($child->{NAME}, 'state', ''), 'on',
   'invalid live boolean does not supersede a valid snapshot value');

# Power Source is a utility type, not a competing application device type.
MATTERDevice_Parse($types_root, encode_json({
    node_id => 88, attributes => {
        '1/29/0' => [
            { '0' => 0x0011, '1' => 1 },
            { '0' => 0x0076, '1' => 1 },
        ],
    },
}));
is($attr{MATTER_TypeDisplay_EP1}{group}, 'Smoke CO Alarm',
   'Power Source plus Smoke CO Alarm produces one alarm group');
is(ReadingsVal('MATTER_TypeDisplay_EP1', 'device_type_ids', ''), '0x0011,0x0076',
   'structural and functional IDs are stored together, sorted numerically');

# Ambiguous functional types must not force an arbitrary group change.
MATTERDevice_Parse($types_root, encode_json({
    node_id => 88, attributes => {
        '1/29/0' => [
            { '0' => 0x0100, '1' => 1 },
            { '0' => 0x010A, '1' => 1 },
        ],
    },
}));
is($attr{MATTER_TypeDisplay_EP1}{group}, 'Smoke CO Alarm',
   'two application types do not trigger an arbitrary reassignment');

# Unknown application types remain identifiable by their hexadecimal ID.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 89, name => 'Unknown type', available => JSON::true,
    attributes => { '1/29/0' => [{ '0' => 0xF123, '1' => 1 }] },
});
is($attr{MATTER_Unknown_type_EP1}{group}, '0xF123',
   'unknown application type has a stable hexadecimal group');

# Matter Electrical Sensor is usable even though its spec category is Utility.
# Technical bridge topology endpoints should not retain the legacy node group.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 190, name => 'Bridge grouping',
    available => JSON::true,
    attributes => {
        '1/29/0' => [{ '0' => 0x000E, '1' => 1 }], # Aggregator
        '10/29/0' => [{ '0' => 0x0013, '1' => 1 }], # Bridged Node
        '11/29/0' => [{ '0' => 0x010A, '1' => 1 }], # On/Off plug
        '11/6/0' => JSON::true,
        '2/29/0' => [{ '0' => 0x0510, '1' => 1 }], # Electrical Sensor
    },
});
is($attr{MATTER_Bridge_grouping}{group}, 'Matter Nodes',
   'bridge root uses administrative root group');
is($attr{MATTER_Bridge_grouping_EP1}{group}, 'Matter Infrastruktur',
   'Aggregator has a structural grouping');
is($attr{MATTER_Bridge_grouping_EP10}{group}, 'Matter Infrastruktur',
   'Bridged Node has a structural grouping');
is($attr{MATTER_Bridge_grouping_EP11}{group}, 'On/Off plug-in unit',
   'bridge actuator remains a functional plug');
is($attr{MATTER_Bridge_grouping_EP2}{group}, 'Electrical Sensor',
   'Electrical Sensor has a functional group instead of 0x0510');

$attr{MATTER_Bridge_grouping_EP1}{group} = 'Node 190 (ioA)';
$attr{MATTER_Bridge_grouping_EP10}{group} = 'Node 190 (ioA)';
MATTER_ProcessNode($defs{ioA}, { node_id => 190, name => 'Bridge grouping' });
is($attr{MATTER_Bridge_grouping_EP1}{group}, 'Matter Infrastruktur',
   'legacy Aggregator node group is migrated without new endpoint attributes');
is($attr{MATTER_Bridge_grouping_EP10}{group}, 'Matter Infrastruktur',
   'legacy Bridged Node group is migrated without new endpoint attributes');



MATTERDevice_Parse($types_root, encode_json({
    result => {'10/29/0' => [{deviceType => '0x0307', revision => 1}]},
}));
$type_html = MATTERDevice_FWDetail('WEB', 'MATTER_TypeDisplay', 'Matter');
like($type_html, qr/<td>10<\/td><td>Humidity sensor<\/td>/,
     'getConfig response refreshes type with a valid hexadecimal ID');

MATTERDevice_Parse($types_root, encode_json({
    node_id => 88, attributes => {
        '1/29/0' => [{deviceType => 0x0016, revision => 1},
                      {deviceType => 0x0100, revision => 1}],
        '10/29/0' => [{deviceType => 0xF123, revision => 1}],
    },
}));
$type_html = MATTERDevice_FWDetail('WEB', 'MATTER_TypeDisplay', 'Matter');
like($type_html, qr/<td>1<\/td><td>On\/Off light<\/td>/,
     'application type is preferred to the utility root type');
like($type_html, qr/<td>10<\/td><td>0xF123<\/td>/,
     'unknown type ID stays explicitly identifiable');
is(ReadingsVal('MATTER_TypeDisplay_EP10', 'device_type_ids', ''), '0xF123',
   'unrecognized type IDs remain persistable and visible without a label');

MATTERDevice_Parse($types_root, encode_json({
    node_id => 88, attributes => { '10/29/0' => [{deviceType => 'invalid'}] },
}));
$type_html = MATTERDevice_FWDetail('WEB', 'MATTER_TypeDisplay', 'Matter');
like($type_html, qr/<td>10<\/td><td>0xF123<\/td>/,
     'malformed type metadata does not replace the last valid device type');
is(ReadingsVal('MATTER_TypeDisplay_EP10', 'device_type_ids', ''), '0xF123',
   'malformed Descriptor updates do not overwrite persisted type IDs');

# Model a FHEM restart after the statefile has restored the readings but
# without any new start_listening response or runtime helper metadata.
for my $ep (qw(MATTER_TypeDisplay_EP1 MATTER_TypeDisplay_EP10 MATTER_TypeDisplay_EP11)) {
    $defs{$ep}{helper} = {};
}
$type_html = MATTERDevice_FWDetail('WEB', 'MATTER_TypeDisplay', 'Matter');
like($type_html, qr/<td>1<\/td><td>On\/Off light<\/td>/,
     'endpoint type is restored from its reading without a Matter connection');
like($type_html, qr/<td>10<\/td><td>0xF123<\/td>/,
     'unknown hexadecimal type is restored without runtime helpers');
like($type_html, qr/<td>11<\/td><td>Contact sensor<\/td>/,
     'other endpoint type is restored independently');
is($attr{MATTER_TypeDisplay_EP1}{group}, 'On/Off light',
   'current group remains unchanged during the simulated restart');
is_deeply([MATTERDevice_DeviceTypeIds($defs{MATTER_TypeDisplay_EP10})], [0xF123],
    'group and display consume the same persisted type ID data');
$attr{MATTER_TypeDisplay_EP10}{group} = 'Node 88 (ioA)';
MATTERDevice_EnsureTypeGroup($defs{MATTER_TypeDisplay_EP10});
is($attr{MATTER_TypeDisplay_EP10}{group}, '0xF123',
   'automatic grouping recovers from the persisted reading after restart');
$defs{MATTER_TypeDisplay_EP10}{READINGS}{device_type_ids}{VAL} = 'not-a-type';
is_deeply([MATTERDevice_DeviceTypeIds($defs{MATTER_TypeDisplay_EP10})], [],
    'invalid restored reading cannot masquerade as a device type');
$defs{MATTER_TypeDisplay_EP10}{READINGS}{device_type_ids}{VAL} = '0xF123';

# Model and availability are the only root readings mirrored onto endpoints.
# Test all supported input paths with independent nodes sharing an ID on two IOs.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 95, name => 'MetadataNode',
    attributes => {'1/6/0' => JSON::true},
});
my $metadata_root = $defs{MATTER_MetadataNode};
my $metadata_ep1 = $defs{MATTER_MetadataNode_EP1};
ok($metadata_root && $metadata_ep1, 'metadata test node and endpoint exist');
ok(!defined(ReadingsVal($metadata_ep1->{NAME}, 'model', undef)),
   'an unknown root model is not fabricated on an endpoint');
ok(!defined(ReadingsVal($metadata_ep1->{NAME}, 'available', undef)),
   'unknown node availability is not fabricated on an endpoint');

# Unknown order between root BasicInformation and child attributes is harmless.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 95, name => 'MetadataNode', available => JSON::true,
    attributes => {'0/40/3' => 'Synthetic Model A', '1/6/0' => JSON::true,
                   '2/6/0' => JSON::false},
});
my $metadata_ep2 = $defs{MATTER_MetadataNode_EP2};
for my $ep ($metadata_ep1, $metadata_ep2) {
    is(ReadingsVal($ep->{NAME}, 'model', ''), 'Synthetic Model A',
       'discovery mirrors the root model to an existing/new endpoint');
    is(ReadingsVal($ep->{NAME}, 'available', ''), 'true',
       'discovery mirrors reported availability to an existing/new endpoint');
}
my $metadata_ep3 = MATTERDevice_GetOrCreateChild($metadata_root, 3);
ok($metadata_ep3, 'another endpoint is created from an existing node');
is(ReadingsVal($metadata_ep3->{NAME}, 'model', ''), 'Synthetic Model A',
   'newly created endpoint immediately receives the known model');
is(ReadingsVal($metadata_ep3->{NAME}, 'available', ''), 'true',
   'newly created endpoint immediately receives node availability');
ok(!defined(ReadingsVal($metadata_ep3->{NAME}, 'producer', undef)),
   'unrelated root readings are not inherited');

my $model_writes = $bulk_writes{$metadata_ep1->{NAME}}{model} // 0;
my $available_writes = $bulk_writes{$metadata_ep1->{NAME}}{available} // 0;
MATTER_ProcessNode($defs{ioA}, {
    node_id => 95, name => 'MetadataNode', available => JSON::true,
    attributes => {'0/40/3' => 'Synthetic Model A', '1/6/0' => JSON::true},
});
is($bulk_writes{$metadata_ep1->{NAME}}{model} // 0, $model_writes,
   'unchanged model does not write the endpoint reading again');
is($bulk_writes{$metadata_ep1->{NAME}}{available} // 0, $available_writes,
   'unchanged available does not write the endpoint reading again');

# Live events update the root model and immediately synchronize endpoints.
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [95, '0/40/3', 'Synthetic Model B'],
}));
is(ReadingsVal($metadata_root->{NAME}, 'model', ''), 'Synthetic Model B',
   'live BasicInformation change is stored at the root');
is(ReadingsVal($metadata_ep1->{NAME}, 'model', ''), 'Synthetic Model B',
   'live model changes reach an existing endpoint');
is(ReadingsVal($metadata_ep3->{NAME}, 'model', ''), 'Synthetic Model B',
   'live model changes reach a newly created endpoint');
is($bulk_writes{$metadata_ep1->{NAME}}{model} // 0, $model_writes + 1,
   'a changed model produces exactly one endpoint update');

# getConfig read_attribute results use the same propagation path.
$defs{ioA}{helper}{pending_config}{95001} = 95;
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => 95001,
    result => {'0/40/3' => 'Synthetic Model C'},
}));
is(ReadingsVal($metadata_ep2->{NAME}, 'model', ''), 'Synthetic Model C',
   'root getConfig results synchronize model on existing endpoints');

MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated', data => {node_id => 95, available => JSON::false},
}));
is(ReadingsVal($metadata_ep1->{NAME}, 'available', ''), 'false',
   'node_updated availability is propagated to endpoints');
is(ReadingsVal($metadata_ep3->{NAME}, 'available', ''), 'false',
   'node_updated reaches all endpoints');
is(ReadingsVal($metadata_root->{NAME}, 'state', ''), 'offline',
   'node_updated also sets the root native status');
is($bulk_writes{$metadata_ep1->{NAME}}{available} // 0, $available_writes + 1,
   'changed availability produces one endpoint update');

# An invalid or absent value must not turn into an invented state.
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated', data => {node_id => 95, available => 'unknown'},
}));
MATTER_ProcessNode($defs{ioA}, {node_id => 95, name => 'MetadataNode'});
is(ReadingsVal($metadata_ep1->{NAME}, 'available', ''), 'false',
   'unknown or missing availability never overwrites a valid report');
MATTERDevice_Parse($metadata_root, encode_json({
    event => 'node_updated', data => {node_id => 95, available => JSON::true},
}));
is(ReadingsVal($metadata_ep1->{NAME}, 'available', ''), 'true',
   'direct MATTERDevice node_updated event mirrors valid availability');
is(ReadingsVal($metadata_root->{NAME}, 'state', ''), 'online',
   'direct MATTERDevice updates use the same root state mapping');
MATTERDevice_Parse($metadata_root, encode_json({
    event => 'node_updated', data => {node_id => 95, available => 'unknown'},
}));
is(ReadingsVal($metadata_ep1->{NAME}, 'available', ''), 'true',
   'direct MATTERDevice node_updated ignores malformed availability');

# Same node ID under another MATTER IO must remain isolated.
$preferred_io = 'ioA';
MATTER_ProcessNode($defs{ioB}, {
    node_id => 95, name => 'OtherMetadataNode', available => JSON::true,
    attributes => {'0/40/3' => 'Other Model', '1/6/0' => JSON::true},
});
my $other_metadata_ep = $defs{MATTER_OtherMetadataNode_EP1};
ok($other_metadata_ep, 'a second IO may have the same Matter node ID');
is(ReadingsVal($other_metadata_ep->{NAME}, 'model', ''), 'Other Model',
   'same-ID endpoint on another IO keeps its own model');
MATTER_ProcessNode($defs{ioB}, {node_id => 95, available => JSON::false});
is(ReadingsVal($other_metadata_ep->{NAME}, 'available', ''), 'false',
   'same-ID endpoint on another IO keeps its own availability');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [95, '0/40/3', 'Synthetic Model D'],
}));
is(ReadingsVal($other_metadata_ep->{NAME}, 'model', ''), 'Other Model',
   'root model updates do not affect another IO');
MATTER_ProcessNode($defs{ioA}, {
    node_id => 95, name => 'MetadataNode', available => JSON::true,
});
is(ReadingsVal($other_metadata_ep->{NAME}, 'available', ''), 'false',
   'root availability updates do not affect another IO');

# autocreate=0 still allows metadata changes on already defined endpoints.
is(CommandAttr(undef, 'ioA autocreate 0'), undef,
   'autocreate can be disabled during metadata synchronization');
# The metadata update below represents another independently fresh interview,
# accepted after the preceding valid online report.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 95, name => 'MetadataNode', available => JSON::true,
    attributes => {'0/40/3' => 'Synthetic Model E', '4/6/0' => JSON::true},
});
is(ReadingsVal($metadata_ep1->{NAME}, 'model', ''), 'Synthetic Model E',
   'existing endpoint model updates with autocreate disabled');
is(ReadingsVal($metadata_ep2->{NAME}, 'available', ''), 'true',
   'existing endpoint availability updates with autocreate disabled');
ok(!$defs{MATTER_MetadataNode_EP4},
   'mirroring node metadata cannot create an endpoint when autocreate is disabled');
delete $attr{ioA}{autocreate};

# Existing endpoints missing mirrored readings are backfilled by an attribute-free
# snapshot. The persisted IODev also handles a transient missing runtime pointer.
delete $metadata_ep2->{READINGS}{model};
delete $metadata_ep2->{READINGS}{available};
delete $metadata_ep2->{IODev};
MATTER_ProcessNode($defs{ioA}, {node_id => 95, name => 'MetadataNode'});
is(ReadingsVal($metadata_ep2->{NAME}, 'model', ''), 'Synthetic Model E',
   'attribute-free discovery restores model on an existing endpoint');
is(ReadingsVal($metadata_ep2->{NAME}, 'available', ''), 'true',
   'attribute-free discovery restores availability on an existing endpoint');
is(CommandAttr(undef, 'MATTER_MetadataNode_EP2 IODev ioA'), undef,
   'test restores the endpoint runtime IODev pointer');


# Commissioning is initiated on the MATTER IO, not on an existing endpoint.
# Read the actual masked client WebSocket frames instead of mocking the JSON
# sender, so assertions cover the command payload on the wire.
socketpair(my $commission_client, my $commission_server, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "commissioning socketpair: $!";
my $commission_io = {
    NAME => 'commissionIO', TYPE => 'MATTER', READINGS => {}, helper => {},
    CD => $commission_client, FD => fileno($commission_client),
    ws_status => 'connected', websocket => 1,
};
$defs{commissionIO} = $commission_io;
my $read_exact = sub {
    my ($socket, $length) = @_;
    my $bytes = '';
    while (length($bytes) < $length) {
        my $received = sysread($socket, my $chunk, $length - length($bytes));
        die 'truncated commissioning WebSocket frame'
            unless defined($received) && $received > 0;
        $bytes .= $chunk;
    }
    return $bytes;
};
my $read_ws_json = sub {
    my ($peer) = @_;
    my ($first, $second) = unpack('CC', $read_exact->($peer, 2));
    die 'expected text WebSocket frame' unless ($first & 0x0f) == 1;
    die 'expected masked FHEM WebSocket frame' unless $second & 0x80;
    my $length = $second & 0x7f;
    $length = unpack('n', $read_exact->($peer, 2)) if $length == 126;
    $length = unpack('Q>', $read_exact->($peer, 8)) if $length == 127;
    my $mask = $read_exact->($peer, 4);
    my $encoded = $read_exact->($peer, $length);
    my $decoded = '';
    for my $i (0 .. $length-1) {
        $decoded .= chr(ord(substr($encoded, $i, 1)) ^
                        ord(substr($mask, $i % 4, 1)));
    }
    return JSON::decode_json($decoded);
};
my $manual_code = '35325335079'; # Synthetic setup code, not a production secret.
my $qr_code = 'MT:Y.ABCDEFG123456789';
my $usage = MATTER_Set($commission_io, 'commissionIO', 'commissionCode');
like($usage // '', qr/\[network\|auto\]/,
     'commissionCode without a code returns usage including the modes');
is(scalar(keys %{$commission_io->{helper}{pending_command} // {}}), 0,
   'missing code creates no pending server request');

@log = ();
is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode', $manual_code),
   undef, 'legacy one-argument command remains accepted');
my $network_request = $read_ws_json->($commission_server);
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'running',
   'commissioning starts with running status');
is(ReadingsVal('commissionIO', 'commissioning_mode', ''), 'network',
   'default mode recorded');
is(ReadingsVal('commissionIO', 'commissioning_error', 'unset'), '',
   'running clears previous error');
is($network_request->{command}, 'commission_with_code',
   'commissioning keeps the existing server API command');
is($network_request->{args}{code}, $manual_code,
   'manual code reaches the Matter server unchanged');
ok($network_request->{args}{network_only},
   'omitted mode retains network_only=true');
like(join("\n", @log), qr/Commissioning requested \(mode=network; BLE disabled\)/,
     'network mode is included in FHEM logs');
unlike(join("\n", @log), qr/\Q$manual_code\E/,
       'setup code is not logged for default mode');

my $busy = MATTER_Set($commission_io, 'commissionIO', 'commissionCode', $manual_code, 'auto');
like($busy // '', qr/already in progress/, 'parallel attempt is rejected');
unlike($busy // '', qr/\Q$manual_code\E/, 'busy error omits setup code');
is(scalar(keys %{$commission_io->{helper}{pending_command} // {}}), 1,
   'busy attempt does not add a request');
$mock_time += 38;
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $network_request->{message_id}, result => { node_id => 121 }
}));
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'success',
   'server response reports success');
is(ReadingsVal('commissionIO', 'commissioning_node_id', ''), 121,
   'successful response contains node ID');
is(ReadingsVal('commissionIO', 'commissioning_duration', ''), 38,
   'duration measures elapsed seconds');
ok(!exists($commission_io->{helper}{commissioning_active}),
   'success releases the active commissioning slot');

is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode',
              $manual_code, 'network'), undef,
   'explicit network mode is accepted');
my $explicit_network = $read_ws_json->($commission_server);
ok($explicit_network->{args}{network_only},
   'explicit network mode also sends network_only=true');
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $explicit_network->{message_id}, result => { node_id => 122 }
}));
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'success',
   'second network request completes independently');

# Attribute default is persistent FHEM configuration; command mode overrides it.
is(CommandAttr(undef, 'commissionIO commissionMode auto'), undef,
   'commissionMode auto is a valid MATTER attribute');
is(AttrVal('commissionIO', 'commissionMode', ''), 'auto',
   'configured commissioning mode is stored');
is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode', $manual_code),
   undef, 'omitted command mode uses configured auto');
my $from_auto_attr = $read_ws_json->($commission_server);
ok(!$from_auto_attr->{args}{network_only},
   'configured auto enables BLE/IP discovery without command suffix');
is(ReadingsVal('commissionIO', 'commissioning_mode', ''), 'auto',
   'status reading reflects configured auto');
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $from_auto_attr->{message_id}, result => { node_id => 124 }
}));

is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode', $manual_code, 'network'),
   undef, 'explicit network overrides configured auto');
my $from_network_override = $read_ws_json->($commission_server);
ok($from_network_override->{args}{network_only},
   'explicit network requires IP-only despite auto attribute');
is(ReadingsVal('commissionIO', 'commissioning_mode', ''), 'network',
   'status reading reflects explicit network');
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $from_network_override->{message_id}, result => { node_id => 125 }
}));
is(AttrVal('commissionIO', 'commissionMode', ''), 'auto',
   'one-off override does not alter persistent attribute');
like(CommandAttr(undef, 'commissionIO commissionMode invalid') // '',
     qr/commissionMode must be network or auto/,
   'invalid commissioning default is rejected');
is(AttrVal('commissionIO', 'commissionMode', ''), 'auto',
   'invalid value does not overwrite configured default');

is(CommandAttr(undef, 'commissionIO commissionMode network'), undef,
   'network can be configured explicitly');
is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode', $manual_code),
   undef, 'omitted mode works with configured network');
my $from_network_attr = $read_ws_json->($commission_server);
ok($from_network_attr->{args}{network_only},
   'configured network uses IP-only mode');
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $from_network_attr->{message_id}, result => { node_id => 126 }
}));

is(CommandDeleteAttr(undef, 'commissionIO commissionMode'), undef,
   'commissionMode attribute can be removed');
is(AttrVal('commissionIO', 'commissionMode', 'network'), 'network',
   'unset commissioning mode falls back to network');
is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode', $manual_code),
   undef, 'omitted mode works after deleting attribute');
my $without_attr = $read_ws_json->($commission_server);
ok($without_attr->{args}{network_only},
   'removing attribute restores original IP-only default');
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $without_attr->{message_id}, result => { node_id => 127 }
}));

@log = ();
my ($auto_return, $auto_skip_event) = MATTER_Set(
    $commission_io, 'commissionIO', 'commissionCode', $manual_code, 'auto');
is($auto_return, undef, 'auto mode is accepted for manual setup codes');
is($auto_skip_event, 1, 'commissionCode suppresses the synthetic FHEM set event carrying the code');
my $auto_request = $read_ws_json->($commission_server);
ok(!$auto_request->{args}{network_only},
   'auto mode sends network_only=false (BLE and IP discovery enabled)');
like(join("\n", @log), qr/Commissioning requested \(mode=auto; BLE allowed\)/,
     'auto mode is logged without implying that BLE was actually used');
unlike(join("\n", @log), qr/\Q$manual_code\E/,
       'manual setup code is not logged in auto mode');
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'running',
   'BLE-capable attempt shows running');
is(ReadingsVal('commissionIO', 'commissioning_mode', ''), 'auto',
   'BLE-capable attempt records auto mode');
$mock_time += 7;
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $auto_request->{message_id}, error_code => 4,
    reason => 'not-discovered',
    details => "Could not commission code $manual_code from $qr_code"
}));
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'failed',
   'server error reports failure');
is(ReadingsVal('commissionIO', 'commissioning_duration', ''), 7,
   'failed attempt records duration');
like(ReadingsVal('commissionIO', 'commissioning_error', ''), qr/^not-discovered:/,
   'typed failure reason preserved');
like(ReadingsVal('commissionIO', 'commissioning_error', ''),
     qr/\[code redacted\].*\[QR code redacted\]/,
   'error reading redacts manual and QR codes');
unlike(ReadingsVal('commissionIO', 'commissioning_error', ''),
       qr/\Q$manual_code\E|\Q$qr_code\E/,
   'error reading contains no setup code');
unlike(join("\n", @log), qr/\Q$manual_code\E|\Q$qr_code\E/,
   'error log contains no setup code');

is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode',
              $qr_code, 'auto'), undef,
   'Matter QR payloads are also accepted in auto mode');
my $qr_request = $read_ws_json->($commission_server);
is($qr_request->{args}{code}, $qr_code,
   'QR payload is delivered unchanged to the Matter server');
ok(!$qr_request->{args}{network_only}, 'QR auto mode also permits BLE discovery');
is(ReadingsVal('commissionIO', 'commissioning_error', 'unset'), '',
   'new attempt clears stale failure');
MATTER_ParseMessage($commission_io, encode_json({
    message_id => 'unrelated', result => { node_id => 999 }
}));
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'running',
   'unrelated result cannot finish active commissioning');
$mock_time += 3;
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $qr_request->{message_id}, result => { node_id => 123 }
}));
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'success',
   'QR response reports success');
is(ReadingsVal('commissionIO', 'commissioning_node_id', ''), 123,
   'QR response reports new node ID');

# Legacy server error envelopes must also be sanitized in event-visible readings.
@log = ();
is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode', $manual_code),
   undef, 'another request may start after QR commissioning succeeded');
my $legacy_request = $read_ws_json->($commission_server);
$mock_time += 2;
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $legacy_request->{message_id},
    error => { message => "Legacy server failure for code $manual_code" }
}));
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'failed',
   'legacy error response reports failure');
like(ReadingsVal('commissionIO', 'commissioning_error', ''), qr/\[code redacted\]/,
   'legacy error reading redacts setup code');
unlike(join("\n", @log), qr/\Q$manual_code\E/,
   'legacy error log redacts setup code');
unlike(join("\n", @log), qr/\Q$qr_code\E/,
   'QR code is absent from FHEM logs');
unlike(join("\n", @log), qr/\Q$qr_code\E/,
       'QR setup code is absent from FHEM logs');

is(MATTER_Set($commission_io, 'commissionIO', 'commissionCode',
              ('0' x 21), 'auto'), undef,
   'extended 21-digit Matter manual codes remain accepted');
my $extended_request = $read_ws_json->($commission_server);
is($extended_request->{args}{code}, '0' x 21,
   'extended manual setup code is transmitted without numeric conversion');

my $pending_before_invalid = scalar keys %{$commission_io->{helper}{pending_command}};
for my $invalid (
    ['1234', 'auto'],
    [$manual_code, 'ble'],
    [$manual_code, 'auto', 'extra'],
    ['MT:INVALID_QR', 'auto'],
    ['MT:' . ('A' x 3000), 'auto'],
) {
    my $error = MATTER_Set($commission_io, 'commissionIO', 'commissionCode', @$invalid);
    ok(defined($error) && length($error), 'invalid commissioning parameters are rejected');
    unlike($error // '', qr/\Q$invalid->[0]\E/,
           'invalid setup code is not echoed in the error');
    is(scalar(keys %{$commission_io->{helper}{pending_command}}),
       $pending_before_invalid, 'invalid request creates no pending command');
}

# A WebSocket disconnect interrupts the outstanding extended-code attempt.
# The Matter server may still complete; a lost response is not a failure.
$mock_time += 5;
MATTER_Close($commission_io);
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'interrupted',
   'connection loss marks commissioning as interrupted');
is(ReadingsVal('commissionIO', 'commissioning_duration', ''), 5,
   'interrupt reports elapsed time');
like(ReadingsVal('commissionIO', 'commissioning_error', ''), qr/outcome unknown/,
   'interruption does not imply a failed server operation');
ok(!exists $commission_io->{helper}{commissioning_active},
   'closed connection releases active commissioning');
ok(!exists $commission_io->{helper}{pending_command},
   'closed connection clears all pending requests');
MATTER_ParseMessage($commission_io, encode_json({
    message_id => $extended_request->{message_id}, result => { node_id => 456 }
}));
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'interrupted',
   'late reply cannot overwrite interrupted status');
my $disconnected = MATTER_Set($commission_io, 'commissionIO', 'commissionCode',
                              $manual_code, 'auto');
like($disconnected // '', qr/No active WebSocket/, 'disconnected IO refuses new request');
unlike($disconnected // '', qr/\Q$manual_code\E/,
   'disconnected error does not echo setup code');
is(ReadingsVal('commissionIO', 'commissioning_status', ''), 'interrupted',
   'failed send does not produce misleading running status');
close($commission_server);

# FHEM calls SetFn in list context. The second return value prevents DoSet
# from synthesizing a plaintext password-bearing event on this device.
socketpair(my $credential_socket, my $credential_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die 'credential socketpair';
my $credential_io = {
    NAME => 'credentialIO', TYPE => 'MATTER', READINGS => {}, helper => {},
    CD => $credential_socket, websocket => 1, ws_status => 'connected'
};
$defs{credentialIO} = $credential_io;
my ($wifi_result, $wifi_skip_event) = MATTER_Set(
    $credential_io, 'credentialIO', 'setWifiCredentials',
    'SyntheticSSID', 'SyntheticPassword'
);
is($wifi_result, undef, 'credential setter accepts a connected request');
is($wifi_skip_event, 1, 'credential command suppresses FHEM synthetic set event');
$credential_io->{READINGS}{wifi_7_ssid} = { VAL => 'PreviousSSID' };
is(MATTER_Set($credential_io, 'credentialIO', 'getCredentials'), undef,
   'request credential inventory for failure-preservation checks');
my $invalid_credential_id = $credential_io->{helper}{next_message_id};
my $credential_parse_ok = eval {
    MATTER_ParseMessage($credential_io, encode_json({
        message_id => $invalid_credential_id, result => []
    }));
    1;
};
ok($credential_parse_ok, 'unexpected credential array response cannot crash parser');
is(ReadingsVal('credentialIO', 'wifi_7_ssid', ''), 'PreviousSSID',
   'malformed credential response does not erase existing readings');
is(MATTER_Set($credential_io, 'credentialIO', 'getCredentials'), undef,
   'request credential inventory with invalid nested shape');
my $invalid_nested_id = $credential_io->{helper}{next_message_id};
MATTER_ParseMessage($credential_io, encode_json({
    message_id => $invalid_nested_id, result => { wifi => 'unexpected' }
}));
is(ReadingsVal('credentialIO', 'wifi_7_ssid', ''), 'PreviousSSID',
   'malformed nested credential list preserves existing readings');
is(MATTER_Set($credential_io, 'credentialIO', 'getCredentials'), undef,
   'request credential inventory with malformed item');
my $invalid_item_id = $credential_io->{helper}{next_message_id};
MATTER_ParseMessage($credential_io, encode_json({
    message_id => $invalid_item_id,
    result => { wifi => [{ id => 7, ssid => ['not-a-scalar'] }] }
}));
is(ReadingsVal('credentialIO', 'wifi_7_ssid', ''), 'PreviousSSID',
   'malformed credential item cannot partially delete the previous inventory');
is(MATTER_Set($credential_io, 'credentialIO', 'getCredentials'), undef,
   'request valid updated credential inventory');
my $valid_credential_id = $credential_io->{helper}{next_message_id};
MATTER_ParseMessage($credential_io, encode_json({
    message_id => $valid_credential_id,
    result => { wifi => [{ id => 7, ssid => 'ReplacementSSID' }], thread => [] }
}));
is(ReadingsVal('credentialIO', 'wifi_7_ssid', ''), 'ReplacementSSID',
   'valid credential inventory replaces the previous readings');
MATTER_Close($credential_io);
close($credential_peer);

# FHEM renaming an IO does not automatically migrate its clients. Test both
# the native callback and subsequent discovery without losing client identity.
my $old_preferred_io = $preferred_io;
$preferred_io = 'renameIO';
$defs{renameIO} = {
    NAME => 'renameIO', TYPE => 'MATTER', helper => {}, READINGS => {}
};
MATTER_ProcessNode($defs{renameIO}, node(778, 'Renamable'));
my $rename_root = $defs{MATTER_Renamable};
my $rename_child = $defs{MATTER_Renamable_EP1};
ok($rename_root && $rename_child, 'IO rename fixture creates node and endpoint');
# Explicit root IODev and auto-assigned endpoint IODev both need to survive.
delete $attr{$rename_child->{NAME}}{IODev};
$defs{renameIO}{FD} = 100;
$selectlist{renameIO} = $defs{renameIO};
is(CommandRename(undef, 'renameIO renamedIO'), undef, 'native FHEM IO rename succeeds');
is(AttrVal($rename_root->{NAME}, 'IODev', ''), 'renamedIO',
   'root IODev attribute follows renamed IO');
is(AttrVal($rename_child->{NAME}, 'IODev', ''), 'renamedIO',
   'endpoint without a prior IODev attribute gains durable new ownership');
is($modules{MATTERDevice}{defptr}{'renamedIO:778'}, $rename_root,
   'root defptr is indexed under new IO name');
ok(!exists $modules{MATTERDevice}{defptr}{'renameIO:778'},
   'old IO root key is removed');
ok(!exists $selectlist{renameIO} && $selectlist{renamedIO} eq $defs{renamedIO},
   'FHEM selectlist uses renamed IO key');
my $before_rename_resync = count_devices();
MATTER_ProcessNode($defs{renamedIO}, node(778, 'Renamable'));
is(count_devices(), $before_rename_resync,
   'rediscovery after IO rename preserves the original devices');
$preferred_io = $old_preferred_io;
delete $selectlist{renamedIO};

# Request IDs are unique across all in-flight command and read namespaces.
$defs{ioA}{helper}{next_message_id} = 15;
$defs{ioA}{helper}{pending_command}{16} = 'get_nodes';
$defs{ioA}{helper}{pending_config}{17} = { node_id => 42, created_at => $mock_time };
is(MATTER_NextMessageId($defs{ioA}), 18,
   'shared message ID allocator skips both pending request maps');
delete $defs{ioA}{helper}{pending_command}{16};
delete $defs{ioA}{helper}{pending_config}{17};

# A complete snapshot cannot reverse structural events delivered after its
# request, even if the snapshot contains the affected node.
is(MATTER_Set($defs{ioA}, 'ioA', 'discover'), undef, 'tracked discovery is sent');
my $snapshot_id = $defs{ioA}{helper}{next_message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_removed', data => 42
}));
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'removed',
   'newer node removal event is applied');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $snapshot_id, result => [node(42, 'OldNodeLabel')]
}));
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'removed',
   'late snapshot does not re-add node removed by a newer event');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_added', data => node(42, 'Hall Light')
}));
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'present',
   'new node_added event restores node membership');

# One partial node_updated cannot invalidate useful fields from an older
# complete snapshot. Other missing nodes must still be marked removed.
MATTER_ProcessNode($defs{ioA}, node(779, 'MissingInSnapshot'));
my $snapshot_other_root = $defs{MATTER_MissingInSnapshot};
ok($snapshot_other_root, 'separate node is present before the structural race');
is(MATTER_Set($defs{ioA}, 'ioA', 'discover'), undef,
   'discover starts a complete snapshot for multiple nodes');
my $partial_snapshot_id = $defs{ioA}{helper}{next_message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated', data => { node_id => 42, available => JSON::false }
}));
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated',
    data => { node_id => 42, attributes => { '1/6/0' => JSON::false } }
}));
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $partial_snapshot_id,
    result => [{
        node_id => 42, name => 'OldSnapshotName',
        available => JSON::true,
        attributes => { '1/6/0' => JSON::true, '1/47/12' => 154 }
    }]
}));
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'false',
   'partial live availability overrides only matching snapshot field');
is(ReadingsVal($child->{NAME}, 'state', ''), 'on',
   'partial node data does not import cached OnOff while the node is offline');
is(ReadingsVal($child->{NAME}, 'battery_percent', ''), 66,
   'unrelated battery data is retained from earlier live reports');
is(ReadingsVal($snapshot_other_root->{NAME}, 'matter_status', ''), 'removed',
   'event for first node does not suppress removal of unrelated missing node');

# The latest explicit discovery supersedes an unresponsive earlier one,
# keeping only one full snapshot request in flight.
is(MATTER_Set($defs{ioA}, 'ioA', 'discover'), undef,
   'first explicit discovery queued');
my $superseded_id = $defs{ioA}{helper}{next_message_id};
is(MATTER_Set($defs{ioA}, 'ioA', 'discover'), undef,
   'newer discovery supersedes prior unanswered discovery');
my $current_snapshot_id = $defs{ioA}{helper}{next_message_id};
ok(!exists($defs{ioA}{helper}{pending_command}{$superseded_id}),
   'superseded discovery does not accumulate an orphaned pending request');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $superseded_id, result => []
}));
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'present',
   'response to superseded discovery is ignored');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $current_snapshot_id,
    result => [node(42, 'Hall Light'), node(779, 'MissingInSnapshot')]
}));
is(ReadingsVal($snapshot_other_root->{NAME}, 'matter_status', ''), 'present',
   'latest discovery resynchronizes an independently missing node');

# Invalid live node metadata is not a reason to discard a valid attribute
# from the snapshot; it was never published as a real device state.
is(MATTER_Set($defs{ioA}, 'ioA', 'discover'), undef,
   'start discovery before invalid live node attribute');
my $valid_snapshot_id = $defs{ioA}{helper}{next_message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated',
    data => { node_id => 42, attributes => { '1/6/0' => 'false' } }
}));
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $valid_snapshot_id,
    result => [{ node_id => 42, name => 'Hall Light',
                 attributes => { '1/6/0' => JSON::true } },
               node(779, 'MissingInSnapshot')]
}));
is(ReadingsVal($child->{NAME}, 'state', ''), 'on',
   'a valid snapshot remains usable in a separately recovered online scenario');
close($io_a_peer);
MATTER_Close($defs{ioA});


# Issue #30 - standard sensor clusters; descriptor-before-attribute ordering.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 3000, name => 'SensorProbe', available => JSON::true,
    attributes => {
        '1/69/0' => JSON::true,
        '1/29/0' => [{ '0' => 0x0015, '1' => 1 }],
        '2/1026/0' => 2234,
        '2/29/0' => [{ '0' => 0x0302, '1' => 1 }],
        '3/1029/0' => 4350,
        '3/29/0' => [{ '0' => 0x0307, '1' => 1 }],
        '4/1024/0' => 30001,
        '4/29/0' => [{ '0' => 0x0106, '1' => 1 }],
        '5/1030/0' => 1,
        '5/29/0' => [{ '0' => 0x0107, '1' => 1 }],
        '6/69/0' => JSON::true,
        '6/29/0' => [{ '0' => 0x0043, '1' => 1 }],
        '7/69/0' => JSON::false,
        '7/29/0' => [{ '0' => 0x0044, '1' => 1 }],
    },
});
is(ReadingsVal('MATTER_SensorProbe_EP1', 'contact', ''), 'closed',
   'contact sensor true means closed');
is(ReadingsVal('MATTER_SensorProbe_EP2', 'temperature', ''), 22.34,
   'temperature centidegrees become Celsius');
is(ReadingsVal('MATTER_SensorProbe_EP3', 'humidity', ''), 43.5,
   'humidity centipercent converts to percent');
is(ReadingsVal('MATTER_SensorProbe_EP4', 'illuminance', ''), 1000,
   'logarithmic Matter illuminance becomes lux');
is(ReadingsVal('MATTER_SensorProbe_EP5', 'motion', ''), 'motion',
   'occupancy bitmask sets motion');
is(ReadingsVal('MATTER_SensorProbe_EP6', 'water_leak', ''), 'leak',
   'water-leak type maps true to leak');
is(ReadingsVal('MATTER_SensorProbe_EP7', 'rain', ''), 'dry',
   'rain type maps false to dry');
MATTERDevice_Parse($defs{MATTER_SensorProbe}, encode_json({
    node_id => 3000, attributes => {
        '1/69/0' => JSON::false,
        '2/1026/0' => -32768,
        '3/1029/0' => 65535,
        '4/1024/0' => 65535,
        '5/1030/0' => 0,
    }
}));
is(ReadingsVal('MATTER_SensorProbe_EP1', 'contact', ''), 'open',
   'contact false means open');
is(ReadingsVal('MATTER_SensorProbe_EP5', 'motion', ''), 'nomotion',
   'occupancy zero means nomotion');
is(ReadingsVal('MATTER_SensorProbe_EP2', 'temperature', ''), 22.34,
   'temperature invalid sentinel leaves old value');
is(ReadingsVal('MATTER_SensorProbe_EP3', 'humidity', ''), 43.5,
   'humidity invalid sentinel leaves old value');
is(ReadingsVal('MATTER_SensorProbe_EP4', 'illuminance', ''), 1000,
   'illuminance invalid sentinel leaves old value');


# Issue #31: repeated identical switch events must not be lost.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 3100, name => 'SwitchProbe', available => JSON::true,
    attributes => { '1/59/0' => 0, '1/29/0' => [{ '0' => 0x000F, '1' => 1 }],
                    '2/59/0' => 0, '2/29/0' => [{ '0' => 0x000F, '1' => 1 }] }
});
@direct_events = ();
for (1 .. 2) {
    MATTER_ParseMessage($defs{ioA}, encode_json({
        event => 'node_event',
        data => { node_id => 3100, endpoint_id => 1, cluster_id => 59,
                  event_id => 3, data => {} }
    }));
}
is(ReadingsVal('MATTER_SwitchProbe_EP1', 'button', ''), 'short',
   'Matter short release produces button short');
is(scalar(@direct_events), 2,
   'two identical button values emit two explicit FHEM events');
is($direct_events[0][1], 'button: short',
   'button event is suitable for notify/DOIF');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_event',
    data => { node_id => 3100, endpoint_id => 2, cluster_id => 59,
              event_id => 6, data => { totalNumberOfPressesCounted => 2 } }
}));
is(ReadingsVal('MATTER_SwitchProbe_EP2', 'button', ''), 'double',
   'second endpoint receives double-press event');
my $before_invalid = scalar(@direct_events);
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_event',
    data => { node_id => 3100, endpoint_id => 2, cluster_id => 59,
              event_id => 6, data => { totalNumberOfPressesCounted => 'bad' } }
}));
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_event',
    data => { node_id => 3100, endpoint_id => 2, cluster_id => 51,
              event_id => 3, data => {} }
}));
is(scalar(@direct_events), $before_invalid,
   'invalid event payload and unrelated clusters cause no button events');


# Issue #32: pressure and concentration clusters use specified units.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 3200, name => 'EnvironmentProbe', available => JSON::true,
    attributes => {
        '1/1027/0' => 1013, # 10 * 101.3 kPa -> 1013 hPa
        '2/1037/0' => 650,
        '2/1037/8' => 0, # ppm
        '3/1066/0' => 12.5,
        '3/1066/8' => 4, # ug/m3
        '4/1070/0' => 3.5,
        '4/1070/8' => 1, # ppb
    },
});
is(ReadingsVal('MATTER_EnvironmentProbe_EP1', 'pressure', ''), 1013,
   'pressure MeasuredValue is displayed in hPa');
is(ReadingsVal('MATTER_EnvironmentProbe_EP2', 'co2', ''), 650,
   'CO2 measured value is preserved');
is(ReadingsVal('MATTER_EnvironmentProbe_EP2', 'co2_unit', ''), 'ppm',
   'CO2 unit is advertised, not guessed');
is(ReadingsVal('MATTER_EnvironmentProbe_EP3', 'pm25', ''), 12.5,
   'PM2.5 measurement handles decimal values');
is(ReadingsVal('MATTER_EnvironmentProbe_EP3', 'pm25_unit', ''), 'ug/m3',
   'PM2.5 microgram-per-cubic-metre unit');
is(ReadingsVal('MATTER_EnvironmentProbe_EP4', 'tvoc_unit', ''), 'ppb',
   'TVOC unit is independent of CO2 unit');
MATTERDevice_Parse($defs{MATTER_EnvironmentProbe}, encode_json({
    node_id => 3200, attributes => {
        '1/1027/0' => -32768,
        '2/1037/0' => -5,
        '2/1037/8' => 255,
    }
}));
is(ReadingsVal('MATTER_EnvironmentProbe_EP1', 'pressure', ''), 1013,
   'pressure null sentinel leaves previous reading');
is(ReadingsVal('MATTER_EnvironmentProbe_EP2', 'co2', ''), 650,
   'negative concentrations are ignored');
is(ReadingsVal('MATTER_EnvironmentProbe_EP2', 'co2_unit', ''), 'ppm',
   'unknown units do not overwrite a valid known unit');


# The earlier transport tests close ioA deliberately. Restore a modeled
# active connection for the new set-command fixtures.
socketpair(my $feature_socket, my $feature_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die 'feature socketpair';
$defs{ioA}{CD} = $feature_socket;
$defs{ioA}{websocket} = 1;
$defs{ioA}{ws_status} = 'connected';
$defs{ioA}{test_send_text} = sub {
    push @sent_requests, JSON::decode_json($_[0]);
    return 1;
};

# Issue #34: native LevelControl move, step and stop.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 3400, name => 'DimProbe', available => JSON::true,
    attributes => {
        '1/8/65529' => [1, 2, 3],
        '1/8/65531' => [0],
        '1/8/0' => 100,
    },
});
my $dim = $defs{MATTER_DimProbe_EP1};
ok(grep(/^dim_up:noArg$/, MATTERDevice_GetSetList($dim)),
   'native Move is offered when accepted');
ok(grep(/^dim_stop:noArg$/, MATTERDevice_GetSetList($dim)),
   'native Stop is offered when accepted');
@sent_requests = ();
is(MATTERDevice_Set($dim, $dim->{NAME}, 'dim_up'), undef,
   'native dim up command accepted');
is($sent_requests[-1]{args}{command_name}, 'Move',
   'native Move rather than repeated pct command');
is($sent_requests[-1]{args}{payload}{rate}, 30,
   'continuous dimming defaults to rate 30');
is($sent_requests[-1]{args}{payload}{moveMode}, 0,
   'dim_up uses MoveMode Up');
is(CommandAttr(undef, $dim->{NAME} . ' dimRate 60'), undef,
   'device-specific dimRate can be configured');
@sent_requests = ();
is(MATTERDevice_Set($dim, $dim->{NAME}, 'dim_down'), undef,
   'native dim down command accepted');
is($sent_requests[-1]{args}{payload}{rate}, 60,
   'the following dim command uses the changed rate');
is($sent_requests[-1]{args}{payload}{moveMode}, 1,
   'dim_down uses MoveMode Down');
is(MATTERDevice_Set($dim, $dim->{NAME}, 'dim_step_up'), undef,
   'native step command accepted');
is($sent_requests[-1]{args}{command_name}, 'Step',
   'step uses native LevelControl Step');
is(MATTERDevice_Set($dim, $dim->{NAME}, 'dim_stop'), undef,
   'native stop command accepted');
is($sent_requests[-1]{args}{command_name}, 'Stop',
   'dim_stop uses native Stop and no timer');


# Issue #33: Thermostat, FanControl, Identify and structured writes.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 3300, name => 'HVACProbe', available => JSON::true,
    attributes => {
        '1/513/65531' => [0, 18, 27, 28],
        '1/513/65532' => 1,
        '1/513/27' => 2,
        '1/513/0' => 2250,
        '1/513/18' => 2100,
        '1/513/28' => 4,
        '2/514/65531' => [0, 1, 2, 3],
        '2/514/65532' => 0,
        '2/514/1' => 0,
        '2/514/0' => 2,
        '2/514/2' => 55,
        '2/514/3' => 53,
        '3/3/65529' => [0],
        '3/3/0' => 0,
    }
});
my $therm = $defs{MATTER_HVACProbe_EP1};
my $fan = $defs{MATTER_HVACProbe_EP2};
my $identify = $defs{MATTER_HVACProbe_EP3};
is(ReadingsVal($therm->{NAME}, 'measured-temp', ''), 22.5,
   'thermostat measured temperature is centidegrees to Celsius');
is(ReadingsVal($therm->{NAME}, 'desired-temp', ''), 21,
   'thermostat heating setpoint is scaled');
is(ReadingsVal($therm->{NAME}, 'mode', ''), 'heat',
   'thermostat mode is decoded');
is(ReadingsVal($fan->{NAME}, 'fan_mode', ''), 'medium',
   'fan mode is decoded');
is(ReadingsVal($fan->{NAME}, 'fan_pct', ''), 53,
   'fan current percentage is read separately from setting');
ok(grep(/^desired-temp:/, MATTERDevice_GetSetList($therm)),
   'thermostat setpoint offered if advertised in AttributeList');
ok(grep(/^fan_pct:/, MATTERDevice_GetSetList($fan)),
   'fan setting offered if advertised');
ok(grep(/^identify:noArg$/, MATTERDevice_GetSetList($identify)),
   'Identify offered if command is accepted');
@sent_requests = ();
is(MATTERDevice_Set($therm, $therm->{NAME}, 'desired-temp', '21.5'), undef,
   'thermostat setpoint accepts decimal value');
is($sent_requests[-1]{command}, 'write_attribute',
   'thermostat writes through the Matter server');
is($sent_requests[-1]{args}{attribute_path}, '1/513/18',
   'thermostat uses OccupiedHeatingSetpoint');
is($sent_requests[-1]{args}{value}, 2150,
   'temperature write uses centidegrees');
is(ReadingsVal($therm->{NAME}, 'desired-temp', ''), 21,
   'outgoing set does not optimistically overwrite measured reading');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $sent_requests[-1]{message_id}, result => undef
}));
is(MATTERDevice_Set($fan, $fan->{NAME}, 'fan_mode', 'high'), undef,
   'fan mode is set with native attribute write');
is($sent_requests[-1]{args}{value}, 3,
   'fan high maps to native enum value 3');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $sent_requests[-1]{message_id}, result => undef
}));
is(MATTERDevice_Set($identify, $identify->{NAME}, 'identify'), undef,
   'Identify command accepted');
is($sent_requests[-1]{args}{command_name}, 'Identify',
   'native Identify command used');
is($sent_requests[-1]{args}{payload}{identifyTime}, 15,
   'Identify lasts 15 seconds');
like(MATTERDevice_Set($fan, $fan->{NAME}, 'fan_pct', '300') // '',
   qr/between 0 and 100/, 'invalid fan target is rejected');


# Issue #27: cache protection is node-wide, preserves manual edits and all
# device-derived metadata; valid online reports resume normal synchronization.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2700, name => 'OfflineProbe', available => JSON::true,
    attributes => {
        '1/6/0' => JSON::true,
        '1/47/12' => 154,
        '1/29/0' => [{ '0' => 0x0100, '1' => 1 }],
    },
});
my $offline_root = $defs{MATTER_OfflineProbe};
my $offline_child = $defs{MATTER_OfflineProbe_EP1};
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'on',
   'pre-outage state is known online');
MATTER_ProcessNode($defs{ioA}, { node_id => 2700, available => JSON::false });
readingsSingleUpdate($offline_child, 'state', 'off', 1);
readingsSingleUpdate($offline_child, 'battery_percent', 10, 1);
my $old_type = ReadingsVal($offline_child->{NAME}, 'device_type_ids', '');
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2700, available => JSON::false,
    attributes => {
        '1/6/0' => JSON::true,
        '1/47/12' => 160,
        '1/29/0' => [{ '0' => 0x010A, '1' => 1 }],
        '1/8/65529' => [1, 2, 3],
    },
});
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'off',
   'cached offline OnOff does not overwrite manual correction');
is(ReadingsVal($offline_child->{NAME}, 'battery_percent', ''), 10,
   'cached offline power source does not overwrite manual correction');
is(ReadingsVal($offline_child->{NAME}, 'device_type_ids', ''), $old_type,
   'cached offline device types are not adopted');
ok(!MATTERDevice_CommandAccepted($offline_child, 8, 1),
   'cached offline command metadata is not adopted');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [2700, '1/6/0', JSON::true]
}));
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'off',
   'individual update is ignored while explicitly offline');
@sent_requests = ();
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2700, available => JSON::true,
    attributes => { '1/6/0' => JSON::true, '1/47/12' => 190 },
});
my @recovery_requests = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2700
} @sent_requests;
is(scalar(@recovery_requests), 1,
   'offline to online generates exactly one event-driven capability read');
is_deeply([sort @{$recovery_requests[0]{args}{attribute_path}}],
          [sort qw(*/*/65529 */*/65531 */*/65532 */*/65533)],
          'automatic refresh asks only for structural Matter metadata');
ok($defs{ioA}{helper}{pending_config}{$recovery_requests[0]{message_id}}{capability_only},
   'capability request is tracked separately from device-state updates');
ok(!grep(/^on:noArg$/, MATTERDevice_GetSetList($offline_child)),
   'setter is not fabricated before command metadata is received');
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'on',
   'valid online snapshot restores the reported state without another live event');
is(ReadingsVal($offline_child->{NAME}, 'battery_percent', ''), 95,
   'valid online snapshot restores the reported battery value');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $recovery_requests[0]{message_id},
    result => {
        '1/6/65529' => [0, 1, 2],
        '1/6/65533' => 6,
        '1/6/65532' => 0, # No OffOnly feature: On/Toggle are usable.
        '1/6/0' => JSON::true,
        '1/47/12' => 175,
    }
}));
is($offline_child->{helper}{capabilities}{6}{cluster_revision}, 6,
   'capability recovery retains the reported cluster revision');
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($offline_child)),
   'recovery restores On setter from an advertised AcceptedCommandList');
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'on',
   'automatic metadata recovery leaves the accepted state unchanged');
is(ReadingsVal($offline_child->{NAME}, 'battery_percent', ''), 95,
   'automatic metadata recovery cannot inject unrequested sensor values');

@sent_requests = ();
is(MATTERDevice_Set($offline_child, $offline_child->{NAME}, 'getConfig'),
   undef, 'manual getConfig reads device values while online');
my $manual_recovery_id = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $manual_recovery_id,
    result => {
        '1/6/65529' => [0, 1, 2],
        '1/6/65532' => 0,
        '1/6/0' => JSON::false,
        '1/47/12' => 180,
    }
}));
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'off',
   'explicit getConfig accepts reported OnOff while online');
is(ReadingsVal($offline_child->{NAME}, 'battery_percent', ''), 90,
   'explicit getConfig accepts reported battery while online');
ok(MATTERDevice_CommandAccepted($offline_child, 6, 1),
   'explicit getConfig preserves advertised command metadata');

@sent_requests = ();
is(MATTERDevice_Set($offline_child, $offline_child->{NAME}, 'getConfig'),
   undef, 'second manual getConfig starts before another offline transition');
my $expired_recovery_id = $sent_requests[-1]{message_id};
MATTER_ProcessNode($defs{ioA}, { node_id => 2700, available => JSON::false });
like(MATTERDevice_Set($offline_child, $offline_child->{NAME}, 'getConfig') // '',
     qr/offline/, 'manual read is not sent while the node is offline');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $expired_recovery_id,
    result => { '1/6/65529' => [] }
}));
ok(MATTERDevice_CommandAccepted($offline_child, 6, 1),
   'reply from a previous availability epoch cannot erase command metadata');
@sent_requests = ();
ok(!MATTERDevice_NeedsCapabilityRefresh($offline_root),
   'empty capability cache placeholders do not imply missing Matter commands');
MATTER_ProcessNode($defs{ioA}, { node_id => 2700, available => JSON::true });
my @second_recovery = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2700
} @sent_requests;
is(scalar(@second_recovery), 0,
   'another offline/online cycle does not re-read already known commands');
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($offline_child)),
   'the existing verified command metadata remains usable after recovery');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [2700, '1/6/0', JSON::true]
}));
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'on',
   'new live report releases state for its specific attribute');
is(ReadingsVal($offline_child->{NAME}, 'battery_percent', ''), 90,
   'unreported battery retains its last accepted read value');
is(ReadingsVal($offline_root->{NAME}, 'state', ''), 'online',
   'root availability remains independent from endpoint state');


# Startup when a known node is offline must not depend on old has_* flags
# or a subsequent FHEM process restart to restore its set commands.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2701, name => 'BootOfflineProbe', available => JSON::false,
    attributes => { '1/6/0' => JSON::true },
});
my $boot_root = $defs{MATTER_BootOfflineProbe};
my $boot_child = $defs{MATTER_BootOfflineProbe_EP1};
ok($boot_root && $boot_child, 'offline startup retains endpoint ownership');
readingsSingleUpdate($boot_child, 'state', 'off', 1);
ok(!grep(/^on:noArg$/, MATTERDevice_GetSetList($boot_child)),
   'offline startup does not invent an On setter');
@sent_requests = ();
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2701, available => JSON::true,
    attributes => { '1/6/0' => JSON::true }
});
my @boot_reads = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2701
} @sent_requests;
is(scalar(@boot_reads), 1,
   'recovery after an offline startup automatically requests capabilities');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $boot_reads[0]{message_id},
    result => {
        '1/6/65529' => [0, 1, 2],
        '1/6/0' => JSON::true,
    },
}));
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($boot_child)),
   'On setter returns after offline startup without has_* fallback');
is(ReadingsVal($boot_child->{NAME}, 'state', ''), 'on',
   'offline-start recovery synchronizes the online snapshot state');

# Known command metadata survives a temporary outage. Do not read it again
# just because the server publishes another availability=true snapshot.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2702, name => 'KnownCapabilitiesProbe', available => JSON::true,
    attributes => {
        '1/6/0' => JSON::true,
        '1/6/65529' => [0, 1, 2],
        '1/6/65532' => 0,
    },
});
my $known_root = $defs{MATTER_KnownCapabilitiesProbe};
my $known_child = $defs{MATTER_KnownCapabilitiesProbe_EP1};
ok(MATTERDevice_CommandAccepted($known_child, 6, 1),
   'known capability fixture has a valid accepted command list');
MATTER_ProcessNode($defs{ioA}, { node_id => 2702, available => JSON::false });
readingsSingleUpdate($known_child, 'state', 'off', 1);
@sent_requests = ();
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2702, available => JSON::true,
    attributes => { '1/6/0' => JSON::true }
});
ok(!grep({ ($_->{command} // '') eq 'read_attribute' &&
             ($_->{args}{node_id} // 0) == 2702 } @sent_requests),
   'already known command metadata needs no additional read');
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($known_child)),
   'known On control remains available without refresh');
is(ReadingsVal($known_child->{NAME}, 'state', ''), 'on',
   'known-command recovery accepts physical values from the online snapshot');

# A missing FeatureMap for an advertised feature-dependent command is still
# missing metadata, even though AcceptedCommandList already exists.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2705, name => 'PartialFeatureProbe', available => JSON::true,
    attributes => {
        '1/768/0' => 30,
        '1/768/65529' => [6],
    },
});
my $feature_root = $defs{MATTER_PartialFeatureProbe};
my $feature_child = $defs{MATTER_PartialFeatureProbe_EP1};
MATTER_ProcessNode($defs{ioA}, {node_id => 2705, available => JSON::false});
@sent_requests = ();
MATTER_ProcessNode($defs{ioA}, {node_id => 2705, available => JSON::true});
my @feature_reads = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2705
} @sent_requests;
is(scalar(@feature_reads), 1,
   'missing FeatureMap triggers recovery even with a known command list');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $feature_reads[0]{message_id},
    result => { '1/768/65532' => 1 }
}));
ok(grep(/^rgb:/, MATTERDevice_GetSetList($feature_child)),
   'recovered FeatureMap unlocks the advertised Hue command');

# A matched but empty response is not a completed recovery. Only later
# events, with cooldown and a per-availability-epoch bound, can retry.
my $time_before_recovery = $mock_time;
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2703, name => 'RetryProbe', available => JSON::false,
    attributes => { '1/6/0' => JSON::true },
});
my $retry_child = $defs{MATTER_RetryProbe_EP1};
@sent_requests = ();
MATTER_ProcessNode($defs{ioA}, {node_id => 2703, available => JSON::true});
my @retry_reads = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2703
} @sent_requests;
is(scalar(@retry_reads), 1,
   'first recovery attempt is issued once');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $retry_reads[0]{message_id}, result => {}
}));
MATTER_ProcessNode($defs{ioA}, {node_id => 2703, available => JSON::true});
is(scalar(grep { ($_->{command} // '') eq 'read_attribute' &&
                ($_->{args}{node_id} // 0) == 2703 } @sent_requests), 1,
   'an immediate repeated event cannot bypass the read cooldown');
$mock_time += 16;
MATTER_ProcessNode($defs{ioA}, {node_id => 2703, available => JSON::true});
@retry_reads = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2703
} @sent_requests;
is(scalar(@retry_reads), 2,
   'later online event retries incomplete command metadata');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $retry_reads[-1]{message_id}, result => {}
}));
$mock_time += 16;
MATTER_ProcessNode($defs{ioA}, {node_id => 2703, available => JSON::true});
@retry_reads = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2703
} @sent_requests;
is(scalar(@retry_reads), 3, 'a third attempt is the upper bound');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $retry_reads[-1]{message_id}, result => {}
}));
$mock_time += 16;
MATTER_ProcessNode($defs{ioA}, {node_id => 2703, available => JSON::true});
is(scalar(grep { ($_->{command} // '') eq 'read_attribute' &&
                ($_->{args}{node_id} // 0) == 2703 } @sent_requests), 3,
   'subsequent online events do not bypass the attempt limit');
is(MATTERDevice_Set($retry_child, $retry_child->{NAME}, 'getConfig'),
   undef, 'manual getConfig remains usable after automatic attempt budget');
my $manual_retry_id = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $manual_retry_id,
    result => { '1/6/65529' => [0, 1, 2] }
}));
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($retry_child)),
   'manual getConfig repairs metadata after bounded automatic retries');

# A transport-send failure does not count as a successful read, and a
# future event can retry without stale pending_config records.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2704, name => 'SendFailureProbe', available => JSON::false,
    attributes => { '1/6/0' => JSON::true },
});
my $failure_child = $defs{MATTER_SendFailureProbe_EP1};
my $recovery_sender = $defs{ioA}{test_send_text};
$defs{ioA}{test_send_text} = sub { return 0 };
MATTER_ProcessNode($defs{ioA}, {node_id => 2704, available => JSON::true});
ok(!grep({ ref($_) eq 'HASH' && ($_->{node_id} // -1) == 2704 }
         values %{$defs{ioA}{helper}{pending_config} // {}}),
   'failed metadata send leaves no pending request');
$defs{ioA}{test_send_text} = $recovery_sender;
@sent_requests = ();
$mock_time += 16;
MATTER_ProcessNode($defs{ioA}, {node_id => 2704, available => JSON::true});
my @failure_retry = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2704
} @sent_requests;
is(scalar(@failure_retry), 1,
   'later event retries a previously failed metadata send');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $failure_retry[0]{message_id},
    result => { '1/6/65529' => [0, 1, 2] }
}));
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($failure_child)),
   'successful retry restores the missing On command');

# A later manual read can finish recovery before a slower automatic read
# returns. A stale automatic response must never undo the newer metadata.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2706, name => 'ReadRaceProbe', available => JSON::false,
    attributes => { '1/6/0' => JSON::true }
});
my $race_child = $defs{MATTER_ReadRaceProbe_EP1};
@sent_requests = ();
MATTER_ProcessNode($defs{ioA}, {node_id => 2706, available => JSON::true});
my @race_reads = grep {
    ($_->{command} // '') eq 'read_attribute' &&
    ($_->{args}{node_id} // 0) == 2706
} @sent_requests;
is(scalar(@race_reads), 1, 'auto metadata read is in flight');
my $race_auto_id = $race_reads[0]{message_id};
is(MATTERDevice_Set($race_child, $race_child->{NAME}, 'getConfig'),
   undef, 'explicit recovery read can start while auto request is pending');
my $race_manual_id = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $race_manual_id,
    result => { '1/6/65529' => [0, 1, 2], '1/6/65532' => 0 },
}));
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($race_child)),
   'newer manual capability data restores On');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $race_auto_id,
    result => { '1/6/65529' => [] },
}));
ok(grep(/^on:noArg$/, MATTERDevice_GetSetList($race_child)),
   'late automatic metadata cannot overwrite newer complete capabilities');
$mock_time = $time_before_recovery;

# Issue #35: explicit opt-in diagnostic and raw visibility.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 3500, name => 'DiagnosticsProbe', available => JSON::true,
    attributes => {
        '0/53/0' => 15, '0/53/1' => 5, '0/53/2' => 'Mesh',
        '0/53/7' => [{'0' => 'abcd', '6' => -50, '5' => 3, '13' => JSON::false}],
        '0/54/4' => -67, '1/987/3' => 42,
    }
});
my $dr = $defs{MATTER_DiagnosticsProbe};
my $dep = $defs{MATTER_DiagnosticsProbe_EP1};
ok(!defined(ReadingsVal($dr->{NAME}, 'thread_role', undef)),
   'no default diagnostic readings');
ok(!defined(ReadingsVal($dep->{NAME}, 'raw_1_987_3', undef)),
   'unmapped data not published by default');
is(CommandAttr(undef, 'MATTER_DiagnosticsProbe diagnostics 1'), undef,
   'diagnostics opt-in accepted');
is(CommandAttr(undef, 'MATTER_DiagnosticsProbe_EP1 rawReadings 1'), undef,
   'raw opt-in accepted');
MATTERDevice_Parse($dr, encode_json({
    node_id => 3500, attributes => {
        '0/53/0' => 15, '0/53/1' => 5, '0/53/2' => 'Mesh',
        '0/53/7' => [{'0' => 'abcd', '6' => -50, '5' => 3, '13' => JSON::false}],
        '0/54/4' => -67, '1/987/3' => 42,
    }
}));
is(ReadingsVal($dr->{NAME}, 'thread_role', ''), 'router',
   'Thread role maps to router');
is(ReadingsVal($dr->{NAME}, 'thread_neighbors', ''), 1,
   'neighbor table count');
is(ReadingsVal($dr->{NAME}, 'rssi', ''), -50,
   'best router RSSI');
is(ReadingsVal($dr->{NAME}, 'lqi', ''), 3,
   'best router LQI');
is(ReadingsVal($dr->{NAME}, 'wifi_rssi', ''), -67,
   'Wi-Fi RSSI');
is(ReadingsVal($dep->{NAME}, 'raw_1_987_3', ''), 42,
   'unmapped scalar exposed explicitly');
is(CommandAttr(undef, 'MATTER_DiagnosticsProbe diagnostics 0'), undef,
   'disable diagnostics');
MATTERDevice_Parse($dr, encode_json({
    node_id => 3500, attributes => {'0/54/4' => -62}
}));
is(ReadingsVal($dr->{NAME}, 'wifi_rssi', ''), -67,
   'disable stops updating diagnostics without deleting old data');

subtest 'Issue #35 passive diagnostics and raw boundaries' => sub {
    my $node = 3501;
    my ($primary, $other) = @defs{qw(ioA ioB)};
    for my $pair ([$primary, 'DiagFirst'], [$other, 'DiagSecond']) {
        my ($io, $name) = @$pair;
        MATTER_ProcessNode($io, {node_id => $node, name => $name, available => JSON::true,
            attributes => {'0/54/4' => -63, '1/987/3' => 'initial'}});
        CommandAttr(undef, "MATTER_${name} diagnostics 1");
        CommandAttr(undef, "MATTER_${name}_EP1 rawReadings 1");
        MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
            node_id => $node, available => JSON::true,
            attributes => {'0/54/4' => -63, '1/987/3' => 'baseline'},
        }}));
    }
    my $report = sub {
        my ($path, $value) = @_;
        MATTER_ParseMessage($primary, encode_json({event => 'attribute_updated',
            data => [$node, $path, $value]}));
    };
    my $root = 'MATTER_DiagFirst';
    my $ep = 'MATTER_DiagFirst_EP1';
    $report->('0/54/4', -47);
    for my $bad (undef, {}, -129, 1, 'invalid') {
        $report->('0/54/4', $bad);
        is(ReadingsVal($root, 'wifi_rssi', ''), -47, 'invalid RSSI preserves last valid report');
    }
    is(ReadingsVal('MATTER_DiagSecond', 'wifi_rssi', ''), -63, 'other IO retains snapshot RSSI');
    my @rows = map { {extAddress => "n$_", averageRssi => -$_, isChild => JSON::false} } 1..17;
    $report->('0/53/7', [reverse @rows]);
    is(ReadingsVal($root, 'thread_neighbors', -1), 17, 'count includes all neighbors');
    is(ReadingsVal($root, 'thread_neighbor_list', ''), join(', ', map {"n$_ (router, -$_ dBm)"} 1..16),
       'list contains exactly the strongest sixteen in signal order');
    my @long = map { {extAddress => 'a' x 24, averageRssi => -$_} } 1..16;
    $report->('0/53/7', \@long);
    is(length(ReadingsVal($root, 'thread_neighbor_list', '')), 600, 'formatted list capped at 600 characters');
    $report->('0/53/7', [($rows[0]) x 256]);
    is(ReadingsVal($root, 'thread_neighbors', -1), 256, '256 rows accepted');
    my $list = ReadingsVal($root, 'thread_neighbor_list', '');
    for my $invalid (undef, {}, [($rows[-1]) x 257]) {
        $report->('0/53/7', $invalid);
        is(ReadingsVal($root, 'thread_neighbors', -1), 256, 'invalid table preserves count');
        is(ReadingsVal($root, 'thread_neighbor_list', ''), $list, 'invalid table preserves list');
        is(ReadingsVal($root, 'rssi', ''), -1, 'invalid table preserves RSSI');
    }
    $report->('0/53/7', []);
    is(ReadingsVal($root, 'thread_neighbors', -1), 0, 'empty table clears count');
    is(ReadingsVal($root, 'thread_neighbor_list', ''), 'none', 'empty table clears list');

    my $limit = 'x' x 512;
    $report->('1/987/3', $limit);
    is(ReadingsVal($ep, 'raw_1_987_3', ''), $limit, '512-character scalar accepted');
    for my $invalid (undef, $limit . 'x') {
        $report->('1/987/3', $invalid);
        is(ReadingsVal($ep, 'raw_1_987_3', ''), $limit, 'null or oversized raw value preserves reading');
    }
    my $unicode = chr(0x20ac) x 512;
    $report->('1/987/3', $unicode);
    is(ReadingsVal($ep, 'raw_1_987_3', ''), $unicode, 'scalar limit counts characters');
    $report->('1/987/3', [$unicode]);
    is(ReadingsVal($ep, 'raw_1_987_3', ''), $unicode, 'encoded structure exceeds byte limit');
    my $string = 'x' x 508;
    $report->('1/987/3', [$string]);
    is(ReadingsVal($ep, 'raw_1_987_3', ''), encode_json([$string]), '512-byte JSON array accepted');
    $report->('1/987/3', [$string . 'x']);
    is(ReadingsVal($ep, 'raw_1_987_3', ''), encode_json([$string]), '513-byte JSON array ignored');
    is(ReadingsVal('MATTER_DiagSecond_EP1', 'raw_1_987_3', ''), 'baseline', 'raw reading isolated by IO');
    for my $cluster (31, 48, 49, 60, 62, 63, 64, 65) {
        $report->("1/$cluster/234", 'probe');
        ok(!exists $defs{$ep}{READINGS}{"raw_1_${cluster}_234"}, "cluster $cluster excluded");
    }
    $report->('1/987/65519', 0);
    is(ReadingsVal($ep, 'raw_1_987_65519', ''), 0, 'unmapped zero below global boundary retained');
    $report->('1/987/65520', 1);
    ok(!exists $defs{$ep}{READINGS}{raw_1_987_65520}, 'global boundary excluded');
    CommandAttr(undef, "$ep rawReadings 0");
    $report->('1/987/3', 'changed');
    is(ReadingsVal($ep, 'raw_1_987_3', ''), encode_json([$string]), 'disabling raw retains cached value');
};

# Issue #28: passive ICD detection, LIT gating, explicit ICD query and
# asynchronous correlation. Never infer awake status from availability.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2800, name => 'IcdProbe', available => JSON::true,
    attributes => {
        '0/40/21' => 0x01040000,
        '0/70/65532' => 5, # Check-In and Long Idle Time features
        '0/70/8' => 1,
        '0/70/0' => 3600,
    }
});
my $icd = $defs{MATTER_IcdProbe};
is(ReadingsVal($icd->{NAME}, 'icd_supported', ''), 'true',
   'ICD presence is announced passively');
is(ReadingsVal($icd->{NAME}, 'icd_lit_supported', ''), 'true',
   'Matter 1.4 and LIT bit both required');
is(ReadingsVal($icd->{NAME}, 'icd_operating_mode', ''), 'LIT',
   'current LIT mode is distinct from LIT capability');
is(ReadingsVal($icd->{NAME}, 'icd_idle_mode_duration', ''), 3600,
   'idle duration is retained');
is(CommandAttr(undef, 'ioA autocreate 1'), undef,
   'IO remains assignable during ICD tests');
MATTER_ParseMessage($defs{ioA}, encode_json({
    schema_version => 12, sdk_version => 'matter-server/1.1.7 (matter.js/0.17.5-alpha)',
}));
ok(grep(/^icdRegister:noArg$/, MATTERDevice_GetSetList($icd)),
   'ICD registration set is gated by check-in feature and server schema');
@sent_requests = ();
like(MATTERDevice_Get($icd, $icd->{NAME}, 'icdState'),
     qr/requested/, 'ICD Get acknowledges an asynchronous server request');
is($sent_requests[-1]{command}, 'get_icd_state',
   'dedicated controller-side ICD API');
my $icd_req = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $icd_req,
    result => {
        supported => JSON::true, lit_supported => JSON::true,
        registered => JSON::true, operating_mode => 'LIT',
        awake => JSON::false, available => JSON::true,
        next_expected_checkin => 1735689600000,
    }
}));
is(ReadingsVal($icd->{NAME}, 'icd_awake', ''), 'false',
   'sleeping ICD is recorded as awake false');
is(ReadingsVal($icd->{NAME}, 'icd_controller_available', ''), 'true',
   'controller availability is independent of awake');
is(ReadingsVal($icd->{NAME}, 'state', ''), 'online',
   'sleeping ICD never forces root offline');
is(ReadingsVal($icd->{NAME}, 'icd_registered', ''), 'true',
   'registration is confirmed only from correlated response');
@sent_requests = ();
is(MATTERDevice_Set($icd, $icd->{NAME}, 'icdRegister'), undef,
   'explicit ICD administrative command accepted');
is($sent_requests[-1]{command}, 'register_icd',
   'server remains responsible for ICD registration');

# Issue #36: server-backed, strictly manual OTA.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 3600, name => 'OtaProbe', available => JSON::true,
    attributes => {
        '0/42/2' => 1, '0/42/3' => 0,
        '0/40/9' => 100, '0/40/10' => '1.0.0',
    }
});
my $ota = $defs{MATTER_OtaProbe};
ok(grep(/^checkFirmwareUpdate:noArg$/, MATTERDevice_GetSetList($ota)),
   'OTA root exposes explicit manual firmware check');
ok(!grep(/^updateFirmware:noArg$/, MATTERDevice_GetSetList($ota)),
   'no firmware install without server-approved version');
@sent_requests = ();
is(MATTERDevice_Set($ota, $ota->{NAME}, 'checkFirmwareUpdate'), undef,
   'server firmware check request accepted');
is($sent_requests[-1]{command}, 'check_node_update',
   'server does the actual update discovery');
my $cid = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $cid,
    result => {software_version => 101, software_version_string => '1.0.1'}
}));
is(ReadingsVal($ota->{NAME}, 'firmware_update', ''), 'available',
   'available firmware comes from server response');
is(ReadingsVal($ota->{NAME}, 'firmware_update_version', ''), '1.0.1',
   'server-confirmed version label shown');
ok(grep(/^updateFirmware:noArg$/, MATTERDevice_GetSetList($ota)),
   'firmware install enabled after actual update discovery');
@sent_requests = ();
is(MATTERDevice_Set($ota, $ota->{NAME}, 'updateFirmware'), undef,
   'manual firmware installation request accepted');
is($sent_requests[-1]{command}, 'update_node',
   'Matter server performs OTA installation');
is($sent_requests[-1]{args}{software_version}, 101,
   'only confirmed software version sent');
my $uid = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $uid, result => undef
}));
is(ReadingsVal($ota->{NAME}, 'firmware_update', ''), 'update requested',
   'server acknowledgement is not successful installation');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [3600, '0/42/2', 4]
}));
is(ReadingsVal($ota->{NAME}, 'firmware_update', ''), 'downloading',
   'device OTA Requestor progress received');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [3600, '0/40/9', 101]
}));
is(ReadingsVal($ota->{NAME}, 'firmware_update', ''), 'installed',
   'installation requires matching new reported software version');

subtest 'Issue 36 OTA eligibility and install lifecycle' => sub {
    my @requests;
    my @peers;
    my $io = $defs{ioOta} = {NAME => 'ioOta', TYPE => 'MATTER', READINGS => {}, helper => {}};
    my $connect = sub {
        socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'OTA socketpair';
        push @peers, $peer;
        $io->{CD} = $socket;
        $io->{websocket} = 1;
        $io->{ws_status} = 'connected';
        $io->{test_send_text} = sub { push @requests, JSON::decode_json($_[0]); return 1 };
    };
    $connect->();
    my $node = 6800;
    my $js = 'matter-server/1.1.7 (matter.js/0.17.5-alpha)';
    my $info = sub {
        MATTER_ParseMessage($io, encode_json({schema_version => $_[0], sdk_version => $_[1]}));
    };
    my $report = sub {
        MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [$node, @_]}));
    };
    MATTER_ProcessNode($io, {node_id => $node, name => 'OtaLifecycle', available => JSON::true,
        attributes => {'0/29/1' => [29,40], '1/42/2' => 1}});
    my $root = $defs{MATTER_OtaLifecycle};
    my ($child) = MATTERDevice_NodeChildren($root);
    my $can = sub { my ($dev, $cmd) = @_; return scalar grep { /^\Q$cmd\E:/ } MATTERDevice_GetSetList($dev) };
    my $check = 'checkFirmwareUpdate';
    my $install = 'updateFirmware';
    my $set = sub { MATTERDevice_Set($root, $root->{NAME}, $_[0]) };
    my $reply = sub { MATTER_ParseMessage($io, encode_json({message_id => $requests[-1]{message_id}, @_})) };
    my $status = sub { ReadingsVal($root->{NAME}, 'firmware_update', '') };
    my $offer = sub {
        is($set->($check), undef, 'manual check sent');
        $reply->(result => {software_version => $_[0]});
    };
    readingsSingleUpdate($root, 'ota_update_state', 'idle', 0);
    $info->(11, $js);
    ok(!$can->($root, $check) && !$can->($child, $check), 'saved state and child cluster cannot authorize root or child');
    $report->('0/29/1', [29,42]);
    ok($can->($root, $check), 'root ServerList alone proves capability without progress attributes');
    for my $pair ([10,$js], [9,'2024.7.0'], [15,'unknown'], [undef,$js]) {
        $info->(@$pair);
        ok(!$can->($root, $check), 'unsupported server handshake hides OTA');
        like($set->($check), qr/Unknown argument/, 'explicit set uses same eligibility');
    }
    $info->(10, '2024.7.0');
    ok($can->($root, $check), 'Python server schema 10 supports both OTA commands');
    $info->(11, $js);
    $report->('0/29/1', [29,{}]);
    ok($can->($root, $check), 'malformed ServerList preserves capability');
    MATTER_ProcessNode($io, {node_id => $node, available => JSON::false});
    ok($can->($root, $check), 'offline root with known OTA capability can query connected server');
    MATTER_ProcessNode($io, {node_id => $node, available => JSON::true});
    for my $bad (-1, 1.5, 4294967296, '101', [], JSON::true, undef) {
        $offer->($bad);
        is($status->(), 'invalid response', 'invalid version rejected');
        ok(!$can->($root, $install), 'invalid version grants no install');
    }
    $offer->(0);
    ok($can->($root, $install), 'zero is valid when installed version is unknown');
    $report->('0/40/9', 100);
    ok(!$can->($root, $install), 'new version report supersedes older offer');
    $offer->(4294967295);
    ok($can->($root, $install), 'maximum uint32 accepted');
    $report->('0/29/1', [29]);
    $report->('0/29/1', [29,42]);
    ok(!$can->($root, $install), 'revoked and restored capability requires a fresh offer');

    my $timeout = sub {
        my $id = $requests[-1]{message_id};
        $io->{helper}{pending_command}{$id}{started_at} = gettimeofday() - 301;
        delete $io->{helper}{pending_pong};
        MATTER_Heartbeat($io);
        like($status->(), qr/timeout.*unknown/, 'timeout records unknown outcome');
        MATTER_ParseMessage($io, encode_json({message_id => $id, result => {software_version => 101}}));
        ok(!$can->($root, $install), 'late response cannot restore permission');
    };
    $offer->(101);
    is($set->($check), undef, 'new check replaces old offer');
    is($status->(), 'checking', 'checking is distinct from a result');
    like($set->($check), qr/already pending/, 'second simultaneous check is refused');
    $timeout->();
    $offer->(101);
    is($set->($install), undef, 'install sent');
    like($set->($install), qr/Unknown argument/, 'double install rejected');
    ok(!$can->($root, $check), 'another check cannot replace active install target');
    $timeout->();
    is(scalar(grep {$_->{command} eq 'update_node'} @requests), 1, 'no duplicate or automatic retry');
    $offer->(101);
    is($set->($install), undef, 'new offer permits explicit retry');
    $reply->(result => {software_version => 102});
    is($status->(), 'invalid response', 'mismatched acknowledgement rejected');
    ok(!$can->($root, $install), 'malformed acknowledgement consumes offer');

    $offer->(101);
    is($set->($install), undef, 'new install requested');
    $reply->(result => {software_version => 101, software_version_string => 'v101'});
    is($status->(), 'update requested', 'matterjs result object acknowledges install');
    ok(!$can->($root, $install), 'accepted install still cannot be repeated');
    $report->('0/40/9', 101);
    is($status->(), 'installed', 'matching version confirms without progress attributes');
    $offer->(102);
    is($set->($install), undef, 'subsequent version requested');
    $report->('0/40/9', 102);
    $reply->(result => undef);
    is($status->(), 'installed', 'late acknowledgement preserves physical confirmation');
    $offer->(103);
    is($set->($install), undef, 'install sent before device progress');
    $report->('0/42/2', 4);
    $reply->(result => {software_version => 103});
    is($status->(), 'downloading', 'late server acknowledgement preserves progress');
    MATTER_Close($io);
    like($status->(), qr/unknown.*disconnected/, 'disconnect after acknowledgement releases target with unknown outcome');
    $connect->();
    $info->(11,$js);
    MATTER_ProcessNode($io, {node_id => $node, available => JSON::true});
    MATTER_ProcessNode($io, {node_id => $node, available => JSON::false});
    $offer->(103);
    is($requests[-1]{command}, 'check_node_update', 'offline check reached the server');
    ok($can->($root, $install), 'server offer enables installation for offline root');
    is($set->($install), undef, 'offline install request sent');
    is_deeply($requests[-1]{args}, {node_id => $node, software_version => 103}, 'offline install sends offered version to server');
    $reply->(error_code => 11, details => 'Node is not connected');
    is($status->(), 'failed: Node is not connected', 'actual server refusal visible');
    ok(!$can->($root, $install), 'server refusal requires fresh offer');
    $offer->(103);
    is($set->($install), undef, 'install outstanding at disconnect');
    MATTER_Close($io);
    like($status->(), qr/interrupted.*unknown/, 'disconnect records unknown outcome');
    $connect->();
    MATTER_ProcessNode($io, {node_id => $node, available => JSON::true});
    ok(!$can->($root, $check), 'reconnect requires fresh server info');
    $info->(11,$js);
    ok($can->($root, $check) && !$can->($root, $install), 'reconnect permits fresh check only');
};

# A second operation for the same node cannot race the first response.
@sent_requests = ();
my $pending_icd_query = MATTERDevice_Get($icd, $icd->{NAME}, 'icdState');
like($pending_icd_query, qr/pending/, 'in-flight ICD operations are serialized');
# Clear pending administrative request through its matched server response.
my ($current_icd_request) = grep {
    ref($defs{ioA}{helper}{pending_command}{$_}) eq 'HASH' &&
    ($defs{ioA}{helper}{pending_command}{$_}{node_id} // '') == 2800
} keys %{$defs{ioA}{helper}{pending_command}};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $current_icd_request, result => {
        supported => JSON::true, registered => JSON::true,
    }
})) if defined $current_icd_request;

# A reported version equal to the installed version is not an update.
@sent_requests = ();
is(MATTERDevice_Set($ota, $ota->{NAME}, 'checkFirmwareUpdate'), undef,
   'can check again after the previous OTA command completed');
my $same_version_id = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $same_version_id,
    result => { software_version => 101, software_version_string => '1.0.1' }
}));
is(ReadingsVal($ota->{NAME}, 'firmware_update', ''), 'up to date',
   'already installed firmware is not offered as a newer update');
ok(!grep(/^updateFirmware:noArg$/, MATTERDevice_GetSetList($ota)),
   'no install action for the already installed firmware');

# Review #33: asynchronous thermostat writes are correlated, not reported
# successful merely because FHEM accepted an outgoing WebSocket frame.
@sent_requests = ();
is(MATTERDevice_Set($therm, $therm->{NAME}, 'desired-temp', '20.5'), undef,
   'another thermostat write is queued');
my $write_id = $sent_requests[-1]{message_id};
ok(exists($defs{ioA}{helper}{pending_command}{$write_id}),
   'write request is held until matching server response');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $write_id,
    error_code => 1,
    error => { message => 'attribute is not writable' }
}));
like(ReadingsVal($therm->{NAME}, 'lastError', ''),
     qr/not writable/, 'server rejected write is visible on the FHEM device');
is(ReadingsVal($therm->{NAME}, 'desired-temp', ''), 21,
   'failed write never changes the physical reported setpoint');
@sent_requests = ();
is(MATTERDevice_Set($therm, $therm->{NAME}, 'desired-temp', '20.5'), undef,
   'write may be retried explicitly');
my $write_ok_id = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $write_ok_id, result => undef
}));
is(ReadingsVal($therm->{NAME}, 'lastError', ''), 'none',
   'server-confirmed write clears the prior error');
is(ReadingsVal($therm->{NAME}, 'desired-temp', ''), 21,
   'server acknowledgement is still not new device telemetry');

# Independent request IDs allow consecutive writes without a response lock.
@sent_requests = ();
is(MATTERDevice_Set($therm, $therm->{NAME}, 'mode', 'off'), undef,
   'first thermostat mode write queued');
my $first_mode_id = $sent_requests[-1]{message_id};
is(MATTERDevice_Set($therm, $therm->{NAME}, 'mode', 'heat'), undef,
   'concurrent write is sent without waiting for the first response');
my $second_mode_id = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $second_mode_id, error_code => 1, details => 'newer write refused'
}));
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $first_mode_id, result => undef
}));
is(MATTERDevice_Set($therm, $therm->{NAME}, 'mode', 'heat'), undef,
   'further writes remain available after either response');

# Review against additional fhempy regression scenarios.
is(ReadingsVal('MATTER_SensorProbe_EP1', 'state', ''), 'open',
   'contact sensor exposes a native FHEM state in addition to contact');
is(ReadingsVal('MATTER_SensorProbe_EP5', 'state', ''), 'nomotion',
   'occupancy endpoint exposes standard motion/nomotion state');
my $stray_name = 'MATTER_SwitchProbe_EP999';
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_event',
    data => { node_id => 3100, endpoint_id => 999,
              cluster_id => 59, event_id => 3, data => {} }
}));
ok(!exists($defs{$stray_name}),
   'unadvertised Switch event endpoints do not autocreate devices');
is(ReadingsVal($dr->{NAME}, 'thread_device_type', ''), 'FTD',
   'Thread router role implies a full Thread device');
is(CommandAttr(undef, 'MATTER_DiagnosticsProbe diagnostics 1'), undef,
   'diagnostics can be re-enabled for later reports');
MATTERDevice_Parse($dr, encode_json({
    node_id => 3500,
    attributes => {'0/53/7' => [
        {'0' => 'router', '6' => -72, '5' => 2, '13' => JSON::false},
        {'0' => 'child', '6' => -30, '5' => 3, '13' => JSON::true}
    ]}
}));
is(ReadingsVal($dr->{NAME}, 'thread_neighbors', ''), 2,
   'parent/child neighbors counted');
is(ReadingsVal($dr->{NAME}, 'rssi', ''), -72,
   'child signal never replaces router-link RSSI');
is(ReadingsVal($dr->{NAME}, 'lqi', ''), 2,
   'link quality belongs to best router, not strongest child');
MATTERDevice_Parse($dr, encode_json({
    node_id => 3500, attributes => {'1/62/42' => 'private'}
}));
ok(!defined(ReadingsVal($dep->{NAME}, 'raw_1_62_42', undef)),
   'sensitive credential cluster excluded even with rawReadings enabled');

# Review #36: an empty firmware offer and a failed check invalidate the
# prior version, never leaving an unsafe install command available.
@sent_requests = ();
is(MATTERDevice_Set($ota, $ota->{NAME}, 'checkFirmwareUpdate'), undef,
   'new manual check after previous result');
my $none_id = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $none_id, result => undef
}));
is(ReadingsVal($ota->{NAME}, 'firmware_update', ''), 'none reported',
   'a null update response means none reported, not up to date forever');
is(ReadingsVal($ota->{NAME}, 'firmware_update_version', ''), 'none',
   'outdated firmware offer label is cleared');
ok(!grep(/^updateFirmware:noArg$/, MATTERDevice_GetSetList($ota)),
   'no install set after null result');
@sent_requests = ();
is(MATTERDevice_Set($ota, $ota->{NAME}, 'checkFirmwareUpdate'), undef,
   'firmware check can be retried explicitly');
my $failure_id = $sent_requests[-1]{message_id};
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $failure_id,
    error_code => 1, error => { message => 'DCL unavailable' }
}));
like(ReadingsVal($ota->{NAME}, 'firmware_update', ''), qr/DCL unavailable/,
   'server lookup failure is visible in firmware_update');
ok(!grep(/^updateFirmware:noArg$/, MATTERDevice_GetSetList($ota)),
   'lookup errors do not leave a stale install action');
# Receive diagnostics exercise the real IO -> root -> endpoint routing. These
# count server messages, including cached/blocked data, not device contact.
for my $io_name (qw(ioReceive ioReceiveOther)) {
    $defs{$io_name} = { NAME => $io_name, TYPE => 'MATTER', READINGS => {}, helper => {} };
}
$mock_time = 10;
$defs{ioReceive}{helper}{pending_command}{70001} = 'start_listening';
MATTER_ParseMessage($defs{ioReceive}, encode_json({
    message_id => 70001, result => [{
        node_id => 4100, name => 'ReceiveProbe', available => JSON::true,
        attributes => { '0/40/3' => 'Synthetic model', '0/29/3' => [1, 2, 3],
                        '1/6/0' => JSON::true, '1/8/0' => 100,
                        '2/6/0' => JSON::false }
    }]
}));
my $rr = $defs{MATTER_ReceiveProbe};
my $r1 = $defs{MATTER_ReceiveProbe_EP1};
my $r2 = $defs{MATTER_ReceiveProbe_EP2};
my $r3 = $defs{MATTER_ReceiveProbe_EP3};
for my $device ($rr, $r1, $r2) {
    is($device->{MSGCNT}, 1, "$device->{NAME}: snapshot counts once despite multiple attributes");
    is($device->{ioReceive_MSGCNT}, 1, "$device->{NAME}: per-IO counter matches");
    is($device->{ioReceive_TIME}, TimeNow(), "$device->{NAME}: receive time uses FHEM TimeNow");
    is($device->{LASTInputDev}, 'ioReceive', "$device->{NAME}: records receiving IO");
}
ok(!exists($r3->{MSGCNT}), 'a PartsList reference alone is no endpoint reception');

$mock_time = 11;
my $seen_during_update;
$reading_event_hook = sub {
    my ($device, $reading) = @_;
    $seen_during_update = [$rr->{MSGCNT}, $r1->{MSGCNT}]
        if $device eq $r1 && $reading eq 'state';
};
MATTER_ParseMessage($defs{ioReceive}, encode_json({
    event => 'attribute_updated', data => [4100, '1/6/0', JSON::true]
}));
$reading_event_hook = undef;
is_deeply($seen_during_update, [2, 2], 'receive internals are set before publishing endpoint telemetry');
is($r1->{ioReceive_TIME}, TimeNow(), 'unchanged value still advances receive time');
is($r2->{MSGCNT}, 1, 'another endpoint is not counted by a live attribute');

MATTER_ParseMessage($defs{ioReceive}, encode_json({
    event => 'node_updated', data => {node_id => 4100, available => JSON::false}
}));
is($rr->{MSGCNT}, 3, 'availability-only message counts for root');
is($r1->{MSGCNT}, 2, 'mirrored availability is not endpoint reception');
MATTER_ParseMessage($defs{ioReceive}, encode_json({
    event => 'node_updated', data => {node_id => 4100,
        attributes => {'1/6/0' => JSON::false, '1/8/0' => 0, '2/6/0' => JSON::true}}
}));
is($rr->{MSGCNT}, 4, 'blocked snapshot counts once for root');
is($r1->{MSGCNT}, 3, 'blocked endpoint attributes count once');
is($r2->{MSGCNT}, 2, 'second included endpoint receives the same snapshot');
is(ReadingsVal($r1->{NAME}, 'state', ''), 'on', 'receive accounting preserves offline state protection');
MATTER_ParseMessage($defs{ioReceive}, encode_json({
    event => 'node_event', data => {node_id => 4100, endpoint_id => 1,
        cluster_id => 59, event_id => 3, data => {}}
}));
is($rr->{MSGCNT}, 5, 'Switch event counts for root');
is($r1->{MSGCNT}, 4, 'Switch event counts for target endpoint');

# Matched reads, including the capability-only bypass and errors, are counted
# independently of whether values may be imported. Unknown replies are ignored.
$defs{ioReceive}{helper}{pending_config}{70002} = {
    node_id => 4100, endpoint_id => 1, root_fuuid => $rr->{FUUID}
};
MATTER_ParseMessage($defs{ioReceive}, encode_json({
    message_id => 70002, result => {'1/6/65529' => [0, 1], '1/6/65532' => 0}
}));
is($rr->{MSGCNT}, 6, 'blocked correlated read counts for root');
is($r1->{MSGCNT}, 5, 'blocked read counts once for requested endpoint');
$defs{ioReceive}{helper}{pending_config}{70003} = {
    node_id => 4100, endpoint_id => 1, root_fuuid => $rr->{FUUID}
};
MATTER_ParseMessage($defs{ioReceive}, encode_json({message_id => 70003, error_code => 1}));
is($rr->{MSGCNT}, 7, 'correlated server error is a received node message');
is($r1->{MSGCNT}, 6, 'correlated read error belongs to requested endpoint');
MATTER_ParseMessage($defs{ioReceive}, encode_json({message_id => 79999, result => {}}));
MATTER_ParseMessage($defs{ioReceive}, encode_json({
    event => 'attribute_updated', data => [4100, 'invalid-path', 1]
}));
MATTER_ParseMessage($defs{ioReceive}, '{broken');
MATTERDevice_Parse($rr, encode_json({node_id => 4101, attributes => {'1/6/0' => JSON::true}}));
is($rr->{MSGCNT}, 7, 'unmatched replies, malformed input and foreign nodes do not count');
$defs{ioReceive}{helper}{pending_config}{70004} = {
    node_id => 4100, endpoint_id => 1, root_fuuid => 'replaced-owner'
};
MATTER_ParseMessage($defs{ioReceive}, encode_json({message_id => 70004, result => {}}));
is($rr->{MSGCNT}, 7, 'a replaced request owner does not inherit receipt');

# Online full reads also traverse MATTERDevice_Parse: shared per-message
# context must prevent counting both response correlation and attribute routing.
MATTER_ParseMessage($defs{ioReceive}, encode_json({
    event => 'node_updated', data => {node_id => 4100, available => JSON::true}
}));
$defs{ioReceive}{helper}{pending_config}{70005} = {
    node_id => 4100, all_endpoints => 1, root_fuuid => $rr->{FUUID},
    live_values => {'2/6/0' => JSON::false}
};
MATTER_ParseMessage($defs{ioReceive}, encode_json({
    message_id => 70005, result => {'1/6/0' => JSON::true, '1/8/0' => 80}
}));
is($rr->{MSGCNT}, 9, 'full online read counts root once across both layers');
is($r1->{MSGCNT}, 7, 'full online read counts endpoint once across both layers');
is($r2->{MSGCNT}, 2, 'reconciled earlier live value does not manufacture new endpoint reception');

$defs{ioReceive}{helper}{pending_command}{70006} = {
    type => 'node_operation', operation => 'write_attribute', name => $r1->{NAME},
    owner => $r1, endpoint_id => $r1->{endpoint_id},
    fuuid => $r1->{FUUID}, node_id => 4100, reading => 'lastError',
    group => {remaining => 1}
};
$r1->{helper}{latest_request}{lastError} = $defs{ioReceive}{helper}{pending_command}{70006}{group};
MATTER_ParseMessage($defs{ioReceive}, encode_json({message_id => 70006, result => undef}));
is($rr->{MSGCNT}, 10, 'endpoint write reply also counts for its root');
is($r1->{MSGCNT}, 8, 'endpoint write reply counts for its actual owner');
MATTER_ParseMessage($defs{ioReceive}, encode_json({event => 'node_removed', data => 4100}));
is($rr->{MSGCNT}, 11, 'explicit removal message counts for root');
is($r1->{MSGCNT}, 8, 'removal status propagated to endpoint is not endpoint reception');

MATTER_ParseMessage($defs{ioReceiveOther}, encode_json({
    event => 'node_added', data => {node_id => 4100, name => 'ReceiveOther',
        attributes => {'1/6/0' => JSON::false}}
}));
is($defs{MATTER_ReceiveOther}{MSGCNT}, 1, 'same node ID on another IO has independent counters');
is($rr->{MSGCNT}, 11, 'other IO cannot update original root receive internals');
my @receive_readings = grep {/^(?:MSGCNT|LASTInputDev|ioReceive_(?:TIME|MSGCNT))$/}
    keys %{$r1->{READINGS}};
is_deeply(\@receive_readings, [], 'receive diagnostics do not create readings or database events');
my $before_close = $rr->{MSGCNT};
MATTER_Close($defs{ioReceive});
is($rr->{MSGCNT}, $before_close, 'local IO disconnect is not an incoming message');
is(CommandRename(undef, 'ioReceive ioReceiveRenamed'), undef, 'receiving IO can be renamed');
$mock_time = 12;
MATTER_ParseMessage($defs{ioReceiveRenamed}, encode_json({
    event => 'attribute_updated', data => [4100, '1/6/0', JSON::true]
}));
is($r1->{LASTInputDev}, 'ioReceiveRenamed', 'next reception uses renamed IO');
is($r1->{ioReceiveRenamed_TIME}, TimeNow(), 'renamed IO receives its own conventional timestamp field');
is($r1->{ioReceiveRenamed_MSGCNT}, 1, 'per-IO count starts under new IO name');
is($r1->{MSGCNT}, 9, 'total count survives IO rename and disconnect');
is(CommandDefine(undef, 'ReceiveDefined MATTERDevice 4101'), undef, 'a fresh FHEM device can be defined');
ok(!exists($defs{ReceiveDefined}{MSGCNT}), 'definition alone does not manufacture a receive time or count');

my ($root_before_raw_event, $child_before_raw_event) = ($rr->{MSGCNT}, $r1->{MSGCNT});
MATTER_ParseMessage($defs{ioReceiveRenamed}, encode_json({
    event => 'node_event', data => {node_id => 4100, endpoint_id => 1,
        cluster_id => 1234, event_id => 99, data => {}}
}));
is($rr->{MSGCNT}, $root_before_raw_event + 1, 'unmapped Matter event still counts as node reception');
is($r1->{MSGCNT}, $child_before_raw_event + 1, 'unmapped event counts for its known endpoint without new readings');
MATTER_ParseMessage($defs{ioReceiveRenamed}, encode_json({
    event => 'node_event', data => {node_id => 4100, endpoint_id => 99,
        cluster_id => 1234, event_id => 99, data => {}}
}));
ok(!exists($defs{MATTER_ReceiveProbe_EP99}), 'receive accounting does not autocreate unknown event endpoints');
is($r1->{MSGCNT}, $child_before_raw_event + 1, 'unknown event endpoint cannot refresh another endpoint');
MATTER_ParseMessage($defs{ioReceiveRenamed}, encode_json({
    event => 'node_added', data => {node_id => 4102, name => 'ReceiveMinimal'}
}));
is($defs{MATTER_ReceiveMinimal}{MSGCNT}, 1, 'node announcement without attributes or availability still counts');
my $before_empty = $rr->{MSGCNT};
my $endpoint_before_empty = $r1->{MSGCNT};
$defs{ioReceiveRenamed}{helper}{pending_config}{70007} = {
    node_id => 4100, all_endpoints => 1, root_fuuid => $rr->{FUUID}
};
MATTER_ParseMessage($defs{ioReceiveRenamed}, encode_json({message_id => 70007, result => {}}));
is($rr->{MSGCNT}, $before_empty + 1, 'empty correlated wildcard reply counts for root');
is($r1->{MSGCNT}, $endpoint_before_empty, 'empty wildcard reply cannot attribute reception to every endpoint');

# An accepted live model report can synchronously notify children after IO
# recovery. Mirroring is not child traffic; a nested endpoint report is.
my $before_nested = $r1->{MSGCNT};
my $count_at_mirrored_model;
$mock_time = 13;
$reading_event_hook = sub {
    my ($device, $reading) = @_;
    return unless $device eq $r1 && $reading eq 'model';
    $count_at_mirrored_model = $r1->{MSGCNT};
    $mock_time = 14;
    MATTER_ParseMessage($defs{ioReceiveRenamed}, encode_json({
        event => 'attribute_updated', data => [4100, '1/6/0', JSON::false]
    }));
};
MATTER_ParseMessage($defs{ioReceiveRenamed}, encode_json({
    event => 'node_updated', data => {node_id => 4100, available => JSON::true}
}));
MATTER_ParseMessage($defs{ioReceiveRenamed}, encode_json({
    event => 'attribute_updated',
    data => [4100, '0/40/3', 'Changed synthetic model']
}));
$reading_event_hook = undef;
is($count_at_mirrored_model, $before_nested, 'live root model mirroring is not endpoint reception');
is($r1->{MSGCNT}, $before_nested + 1, 'nested endpoint report counts independently during model mirroring');
is($r1->{ioReceiveRenamed_TIME}, '2026-11-18 12:00:14', 'resumed older routing preserves newer nested receive time');

subtest 'Matter node network type through existing server routing' => sub {
    my $io = $defs{ioNetwork} = {
        NAME => 'ioNetwork', TYPE => 'MATTER', READINGS => {}, helper => {},
    };
    my $timers_before = scalar @timers;
    my $wifi = [{'1' => JSON::true, '7' => 1},
                {'1' => JSON::false, '7' => 4}];
    my $thread = [{isOperational => JSON::true, type => 4}];
    my $ethernet = [{isOperational => 1, type => 2}];
    $io->{helper}{pending_command}{8100} = 'start_listening';
    MATTER_ParseMessage($io, encode_json({message_id => 8100, result => [{
        node_id => 5100, name => 'NetworkProbe', available => JSON::true,
        attributes => {'0/51/0' => $wifi, '1/6/0' => JSON::true,
                       '1/29/0' => [{'0' => 0x0013, '1' => 1}]},
    }]}));
    my $nr = $defs{MATTER_NetworkProbe};
    my $ne = $defs{MATTER_NetworkProbe_EP1};
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'wifi',
       'initial tag-based snapshot uses only operational interfaces without diagnostics opt-in');
    ok(!exists($ne->{READINGS}{networkType}),
       'bridge endpoints do not inherit their Matter node network type');
    my $report = sub {
        MATTER_ParseMessage($io, encode_json({
            event => 'attribute_updated', data => [5100, '0/51/0', $_[0]],
        }));
    };
    $report->($thread);
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'thread',
       'named fields and JSON booleans work in live reports');
    $report->($ethernet);
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'ethernet',
       'Ethernet and numeric booleans are recognized');
    $report->([{'1' => 1, '7' => 3}]);
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'cellular',
       'standard Cellular interface is not mislabeled as Wi-Fi');
    my $multi = [{'1' => 1, '7' => 4}, {'1' => 1, '7' => 1},
                 {'1' => 1, '7' => 2}, {'1' => 1, '7' => 1}];
    $report->($multi);
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'ethernet,thread,wifi',
       'multiple active types are sorted and deduplicated without choosing a route');
    my $writes_before = $single_writes{$nr->{NAME}}{networkType};
    $report->([reverse @$multi]);
    is($single_writes{$nr->{NAME}}{networkType}, $writes_before,
       'unchanged types and interface reordering do not rewrite the reading');
    for my $unknown ([], [{'1' => 0, '7' => 1}],
                     [{'1' => 1, '7' => 0}], [{'1' => 1, '7' => 5}]) {
        $report->($unknown);
        is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'unknown',
           'valid list without a recognized active type explicitly reports unknown');
    }
    $report->([{'1' => 1, '7' => 1}, {'1' => 1, '7' => 5}]);
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'unknown,wifi',
       'an unknown operational interface is not hidden by a known interface');
    $report->($thread);
    $writes_before = $single_writes{$nr->{NAME}}{networkType};
    for my $bad (undef, {}, 'wifi', [undef], [{}],
                 [{isOperational => 'false', type => 1}],
                 [{isOperational => JSON::true, type => undef}],
                 [{isOperational => 1, type => JSON::true}],
                 [{isOperational => 1, type => -1}],
                 [{isOperational => 1, type => 256}],
                 [{isOperational => 1, type => '1oops'}],
                 [@$wifi, {isOperational => 1, type => []}]) {
        $report->($bad);
    }
    is($single_writes{$nr->{NAME}}{networkType}, $writes_before,
       'malformed/null reports preserve the last reading and cause no reading writes');
    MATTER_ParseMessage($io, encode_json({
        event => 'attribute_updated', data => [5100, '1/51/0', $ethernet],
    }));
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'thread',
       'non-root reports cannot replace node network type');
    ok(!exists($ne->{READINGS}{networkType}),
       'endpoint reports cannot create a misleading endpoint networkType');

    # Both discovery and explicit reads must retain newer valid live reports.
    $io->{helper}{pending_command}{8101} = 'get_nodes';
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 5100, attributes => {'0/51/0' => $wifi},
    }}));
    MATTER_ParseMessage($io, encode_json({message_id => 8101, result => [{
        node_id => 5100, attributes => {'0/51/0' => $ethernet},
    }]}));
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'wifi',
       'late discovery snapshot cannot overwrite a newer node_updated attribute');
    $io->{helper}{pending_command}{8102} = 'get_nodes';
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 5100, attributes => {'0/51/0' => [{type => 1}]},
    }}));
    MATTER_ParseMessage($io, encode_json({message_id => 8102, result => [{
        node_id => 5100, attributes => {'0/51/0' => $ethernet},
    }]}));
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'ethernet',
       'malformed newer attribute cannot suppress a valid pending snapshot');
    $io->{helper}{pending_command}{8105} = 'get_nodes';
    $report->($thread);
    MATTER_ParseMessage($io, encode_json({message_id => 8105, result => [{
        node_id => 5100, attributes => {'0/51/0' => $ethernet},
    }]}));
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'thread',
       'late discovery snapshot cannot overwrite a newer attribute_updated event');
    $io->{helper}{pending_command}{8106} = 'get_nodes';
    $report->([{isOperational => 'false', type => 1}]);
    MATTER_ParseMessage($io, encode_json({message_id => 8106, result => [{
        node_id => 5100, attributes => {'0/51/0' => $ethernet},
    }]}));
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'ethernet',
       'invalid attribute_updated event cannot suppress valid discovery data');
    $io->{helper}{pending_config}{8103} = {node_id => 5100, all_endpoints => 1};
    $report->($thread);
    MATTER_ParseMessage($io, encode_json({message_id => 8103,
        result => {'0/51/0' => $ethernet}}));
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'thread',
       'late correlated getConfig cannot overwrite a newer live interface list');
    $io->{helper}{pending_config}{8104} = {node_id => 5100, all_endpoints => 1};
    $report->([{isOperational => 'false', type => 1}]);
    MATTER_ParseMessage($io, encode_json({message_id => 8104,
        result => {'0/51/0' => $ethernet}}));
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'ethernet',
       'malformed live event cannot poison the correlated read result');

    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 5100, available => JSON::false,
        attributes => {'0/51/0' => $wifi},
    }}));
    $report->($wifi);
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'ethernet',
       'offline reports retain the last accepted network type');
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 5100, available => JSON::true,
        attributes => {'0/51/0' => $wifi},
    }}));
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'wifi',
       'valid online recovery snapshot refreshes the reported network type');
    $report->($thread);
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'thread',
       'live reports continue updating network type after online synchronization');

    MATTER_ProcessNode($io, {node_id => 5101, name => 'NetworkCapabilityOnly',
        available => JSON::true, attributes => {'0/49/65532' => 1}});
    ok(!exists($defs{MATTER_NetworkCapabilityOnly}{READINGS}{networkType}),
       'supported Wi-Fi commissioning feature alone does not invent an active interface');
    my $other = $defs{ioNetworkOther} = {
        NAME => 'ioNetworkOther', TYPE => 'MATTER', READINGS => {}, helper => {},
    };
    MATTER_ProcessNode($other, {node_id => 5100, name => 'OtherNetworkProbe',
        available => JSON::true, attributes => {'0/51/0' => $wifi}});
    is(ReadingsVal('MATTER_OtherNetworkProbe', 'networkType', ''), 'wifi',
       'same node ID on another IO has its own network type');
    is(ReadingsVal($nr->{NAME}, 'networkType', ''), 'thread',
       'other IO cannot change the original root');
    is(scalar(@timers), $timers_before, 'network type introduces no timers');
    is_deeply($io->{helper}{pending_config}, {}, 'no additional network reads are queued');
};

# Device limits are telemetry, never configuration overrides. Exercise the
# actual IO -> root -> endpoint -> command path with synthetic reports.
my @limit_commands;
my $limit_io = $defs{ioLimits} = {
    NAME => 'ioLimits', TYPE => 'MATTER', READINGS => {}, helper => {},
    CD => 1, websocket => 1, ws_status => 'connected',
    test_send_text => sub {
        push @limit_commands, JSON::decode_json($_[0]); return 1;
    },
};
MATTER_ParseMessage($limit_io, encode_json({event => 'node_added', data => {
    node_id => 6400, name => 'LimitProbe', available => JSON::true,
    attributes => {
        '1/8/65529' => [0, 4, 8], '1/8/65532' => 4,
        '1/8/65531' => [0, 2, 3, 4, 5, 6],
        '1/768/65529' => [6, 10], '1/768/65532' => 17,
        '1/768/65531' => [0, 1, 7, 16395, 16396],
        '2/8/65529' => [4], '2/8/65532' => 0,
    },
}}));
my $limit_root = $defs{MATTER_LimitProbe};
my $limit_ep = $defs{MATTER_LimitProbe_EP1};
my $limit_ep2 = $defs{MATTER_LimitProbe_EP2};
my @obsolete_limits = qw(color_temp_min color_temp_max min_brightness
    max_brightness min_frequency max_frequency min_pin_code_length
    max_pin_code_length min_rfid_code_length max_rfid_code_length);
for my $old (@obsolete_limits) {
    like(CommandAttr(undef, "$limit_ep->{NAME} $old 999") // '',
       qr/unknown attribute/, "removed $old attribute is rejected");
    ok(!exists($attr{$limit_ep->{NAME}}{$old}),
       "rejected $old attribute is not stored");
    ok(!exists($limit_ep->{READINGS}{$old}),
       "saved $old is not migrated into a device reading");
}
ok(grep(/^ct:textField$/, MATTERDevice_GetSetList($limit_ep)),
   'CT command remains usable without fabricated colorpicker limits');
ok(grep(/^frequency:textField$/, MATTERDevice_GetSetList($limit_ep)),
   'Frequency command remains usable without fabricated 50/60 boundaries');
is(MATTERDevice_MaxBrightness($limit_ep), 254,
   'protocol fallback applies while device data is missing');
my $limit_report = sub {
    my ($ep, $cluster, $id, $value) = @_;
    MATTER_ParseMessage($limit_io, encode_json({event => 'attribute_updated',
        data => [6400, "$ep/$cluster/$id", $value]}));
};
my @limit_reports = (
    [8, 2, 'min_brightness', 1], [8, 3, 'max_brightness', 200],
    [8, 5, 'min_frequency', 1000], [8, 6, 'max_frequency', 4000],
    [768, 16395, 'color_temp_min', 200],
    [768, 16396, 'color_temp_max', 454],
    [257, 23, 'max_pin_code_length', 8],
    [257, 24, 'min_pin_code_length', 4],
    [257, 25, 'max_rfid_code_length', 20],
    [257, 26, 'min_rfid_code_length', 8],
);
for my $r (@limit_reports) {
    $limit_report->(1, $r->[0], $r->[1], $r->[3]);
    is(ReadingsVal($limit_ep->{NAME}, $r->[2], ''), $r->[3],
       "$r->[2] is reported at the addressed endpoint");
    ok(!exists($attr{$limit_ep->{NAME}}{$r->[2]}),
       "$r->[2] report never creates the removed attribute");
    ok(!exists($limit_root->{READINGS}{$r->[2]}),
       "$r->[2] is not copied to the root");
}
ok(grep(/^ct:colorpicker,CT,200,1,454$/, MATTERDevice_GetSetList($limit_ep)),
   'colorpicker uses actual device limits');
ok(grep(/^frequency:slider,1000,1,4000$/, MATTERDevice_GetSetList($limit_ep)),
   'frequency slider uses actual device limits');
$limit_report->(2, 8, 3, 100);
is(MATTERDevice_MaxBrightness($limit_ep2), 100,
   'second endpoint retains its independent reported maximum');
$limit_report->(1, 8, 3, 180);
is(ReadingsVal($limit_ep->{NAME}, 'max_brightness', ''), 180,
   'later limit reports replace the previous reading');
@limit_commands = ();
is(MATTERDevice_Set($limit_ep, $limit_ep->{NAME}, 'pct', 33), undef,
   'percentage command accepted with reported maximum');
is($limit_commands[-1]{args}{payload}{level}, 59,
   'percentage maps to an integer device level using reported maximum');
$limit_report->(1, 8, 0, 90);
is(ReadingsVal($limit_ep->{NAME}, 'pct', ''), 50,
   'received percentage uses the same reported scale');
@limit_commands = ();
is(MATTERDevice_Set($limit_ep, $limit_ep->{NAME}, 'rgb', 'FFFFFF'), undef,
   'RGB command accepted with reported maximum');
is($limit_commands[0]{args}{payload}{level}, 180,
   'RGB brightness uses reported maximum');
$limit_report->(1, 8, 3, 100);
is(ReadingsVal($limit_ep->{NAME}, 'pct', ''), 90,
   'changed maximum recalculates percentage without another brightness report');
$limit_report->(1, 8, 3, 180);
$limit_report->(1, 8, 65532, 6); # Frequency + Lighting
is(MATTERDevice_MaxBrightness($limit_ep), 254,
   'Lighting feature uses standardized 254 maximum despite contradictory report');
is(ReadingsVal($limit_ep->{NAME}, 'pct', ''), 35,
   'changed Lighting metadata updates percentage on the standardized scale');
$limit_report->(1, 8, 65532, 4);
is(ReadingsVal($limit_ep->{NAME}, 'pct', ''), 50,
   'generic scale restoration updates percentage without physical level churn');
for my $bad (undef, JSON::true, [], {}, 'nonsense', -1, 255, '1.5') {
    $limit_report->(1, 8, 3, $bad);
    is(ReadingsVal($limit_ep->{NAME}, 'max_brightness', ''), 180,
       'invalid maximum preserves last valid device report');
}
$limit_report->(1, 8, 3, 0);
is(ReadingsVal($limit_ep->{NAME}, 'max_brightness', ''), 0,
   'generic uint8 MaxLevel zero is retained as reported, not replaced by fallback');
is(MATTERDevice_MaxBrightness($limit_ep), 0,
   'a reported generic zero maximum is not a missing attribute');
ok(!defined(MATTERDevice_Percentage($limit_ep)),
   'zero maximum never divides by zero or invents a percentage');
$limit_report->(1, 8, 3, 180);
$limit_report->(1, 8, 5, 0);
ok(grep(/^frequency:textField$/, MATTERDevice_GetSetList($limit_ep)),
   'zero means undefined frequency limit, not slider boundary');
$limit_report->(1, 8, 5, 5000);
ok(grep(/^frequency:textField$/, MATTERDevice_GetSetList($limit_ep)),
   'reversed frequency range does not create misleading slider');
$limit_report->(1, 8, 5, 1000);
$limit_report->(1, 768, 16395, 500);
ok(grep(/^ct:textField$/, MATTERDevice_GetSetList($limit_ep)),
   'reversed CT range does not create misleading colorpicker');
$limit_report->(1, 768, 16395, 200);
$limit_report->(1, 768, 16396, 65535);
is(ReadingsVal($limit_ep->{NAME}, 'color_temp_max', ''), 454,
   'out-of-domain color temperature cannot replace hardware limit');
$limit_report->(1, 257, 23, 256);
is(ReadingsVal($limit_ep->{NAME}, 'max_pin_code_length', ''), 8,
   'DoorLock length is validated as uint8');
$limit_report->(1, 8, 65531, [0, 2]);
is(MATTERDevice_MaxBrightness($limit_ep), 254,
   'new AttributeList excludes unsupported saved maximum');
is(ReadingsVal($limit_ep->{NAME}, 'pct', ''), 35,
   'AttributeList change recalculates the derived percentage');
$limit_report->(1, 8, 65531, [0, 2, 3, 4, 5, 6]);
$limit_report->(1, 768, 65531, [7]);
ok(grep(/^ct:textField$/, MATTERDevice_GetSetList($limit_ep)),
   'fresh AttributeList can invalidate restored CT limits');
$limit_report->(1, 768, 65531, [7, 16395, 16396]);
# Simulate statefile restoration: readings survive, helper metadata does not.
my $limit_saved_ct = $limit_ep->{READINGS}{color_temp_min}{VAL};
$limit_ep->{READINGS}{color_temp_min}{VAL} = 'broken';
ok(grep(/^ct:textField$/, MATTERDevice_GetSetList($limit_ep)),
   'invalid restored boundary is validated before constructing a widget');
$limit_ep->{READINGS}{color_temp_min}{VAL} = $limit_saved_ct;
my $saved_limit_helper = delete $limit_ep->{helper};
ok(!grep(/^ct:colorpicker,CT,200,1,454$/, MATTERDevice_GetSetList($limit_ep)),
   'restored readings cannot invent commands without AcceptedCommandList');
is(MATTERDevice_ReportedLimit($limit_ep, 768, 16395), 200,
   'valid restored reading survives runtime capability rebuild');
$limit_ep->{helper} = $saved_limit_helper;
MATTER_ParseMessage($limit_io, encode_json({event => 'node_updated', data => {
    node_id => 6400, available => JSON::false}}));
readingsSingleUpdate($limit_ep, 'pct', 99, 1); # user's manual offline edit
$limit_report->(1, 8, 3, 111);
is(ReadingsVal($limit_ep->{NAME}, 'max_brightness', ''), 180,
   'offline live data cannot overwrite device limits');
MATTER_ParseMessage($limit_io, encode_json({event => 'node_updated', data => {
    node_id => 6400, available => JSON::true,
    attributes => {'1/8/3' => 112}}}));
is(ReadingsVal($limit_ep->{NAME}, 'max_brightness', ''), 112,
   'valid online recovery snapshot refreshes the device limit');
MATTERDevice_ApplyCapabilityMetadata($limit_root, {'1/8/65532' => 6});
is(ReadingsVal($limit_ep->{NAME}, 'pct', ''), 35,
   'online Lighting metadata recalculates percentage using its standardized scale');
MATTERDevice_ApplyCapabilityMetadata($limit_root, {'1/8/65532' => 4});
$limit_report->(1, 8, 3, 170);
is(ReadingsVal($limit_ep->{NAME}, 'max_brightness', ''), 170,
   'fresh online limit report updates the reading after recovery');
is(ReadingsVal($limit_ep->{NAME}, 'pct', ''), 52,
   'online limit change recalculates percentage from the last reported brightness');
$limit_report->(1, 8, 0, 85);
is(ReadingsVal($limit_ep->{NAME}, 'pct', ''), 50,
   'accepted fresh brightness report can refresh derived percentage during recovery');
for my $r (@limit_reports) {
    $limit_report->(1, $r->[0], $r->[1], $r->[3]);
    ok(!exists($attr{$limit_ep->{NAME}}{$r->[2]}),
       "$r->[2] is never auto-created as an attribute");
}
$limit_report->(1, 8, 3, 160);
ok(!exists($attr{$limit_ep->{NAME}}{max_brightness}),
   'reports never recreate removed obsolete attributes');
is(ReadingsVal($limit_ep->{NAME}, 'max_brightness', ''), 160,
   'subsequent reports continue to update the reading');

subtest 'Issue 27: unknown/offline blocks, valid online synchronizes' => sub {
    my @requests;
    my @peers;
    my $connect = sub {
        my ($io) = @_;
        socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'lifecycle socketpair';
        push @peers, $peer;
        $io->{CD} = $socket;
        $io->{websocket} = 1;
        $io->{ws_status} = 'connected';
        $io->{test_send_text} = sub {
            push @requests, JSON::decode_json($_[0]); return 1;
        };
    };
    my $io = $defs{ioLifecycle} = {NAME => 'ioLifecycle', TYPE => 'MATTER', READINGS => {}, helper => {}};
    my $other = $defs{ioLifecycleOther} = {NAME => 'ioLifecycleOther', TYPE => 'MATTER', READINGS => {}, helper => {}};
    $connect->($_) for ($io, $other);
    my $values = {
        '0/40/3' => 'Synthetic model', '0/51/0' => [{'1' => 1, '7' => 1}],
        '1/6/0' => JSON::true, '1/47/12' => 160,
        '1/29/0' => [{'0' => 0x0100, '1' => 1}], '1/8/3' => 200,
        '1/6/65529' => [0, 1, 2], '1/6/65532' => 0,
        '1/8/65529' => [0, 4], '1/8/65532' => 0,
    };
    for my $fixture ([$io, 6100, 'LifecycleA'], [$io, 6102, 'LifecycleB'],
                     [$other, 6100, 'LifecycleOther']) {
        MATTER_ProcessNode($fixture->[0], {node_id => $fixture->[1], name => $fixture->[2],
            available => JSON::true, attributes => $values});
    }
    my $a = $defs{MATTER_LifecycleA};
    my $b = $defs{MATTER_LifecycleB};
    my $ep = $defs{MATTER_LifecycleA_EP1};
    my $bep = $defs{MATTER_LifecycleB_EP1};
    my $other_ep = $defs{MATTER_LifecycleOther_EP1};
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', 'confirmed new online node accepts its initial snapshot');
    readingsSingleUpdate($ep, 'state', 'off', 1);
    readingsSingleUpdate($ep, 'battery_percent', 10, 1);
    readingsSingleUpdate($ep, 'model', 'Manual model', 1);
    readingsSingleUpdate($bep, 'state', 'off', 1);
    my $state_writes = $single_writes{$ep->{NAME}}{state};
    my $battery_writes = $single_writes{$ep->{NAME}}{battery_percent};
    my $type_writes = $single_writes{$ep->{NAME}}{device_type_ids};
    my $epoch = $a->{helper}{availability_epoch};
    my $reentered = 0;
    $reading_event_hook = sub {
        my ($device, $reading, $value) = @_;
        return unless $device eq $io && $reading eq 'state' && $value eq 'disconnected';
        ++$reentered;
        MATTER_ProcessNode($io, {node_id => $_, attributes => $values}) for (6100, 6102);
    };
    MATTER_Close($io);
    $reading_event_hook = undef;
    ok($reentered, 'IO reading event exercised synchronous parser reentry');
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'off', 'all roots are blocked before the first IO disconnect event');
    is(ReadingsVal($bep->{NAME}, 'state', ''), 'off', 'second root is blocked before reentrant callbacks too');
    is(ReadingsVal($a->{NAME}, 'available', ''), 'true', 'disconnect retains last reported availability for display');
    ok(!defined($a->{helper}{available}), 'display value does not grant runtime availability');
    ok($a->{helper}{availability_epoch} > $epoch, 'disconnect invalidates pending availability generations');
    is(ReadingsVal($other_ep->{NAME}, 'state', ''), 'on', 'same node ID on another IO is unaffected');

    $connect->($io);
    my $before_reads = scalar @requests;
    for my $reported (undef, 'true', [], {}) {
        MATTER_ProcessNode($io, {node_id => 6100, available => $reported, attributes => $values});
    }
    MATTERDevice_Parse($a, encode_json({result => $values}));
    MATTERDevice_ApplyCapabilityMetadata($a, {'1/6/65529' => []});
    like(MATTERDevice_Set($ep, $ep->{NAME}, 'getConfig') // '', qr/availability is unknown/,
         'unknown current availability rejects a physical read despite restored true');
    ok(MATTERDevice_CommandAccepted($ep, 6, 1), 'unknown availability cannot apply unsolicited recovery metadata');
    is(scalar(@requests), $before_reads, 'unknown availability triggers no automatic or manual read');
    is($single_writes{$ep->{NAME}}{state}, $state_writes, 'blocked snapshots do not churn physical state events');
    is($single_writes{$ep->{NAME}}{battery_percent}, $battery_writes, 'blocked snapshots preserve manual sensor value and timestamp');
    is($single_writes{$ep->{NAME}}{device_type_ids}, $type_writes, 'blocked snapshots preserve device types and metadata');
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 6100, available => JSON::true, attributes => $values}}));
    is(ReadingsVal($a->{NAME}, 'state', ''), 'online', 'validated availability independently restores root status');
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', 'online node_updated restores OnOff without any attribute_updated event');
    is(ReadingsVal($ep->{NAME}, 'model', ''), 'Synthetic model', 'online snapshot restores the server model on root and children');
    MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [6100, '0/40/3', 'Fresh model']}));
    is(ReadingsVal($ep->{NAME}, 'model', ''), 'Fresh model', 'accepted live model report updates children normally');
    MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [6100, '1/6/0', JSON::true]}));
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', 'fresh individual report restores physical state after recovery');
    is(ReadingsVal($ep->{NAME}, 'battery_percent', ''), 80, 'online snapshot restores its reported battery value');

    # Model normal statefile/configDB restoration: preserve public readings,
    # rebuild only transient helper metadata, then deliver the real lifecycle callback.
    readingsSingleUpdate($ep, 'state', 'off', 1);
    $a->{helper} = {};
    $ep->{helper} = {};
    for my $event (qw(INITIALIZED REREADCFG)) {
        readingsSingleUpdate($ep, 'state', 'off', 1);
        MATTERDevice_Notify($a, {NAME => 'global', CHANGED => [$event]});
        is(ReadingsVal($a->{NAME}, 'state', ''), 'unknown', "$event invalidates restored root status");
        MATTER_ProcessNode($io, {node_id => 6100, attributes => $values});
        is(ReadingsVal($ep->{NAME}, 'state', ''), 'off', "$event: snapshot without availability preserves restored state");
        MATTER_ProcessNode($io, {node_id => 6100, available => JSON::true, attributes => $values});
        is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', "$event: valid online snapshot synchronizes restored state");
        my ($read) = reverse grep {($_->{command} // '') eq 'read_attribute' &&
            ($_->{args}{node_id} // 0) == 6100} @requests;
        if ($read) {
            MATTER_ParseMessage($io, encode_json({message_id => $read->{message_id}, result => $values}));
        }
        is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', "$event: explicit reads and recovery do not prevent online synchronization");
    }
    MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [6100, '1/6/0', JSON::true]}));
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', 'live report after statefile restoration is accepted');

    MATTER_SetNodeStatus($io, 6100, 'removed');
    MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [6100, '1/6/0', JSON::false]}));
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', 'removed node cannot reuse its previous online permission');
    is(ReadingsVal($a->{NAME}, 'state', ''), 'removed', 'membership status is independent from physical state');
    MATTER_ProcessNode($io, {node_id => 6103, name => 'LifecycleUnknown', attributes => $values});
    ok(!exists($defs{MATTER_LifecycleUnknown_EP1}{READINGS}{state}), 'new node with unknown availability gets identity without invented device state');
    MATTER_Close($_) for ($io, $other);
};

subtest 'Issue 28: explicit ICD reconciliation and current backend support' => sub {
    my @requests;
    my @peers;
    my $connect = sub {
        my ($io) = @_;
        socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'ICD socketpair';
        push @peers, $peer;
        $io->{CD} = $socket;
        $io->{websocket} = 1;
        $io->{ws_status} = 'connected';
        $io->{test_send_text} = sub {
            push @requests, JSON::decode_json($_[0]); return 1;
        };
    };
    my $io = $defs{ioIcd} = {NAME => 'ioIcd', TYPE => 'MATTER', READINGS => {}, helper => {}};
    my $other = $defs{ioIcdOther} = {NAME => 'ioIcdOther', TYPE => 'MATTER', READINGS => {}, helper => {}};
    $connect->($_) for ($io, $other);
    my $sdk = 'matter-server/1.1.7 (matter.js/0.17.5-alpha)';
    my $info = sub {
        my ($target, $schema, $backend) = @_;
        MATTER_ParseMessage($target, encode_json({schema_version => $schema, sdk_version => $backend}));
    };
    my $values = {
        '0/29/1' => [29, 40, 70], '0/29/3' => [1],
        '0/40/21' => 0x01040000, '0/70/65532' => 5,
        '0/70/8' => 1, '0/70/0' => 3600,
        '1/6/0' => JSON::true,
    };
    for my $target ($io, $other) {
        MATTER_ProcessNode($target, {node_id => 6200, name => 'IcdLifecycle',
            available => JSON::true, attributes => $values});
    }
    my $root = $modules{MATTERDevice}{defptr}{'ioIcd:6200'};
    my $other_root = $modules{MATTERDevice}{defptr}{'ioIcdOther:6200'};
    my ($child) = MATTERDevice_NodeChildren($root);
    my $can_admin = sub { return scalar grep { /^icdRegister:/ } MATTERDevice_GetSetList($_[0]); };
    my $can_get = sub { return MATTERDevice_Get($_[0], $_[0]{NAME}, '?') =~ /\bicdState\b/; };
    my $report = sub {
        my ($path, $value) = @_;
        MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [6200, $path, $value]}));
    };

    MATTER_ProcessNode($io, {node_id => 6201, name => 'NonIcd', available => JSON::true,
        attributes => {'0/29/1' => [29, 40]}});
    ok(!exists($defs{MATTER_NonIcd}{READINGS}{icd_supported}), 'ordinary non-ICD root gets no new negative ICD readings');

    # Persisted presentation readings alone do not establish backend support.
    readingsSingleUpdate($io, 'schema_version', 15, 0);
    readingsSingleUpdate($io, 'sdk_version', $sdk, 0);
    ok(!$can_get->($root) && !$can_admin->($root), 'restored server readings do not advertise ICD operations');
    for my $case ([15, 'python-matter-server/8.0'], [15, 'unknown'],
                  [11, $sdk], [undef, $sdk], [[], $sdk], [12, undef], [12, {}]) {
        $info->($io, @$case);
        ok(!$can_get->($root) && !$can_admin->($root), 'unsupported or malformed current backend hides ICD operations');
    }
    my $before = @requests;
    like(MATTERDevice_Get($root, $root->{NAME}, 'icdState'), qr/Unknown argument/, 'explicit unsupported query is rejected');
    like(MATTERDevice_Set($root, $root->{NAME}, 'icdRegister'), qr/Unknown argument/, 'explicit unsupported registration is rejected');
    is(scalar @requests, $before, 'rejected operations send no request');
    $info->($io, 12, $sdk);
    $info->($other, 15, $sdk);
    ok($can_get->($root) && $can_admin->($root), 'current matterjs server and schema 12 enable supported root operations');
    ok(!$can_get->($child) && !$can_admin->($child), 'ICD operations remain root-only');

    # Registration keeps upstream conservative defaults, with correlated replies.
    for my $pair (['icdRegister', 'register_icd'], ['icdUnregister', 'unregister_icd'], ['icdResync', 'resync_icd']) {
        is(MATTERDevice_Set($root, $root->{NAME}, $pair->[0]), undef, "$pair->[0] accepted");
        my $request = $requests[-1];
        is($request->{command}, $pair->[1], 'correct server operation');
        is_deeply($request->{args}, {node_id => 6200}, 'no force or multi-admin bypass');
        MATTER_ParseMessage($io, encode_json({message_id => $request->{message_id},
            result => $pair->[1] eq 'resync_icd' ? undef : {supported => JSON::true, registered => JSON::true}}));
    }
    like(MATTERDevice_Get($root, $root->{NAME}, 'icdState'), qr/requested/, 'controller state query remains asynchronous');
    MATTER_ParseMessage($io, encode_json({message_id => $requests[-1]{message_id}, result => {
        supported => JSON::true, registered => JSON::true, awake => JSON::false,
        available => JSON::true, next_expected_checkin => 1735689600000}}));
    is(ReadingsVal($root->{NAME}, 'state', ''), 'online', 'sleeping ICD does not imply offline');

    # Whole ServerList content, not the presence of attributes in a node patch,
    # determines explicit removal. Malformed lists never act as absence.
    MATTER_ProcessNode($io, {node_id => 6200, attributes => {'0/40/3' => 'Synthetic ICD'}});
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'true', 'partial node update preserves ICD support');
    for my $bad (undef, '', {}, [29, undef], [29, {}], [-1], [4294967296]) {
        $report->('0/29/1', $bad);
        is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'true', 'malformed ServerList cannot revoke ICD support');
    }
    $report->('1/29/1', [29, 6]);
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'true', 'child ServerList does not revoke root support');
    MATTER_ProcessNode($io, {node_id => 6200, available => JSON::false, attributes => {'0/29/1' => []}});
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'true', 'offline snapshot cannot revoke persisted capability');
    MATTER_ProcessNode($io, {node_id => 6200, available => JSON::true, attributes => $values});

    # ServerList wins over obsolete cluster values in the same payload.
    MATTER_ProcessNode($io, {node_id => 6200, attributes => {%$values, '0/29/1' => [29, 40]}});
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'false', 'explicit ServerList absence revokes prior ICD support');
    is(ReadingsVal($root->{NAME}, 'icd_lit_supported', ''), 'false', 'revoked ICD cannot remain LIT-capable');
    ok(!exists($root->{helper}{capabilities}{70}), 'obsolete ICD command metadata is removed');
    ok(!$can_get->($root) && !$can_admin->($root), 'revoked capability removes get and set commands');
    ok($can_get->($other_root) && $can_admin->($other_root), 'same node on another IO remains supported');
    is(ReadingsVal($child->{NAME}, 'state', ''), 'on', 'capability reconciliation preserves physical endpoint state');
    my $writes = $single_writes{$root->{NAME}}{icd_supported};
    $report->('0/29/1', []);
    is($single_writes{$root->{NAME}}{icd_supported}, $writes, 'repeated absent/empty ServerList does not churn readings');
    $report->('0/29/1', ['0x001D', '0x0046']);
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'true', 'reported ServerList presence restores ICD capability');
    ok($can_get->($root) && !$can_admin->($root), 'restored cluster alone does not reuse obsolete Check-In features');
    $report->('0/70/65532', 5);
    ok($can_admin->($root), 'new Check-In feature report restores administrative commands');

    # The ordinary correlated getConfig path includes ServerList and preserves
    # a newer live list when an older read response arrives.
    is(MATTERDevice_Set($root, $root->{NAME}, 'getConfig'), undef, 'explicit online getConfig accepted');
    my $read = $requests[-1];
    ok(grep($_ eq '0/29/1', @{$read->{args}{attribute_path}}), 'root getConfig requests ServerList in its existing read');
    $report->('0/29/1', [29, 40]);
    MATTER_ParseMessage($io, encode_json({message_id => $read->{message_id}, result => $values}));
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'false', 'older getConfig cannot undo newer live capability removal');
    MATTER_ProcessNode($io, {node_id => 6200, attributes => $values});
    is(MATTERDevice_Set($root, $root->{NAME}, 'getConfig'), undef, 'second explicit configuration read accepted');
    MATTER_ParseMessage($io, encode_json({message_id => $requests[-1]{message_id},
        result => {%$values, '0/29/1' => [29, 40]}}));
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'false', 'getConfig ServerList wins over other cluster data in that reply');
    MATTER_ProcessNode($io, {node_id => 6200, attributes => $values});
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 6200, attributes => {'0/29/1' => [29, 40]}}}));
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'false', 'partial node_updated with explicit complete ServerList reconciles support');
    MATTER_ProcessNode($io, {node_id => 6200, attributes => $values});
    $io->{helper}{pending_command}{'icd-discovery-test'} = 'get_nodes';
    $report->('0/29/1', [29, 40]);
    $report->('0/29/1', [29, undef]);
    MATTER_ParseMessage($io, encode_json({message_id => 'icd-discovery-test', result => [{
        node_id => 6200, available => JSON::true, attributes => $values}]}));
    is(ReadingsVal($root->{NAME}, 'icd_supported', ''), 'false', 'older discovery preserves valid live ServerList despite a later malformed list');

    # Dynamic observations retain their normal FHEM timestamps and values.
    MATTER_ProcessNode($io, {node_id => 6200, attributes => $values});
    my %before_close = map { $_ => {%{$root->{READINGS}{$_}}} } grep { /^icd_/ } keys %{$root->{READINGS}};
    my %before_writes = map { $_ => $single_writes{$root->{NAME}}{$_} } keys %before_close;
    {
        $reading_event_hook = sub {
            my ($device, $reading) = @_;
            ok(!$can_get->($root), 'disconnect event observes ICD API permission already cleared')
                if $device eq $io && $reading eq 'state';
        };
        MATTER_Close($io);
        $reading_event_hook = undef;
    }
    is_deeply({map { $_ => $root->{READINGS}{$_} } keys %before_close}, \%before_close,
        'disconnect preserves ICD observations and their existing timestamps');
    ok(!$can_get->($root) && !$can_admin->($root), 'disconnect clears backend permission before reuse');
    $connect->($io);
    ok(!$can_get->($root), 'reconnect cannot use persisted schema/sdk readings');
    $info->($io, 15, 'python-matter-server/8.0');
    ok(!$can_get->($root) && !$can_admin->($root), 'switch to another backend does not retain ICD API support');
    $info->($io, 15, $sdk);
    ok($can_get->($root) && $can_admin->($root), 'current matterjs identification restores operations');
    is_deeply({map { $_ => $root->{READINGS}{$_} } keys %before_close}, \%before_close,
        'server identification does not refresh or erase historical device readings');
    is_deeply({map { $_ => $single_writes{$root->{NAME}}{$_} } keys %before_writes}, \%before_writes,
        'disconnect and server identification publish no extra ICD reading updates');
    MATTER_Close($_) for ($io, $other);
};

subtest 'Issue 30: persisted sensors follow the shared availability lifecycle' => sub {
    my @requests;
    my @peers;
    my $connect = sub {
        my ($io) = @_;
        socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'sensor lifecycle socketpair';
        push @peers, $peer;
        $io->{CD} = $socket;
        $io->{websocket} = 1;
        $io->{ws_status} = 'connected';
        $io->{test_send_text} = sub {
            push @requests, JSON::decode_json($_[0]); return 1;
        };
    };
    my $io = $defs{ioSensors} = {NAME => 'ioSensors', TYPE => 'MATTER', READINGS => {}, helper => {}};
    my $other = $defs{ioSensorsOther} = {NAME => 'ioSensorsOther', TYPE => 'MATTER', READINGS => {}, helper => {}};
    $connect->($_) for ($io, $other);
    # ep, type, cluster, reading, initial raw/value, manual value,
    # online raw/value, live raw/value, invalid raw. Values are synthetic.
    my @sensors = (
        [1, 0x0015, 69, 'contact', JSON::true, 'closed', 'open', JSON::true, 'closed', JSON::false, 'open', 'unknown'],
        [2, 0x0302, 1026, 'temperature', 2234, 22.34, 18.5, 2145, 21.45, -550, -5.5, -32768],
        [3, 0x0307, 1029, 'humidity', 4350, 43.5, 40, 5150, 51.5, 0, 0, 65535],
        [4, 0x0106, 1024, 'illuminance', 30001, 1000, 10, 20001, 100, 0, 0, 65535],
        [5, 0x0107, 1030, 'motion', 3, 'motion', 'nomotion', 5, 'motion', 2, 'nomotion', 256],
        [6, 0x0043, 69, 'water_leak', JSON::true, 'leak', 'dry', JSON::true, 'leak', JSON::false, 'dry', 7],
        [7, 0x0044, 69, 'rain', JSON::false, 'dry', 'rain', JSON::false, 'dry', JSON::true, 'rain', -1],
        [8, 0xFFF0, 69, 'boolean_state', JSON::true, 1, 0, JSON::true, 1, JSON::false, 0, 'unknown'],
    );
    my (%initial, %online, %invalid, %nulls);
    for my $row (@sensors) {
        my ($ep, $type, $cluster) = @$row;
        $initial{"$ep/29/0"} = [{'0' => $type, '1' => 1}];
        $initial{"$ep/$cluster/0"} = $row->[4];
        $online{"$ep/$cluster/0"} = $row->[7];
        $invalid{"$ep/$cluster/0"} = $row->[11];
        $nulls{"$ep/$cluster/0"} = undef;
    }
    for my $target ($io, $other) {
        MATTER_ProcessNode($target, {node_id => 6300, name => 'SensorLifecycle',
            available => JSON::true, attributes => \%initial});
    }
    my $root = $modules{MATTERDevice}{defptr}{'ioSensors:6300'};
    my $other_root = $modules{MATTERDevice}{defptr}{'ioSensorsOther:6300'};
    my %devices = map { $_->{endpoint_id} => $_ } MATTERDevice_NodeChildren($root);
    my %other_devices = map { $_->{endpoint_id} => $_ } MATTERDevice_NodeChildren($other_root);
    my $binary = sub { return $_[0] =~ /\A(?:contact|water_leak|rain|motion)\z/; };
    # Include saved timestamps AND write counters: the general test stub's
    # fixed clock alone cannot detect a repeated write of an unchanged value.
    my $capture = sub {
        my ($targets) = @_;
        my %snapshot;
        for my $row (@sensors) {
            my $device = $targets->{$row->[0]};
            for my $reading ($row->[3], 'device_type_ids', $binary->($row->[3]) ? ('state') : ()) {
                $snapshot{$row->[0]}{$reading} = {
                    %{$device->{READINGS}{$reading}},
                    writes => $single_writes{$device->{NAME}}{$reading} // 0,
                };
            }
        }
        return \%snapshot;
    };
    for my $row (@sensors) {
        is(ReadingsVal($devices{$row->[0]}{NAME}, $row->[3], ''), $row->[5], "$row->[3]: initial online snapshot is mapped");
    }
    ok(!exists($devices{8}{READINGS}{contact}), 'unknown type remains a generic boolean, without guessing a contact');
    is(CommandRename(undef, "$root->{NAME} SensorLifecycleRenamed"), undef, 'root can be manually renamed');
    is(CommandRename(undef, "$devices{1}{NAME} SensorContactRenamed"), undef, 'contact endpoint can be manually renamed');
    my $other_before = $capture->(\%other_devices);
    my $manual = sub {
        for my $row (@sensors) {
            my $device = $devices{$row->[0]};
            for my $reading ($row->[3], $binary->($row->[3]) ? ('state') : ()) {
                readingsSingleUpdate($device, $reading, $row->[6], 1);
                $device->{READINGS}{$reading}{TIME} = '2026-11-21 23:59:00';
            }
        }
    };
    $manual->();
    my $saved = $capture->(\%devices);
    MATTER_Close($io);
    is_deeply($capture->(\%devices), $saved, 'IO loss preserves manual sensor values, states and timestamps');
    # Model statefile/configDB restoration by retaining readings and identity,
    # rebuilding helpers and invoking the actual post-restoration callback.
    $_->{helper} = {} for ($root, values %devices);
    MATTERDevice_Notify($root, {NAME => 'global', CHANGED => ['INITIALIZED']});
    $connect->($io);
    is(ReadingsVal($root->{NAME}, 'state', ''), 'unknown', 'startup root status does not reuse persisted online authority');
    for my $node ({node_id => 6300, attributes => \%initial},
                  {node_id => 6300, available => undef, attributes => \%initial},
                  {node_id => 6300, available => JSON::false, attributes => \%initial}) {
        MATTER_ProcessNode($io, $node);
        is_deeply($capture->(\%devices), $saved, 'unknown/null/offline initial snapshot preserves all saved sensor readings');
    }
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 6300, available => JSON::true, attributes => \%online}}));
    is(ReadingsVal($root->{NAME}, 'state', ''), 'online', 'valid online node_updated restores root status');
    for my $row (@sensors) {
        my $device = $devices{$row->[0]};
        is(ReadingsVal($device->{NAME}, $row->[3], ''), $row->[8], "$row->[3]: online snapshot replaces the saved manual value");
        is(ReadingsVal($device->{NAME}, 'state', ''), $row->[8], "$row->[3]: endpoint state follows the sensor")
            if $binary->($row->[3]);
    }
    is($defs{SensorLifecycleRenamed}, $root, 'rediscovery preserves renamed root identity');
    is($defs{SensorContactRenamed}, $devices{1}, 'rediscovery preserves renamed endpoint identity');
    is(ReadingsVal('SensorContactRenamed', 'device_type_ids', ''), '0x0015', 'saved type identifies contact without a new Descriptor report');
    is_deeply($capture->(\%other_devices), $other_before, 'same-node sensor values on another IO are unchanged');

    my $valid = $capture->(\%devices);
    for my $values (\%nulls, \%invalid, {}) {
        MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
            node_id => 6300, attributes => $values}}));
        is_deeply($capture->(\%devices), $valid, 'null, invalid or omitted sensor values preserve readings and timestamps');
    }
    for my $row (@sensors) {
        my $before = $capture->(\%devices);
        MATTER_ParseMessage($io, encode_json({event => 'attribute_updated',
            data => [6300, "$row->[0]/$row->[2]/0", $row->[9]]}));
        is(ReadingsVal($devices{$row->[0]}{NAME}, $row->[3], ''), $row->[10], "$row->[3]: live report maps to its endpoint");
        my $after = $capture->(\%devices);
        delete $before->{$row->[0]}; delete $after->{$row->[0]};
        is_deeply($after, $before, 'live report preserves sibling sensor endpoints');
    }
    is_deeply($capture->(\%other_devices), $other_before, 'live sensor updates remain isolated from the other IO');

    MATTER_ProcessNode($io, {node_id => 6300, available => JSON::false});
    $manual->(); $saved = $capture->(\%devices);
    for my $row (@sensors) {
        MATTER_ParseMessage($io, encode_json({event => 'attribute_updated',
            data => [6300, "$row->[0]/$row->[2]/0", $row->[7]]}));
    }
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 6300, available => JSON::false, attributes => \%online}}));
    is_deeply($capture->(\%devices), $saved, 'offline live reports and node_updated preserve every manual sensor correction');
    MATTER_ProcessNode($io, {node_id => 6300, available => JSON::true, attributes => \%online});
    for my $row (@sensors) {
        is(ReadingsVal($devices{$row->[0]}{NAME}, $row->[3], ''), $row->[8], "$row->[3]: offline/online recovery resumes normal snapshots");
    }
    $manual->(); $saved = $capture->(\%devices);
    MATTERDevice_Notify($root, {NAME => 'global', CHANGED => ['REREADCFG']});
    MATTER_ProcessNode($io, {node_id => 6300, attributes => \%online});
    is_deeply($capture->(\%devices), $saved, 'REREADCFG requires a new availability report before replacing sensor values');
    MATTER_ProcessNode($io, {node_id => 6300, available => JSON::true, attributes => \%online});
    for my $row (@sensors) {
        is(ReadingsVal($devices{$row->[0]}{NAME}, $row->[3], ''), $row->[8], "$row->[3]: valid online report resumes after REREADCFG");
    }
    is_deeply($capture->(\%other_devices), $other_before, 'all lifecycle transitions preserve the other IO readings');
    is(scalar @requests, 0, 'sensor synchronization uses supplied data without additional reads or commands');
    MATTER_Close($_) for ($io, $other);
};

subtest 'Issue 32: environmental values, units and optional numeric measurements' => sub {
    my @requests;
    socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'environment socketpair';
    my $io = $defs{ioEnvironment} = {
        NAME => 'ioEnvironment', TYPE => 'MATTER', READINGS => {}, helper => {},
        CD => $socket, websocket => 1, ws_status => 'connected',
        test_send_text => sub {
            push @requests, JSON::decode_json($_[0]); return 1;
        },
    };
    # ep, cluster, value reading, unit reading/id/label, initial/live/snapshot,
    # invalid raw value. Synthetic payloads use Matter 1.4 attribute IDs.
    my @rows = (
        [1, 1027, 'pressure', undef, undef, undef, 1013, 1008, 999, -32768],
        [2, 1037, 'co2', 'co2_unit', 0, 'ppm', 650, 720.5, 500.25, -5],
        [3, 1066, 'pm25', 'pm25_unit', 4, 'ug/m3', 12.5, 4.5, 0.1, -0.1],
        [4, 1070, 'tvoc', 'tvoc_unit', 1, 'ppb', 3.5, 0.25, 12, -1],
    );
    my %initial;
    for my $row (@rows) {
        my ($ep, $cluster) = @$row;
        $initial{"$ep/$cluster/0"} = $row->[6];
        $initial{"$ep/$cluster/65532"} = $ep == 1 ? 0 : 1;
        $initial{"$ep/$cluster/65531"} = $ep == 1 ? [0] : [0, 8];
        $initial{"$ep/$cluster/8"} = $row->[4] if defined $row->[3];
    }
    # LEV only (bit 1), with LevelValue (attribute 10), never a MeasuredValue.
    my @qualitative = ([5, 1037, 'co2'], [6, 1066, 'pm25'], [7, 1070, 'tvoc']);
    for my $q (@qualitative) {
        $initial{"$q->[0]/$q->[1]/65532"} = 2;
        $initial{"$q->[0]/$q->[1]/65531"} = [10];
        $initial{"$q->[0]/$q->[1]/10"} = 3;
    }
    $initial{'8/1037/65532'} = 1;
    $initial{'8/1037/0'} = 0.75; # No unit supplied yet: never assume ppm.
    $initial{'9/1070/65532'} = 1;
    $initial{'9/1070/8'} = 1; # Unit supplied before any value.
    MATTER_ProcessNode($io, {node_id => 6400, name => 'EnvironmentMatrix',
        available => JSON::true, attributes => \%initial});
    my $root = $modules{MATTERDevice}{defptr}{'ioEnvironment:6400'};
    my %ep = map { $_->{endpoint_id} => $_ } MATTERDevice_NodeChildren($root);
    my $report = sub {
        my ($endpoint, $cluster, $attr, $value) = @_;
        MATTER_ParseMessage($io, encode_json({event => 'attribute_updated',
            data => [6400, "$endpoint/$cluster/$attr", $value]}));
    };
    my $snapshot = sub {
        MATTER_ParseMessage($io, encode_json({event => 'node_updated',
            data => {node_id => 6400, attributes => $_[0]}}));
    };
    my $capture = sub {
        my %state;
        for my $row (@rows) {
            for my $reading ($row->[2], defined($row->[3]) ? ($row->[3]) : ()) {
                my $name = $ep{$row->[0]}{NAME};
                $state{$row->[0]}{$reading} = {
                    %{$ep{$row->[0]}{READINGS}{$reading}},
                    writes => $single_writes{$name}{$reading} // 0,
                };
            }
        }
        return \%state;
    };
    for my $row (@rows) {
        is(ReadingsVal($ep{$row->[0]}{NAME}, $row->[2], ''), $row->[6], "$row->[2]: initial snapshot preserves the specified value");
        is(ReadingsVal($ep{$row->[0]}{NAME}, $row->[3], ''), $row->[5], "$row->[2]: initial unit is mapped")
            if defined $row->[3];
    }
    for my $q (@qualitative) {
        ok(!exists($ep{$q->[0]}{READINGS}{$q->[2]}), "$q->[2]: LevelValue alone cannot fabricate a numeric concentration");
        ok(!exists($ep{$q->[0]}{READINGS}{$q->[2] . '_unit'}), 'qualitative feature metadata cannot fabricate a measurement unit');
    }
    is(ReadingsVal($ep{8}{NAME}, 'co2', ''), 0.75, 'numeric concentration without a unit remains the supplied raw number');
    ok(!exists($ep{8}{READINGS}{co2_unit}), 'missing unit is not assumed to be ppm');
    $report->(8, 1037, 8, 255);
    ok(!exists($ep{8}{READINGS}{co2_unit}), 'unknown unit on a new endpoint does not create a unit reading');
    $report->(8, 1037, 8, undef);
    ok(!exists($ep{8}{READINGS}{co2_unit}), 'null unit on a new endpoint does not create a unit reading');
    my $raw_writes = $single_writes{$ep{8}{NAME}}{co2};
    $report->(8, 1037, 8, 3);
    is(ReadingsVal($ep{8}{NAME}, 'co2_unit', ''), 'mg/m3', 'a later supplied unit is accepted without a ppm default');
    is(ReadingsVal($ep{8}{NAME}, 'co2', ''), 0.75, 'mg/m3 concentration is not silently converted to ppm');
    is($single_writes{$ep{8}{NAME}}{co2}, $raw_writes, 'unit-only report does not rewrite the measured value');
    ok(!exists($ep{9}{READINGS}{tvoc}), 'unit and NumericMeasurement metadata alone do not create a zero measurement');
    $report->(9, 1070, 0, 0);
    is(ReadingsVal($ep{9}{NAME}, 'tvoc', ''), 0, 'explicit numeric zero is a valid first measurement');
    is(ReadingsVal($ep{9}{NAME}, 'tvoc_unit', ''), 'ppb', 'unit-first ordering retains the supplied unit');

    $snapshot->({map { ("$_->[0]/$_->[1]/0" => 0) } @rows});
    for my $row (@rows) {
        is(ReadingsVal($ep{$row->[0]}{NAME}, $row->[2], ''), 0, "$row->[2]: explicit zero in an online snapshot is valid");
    }
    for my $row (@rows) {
        my $before = $capture->();
        $report->($row->[0], $row->[1], 0, $row->[7]);
        is(ReadingsVal($ep{$row->[0]}{NAME}, $row->[2], ''), $row->[7], "$row->[2]: live value is mapped to its endpoint");
        my $after = $capture->();
        delete $before->{$row->[0]}; delete $after->{$row->[0]};
        is_deeply($after, $before, 'live value preserves sibling measurements and units');
    }
    $snapshot->({map { ("$_->[0]/$_->[1]/0" => $_->[8]) } @rows});
    for my $row (@rows) {
        is(ReadingsVal($ep{$row->[0]}{NAME}, $row->[2], ''), $row->[8], "$row->[2]: node_updated synchronizes without repeated FeatureMap metadata");
    }
    my $valid = $capture->();
    for my $values ({map { ("$_->[0]/$_->[1]/0" => undef) } @rows},
                    {map { ("$_->[0]/$_->[1]/0" => $_->[9]) } @rows},
                    {map { ("$_->[0]/$_->[1]/0" => 'unknown') } @rows},
                    {map { ("$_->[0]/$_->[1]/0" => []) } @rows}, {}) {
        $snapshot->($values);
        is_deeply($capture->(), $valid, 'null/invalid/malformed/omitted snapshot values preserve readings, timestamps and write counts');
    }
    for my $row (@rows) {
        $report->($row->[0], $row->[1], 0, undef);
        $report->($row->[0], $row->[1], 0, $row->[9]);
        if (defined $row->[3]) {
            $report->($row->[0], $row->[1], 8, $_) for (undef, 255, 'unknown', {});
        }
    }
    is_deeply($capture->(), $valid, 'invalid live values and units preserve the last valid readings without rewrites');
    for my $bad (0.5, 32768, -32769) {
        $report->(1, 1027, 0, $bad);
    }
    is_deeply($capture->(), $valid, 'fractional and out-of-int16 pressure reports are ignored');
    for my $bound (-32767, 32767) {
        $report->(1, 1027, 0, $bound);
        is(ReadingsVal($ep{1}{NAME}, 'pressure', ''), $bound, 'valid int16 pressure boundary is retained');
    }
    is(ReadingsVal($root->{NAME}, 'state', ''), 'online', 'environment measurements do not replace root reachability');
    is(scalar @requests, 0, 'all measurement handling uses supplied data without extra reads or polling');
    MATTER_Close($io);
};

subtest 'Issue 33: HVAC capabilities, cooling writes and correlated Matter status' => sub {
    my @requests;
    my @peers;
    my $connect = sub {
        my ($io) = @_;
        socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'HVAC socketpair';
        push @peers, $peer;
        $io->{CD} = $socket; $io->{websocket} = 1; $io->{ws_status} = 'connected';
        $io->{test_send_text} = sub {push @requests, JSON::decode_json($_[0]); return 1;};
    };
    my $io = $defs{ioHvac} = {NAME => 'ioHvac', TYPE => 'MATTER', READINGS => {}, helper => {}};
    my $other = $defs{ioHvacOther} = {NAME => 'ioHvacOther', TYPE => 'MATTER', READINGS => {}, helper => {}};
    $connect->($_) for ($io, $other);
    my $values = {
        '1/513/65531' => [18, 27, 28], '1/513/65532' => 1, '1/513/27' => 2,
        '1/513/18' => 2100, '1/513/28' => 4,
        '2/513/65531' => [17, 27, 28], '2/513/65532' => 2, '2/513/27' => 0,
        '2/513/17' => 2600, '2/513/28' => 3,
        '3/513/65531' => [17, 18, 27, 28], '3/513/65532' => 35, '3/513/27' => 4,
        '3/513/17' => 2600, '3/513/18' => 2100, '3/513/28' => 1,
        '4/514/65531' => [0, 1, 2, 3], '4/514/65532' => 0, '4/514/1' => 1,
        '4/514/0' => 3, '4/514/2' => 50, '4/514/3' => 45,
        '5/514/65531' => [0, 1, 2, 3], '5/514/65532' => 2, '5/514/1' => 4,
        '5/514/0' => 5, '5/514/3' => 30,
        '6/513/65531' => [17, 18, 27, 28], '6/513/27' => 4,
        '6/513/18' => 2100, '6/513/28' => 4,
        '7/513/65532' => 3, '7/513/27' => 4, '7/513/18' => 2100,
        '8/3/65529' => [0], '8/3/0' => 0,
        '9/514/65531' => [3], '9/514/65532' => 0, '9/514/3' => 70,
    };
    for my $target ($io, $other) {
        MATTER_ProcessNode($target, {node_id => 6500, name => 'HvacMatrix', available => JSON::true, attributes => $values});
    }
    my $root = $modules{MATTERDevice}{defptr}{'ioHvac:6500'};
    my $other_root = $modules{MATTERDevice}{defptr}{'ioHvacOther:6500'};
    my %ep = map { $_->{endpoint_id} => $_ } MATTERDevice_NodeChildren($root);
    my %other_ep = map { $_->{endpoint_id} => $_ } MATTERDevice_NodeChildren($other_root);
    my $list = sub {return join(' ', MATTERDevice_GetSetList($_[0]));};
    my $report = sub {
        my ($endpoint, $cluster, $attribute, $value) = @_;
        MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [6500, "$endpoint/$cluster/$attribute", $value]}));
    };
    my $status = sub {
        my ($path, $code, $cluster_code) = @_;
        my ($endpoint, $cluster, $attribute) = split '/', $path;
        return [{Path => {EndpointId => 0 + $endpoint, ClusterId => 0 + $cluster, AttributeId => 0 + $attribute},
                 Status => $code, defined($cluster_code) ? (ClusterStatus => $cluster_code) : ()}];
    };
    unlike($list->($root), qr/(?:desired-temp|fan_mode|fan_pct|identify):/, 'endpoint capabilities are not offered on the root');
    like($list->($ep{1}), qr/desired-temp:textField/, 'heating target uses advertised attribute and heating feature');
    unlike($list->($ep{1}), qr/desired-temp-cool:|mode:[^ ]*\b(?:cool|auto)\b/, 'heater does not offer cooling target or cooling/auto modes');
    like($list->($ep{2}), qr/desired-temp-cool:textField/, 'cooler offers the cooling target');
    unlike($list->($ep{2}), qr/desired-temp:|mode:[^ ]*\b(?:heat|emergency_heat|auto)\b/, 'cooler does not offer heating or auto modes');
    like($list->($ep{3}), qr/mode:off,heat,cool,auto,emergency_heat/, 'combined auto thermostat offers feature-compatible modes');
    like($list->($ep{4}), qr/fan_mode:off,low,high(?: |$)/, 'fan sequence excludes medium and auto');
    like($list->($ep{5}), qr/fan_mode:off,high,auto(?: |$)/, 'auto fan sequence excludes low and medium');
    unlike($list->($ep{6}), qr/(?:desired-temp(?:-cool)?|mode):/, 'saved physical mode cannot replace missing FeatureMap');
    unlike($list->($ep{7}), qr/(?:desired-temp(?:-cool)?|mode):/, 'reported values cannot replace missing AttributeList');
    unlike($list->($ep{9}), qr/fan_pct:|fan_mode:/, 'PercentCurrent alone cannot authorize PercentSetting');
    like($list->($ep{8}), qr/identify:noArg/, 'Identify still follows AcceptedCommandList');
    ok(!MATTERDevice_AttributeWritable($ep{9}, 514, 3), 'read-only PercentCurrent is not a standard write target');
    my $before = @requests;
    for my $case ([$ep{1}, 'desired-temp-cool', 26], [$ep{1}, 'mode', 'cool'],
                  [$ep{2}, 'mode', 'heat'], [$ep{4}, 'fan_mode', 'medium'],
                  [$ep{4}, 'fan_mode', 'auto'], [$ep{5}, 'fan_mode', 'low'],
                  [$ep{4}, 'fan_mode', 'on'], [$ep{9}, 'fan_pct', 50]) {
        ok(defined(MATTERDevice_Set($case->[0], $case->[0]{NAME}, $case->[1], $case->[2])), 'explicit unsupported target/mode is rejected');
    }
    is(scalar @requests, $before, 'unsupported commands send no request');

    my $cool_writes = $single_writes{$ep{2}{NAME}}{'desired-temp-cool'};
    my @accepted = MATTERDevice_Set($ep{2}, $ep{2}{NAME}, 'desired-temp-cool', '26.5');
    is_deeply(\@accepted, [undef, 1], 'asynchronous cooling setter suppresses synthetic success events');
    my $cool = $requests[-1];
    is($cool->{command}, 'write_attribute', 'cooling target is a native attribute write');
    is($cool->{args}{attribute_path}, '2/513/17', 'cooling writes OccupiedCoolingSetpoint on the target endpoint');
    is($cool->{args}{value}, 2650, 'cooling temperature is encoded in centidegrees');
    is(ReadingsVal($ep{2}{NAME}, 'desired-temp-cool', ''), 26, 'queued cooling write does not update telemetry');
    MATTER_ParseMessage($other, encode_json({message_id => $cool->{message_id}, result => $status->('2/513/17', 135)}));
    ok(exists($io->{helper}{pending_command}{$cool->{message_id}}), 'same request ID on another IO cannot consume this write');
    MATTER_ParseMessage($io, encode_json({message_id => $cool->{message_id}, result => $status->('2/513/17', 0)}));
    is(ReadingsVal($ep{2}{NAME}, 'lastError', ''), 'none', 'matching Matter success clears the error');
    is($single_writes{$ep{2}{NAME}}{'desired-temp-cool'}, $cool_writes, 'success reply does not rewrite the physical setpoint');
    $report->(2, 513, 17, 2650);
    is(ReadingsVal($ep{2}{NAME}, 'desired-temp-cool', ''), 26.5, 'only the device report updates cooling telemetry');
    is(ReadingsVal($other_ep{2}{NAME}, 'desired-temp-cool', ''), 26, 'same-node other IO telemetry is isolated');

    is(MATTERDevice_Set($ep{1}, $ep{1}{NAME}, 'desired-temp', '-5.25'), undef, 'negative protocol temperature is encoded before device constraint validation');
    my $heat = $requests[-1];
    is($heat->{args}{value}, -525, 'negative centidegree rounding is correct');
    MATTER_ParseMessage($io, encode_json({message_id => $heat->{message_id}, result => $status->('1/513/18', 135, 7)}));
    like(ReadingsVal($ep{1}{NAME}, 'lastError', ''), qr/failed:.*135.*cluster status 7/, 'Matter constraint refusal and cluster status are visible');
    is(ReadingsVal($ep{1}{NAME}, 'desired-temp', ''), 21, 'device refusal preserves heating telemetry');
    for my $bad ('26.555', 'nan', 328, -274) {
        ok(defined(MATTERDevice_Set($ep{2}, $ep{2}{NAME}, 'desired-temp-cool', $bad)), 'malformed/out-of-protocol cooling temperature is rejected');
    }

    my @invalid = (
        {}, {result => []}, {result => {}}, {result => 1},
        {result => [{Path => {EndpointId => 2, ClusterId => 513, AttributeId => 17}}]},
        {result => $status->('2/513/17', undef)},
        {result => $status->('2/513/17', JSON::false)},
        {result => $status->('2/513/17', 256)},
        {result => $status->('2/513/17', 0.5)},
        {result => $status->('3/513/17', 0)},
        {result => $status->('2/514/17', 0)},
        {result => $status->('2/513/18', 0)},
        {result => [@{$status->('2/513/17', 0)}, @{$status->('2/513/17', 0)}]},
        {result => [{Path => {EndpointId => 2, ClusterId => 513, AttributeId => 17}, Status => 0, ClusterStatus => {}}]},
    );
    for my $reply (@invalid) {
        is(MATTERDevice_Set($ep{2}, $ep{2}{NAME}, 'desired-temp-cool', '27'), undef, 'cooling write queued for response validation');
        MATTER_ParseMessage($io, encode_json({message_id => $requests[-1]{message_id}, %$reply}));
        like(ReadingsVal($ep{2}{NAME}, 'lastError', ''), qr/^failed:/, 'missing/malformed/mismatched status never clears lastError');
    }
    is(MATTERDevice_Set($ep{2}, $ep{2}{NAME}, 'desired-temp-cool', '27'), undef, 'write can be retried explicitly after invalid reply');
    MATTER_ParseMessage($io, encode_json({message_id => $requests[-1]{message_id}, result => undef}));
    is(ReadingsVal($ep{2}{NAME}, 'lastError', ''), 'none', 'existing null API acknowledgement remains accepted');
    is(ReadingsVal($ep{2}{NAME}, 'desired-temp-cool', ''), 26.5, 'null acknowledgement also leaves device telemetry untouched');

    for my $sequence (0 .. 5) {
        $report->(5, 514, 1, $sequence);
        my @expected = ('off,low,medium,high', 'off,low,high',
                        'off,low,medium,high,auto', 'off,low,high,auto', 'off,high,auto', 'off,high');
        like($list->($ep{5}), qr/\bfan_mode:\Q$expected[$sequence]\E(?: |$)/, 'FanModeSequence enum controls the displayed list');
    }
    $report->(5, 514, 1, 4);
    $report->(5, 514, 65532, 0);
    like($list->($ep{5}), qr/fan_mode:off,high(?: |$)/, 'missing Auto feature removes auto even from an auto-capable sequence');
    $report->(5, 514, 65532, 2);
    for my $sequence (0 .. 5) {
        $report->(3, 513, 27, $sequence);
        my @expected = ('off,cool', 'off,cool', 'off,heat,emergency_heat',
                        'off,heat,emergency_heat', 'off,heat,cool,auto,emergency_heat',
                        'off,heat,cool,auto,emergency_heat');
        like($list->($ep{3}), qr/\bmode:\Q$expected[$sequence]\E(?: |$)/, 'thermostat control sequence constrains the public mode list');
    }
    $report->(3, 513, 27, 4);
    $report->(3, 513, 65532, 3);
    unlike($list->($ep{3}), qr/mode:[^ ]*\bauto\b/, 'missing AutoMode feature removes auto from a combined thermostat');
    $report->(3, 513, 65532, 35);

    is(MATTERDevice_Set($ep{2}, $ep{2}{NAME}, 'desired-temp-cool', '27'), undef, 'write queued before its timeout');
    my $timed_out = $requests[-1]{message_id};
    my $saved_clock = $mock_time;
    $mock_time += 121;
    MATTER_Heartbeat($io);
    $mock_time = $saved_clock;
    like(ReadingsVal($ep{2}{NAME}, 'lastError', ''), qr/timeout.*unknown/, 'timeout keeps the write outcome unknown');
    ok(!exists($io->{helper}{pending_command}{$timed_out}), 'timed-out write is removed from pending state');
    MATTER_ParseMessage($io, encode_json({message_id => $timed_out, result => $status->('2/513/17', 0)}));
    like(ReadingsVal($ep{2}{NAME}, 'lastError', ''), qr/timeout.*unknown/, 'late timed-out reply cannot clear the failure');

    my $fan_modes = $list->($ep{4});
    $report->(4, 514, 1, $_) for (undef, 99, {});
    is($list->($ep{4}), $fan_modes, 'invalid sequence reports preserve earlier constraints');
    $report->(4, 514, 3, 60);
    is($list->($ep{4}), $fan_modes, 'partial current-speed report does not remove mode metadata');
    is(MATTERDevice_Set($ep{4}, $ep{4}{NAME}, 'getConfig'), undef, 'explicit getConfig can refresh mode metadata');
    MATTER_ParseMessage($io, encode_json({message_id => $requests[-1]{message_id}, result => {
        '4/514/65531' => [0, 1, 2, 3], '4/514/65532' => 0, '4/514/1' => 5}}));
    like($list->($ep{4}), qr/fan_mode:off,high(?: |$)/, 'full getConfig reconciles a changed mode sequence');
    is(MATTERDevice_Set($ep{4}, $ep{4}{NAME}, 'getConfig'), undef, 'configuration read queued before a newer sequence');
    my $sequence_read = $requests[-1]{message_id};
    $report->(4, 514, 1, 1);
    $report->(4, 514, 1, 99);
    MATTER_ParseMessage($io, encode_json({message_id => $sequence_read, result => {
        '4/514/65531' => [0, 1, 2, 3], '4/514/65532' => 0, '4/514/1' => 5}}));
    like($list->($ep{4}), qr/fan_mode:off,low,high(?: |$)/,
         'newer valid sequence wins over an old read despite a later malformed report');
    $report->(4, 514, 65531, [0, 2, 3]);
    unlike($list->($ep{4}), qr/fan_mode:/, 'sequence removed from AttributeList cannot authorize modes from old cached metadata');
    like($list->($ep{4}), qr/fan_pct:/, 'independent writable percentage remains available');

    MATTER_ProcessNode($io, {node_id => 6501, name => 'HvacMissingFeatures', available => JSON::true,
        attributes => {'1/513/65531' => [18], '1/513/18' => 2100}});
    my $missing = $modules{MATTERDevice}{defptr}{'ioHvac:6501'};
    ok(MATTERDevice_NeedsCapabilityRefresh($missing), 'existing bounded recovery notices missing HVAC FeatureMap');
    MATTER_ProcessNode($io, {node_id => 6501, attributes => {'1/513/65532' => 1}});
    ok(!MATTERDevice_NeedsCapabilityRefresh($missing), 'complete global metadata needs no additional read');

    is(MATTERDevice_Set($ep{2}, $ep{2}{NAME}, 'desired-temp-cool', '27'), undef, 'write queued before IO loss');
    my $old = $requests[-1]{message_id};
    MATTER_Close($io);
    like(ReadingsVal($ep{2}{NAME}, 'lastError', ''), qr/interrupted/, 'disconnect reports an unknown write outcome');
    MATTER_ParseMessage($io, encode_json({message_id => $old, result => $status->('2/513/17', 0)}));
    like(ReadingsVal($ep{2}{NAME}, 'lastError', ''), qr/interrupted/, 'old disconnected response cannot manufacture success');
    like(MATTERDevice_Set($ep{2}, $ep{2}{NAME}, 'desired-temp-cool', '27') // '', qr/No active WebSocket/, 'disconnected write is rejected');
    MATTER_Close($other);
};

subtest 'Issue 34: native dim variants, latest command replies and lifecycle' => sub {
    my @requests;
    my %peers;
    my $connect = sub {
        my ($io) = @_;
        socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'dim socketpair';
        $peers{$io->{NAME}} = $peer;
        $io->{CD} = $socket; $io->{FD} = fileno($socket);
        $io->{websocket} = 1; $io->{ws_status} = 'connected';
        $io->{test_send_text} = sub {push @requests, JSON::decode_json($_[0]); return 1;};
    };
    my $io = $defs{ioDim} = {NAME => 'ioDim', TYPE => 'MATTER', READINGS => {}, helper => {}};
    my $other = $defs{ioDimOther} = {NAME => 'ioDimOther', TYPE => 'MATTER', READINGS => {}, helper => {}};
    $connect->($_) for ($io, $other);
    my $values = {};
    my @commands = ([1, 2, 3], [5, 6, 7], [1, 2, 3, 5, 6, 7], [0, 4], [1], [7]);
    for my $ep (1..6) {
        $values->{"$ep/8/65529"} = $commands[$ep - 1];
        $values->{"$ep/8/65531"} = [0];
        $values->{"$ep/8/65532"} = 0;
        $values->{"$ep/8/0"} = 100;
        $values->{"$ep/6/0"} = JSON::true;
    }
    for my $target ($io, $other) {
        MATTER_ProcessNode($target, {node_id => 6600, name => 'DimMatrix', available => JSON::true, attributes => $values});
    }
    my $root = $modules{MATTERDevice}{defptr}{'ioDim:6600'};
    my $other_root = $modules{MATTERDevice}{defptr}{'ioDimOther:6600'};
    my %ep = map {$_->{endpoint_id} => $_} MATTERDevice_NodeChildren($root);
    my %other_ep = map {$_->{endpoint_id} => $_} MATTERDevice_NodeChildren($other_root);
    my $list = sub {return join(' ', MATTERDevice_GetSetList($_[0]));};
    my $send = sub {
        my ($endpoint, $cmd) = @_;
        my @result = MATTERDevice_Set($ep{$endpoint}, $ep{$endpoint}{NAME}, $cmd);
        is_deeply(\@result, [undef, 1], "$cmd accepted without a synthetic FHEM command event");
        return $requests[-1]{message_id};
    };
    my $reply = sub {
        my ($id, %response) = @_;
        MATTER_ParseMessage($io, encode_json({message_id => $id, %response}));
    };
    my $pending = sub {return scalar keys %{$io->{helper}{pending_command} // {}};};
    unlike($list->($root), qr/dim_/, 'root does not borrow endpoint dim commands');
    unlike($list->($ep{4}), qr/dim_/, 'MoveToLevel alone does not authorize Move, Step or Stop');
    like($list->($ep{5}), qr/dim_up:noArg/, 'Move-only endpoint offers continuous dimming');
    unlike($list->($ep{5}), qr/dim_stop:|dim_step_/, 'Move does not imply Stop or Step support');
    like($list->($ep{6}), qr/dim_stop:noArg/, 'advertised StopWithOnOff is usable without a prior local Move');
    unlike($list->($ep{6}), qr/dim_up:|dim_down:|dim_step_/, 'Stop does not imply movement commands');
    for my $case ([1, 'Move', 'Step', 'Stop'], [2, 'MoveWithOnOff', 'StepWithOnOff', 'StopWithOnOff'], [3, 'Move', 'Step', 'Stop']) {
        my ($endpoint, $move, $step, $stop) = @$case;
        my $timers = scalar @timers;
        for my $item (['dim_up', $move, {moveMode => 0, rate => 30}],
                      ['dim_down', $move, {moveMode => 1, rate => 30}],
                      ['dim_step_up', $step, {stepMode => 0, stepSize => 20, transitionTime => 0}],
                      ['dim_step_down', $step, {stepMode => 1, stepSize => 20, transitionTime => 0}],
                      ['dim_stop', $stop, {}]) {
            my ($cmd, $command, $fields) = @$item;
            my $id = $send->($endpoint, $cmd);
            is_deeply($requests[-1]{args}, {node_id => 6600, endpoint_id => $endpoint,
                cluster_id => 8, command_name => $command,
                payload => {optionsMask => 0, optionsOverride => 0, %$fields}},
                "$cmd endpoint $endpoint selects the advertised command and exact Matter payload");
            $reply->($id, result => undef);
            is(ReadingsVal($ep{$endpoint}{NAME}, 'lastError', ''), 'none', 'null response is a command acknowledgement');
        }
        is(scalar(@timers), $timers, 'native movement adds no FHEM dim timer');
        is(ReadingsVal($ep{$endpoint}{NAME}, 'brightness', ''), 100, 'command acknowledgements do not change reported brightness');
        is(ReadingsVal($ep{$endpoint}{NAME}, 'state', ''), 'on', 'command acknowledgements do not change physical on/off state');
    }
    for my $cmd (qw(dim_up dim_down dim_step_up dim_step_down dim_stop)) {
        my $before = scalar @requests;
        like(MATTERDevice_Set($ep{1}, $ep{1}{NAME}, $cmd, '50') // '', qr/Usage:.*no arguments/, "$cmd rejects an unexpected value");
        is(scalar(@requests), $before, 'invalid argument sends nothing');
    }
    for my $rate ('0', '-1', '255', '1.5', 'x', '', "30\n") {
        $attr{$ep{1}{NAME}}{dimRate} = $rate;
        my $before = scalar @requests;
        like(MATTERDevice_Set($ep{1}, $ep{1}{NAME}, 'dim_up') // '', qr/dimRate must be/, 'invalid configured rate is rejected');
        is(scalar(@requests), $before, 'invalid rate sends nothing');
    }
    for my $rate (1, 254) {
        $attr{$ep{1}{NAME}}{dimRate} = $rate;
        my $id = $send->(1, 'dim_up');
        is($requests[-1]{args}{payload}{rate}, $rate, 'inclusive dimRate boundary is encoded unchanged');
        $reply->($id, result => undef);
    }
    # Stop and Step use no rate, so a bad configured Move rate cannot prevent a Stop.
    $attr{$ep{1}{NAME}}{dimRate} = 'invalid';
    my $stop = $send->(1, 'dim_stop');
    $reply->($stop, result => undef);
    delete $attr{$ep{1}{NAME}}{dimRate};

    my $move = $send->(1, 'dim_up');
    $stop = $send->(1, 'dim_stop');
    is($requests[-1]{args}{command_name}, 'Stop', 'Stop sends immediately while Move has no reply');
    ok(exists($io->{helper}{pending_command}{$move}), 'older command keeps its own request correlation until its reply');
    ok(exists($io->{helper}{pending_command}{$stop}), 'latest dim command remains tracked');
    $reply->($stop, error_code => 8, details => 'synthetic device refusal');
    like(ReadingsVal($ep{1}{NAME}, 'lastError', ''), qr/failed: synthetic device refusal/, 'server refusal is reported on the endpoint');
    $reply->($move, result => undef);
    like(ReadingsVal($ep{1}{NAME}, 'lastError', ''), qr/failed:/, 'late Move acknowledgement cannot clear newer Stop failure');
    unlike(ReadingsVal($ep{1}{NAME}, 'firmware_update', ''), qr/failed:/, 'dim errors do not appear as firmware status');

    my $missing = $send->(1, 'dim_stop');
    $reply->($missing);
    like(ReadingsVal($ep{1}{NAME}, 'lastError', ''), qr/failed: invalid device command response/, 'reply without a result or error is malformed');
    for my $result ({}, [], 0, JSON::true) {
        my $id = $send->(1, 'dim_stop');
        $reply->($id, result => $result);
        is(ReadingsVal($ep{1}{NAME}, 'lastError', ''), 'none', 'a successful reply accepts any result value');
    }
    my $first = $send->(1, 'dim_up');
    my $second = $send->(2, 'dim_down');
    is($pending->(), 2, 'separate endpoints have independent latest commands');
    $reply->($first, result => undef);
    ok(exists($io->{helper}{pending_command}{$second}), 'one endpoint reply leaves the other pending');
    $reply->($second, result => undef);
    my @concurrent = map {$send->(1, 'dim_up')} 1..20;
    is($pending->(), 20, 'each parallel command retains its own ID');
    $reply->($_, result => undef) for reverse @concurrent;
    is($pending->(), 0, 'all parallel replies are independently retired');

    my $id = $send->(1, 'dim_up');
    my $send_ok = $io->{test_send_text};
    $io->{test_send_text} = sub {return 0;};
    like(MATTERDevice_Set($ep{1}, $ep{1}{NAME}, 'dim_stop') // '', qr/Unable to send/, 'failed enqueue returns a synchronous error');
    ok(exists($io->{helper}{pending_command}{$id}), 'failed Stop enqueue preserves pending Move tracking');
    is($pending->(), 1, 'failed enqueue leaves no phantom Stop request');
    $io->{test_send_text} = $send_ok;
    $reply->($id, result => undef);

    $id = $send->(1, 'dim_stop');
    MATTER_ParseMessage($other, encode_json({message_id => $id, result => undef}));
    ok(exists($io->{helper}{pending_command}{$id}), 'same request ID on another IO cannot consume this command');
    is(ReadingsVal($other_ep{1}{NAME}, 'lastError', 'absent'), 'absent', 'another IO with the same node and endpoint receives no dim status');
    # Exercise response decoding through the real socket/frame parser as well.
    my $json = encode_json({message_id => $id, result => undef});
    my $wire = pack('CC', 0x81, length($json)) . $json;
    is(syswrite($peers{$io->{NAME}}, $wire), length($wire), 'inject a complete WebSocket response');
    MATTER_Read($io);
    is($pending->(), 0, 'framed response is correlated and retired');
    is(ReadingsVal($ep{1}{NAME}, 'lastError', ''), 'none', 'framed acknowledgement clears the latest command error');

    for my $field (qw(FUUID node_id endpoint_id)) {
        $id = $send->(1, 'dim_stop');
        my $original = $ep{1}{$field};
        $ep{1}{$field} = $field eq 'FUUID' ? 'replacement-uuid' : $original + 1;
        readingsSingleUpdate($ep{1}, 'lastError', 'ownership sentinel', 1);
        $reply->($id, result => undef);
        is(ReadingsVal($ep{1}{NAME}, 'lastError', ''), 'ownership sentinel', "reply cannot update changed $field ownership");
        $ep{1}{$field} = $original;
    }

    MATTER_ProcessNode($io, {node_id => 6600, attributes => {
        '1/514/65531' => [2], '1/514/2' => 40}});
    $id = $send->(1, 'dim_up');
    is(MATTERDevice_Set($ep{1}, $ep{1}{NAME}, 'fan_pct', 50), undef,
       'tracking a dim reply does not introduce a lock for an unrelated setter');
    my $write_id = $requests[-1]{message_id};
    ok(exists($io->{helper}{pending_command}{$id}), 'unrelated write does not cancel the dim request');
    $reply->($write_id, result => undef);
    $stop = $send->(1, 'dim_stop');
    $reply->($stop, result => undef);

    # Metadata removal immediately changes the menu and direct SetFn permission.
    MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [6600, '1/8/65529', [3]]}));
    unlike($list->($ep{1}), qr/dim_up:|dim_down:|dim_step_/, 'capability replacement removes unsupported movement commands');
    my $before = scalar @requests;
    like(MATTERDevice_Set($ep{1}, $ep{1}{NAME}, 'dim_up') // '', qr/Unknown argument/, 'explicit unsupported Move is rejected');
    is(scalar(@requests), $before, 'unsupported explicit command sends nothing');
    $id = $send->(1, 'dim_stop');
    $io->{helper}{pending_command}{$id}{started_at} = gettimeofday() - 121;
    delete $io->{helper}{pending_pong};
    MATTER_Heartbeat($io);
    like(ReadingsVal($ep{1}{NAME}, 'lastError', ''), qr/timeout \(outcome unknown\)/, 'existing heartbeat reports command timeout without claiming motion stopped');
    $reply->($id, result => undef);
    like(ReadingsVal($ep{1}{NAME}, 'lastError', ''), qr/timeout/, 'timed-out command cannot later clear its error');
    is(ReadingsVal($ep{1}{NAME}, 'brightness', ''), 100, 'timeout retains the last reported physical brightness');
    MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [6600, '1/8/0', 120]}));
    is(ReadingsVal($ep{1}{NAME}, 'brightness', ''), 120, 'actual level report is still accepted after timeout');
    is(MATTERDevice_Set($other_ep{1}, $other_ep{1}{NAME}, 'dim_up'), undef, 'same-node command can run independently on another IO');
    my $other_id = $requests[-1]{message_id};
    $id = $send->(1, 'dim_stop');
    MATTER_Close($io);
    like(ReadingsVal($ep{1}{NAME}, 'lastError', ''), qr/interrupted \(outcome unknown\)/, 'disconnect reports the unknown outcome on the endpoint');
    ok(exists($other->{helper}{pending_command}{$other_id}), 'closing one IO preserves the other IO command');
    MATTER_ParseMessage($other, encode_json({message_id => $other_id, result => undef}));
    is(ReadingsVal($other_ep{1}{NAME}, 'lastError', ''), 'none', 'other IO response still reaches its own endpoint');
    $connect->($io);
    $reply->($id, result => undef);
    like(ReadingsVal($ep{1}{NAME}, 'lastError', ''), qr/interrupted/, 'old reply after reconnect cannot confirm the interrupted command');
    $id = $send->(1, 'dim_stop');
    $reply->($id, result => undef);
    is(ReadingsVal($ep{1}{NAME}, 'lastError', ''), 'none', 'new command works after reconnect');
    MATTER_Close($io);
    like(MATTERDevice_Set($ep{1}, $ep{1}{NAME}, 'dim_stop') // '', qr/No active WebSocket/, 'disconnected Stop is rejected instead of pretending to stop');
    MATTER_Close($other);
};

subtest 'Issue 78: disable pauses one endpoint and reuses existing synchronization' => sub {
    my (@sent, @peers);
    my $connect = sub {
        my ($name) = @_;
        socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'disable socketpair';
        push @peers, $peer;
        my $io = $defs{$name} = {NAME => $name, TYPE => 'MATTER', READINGS => {},
            CD => $socket, websocket => 1, ws_status => 'connected', helper => {}};
        $io->{test_send_text} = sub {push @sent, JSON::decode_json($_[0]); 1};
        return $io;
    };
    my $io = $connect->('disableEndpointIO');
    my $other = $connect->('disableEndpointOtherIO');
    my $values = {'0/40/3' => 'Initial model',
        '1/6/0' => JSON::false, '1/6/65529' => [0,1,2], '1/6/65532' => 0,
        '2/6/0' => JSON::false, '2/6/65529' => [0,1,2], '2/6/65532' => 0};
    for my $fixture ([$io, 7800, 'DisableA'], [$io, 7801, 'DisableB'], [$other, 7800, 'DisableOther']) {
        MATTER_ProcessNode($fixture->[0], {node_id => $fixture->[1], name => $fixture->[2],
            available => JSON::true, attributes => $values});
    }
    my $root = MATTERDevice_LookupRoot($io, 7800);
    my ($ep, $sibling) = MATTERDevice_NodeChildren($root);
    my $name = $ep->{NAME};
    my $uuid = $ep->{FUUID};
    my $reply = sub {
        my ($id, %body) = @_;
        MATTER_ParseMessage($io, encode_json({message_id => $id, %body}));
    };
    my $set = sub {
        my ($device, $cmd, @args) = @_;
        my @result = MATTERDevice_Set($device, $device->{NAME}, $cmd, @args);
        is($result[0], undef, "$cmd accepted on active endpoint");
        return $sent[-1]{message_id};
    };
    my $on = $set->($ep, 'on');
    my $old_read = $set->($ep, 'getConfig');
    my $sibling_read = $set->($sibling, 'getConfig');
    my $sibling_command = $set->($sibling, 'on');
    my ($metadata_id, $error) = MATTERDevice_RequestCapabilityRefresh($root);
    is($error, undef, 'start node-wide metadata read before disabling');
    my @snapshot_ids;
    for my $command (qw(get_nodes start_listening)) {
        my $id = MATTER_NextMessageId($io);
        $io->{helper}{pending_command}{$id} = $command;
        push @snapshot_ids, $id;
    }
    my $epoch = $root->{helper}{availability_epoch};
    my @timers_before = @timers;
    is(CommandAttr(undef, "$name disable 1"), undef, 'disable attribute accepted');
    like(CommandAttr(undef, "$name disable bad") // '', qr/must be 0 or 1/, 'invalid disable rejected');
    like(CommandAttr(undef, "$root->{NAME} disable 1") // '', qr/only supported on endpoints/, 'root disable rejected');
    is(CommandAttr(undef, "$name disable 1"), undef, 'repeated disable is harmless');
    is($root->{helper}{availability_epoch}, $epoch, 'endpoint disable does not invalidate the node');
    ok(!exists($io->{helper}{pending_command}{$on}), 'old endpoint command retired');
    ok(!exists($io->{helper}{pending_config}{$old_read}), 'old endpoint read retired');
    ok(exists($io->{helper}{pending_config}{$sibling_read}), 'sibling read remains pending');
    ok(exists($io->{helper}{pending_command}{$sibling_command}), 'sibling command remains pending');
    ok($io->{helper}{pending_config}{$metadata_id}{excluded_endpoints}{1}, 'shared read excludes disabled endpoint');
    is_deeply([MATTERDevice_GetSetList($ep)], [], 'disabled endpoint offers no setter, including getConfig');
    my $before = scalar @sent;
    for my $cmd (qw(on off toggle getConfig)) {
        like(MATTERDevice_Set($ep, $name, $cmd) // '', qr/disable=1/, "$cmd returns disable error");
    }
    like(MATTERDevice_SendRequests($ep, [MATTERDevice_CommandRequest($ep, 6, 'On')], 'lastError', 120) // '',
         qr/disable=1/, 'internal command caller cannot bypass disable');
    like(MATTERDevice_SendRequests($ep, [{command => 'write_attribute', args => {
        node_id => 7800, attribute_path => '1/6/0', value => 1}}], 'lastError', 120) // '',
         qr/disable=1/, 'internal attribute writer cannot bypass disable');
    is(scalar @sent, $before, 'disabled calls send nothing');
    my $saved = JSON::decode_json(encode_json($ep->{READINGS}));
    my $capabilities = JSON::decode_json(encode_json($ep->{helper}{capabilities}));
    my $received = $ep->{MSGCNT};
    my $events = scalar @direct_events;
    MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [7800, '1/6/0', JSON::true]}));
    MATTER_ParseMessage($io, encode_json({event => 'node_event', data => {
        node_id => 7800, endpoint_id => 1, cluster_id => 59, event_id => 1}}));
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {
        node_id => 7800, available => JSON::false, attributes => {'1/6/0' => JSON::true}}}));
    MATTER_ProcessNode($io, {node_id => 7800, available => JSON::true, attributes => {
        '0/40/3' => 'New root model', '1/6/0' => JSON::true, '1/6/65529' => [],
        '2/6/0' => JSON::true}});
    MATTERDevice_ProcessMessage($root, {result => {'1/6/65529' => [], '1/6/0' => JSON::true}});
    MATTERDevice_ApplyCapabilityMetadata($root, {'1/6/65529' => []});
    $reply->($on, error_code => 8, details => 'old failure');
    $reply->($old_read, result => {'1/6/0' => JSON::true});
    MATTER_SetNodeStatus($io, 7800, 'removed');
    is_deeply($ep->{READINGS}, $saved, 'reports, snapshots, mirrors, reads, events and removal preserve disabled readings/timestamps');
    is_deeply($ep->{helper}{capabilities}, $capabilities, 'disabled capability cache stays unchanged');
    is(scalar @direct_events, $events, 'disabled button event is suppressed');
    $reply->($sibling_command, result => undef);
    is(ReadingsVal($sibling->{NAME}, 'lastError', ''), 'none', 'sibling command completes normally');
    ok($ep->{MSGCNT} > $received, 'receive internals continue to record server traffic');
    is(ReadingsVal($sibling->{NAME}, 'state', ''), 'on', 'sibling reports still update');
    is(ReadingsVal($root->{NAME}, 'state', ''), 'removed', 'root status still updates');
    ok($defs{$name} eq $ep && $ep->{FUUID} eq $uuid, 'discovery retains original endpoint identity');

    # A restored disabled child with no metadata must not trigger recovery.
    $ep->{helper}{capabilities} = {}; $ep->{helper}{seen_clusters} = {};
    ok(!MATTERDevice_NeedsCapabilityRefresh($root), 'disabled child does not require missing-command recovery');
    $root->{helper}{capability_refresh} = {attempts => 0};
    MATTER_ProcessNode($io, {node_id => 7800, available => JSON::true});
    is(scalar @sent, $before, 'known online recovery adds no query solely for disabled metadata');
    $ep->{helper}{capabilities} = $capabilities;

    # A shared read started during disable must also be excluded on enable.
    ($metadata_id, $error) = MATTERDevice_RequestCapabilityRefresh($root);
    is($error, undef, 'shared metadata query can serve siblings while this endpoint is disabled');
    my $during_disable = MATTER_NextMessageId($io);
    $io->{helper}{pending_command}{$during_disable} = 'get_nodes';
    push @snapshot_ids, $during_disable;
    $before = scalar @sent;

    # Online activation reads once, after the AttrFn commit, even under readOnly.
    is(CommandAttr(undef, "$name readOnly 1"), undef, 'combine disable with independent readOnly');
    is(CommandAttr(undef, "$name disable 0"), undef, 'enable endpoint online');
    is(scalar @sent, $before + 1, 'enable sends exactly one endpoint configuration read');
    my $fresh_read = $sent[-1];
    is($fresh_read->{command}, 'read_attribute', 'enable uses the existing read path');
    ok(!grep({!/^1\//} @{$fresh_read->{args}{attribute_path}}), 'enable read is endpoint-specific');
    ok(!exists($ep->{helper}{enable_sync}), 'one-shot enable marker consumed before sending');
    is(CommandAttr(undef, "$name disable 0"), undef, 'repeated enable accepted');
    is(scalar @sent, $before + 1, 'repeated enable adds no read');
    like(MATTERDevice_Set($ep, $name, 'off') // '', qr/readOnly=1/, 'enable preserves readOnly control protection');
    $reply->($fresh_read->{message_id}, result => {'1/6/0' => JSON::false, '1/6/65529' => [0,1,2]});
    my $enabled = JSON::decode_json(encode_json($ep->{READINGS}));
    $reply->($on, error_code => 8, details => 'late command error after re-enable');
    $reply->($old_read, result => {'1/6/0' => JSON::true});
    is_deeply($ep->{READINGS}, $enabled, 'retired command/read cannot update a re-enabled endpoint');

    # Node-wide reads/snapshots retain their other endpoints after re-enable.
    # Keep metadata recovery useful for the sibling, otherwise it is correctly skipped.
    delete $sibling->{helper}{capabilities}{6}{accepted_commands};
    $reply->($metadata_id, result => {'1/6/65529' => [], '2/6/65529' => [0,1]});
    ok(MATTERDevice_CommandAccepted($ep, 6, 1), 'old shared read cannot revoke re-enabled commands');
    ok(MATTERDevice_CommandAccepted($sibling, 6, 1), 'old shared read still updates sibling commands');
    for my $id (@snapshot_ids) {
        $reply->($id, result => [{node_id => 7800, available => JSON::true,
            attributes => {'1/6/0' => JSON::true, '1/6/65529' => [], '2/6/0' => JSON::false}},
            {node_id => 7801, available => JSON::true, attributes => $values}]);
        is(ReadingsVal($name, 'state', ''), 'off', 'old discovery response excludes re-enabled endpoint');
        ok(MATTERDevice_CommandAccepted($ep, 6, 1), 'old discovery preserves re-enabled capabilities');
        is(ReadingsVal($sibling->{NAME}, 'state', ''), 'off', 'old discovery keeps unrelated sibling values');
    }
    for my $target ($defs{MATTER_DisableB_EP1}, $defs{MATTER_DisableOther_EP1}) {
        my $id = $set->($target, 'on');
        MATTER_ParseMessage($target->{IODev}, encode_json({message_id => $id, result => undef}));
    }
    ok(!$other->{helper}{pending_snapshot_touched}, 'another IO acquires no exclusions');

    # Offline activation is passive; the next ordinary online snapshot restores data.
    is(CommandAttr(undef, "$name disable 1"), undef, 'disable again');
    MATTER_ParseMessage($io, encode_json({event => 'node_updated', data => {node_id => 7800, available => JSON::false}}));
    $before = scalar @sent;
    is(CommandDeleteAttr(undef, "$name disable"), undef, 'delete disable while offline');
    is(scalar @sent, $before, 'offline enabling sends no query');
    MATTER_ProcessNode($io, {node_id => 7800, available => JSON::true, attributes => $values});
    is(ReadingsVal($name, 'state', ''), 'off', 'ordinary online snapshot resumes synchronization');
    is(CommandDeleteAttr(undef, "$name disable"), undef, 'deleting absent disable is harmless');
    is(scalar @sent, $before, 'no replay or repeat probe after offline recovery');
    CommandDeleteAttr(undef, "$name readOnly");

    # Existing exclusion bookkeeping must not hide server-side node removal.
    my $discovery = MATTER_NextMessageId($io);
    $io->{helper}{pending_command}{$discovery} = 'get_nodes';
    CommandAttr(undef, "$name disable 1");
    $reply->($discovery, result => [{node_id => 7801, available => JSON::true, attributes => $values}]);
    is(ReadingsVal($root->{NAME}, 'state', ''), 'removed', 'local disable marker does not suppress missing-node detection');
    is(ReadingsVal($name, 'state', ''), 'off', 'disabled physical state is not replaced by removed/disabled');
    is_deeply(\@timers, \@timers_before, 'endpoint disable/enable adds no timers');

    # Startup/rereadcfg keeps persisted disable authoritative; rename stays structural.
    is(CommandRename(undef, "$name DisabledRenamed"), undef, 'disabled endpoint can be renamed');
    $name = $ep->{NAME};
    for my $event (qw(INITIALIZED REREADCFG)) {
        # Config loading calls AttrFn without publishing global ATTR yet.
        # The endpoint may receive INITIALIZED before the root invalidates availability.
        $before = scalar @sent;
        {
            local $init_done = 0;
            CommandAttr(undef, "$name disable 0");
        }
        MATTERDevice_Notify($ep, {NAME => 'global', CHANGED => [$event]});
        is(scalar @sent, $before, "$event never probes using pre-restoration availability");
        ok(!exists($ep->{helper}{enable_sync}), "$event consumes deferred enable marker");
        CommandAttr(undef, "$name disable 1");
        $ep->{helper} = {};
        MATTERDevice_Notify($root, {NAME => 'global', CHANGED => [$event]});
        MATTERDevice_Notify($ep, {NAME => 'global', CHANGED => [$event]});
        MATTER_ProcessNode($io, {node_id => 7800, available => JSON::true, attributes => $values});
        like(MATTERDevice_Set($ep, $name, 'getConfig') // '', qr/disable=1/, "$event retains restored disable");
        is($ep->{FUUID}, $uuid, "$event preserves identity");
    }
    $before = scalar @sent;
    CommandDeleteAttr(undef, "$name disable");
    is(scalar @sent, $before + 1, 'deleting disable online synchronizes renamed endpoint once');
    $reply->($sent[-1]{message_id}, result => {'1/6/65529' => [0,1], '1/6/0' => JSON::true});
    is(ReadingsVal($name, 'state', ''), 'on', 'renamed endpoint accepts fresh enable response');
    my $off = $set->($ep, 'off');
    $reply->($off, result => undef);
    for my $command ("$name ^disable\$", $name) {
        CommandAttr(undef, "$name disable 1");
        $before = scalar @sent;
        is(CommandDeleteAttr(undef, $command), undef, 'native deleteattr pattern/all-attributes form is accepted');
        is(scalar @sent, $before + 1, 'native attribute removal also synchronizes once');
        $reply->($sent[-1]{message_id}, result => {'1/6/65529' => [0,1], '1/6/0' => JSON::true});
    }
    my $last_error = ReadingsVal($name, 'lastError', '');
    $io->{test_send_text} = sub {
        push @sent, JSON::decode_json($_[0]);
        CommandAttr(undef, "$name disable 1");
        return 1;
    };
    $before = scalar @sent;
    like(MATTERDevice_SendRequests($ep, [MATTERDevice_CommandRequest($ep, 6, 'On'),
        MATTERDevice_CommandRequest($ep, 6, 'Off')], 'lastError', 120) // '',
        qr/disable=1/, 'synchronous disable blocks remaining compound request');
    is(scalar @sent, $before + 1, 'only first compound component was sent');
    ok(!exists($ep->{helper}{latest_request}), 'disable releases compound result group');
    ok(!grep({ref($_) eq 'HASH' && ($_->{owner} // '') eq $ep}
        values %{$io->{helper}{pending_command}}), 'compound cancellation leaves no owned request');
    is(ReadingsVal($name, 'lastError', ''), $last_error, 'canceled compound does not update disabled diagnostics');
    $before = scalar @sent;
    MATTER_Close($io);
    is(CommandDeleteAttr(undef, "$name disable"), undef, 'enable with disconnected IO');
    is(scalar @sent, $before, 'disconnected activation sends no read or command');
    close $_ for @peers;
};

subtest 'Issue 77: readOnly blocks control while reads and reports stay active' => sub {
    my @sent;
    my @peers;
    my @ios;
    my $values = {
        '1/6/65529' => [0,1,2,64,65,66], '1/6/65532' => 1, '1/6/0' => JSON::false,
        '1/8/65529' => [0,1,2,3,4,5,6,7,8], '1/8/65532' => 7, '1/8/0' => 100,
        '1/768/65529' => [6,7,10], '1/768/65532' => 25,
        '2/258/65529' => [0,1,2,5,8], '2/258/65532' => 23,
        '3/257/65529' => [0,1],
        '4/513/65531' => [17,18,27,28], '4/513/65532' => 3, '4/513/27' => 4,
        '4/513/17' => 2600, '4/513/18' => 2100, '4/513/28' => 4,
        '5/514/65531' => [0,1,2,3], '5/514/65532' => 2, '5/514/1' => 2,
        '5/514/0' => 3, '5/514/2' => 50, '5/514/3' => 40,
        '6/3/65529' => [0],
    };
    for my $name (qw(readOnlyIO readOnlyOtherIO)) {
        socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'readOnly socketpair';
        push @peers, $peer;
        my $io = $defs{$name} = {NAME => $name, TYPE => 'MATTER', READINGS => {},
            CD => $socket, websocket => 1, ws_status => 'connected', helper => {}};
        $io->{test_send_text} = sub {push @sent, JSON::decode_json($_[0]); 1};
        push @ios, $io;
        MATTER_ProcessNode($io, {node_id => 7700, name => $name, available => JSON::true,
            attributes => $values});
    }
    my ($io, $other) = @ios;
    my $root = MATTERDevice_LookupRoot($io, 7700);
    my %ep = map {$_->{endpoint_id} => $_} MATTERDevice_NodeChildren($root);
    my $device = $ep{1};
    my $name = $device->{NAME};
    my @normal = MATTERDevice_GetSetList($device);
    my $reply = sub {
        my ($id, %body) = @_;
        MATTER_ParseMessage($io, encode_json({message_id => $id, %body}));
    };
    my $send = sub {
        my ($target, $cmd, @args) = @_;
        my @result = MATTERDevice_Set($target, $target->{NAME}, $cmd, @args);
        is_deeply(\@result, [undef, 1], "$cmd accepted with asynchronous return");
        return $sent[-1]{message_id};
    };
    my $inflight = $send->($device, 'on');
    is(CommandAttr(undef, "$name readOnly 1"), undef, 'declared readOnly attribute is accepted');
    is(CommandAttr(undef, "$name readOnly 1"), undef, 'repeated locking is harmless');
    like(CommandAttr(undef, "$name readOnly invalid") // '', qr/must be 0 or 1/,
         'invalid value is rejected without unlocking');
    like(CommandAttr(undef, "$root->{NAME} readOnly 1") // '', qr/only supported on endpoints/,
         'root cannot advertise a node-wide protection it does not implement');
    ok(!exists($attr{$root->{NAME}}{readOnly}), 'root rejection leaves its attributes unchanged');
    my $before_toggle = scalar @sent;
    for my $target (values %ep) {
        is(CommandAttr(undef, "$target->{NAME} readOnly 1"), undef, 'lock each functional endpoint');
        is_deeply([MATTERDevice_GetSetList($target)], ['getConfig:noArg'],
                  'dynamic set list retains only the permitted read');
    }
    is(scalar @sent, $before_toggle, 'attribute changes send no commands or reads');
    like(MATTERDevice_Set($device, $name, '?'), qr/choose one of getConfig:noArg\z/,
         'FHEMWEB query offers only getConfig');

    # Exercise every existing setter family through SetFn in FHEM list context.
    # fhem.pl DoSet returns a nonempty error before its synthetic DoTrigger.
    for my $case (
        [1,'on'], [1,'off'], [1,'toggle'], [1,'off_with_effect','DelayedAllOff,NoFade'],
        [1,'on_with_recall_global_scene'], [1,'on_with_timed_off','0,10,0'],
        [1,'brightness',120], [1,'pct',0], [1,'rgb','800000'], [1,'ct',300], [1,'frequency',100],
        [1,'dim_up'], [1,'dim_down'], [1,'dim_step_up'], [1,'dim_step_down'], [1,'dim_stop'],
        [2,'on'], [2,'off'], [2,'pct',50], [2,'tilt',25], [2,'stop'],
        [3,'lock'], [3,'unlock'], [4,'desired-temp',22], [4,'desired-temp-cool',25],
        [4,'mode','cool'], [5,'fan_mode','low'], [5,'fan_pct',60], [6,'identify']) {
        my ($endpoint, $cmd, @args) = @$case;
        my $target = $ep{$endpoint};
        my $readings = encode_json($target->{READINGS});
        my $before = scalar @sent;
        my $pending = scalar keys %{$io->{helper}{pending_command}};
        my $next_id = $io->{helper}{next_message_id};
        my @result = MATTERDevice_Set($target, $target->{NAME}, $cmd, @args);
        like($result[0] // '', qr/readOnly=1.*blocked/, "$cmd returns explicit protection error");
        is(scalar @sent, $before, "$cmd sends nothing");
        is(scalar(keys %{$io->{helper}{pending_command}}), $pending, "$cmd registers no request");
        is($io->{helper}{next_message_id}, $next_id, "$cmd allocates no ID");
        is_deeply($target->{READINGS}, JSON::decode_json($readings), "$cmd changes no reading or timestamp");
    }
    # Internal callers must not bypass the UI/SetFn policy, including writes
    # and multi-request RGB-style operations.
    for my $requests (
        [MATTERDevice_CommandRequest($device, 6, 'Off')],
        [{command => 'write_attribute', args => {node_id => 7700, attribute_path => '1/6/0', value => 0}}],
        [MATTERDevice_CommandRequest($device, 8, 'MoveToLevel'), MATTERDevice_CommandRequest($device, 768, 'MoveToColor')]) {
        my $before = scalar @sent;
        like(MATTERDevice_SendRequests($device, $requests, 'lastError', 120) // '',
             qr/readOnly=1.*blocked/, 'common sender enforces policy for internal callers');
        is(scalar @sent, $before, 'internal call sends no component');
        ok(!grep({exists $_->{message_id}} @$requests), 'blocked payloads acquire no request IDs');
    }
    $reply->($inflight, result => undef);
    is(ReadingsVal($name, 'lastError', ''), 'none', 'previously sent request completes while locked');
    ok(!keys %{$io->{helper}{pending_command}}, 'completion retires the old request');

    my $received = $device->{MSGCNT};
    MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [7700, '1/6/0', JSON::true]}));
    is(ReadingsVal($name, 'state', ''), 'on', 'live state continues while locked');
    ok($device->{MSGCNT} > $received, 'receive internals continue while locked');
    my $events = scalar @direct_events;
    MATTER_ParseMessage($io, encode_json({event => 'node_event', data => {
        node_id => 7700, endpoint_id => 1, cluster_id => 59, event_id => 1}}));
    is(scalar @direct_events, $events + 1, 'button events continue while locked');
    MATTER_ProcessNode($io, {node_id => 7700, available => JSON::true,
        attributes => {'0/40/3' => 'Updated model', '1/6/0' => JSON::false}});
    is(ReadingsVal($name, 'state', ''), 'off', 'discovery snapshot continues while locked');
    is(ReadingsVal($name, 'model', ''), 'Updated model', 'root metadata still mirrors to locked endpoint');

    is(MATTERDevice_Set($device, $name, 'getConfig'), undef, 'explicit getConfig stays allowed');
    $reply->($sent[-1]{message_id}, result => {'1/6/0' => JSON::true, '1/6/65529' => [0]});
    is(ReadingsVal($name, 'state', ''), 'on', 'getConfig still updates physical values');
    ok(!MATTERDevice_CommandAccepted($device, 6, 1), 'getConfig still revokes removed commands');
    my ($metadata_id, $metadata_error) = MATTERDevice_RequestCapabilityRefresh($root);
    is($metadata_error, undef, 'automatic metadata read remains permitted');
    $reply->($metadata_id, result => {'1/6/65529' => [0,1,2]});
    ok(MATTERDevice_CommandAccepted($device, 6, 1), 'automatic metadata reply updates locked capability cache');
    is_deeply([MATTERDevice_GetSetList($device)], ['getConfig:noArg'], 'new capabilities do not bypass protection');

    my $before_unlock = scalar @sent;
    is(CommandAttr(undef, "$ep{2}{NAME} readOnly 0"), undef, 'unlock sibling');
    my $sibling_id = $send->($ep{2}, 'off');
    $reply->($sibling_id, result => undef);
    my $other_root = MATTERDevice_LookupRoot($other, 7700);
    my ($other_ep) = grep {$_->{endpoint_id} == 1} MATTERDevice_NodeChildren($other_root);
    $send->($other_ep, 'off');
    is(scalar @sent, $before_unlock + 2, 'sibling and same node on another IO remain controllable');

    my @timers_before = @timers;
    for my $event (qw(INITIALIZED REREADCFG)) {
        $device->{helper} = {}; # model restored public attributes with fresh transient metadata
        MATTERDevice_Notify($root, {NAME => 'global', CHANGED => [$event]});
        MATTERDevice_Notify($device, {NAME => 'global', CHANGED => [$event]});
        MATTER_ProcessNode($io, {node_id => 7700, available => JSON::true, attributes => $values});
        like(MATTERDevice_Set($device, $name, 'off') // '', qr/readOnly=1/,
             "$event cannot unlock the restored readOnly attribute");
    }
    my $before = scalar @sent;
    is(CommandAttr(undef, "$name readOnly 0"), undef, 'zero unlocks immediately');
    is_deeply([MATTERDevice_GetSetList($device)], \@normal, 'current capabilities restore the original controls');
    is(CommandAttr(undef, "$name readOnly 0"), undef, 'repeated zero is harmless');
    is(CommandAttr(undef, "$name readOnly 1"), undef, 'lock again for deletion check');
    is(CommandDeleteAttr(undef, "$name readOnly"), undef, 'deleting the attribute unlocks');
    is_deeply([MATTERDevice_GetSetList($device)], \@normal, 'deletion preserves capabilities');
    is(scalar @sent, $before, 'unlocking does not probe or replay blocked commands');
    is_deeply(\@timers, \@timers_before, 'readOnly adds no timers');
    my $off = $send->($device, 'off');
    $reply->($off, result => undef);

    # A synchronous result/notify may lock the endpoint during a compound send.
    $io->{test_send_text} = sub {
        my $request = JSON::decode_json($_[0]); push @sent, $request;
        $reply->($request->{message_id}, result => undef);
        CommandAttr(undef, "$name readOnly 1");
        return 1;
    };
    $before = scalar @sent;
    like(MATTERDevice_Set($device, $name, 'rgb', '800080') // '', qr/readOnly=1/,
         'mid-send locking reports the unsent compound remainder');
    is(scalar @sent, $before + 1, 'no second RGB component after synchronous locking');
    ok(!keys %{$io->{helper}{pending_command}}, 'unsent compound remainder leaves no pending request');
    ok(!exists($device->{helper}{latest_request}{lastError}), 'compound result group is retired');
    like(ReadingsVal($name, 'lastError', ''), qr/readOnly=1/, 'partial operation reports protection failure');
    close $_ for @peers;
};

subtest 'Shared device requests: all setters, independent replies and grouped results' => sub {
    my @sent;
    socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'shared request socketpair';
    my $io = $defs{ioRequests} = {NAME => 'ioRequests', TYPE => 'MATTER', READINGS => {},
        CD => $socket, FD => fileno($socket), websocket => 1, ws_status => 'connected', helper => {}};
    my $sender = sub {push @sent, JSON::decode_json($_[0]); return 1;};
    $io->{test_send_text} = $sender;
    MATTER_ProcessNode($io, {node_id => 6700, name => 'RequestMatrix', available => JSON::true,
        attributes => {
            '1/6/65529' => [0,1,2,64,65,66], '1/6/65532' => 1, '1/6/0' => JSON::false,
            '1/8/65529' => [0,1,2,3,4,5,6,7,8], '1/8/65532' => 7, '1/8/0' => 100,
            '1/768/65529' => [6,7,10], '1/768/65532' => 25,
            '2/258/65529' => [0,1,2,5,8], '2/258/65532' => 23,
            '3/257/65529' => [0,1],
            '4/513/65531' => [17,18,27,28], '4/513/65532' => 3, '4/513/27' => 4,
            '4/513/17' => 2600, '4/513/18' => 2100, '4/513/28' => 4,
            '5/514/65531' => [0,1,2,3], '5/514/65532' => 2, '5/514/1' => 2,
            '5/514/0' => 3, '5/514/2' => 50, '5/514/3' => 40,
            '6/3/65529' => [0],
        }});
    my $root = $modules{MATTERDevice}{defptr}{'ioRequests:6700'};
    my %ep = map {$_->{endpoint_id} => $_} MATTERDevice_NodeChildren($root);
    my $reply = sub {
        my ($id, %body) = @_;
        MATTER_ParseMessage($io, encode_json({message_id => $id, %body}));
    };
    my $send = sub {
        my ($endpoint, $cmd, @args) = @_;
        my $before = scalar @sent;
        my @result = MATTERDevice_Set($ep{$endpoint}, $ep{$endpoint}{NAME}, $cmd, @args);
        is_deeply(\@result, [undef,1], "$cmd uses shared asynchronous SetFn return");
        return @sent[$before..$#sent];
    };
    my $physical = sub {
        my ($device) = @_;
        return {map {$_ => $device->{READINGS}{$_}} grep {$_ ne 'lastError'} keys %{$device->{READINGS}}};
    };
    for my $case ([3, 'unlock', 'UnlockDoor'], [1, 'on', 'On']) {
        my ($endpoint, $cmd, $expected) = @$case;
        my @requests = $send->($endpoint, $cmd);
        is_deeply([map { $_->{args}{command_name} } @requests], [$expected],
                  "$cmd sends exactly the expected Matter command without arguments");
        $reply->($_->{message_id}, result => undef) for @requests;

        my $sent_before = scalar @sent;
        my $device = $ep{$endpoint};
        my $error = MATTERDevice_Set($device, $device->{NAME}, $cmd, 'unexpected');
        like($error // '', qr/^Usage:.*no arguments/, "$cmd rejects a surplus argument");
        is(scalar @sent, $sent_before, "invalid $cmd sends no command");
        is_deeply($io->{helper}{pending_command}, {}, "invalid $cmd leaves no pending request");
    }
    my %ids;
    for my $case (
        [1,'on'], [1,'off'], [1,'toggle'], [1,'off_with_effect','DelayedAllOff,NoFade'],
        [1,'on_with_recall_global_scene'], [1,'on_with_timed_off','0,10,0'],
        [1,'brightness',120], [1,'pct',50], [1,'rgb','800000'], [1,'ct',300], [1,'frequency',100],
        [1,'dim_up'], [1,'dim_down'], [1,'dim_step_up'], [1,'dim_step_down'], [1,'dim_stop'],
        [2,'on'], [2,'off'], [2,'pct',50], [2,'tilt',25], [2,'stop'],
        [3,'lock'], [3,'unlock'], [4,'desired-temp',22], [4,'desired-temp-cool',25],
        [4,'mode','cool'], [5,'fan_mode','low'], [5,'fan_pct',60], [6,'identify']) {
        my ($endpoint,$cmd,@args) = @$case;
        my $before = JSON::decode_json(encode_json($physical->($ep{$endpoint})));
        my @requests = $send->($endpoint,$cmd,@args);
        ok(@requests && !(grep { !$io->{helper}{pending_command}{$_->{message_id}} } @requests),
           "$cmd registers every API request");
        for my $request (@requests) {
            ok(!$ids{$request->{message_id}}++, 'each outgoing request has a distinct ID');
            is($request->{args}{node_id}, 6700, 'request retains node identity');
            if ($request->{command} eq 'device_command') {
                is($request->{args}{endpoint_id},$endpoint,'command retains endpoint identity');
            } else {
                like($request->{args}{attribute_path},qr/^$endpoint\//,'write retains endpoint path');
            }
            $reply->($request->{message_id}, result => undef);
        }
        is(ReadingsVal($ep{$endpoint}{NAME},'lastError',''),'none',"$cmd has a correlated acknowledgement");
        is_deeply($physical->($ep{$endpoint}),$before,"$cmd leaves physical readings and timestamps unchanged");
    }
    my ($on) = $send->(1,'on');
    my ($off) = $send->(1,'off');
    ok(exists($io->{helper}{pending_command}{$on->{message_id}}) &&
       exists($io->{helper}{pending_command}{$off->{message_id}}),'on and off remain independently pending');
    $reply->($off->{message_id},error_code => 8,details => 'Off refused');
    like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/Off refused/,'newer Off failure is assigned to the endpoint');
    $reply->($on->{message_id},result => undef);
    like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/Off refused/,'older On acknowledgement cannot clear newer Off error');
    my ($old) = $send->(1,'on');
    my ($latest) = $send->(1,'off');
    $reply->($latest->{message_id},result => undef);
    $reply->($old->{message_id},error_code => 8,details => 'old refusal');
    is(ReadingsVal($ep{1}{NAME},'lastError',''),'none','older failure cannot replace newer acknowledgement');
    $reply->($latest->{message_id},error_code => 8,details => 'duplicate');
    is(ReadingsVal($ep{1}{NAME},'lastError',''),'none','duplicate response is ignored');

    for my $failed_part (0,1) {
        my @rgb = $send->(1,'rgb','008000');
        is(scalar @rgb,2,'one RGB setter produces separate level/color requests');
        my $other_part = 1 - $failed_part;
        $reply->($rgb[$failed_part]{message_id},error_code => 8,details => 'RGB component refused');
        $reply->($rgb[$other_part]{message_id},result => undef);
        like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/RGB component refused/,'success of either component cannot conceal the RGB failure');
    }
    my @rgb = $send->(1,'rgb','000080');
    $reply->($rgb[1]{message_id},result => undef);
    like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/RGB component refused/,'partial acknowledgement does not announce whole-setter success');
    $reply->($rgb[0]{message_id},result => undef);
    is(ReadingsVal($ep{1}{NAME},'lastError',''),'none','all RGB components acknowledged clears the error');

    my ($first_write) = $send->(4,'desired-temp',22);
    my ($last_write) = $send->(4,'desired-temp',23);
    $reply->($last_write->{message_id},error_code => 8,details => 'new setpoint refused');
    $reply->($first_write->{message_id},result => undef);
    like(ReadingsVal($ep{4}{NAME},'lastError',''),qr/new setpoint refused/,'write_attribute uses the same latest-setter ordering');

    my $count = 0;
    $io->{test_send_text} = sub {return ++$count == 1 ? $sender->($_[0]) : 0;};
    like(MATTERDevice_Set($ep{1},$ep{1}{NAME},'rgb','800080') // '',qr/Unable to send/,'second RGB enqueue failure is returned synchronously');
    my $part_id = $sent[-1]{message_id};
    like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/unable to send/,'partial send failure is visible as the setter result');
    $reply->($part_id,result => undef);
    like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/unable to send/,'acknowledging the sent component cannot hide the unsent component');
    $io->{test_send_text} = $sender;
    is(scalar(keys %{$io->{helper}{pending_command}}),0,'completed and unsent requests leave no pending entries');

    $io->{test_send_text} = sub {
        my $request = JSON::decode_json($_[0]); push @sent,$request;
        $reply->($request->{message_id},result => undef); return 1;
    };
    $send->(1,'rgb','808000');
    is(ReadingsVal($ep{1}{NAME},'lastError',''),'none','synchronous replies work because both component owners were installed before sending');
    is(scalar(keys %{$io->{helper}{pending_command}}),0,'synchronous completions leave no orphaned requests');
    $io->{test_send_text} = $sender;

    ($old) = $send->(1,'on'); ($latest) = $send->(1,'off');
    $reply->($latest->{message_id},result => undef);
    $io->{helper}{pending_command}{$old->{message_id}}{started_at} = gettimeofday() - 121;
    delete $io->{helper}{pending_pong};
    MATTER_Heartbeat($io);
    is(ReadingsVal($ep{1}{NAME},'lastError',''),'none','an older timeout cannot overwrite the latest result');
    ($on) = $send->(1,'on');
    $io->{helper}{pending_command}{$on->{message_id}}{started_at} = gettimeofday() - 121;
    delete $io->{helper}{pending_pong};
    MATTER_Heartbeat($io);
    like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/timeout/,'On timeout is handled by the common lifecycle');
    $reply->($on->{message_id},result => undef);
    like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/timeout/,'late On reply cannot clear timeout');

    # A renamed device keeps the same hash/FUUID; the mutable name is no owner key.
    ($on) = $send->(1,'on');
    my $old_name = $ep{1}{NAME}; my $renamed = 'RequestMatrixRenamed';
    $defs{$renamed} = delete $defs{$old_name}; $ep{1}{NAME} = $renamed;
    $reply->($on->{message_id},result => undef);
    is(ReadingsVal($renamed,'lastError',''),'none','response follows the same FHEM device after a rename');
    $defs{$old_name} = delete $defs{$renamed}; $ep{1}{NAME} = $old_name;
    {
        local $io->{helper}{pending_command} = {map {$_ => 'held test request'} 10000..11023};
        my $before = scalar @sent;
        like(MATTERDevice_Set($ep{1},$ep{1}{NAME},'on') // '',qr/Too many pending/,'bounded registry rejects overload explicitly');
        is(scalar @sent,$before,'overload does not send an untracked command');
    }
    # Transport failure while a compound setter is being enqueued must retire
    # each pre-registered component exactly once through the common close path.
    my $group;
    $io->{test_send_text} = sub {
        my $request = JSON::decode_json($_[0]);
        $group = $io->{helper}{pending_command}{$request->{message_id}}{group};
        MATTER_Close($io); return 0;
    };
    like(MATTERDevice_Set($ep{1},$ep{1}{NAME},'rgb','008080') // '',qr/Unable to send/,'connection loss during enqueue is returned');
    is($group->{remaining},0,'close retires a compound request exactly once');
    like(ReadingsVal($ep{1}{NAME},'lastError',''),qr/interrupted/,'common close reports unknown command outcome');
    ok(!keys %{$io->{helper}{pending_command} // {}},'close leaves no pending command');
    is(ReadingsVal($ep{1}{NAME},'state',''),'off','all command outcomes preserve actual reported OnOff state');
    close $peer;
};

{
    my $a = $defs{moveA} = {NAME => 'moveA', TYPE => 'MATTER', CD => 1,
        websocket => 1, ws_status => 'connected'};
    my $b = $defs{moveB} = {NAME => 'moveB', TYPE => 'MATTER'};
    my $id;
    $a->{test_send_text} = sub { $id = JSON::decode_json($_[0])->{message_id}; 1 };
    MATTER_ProcessNode($a, {node_id => 9801, name => 'MoveProbe', available => JSON::true,
        attributes => {'0/40/3' => 'initial'}});
    my $r = $defs{MATTER_MoveProbe};
    is(MATTERDevice_Set($r, $r->{NAME}, 'getConfig'), undef, 'read pending on old IO');
    is(CommandAttr(undef, "$r->{NAME} IODev moveB"), undef, 'move root to second IO');
    is(ReadingsVal($r->{NAME}, 'state', ''), 'unknown', 'new IO must establish availability');
    ok(!defined($r->{helper}{available}), 'old availability cannot authorize reports');
    is($modules{MATTERDevice}{defptr}{'moveB:9801'}, $r, 'new IO indexed immediately');
    ok(!exists($modules{MATTERDevice}{defptr}{'moveA:9801'}), 'old IO index released');
    MATTER_ParseMessage($b, encode_json({event => 'node_updated', data => {
        node_id => 9801, available => JSON::true, attributes => {'0/40/3' => 'new'}}}));
    my $count = $r->{MSGCNT};
    for my $message (
        {event => 'attribute_updated', data => [9801, '0/40/3', 'wrong']},
        {event => 'node_event', data => {node_id => 9801, endpoint_id => 1, cluster_id => 59, event_id => 1}},
        {message_id => $id, result => {'0/40/3' => 'old'}},
        {event => 'node_removed', data => 9801}) {
        # Exercise the receiver even with a stale index, independently of AttrFn.
        $modules{MATTERDevice}{defptr}{'moveA:9801'} = $r;
        MATTER_ParseMessage($a, encode_json($message));
    }
    is($r->{MSGCNT}, $count, 'old IO events and read reply leave receive internals intact');
    is(ReadingsVal($r->{NAME}, 'model', ''), 'new', 'new IO reports update the same root');
    is(ReadingsVal($r->{NAME}, 'state', ''), 'online', 'old removal cannot change new availability');
    MATTER_ProcessNode($a, {node_id => 9801, name => 'OtherMoveRoot', available => JSON::true});
    like(CommandAttr(undef, "$r->{NAME} IODev moveA"), qr/already belongs/,
         'duplicate destination identity rejects rebind');
    is($r->{IODev}, $b, 'failed rebind retains previous IO');
    ok($r->{helper}{available}, 'failed rebind preserves current availability');
    is(CommandRename(undef, 'moveB moveRenamed'), undef, 'rename current IO');
    ok($r->{helper}{available}, 'renaming the same IO preserves availability');
}

{
    my $io = $defs{coverIO} = {NAME => 'coverIO', TYPE => 'MATTER'};
    my $original_attr = \&CommandAttr;
    my @limit_writes;
    no warnings 'redefine';
    local *CommandAttr = sub {
        push @limit_writes, $_[1] if $_[1] =~ /\sphysical_closed_limit_(?:lift|tilt)\s/;
        return $original_attr->(@_);
    };
    MATTER_ProcessNodeList($io, [{node_id => 9802, name => 'CoverLimits', available => JSON::true,
        attributes => {'1/258/1' => 1250, '1/258/2' => 90, '2/258/2' => 45}}], 'get_nodes');
    my $ep = 'MATTER_CoverLimits_EP1';
    is(ReadingsVal($ep, 'physical_closed_limit_lift', undef), 1250, 'discovery publishes lift limit');
    is(ReadingsVal($ep, 'physical_closed_limit_tilt', undef), 90, 'discovery publishes tilt limit');
    for my $value (0, undef, 65536) {
        MATTER_ParseMessage($io, encode_json({event => 'attribute_updated',
            data => [9802, '1/258/2', $value]}));
        is(ReadingsVal($ep, 'physical_closed_limit_tilt', undef), 0,
           'valid zero or subsequent invalid report retains tilt limit zero');
    }
    is(ReadingsVal($ep, 'physical_closed_limit_lift', undef), 1250, 'tilt update preserves lift');
    is(ReadingsVal('MATTER_CoverLimits_EP2', 'physical_closed_limit_tilt', undef), 45,
       'sibling keeps its reported limit');
    is_deeply(\@limit_writes, [], 'reports never attempt to configure covering attributes');
}

{
    my $id;
    my $io = $defs{listIO} = {NAME => 'listIO', TYPE => 'MATTER', CD => 1,
        websocket => 1, ws_status => 'connected', test_send_text => sub { $id = JSON::decode_json($_[0])->{message_id}; 1 }};
    MATTER_ProcessNode($io, node(9803, 'ListProbe'));
    my $root = $defs{MATTER_ListProbe};
    my $ep = $defs{MATTER_ListProbe_EP1};
    my $path = '1/6/65529';
    my $read = sub {
        is(MATTERDevice_Set($ep, $ep->{NAME}, 'getConfig'), undef, 'queue endpoint read');
    };
    my $reply = sub {
        MATTER_ParseMessage($io, encode_json({message_id => $id, result => $_[0]}));
    };
    my $live = sub {
        MATTER_ParseMessage($io, encode_json({event => 'attribute_updated', data => [9803, $path, $_[0]]}));
    };
    my $switches = sub {
        return [sort grep { /^(?:on|off):/ } MATTERDevice_GetSetList($ep)];
    };
    my %routes = (
        live => $live,
        discovery => sub { MATTER_ProcessNodeList($io, [{node_id => 9803,
            attributes => {$path => $_[0], '1/6/0' => JSON::false}}], 'get_nodes') },
        getConfig => sub { $read->(); $reply->({$path => $_[0], '1/6/0' => JSON::true}) },
        recovery => sub { MATTERDevice_ApplyCapabilityMetadata($root, {$path => $_[0]}) },
    );
    for my $route (sort keys %routes) {
        my $report = $routes{$route};
        $report->([0, 1]);
        is_deeply($switches->(), [qw(off:noArg on:noArg)], "$route accepts both commands");
        for my $bad ([0, undef], {}, [4294967296], undef) {
            $report->($bad);
            is_deeply($switches->(), [qw(off:noArg on:noArg)], "$route preserves the complete valid list");
        }
        $report->([0]);
        is_deeply($switches->(), ['off:noArg'], "$route accepts a shorter list");
        $report->([]);
        is_deeply($switches->(), [], "$route accepts explicit revocation");
    }
    $read->();
    $live->([0, undef]);
    $reply->({$path => [0, 1], '1/6/0' => JSON::false});
    is_deeply($switches->(), [qw(off:noArg on:noArg)], 'invalid live list cannot supersede valid read');
    $read->();
    $reply->({$path => [0, {}], '1/6/0' => JSON::true});
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', 'valid sibling path survives invalid list');
    $read->();
    $reply->({'1/6/0' => JSON::true});
    is_deeply($switches->(), [], 'omitted list is cleared on complete read');
    my %lists = (65528 => 'generated_commands', 65529 => 'accepted_commands',
                 65530 => 'event_list', 65531 => 'attribute_list');
    $read->();
    $reply->({map { ("1/6/$_" => [0, '0x01']) } keys %lists});
    $read->();
    $reply->({map { ("1/6/$_" => [0, {}]) } keys %lists});
    for my $key (sort values %lists) {
        is_deeply($ep->{helper}{capabilities}{6}{$key}, {0 => 1, 1 => 1},
                  "complete read retains the last valid $key");
    }
}

{
    socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    my $io = $defs{wireIO} = {NAME => 'wireIO', TYPE => 'MATTER', CD => $socket,
        websocket => 1, ws_status => 'connected'};
    MATTER_ProcessNode($io, {node_id => 9804, name => 'WireProbe', available => JSON::true,
        attributes => {'1/6/65529' => [0, 1]}});
    my $root = $defs{MATTER_WireProbe};
    my $ep = $defs{MATTER_WireProbe_EP1};
    for my $cmd ('on', 'getConfig') {
        my $error = MATTERDevice_Set($ep, $ep->{NAME}, $cmd);
        is($error, undef, "$cmd accepted by the endpoint's IO");
        next if defined $error;
        my $request = $read_ws_json->($peer);
        is($request->{command}, $cmd eq 'on' ? 'device_command' : 'read_attribute',
           "$cmd sent as a JSON command on the selected socket");
        is($request->{args}{node_id}, 9804, "$cmd targets the selected node");
    }
    my ($id, $error) = MATTERDevice_RequestCapabilityRefresh($root);
    is($error, undef, 'metadata read accepted by the root IO');
    if (defined $id) {
        my $request = $read_ws_json->($peer);
        is($request->{message_id}, $id, 'metadata read retains its tracked ID on the wire');
        is($request->{command}, 'read_attribute', 'metadata read uses the same socket');
    }
    MATTER_Close($io);
    (undef, $error) = MATTERDevice_RequestCapabilityRefresh($root);
    like($error, qr/No connected Matter IO/, 'disconnected metadata read rejected');
    close $peer;
}

{
    my $weak;
    {
        my $io = {NAME => 'LifetimeProbe', TYPE => 'MATTER', READINGS => {}};
        MATTER_Define($io, 'LifetimeProbe MATTER 127.0.0.1 5580');
        MATTER_Undef($io, undef);
        $weak = $io;
        Scalar::Util::weaken($weak);
    }
    ok(!defined($weak), 'undef releases the IO after the last external reference goes away');
}

{
    my $id;
    my $io = $defs{decodeIO} = {NAME => 'decodeIO', TYPE => 'MATTER', CD => 1,
        websocket => 1, ws_status => 'connected',
        test_send_text => sub { $id = JSON::decode_json($_[0])->{message_id}; 1 }};
    my $receive = sub {
        my ($label, $message) = @_;
        my $wire = encode_json($message);
        my ($decodes, $encodes) = (0, 0);
        {
            no warnings qw(redefine once);
            local *decode_json = sub { ++$decodes; return JSON::decode_json($_[0]) };
            local *encode_json = sub { ++$encodes; return JSON::encode_json($_[0]) };
            MATTER_ParseMessage($io, $wire);
        }
        is_deeply([$decodes, $encodes], [1, 0], "$label decoded once with no internal re-encoding");
    };
    $io->{helper}{pending_command}{discovery} = 'get_nodes';
    $receive->('discovery', {message_id => 'discovery', result => [node(9805, 'DecodeProbe')]});
    my $root = $defs{MATTER_DecodeProbe};
    my $ep = $defs{MATTER_DecodeProbe_EP1};
    $receive->('live attribute', {event => 'attribute_updated', data => [9805, '1/6/0', JSON::false]});
    $receive->('switch event', {event => 'node_event', data => {
        node_id => 9805, endpoint_id => 1, cluster_id => 59, event_id => 1}});
    is(MATTERDevice_Set($ep, $ep->{NAME}, 'getConfig'), undef, 'explicit read queued');
    $receive->('read reply', {message_id => $id, result => {'1/6/0' => JSON::true}});
    is($ep->{MSGCNT}, 4, 'four server messages counted once each for the endpoint');
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'on', 'read reply routed to the endpoint');
    MATTERDevice_Parse($root, encode_json({event => 'attribute_updated',
        data => [9805, '1/6/0', JSON::false]}));
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'off', 'public ParseFn accepts JSON text');
    MATTERDevice_Parse($root, '{');
    like($log[-1], qr/Invalid JSON object/, 'public ParseFn rejects malformed JSON');
}

{
    my $io = $defs{syncIO} = {NAME => 'syncIO', TYPE => 'MATTER'};
    MATTER_ProcessNode($io, node(9806, 'SyncProbe'));
    my $root = $defs{MATTER_SyncProbe};
    my $ep = $defs{MATTER_SyncProbe_EP1};
    my ($groups, $syncs) = (0, 0);
    my $group = \&MATTERDevice_EnsureTypeGroup;
    my $sync = \&MATTERDevice_SyncNodeReadings;
    no warnings 'redefine';
    local *MATTERDevice_EnsureTypeGroup = sub ($) { ++$groups; return $group->(@_) };
    local *MATTERDevice_SyncNodeReadings = sub ($;$) { ++$syncs; return $sync->(@_) };
    my $report = sub { MATTER_ParseMessage($io, encode_json($_[0])) };
    $report->({event => 'attribute_updated', data => [9806, '1/8/0', 33]});
    is_deeply([$groups, $syncs], [0, 0], 'cached live reading skips group and node synchronization');
    is(ReadingsVal($ep->{NAME}, 'brightness', ''), 33, 'cached endpoint still receives telemetry');
    my $attributes = {'1/6/0' => JSON::true, '1/8/0' => 44, '1/8/3' => 200};
    ($groups, $syncs) = (0, 0);
    $report->({event => 'node_updated', data => {node_id => 9806, available => JSON::true,
        attributes => $attributes}});
    is_deeply([$groups, $syncs], [0, 0], 'ordinary node report skips repeated endpoint maintenance');
    my @cost;
    for my $values ({'1/8/0' => 44}, $attributes) {
        ($groups, $syncs) = (0, 0);
        $io->{helper}{pending_command}{snapshot} = 'get_nodes';
        $report->({message_id => 'snapshot', result => [{node_id => 9806, attributes => $values}]});
        push @cost, [$groups, $syncs];
    }
    is_deeply($cost[1], $cost[0], 'discovery maintenance is independent of attribute count');
    $report->({event => 'attribute_updated', data => [9806, '0/40/3', 'New model']});
    is(ReadingsVal($ep->{NAME}, 'model', ''), 'New model', 'changed root model reaches cached child');
    ($groups, $syncs) = (0, 0);
    $report->({event => 'attribute_updated', data => [9806, '0/40/3', 'New model']});
    is($syncs, 0, 'repeated root model skips endpoint synchronization');
    $report->({event => 'node_updated', data => {node_id => 9806, available => JSON::false}});
    is(ReadingsVal($ep->{NAME}, 'available', ''), 'false', 'changed root availability reaches child');
}

subtest 'Issue 79: runtime permissions belong to the actual Matter identity' => sub {
    my (@sent_a, @sent_b);
    my $a = $defs{identityA} = {NAME => 'identityA', TYPE => 'MATTER', CD => 1,
        websocket => 1, ws_status => 'connected', test_send_text => sub {push @sent_a, JSON::decode_json($_[0]); 1}};
    my $b = $defs{identityB} = {NAME => 'identityB', TYPE => 'MATTER', CD => 1,
        websocket => 1, ws_status => 'connected', test_send_text => sub {push @sent_b, JSON::decode_json($_[0]); 1}};
    for my $io ($a, $b) {
        MATTER_ParseMessage($io, encode_json({schema_version => 12,
            sdk_version => 'matter-server/1.0 (matter.js/1.0)'}));
    }
    MATTER_ProcessNode($a, {node_id => 99008, name => 'IdentityProbe', available => JSON::true,
        attributes => {'0/29/1' => [42], '0/3/65529' => [0], '0/40/9' => 1, '0/40/3' => 'saved model',
                       '1/6/65529' => [0, 1], '1/6/0' => JSON::false}});
    my $root = $modules{MATTERDevice}{defptr}{'identityA:99008'};
    my ($ep) = MATTERDevice_NodeChildren($root);
    is(MATTERDevice_Set($root, $root->{NAME}, 'checkFirmwareUpdate'), undef, 'check on original server');
    MATTER_ParseMessage($a, encode_json({message_id => $sent_a[-1]{message_id}, result => {software_version => 2}}));
    is(CommandModify(undef, "$root->{NAME} 99008"), undef, 'confirm unchanged root definition');
    ok($root->{helper}{available}, 'same identity preserves online authority');
    is(ReadingsVal($root->{NAME}, 'state', ''), 'online', 'same identity preserves native root status');
    is($root->{helper}{firmware_available}, 2, 'same identity preserves update offer');
    is(MATTERDevice_Set($root, $root->{NAME}, 'identify'), undef, 'root command is pending before rebind');
    my $old_id = $sent_a[-1]{message_id};
    # Persistent capability/limit readings must not authorize a new identity.
    $root->{READINGS}{icd_supported}{VAL} = 'true';
    $ep->{READINGS}{max_brightness}{VAL} = 20;
    is(CommandAttr(undef, "$root->{NAME} IODev identityB"), undef, 'move root to another server');
    ok(!defined($root->{helper}{available}), 'new server must establish availability');
    ok(!exists($root->{helper}{firmware_available}), 'old offer is discarded');
    ok(!exists($root->{helper}{seen_clusters}{42}), 'old OTA capability is discarded');
    ok(!exists($root->{READINGS}{icd_supported}), 'old persisted ICD permission is discarded');
    ok(!exists($root->{READINGS}{software_version}), 'old firmware version cannot reject a new server offer');
    ok(!exists($a->{helper}{pending_command}{$old_id}), 'old owner operation is cancelled');
    ok(defined(MATTERDevice_Set($root, $root->{NAME}, 'updateFirmware')), 'new server cannot use old offer');
    is(scalar @sent_b, 0, 'no unchecked install or implicit read on new server');
    is($ep->{IODev}, $a, 'child keeps independent IO assignment');
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'off', 'child physical state is preserved');
    MATTER_ProcessNode($b, {node_id => 99008, available => JSON::true,
        attributes => {'0/29/1' => [42]}});
    is(MATTERDevice_Set($root, $root->{NAME}, 'checkFirmwareUpdate'), undef, 'new server check works');
    MATTER_ParseMessage($b, encode_json({message_id => $sent_b[-1]{message_id}, result => {software_version => 3}}));
    is($root->{helper}{firmware_available}, 3, 'only new server offer is accepted');
    is(CommandRename(undef, 'identityB identityRenamed'), undef, 'rename same IO instance');
    ok($root->{helper}{available}, 'IO rename retains authority');
    is($root->{helper}{firmware_available}, 3, 'IO rename retains offer');
    MATTER_ProcessNode($b, {node_id => 99009, name => 'OccupiedIdentity', available => JSON::true});
    like(CommandModify(undef, "$root->{NAME} 99009") // '', qr/already belongs/, 'modify cannot occupy another root identity');
    is($root->{node_id}, 99008, 'failed modify preserves internal identity');
    is($root->{helper}{firmware_available}, 3, 'failed modify preserves offer');
    is(CommandModify(undef, "$root->{NAME} 99010"), undef, 'change root node identity');
    ok(!defined($root->{helper}{available}), 'new node cannot inherit online authority');
    ok(!exists($root->{helper}{firmware_available}), 'new node cannot inherit offer');
    MATTER_ParseMessage($b, encode_json({event => 'attribute_updated', data => [99010, '0/40/3', 'unapproved']}));
    is(ReadingsVal($root->{NAME}, 'model', ''), 'saved model', 'new node attributes need availability');
    MATTER_ProcessNode($b, {node_id => 99010, available => JSON::true, attributes => {'0/40/3' => 'new model'}});
    is(ReadingsVal($root->{NAME}, 'model', ''), 'new model', 'own availability resumes normal updates');
    is(CommandModify(undef, "$ep->{NAME} 99008 1"), undef, 'same endpoint definition');
    ok(MATTERDevice_CommandAccepted($ep, 6, 1), 'same endpoint retains commands');
    CommandAttr(undef, "$ep->{NAME} readOnly 1");
    is(CommandModify(undef, "$ep->{NAME} 99008 2"), undef, 'change endpoint identity');
    ok(!MATTERDevice_CommandAccepted($ep, 6, 1), 'new endpoint cannot inherit commands');
    ok(!exists($ep->{READINGS}{max_brightness}), 'old limit cannot scale a new endpoint');
    is(AttrVal($ep->{NAME}, 'readOnly', 0), 1, 'manual endpoint policy survives identity change');
    is(ReadingsVal($ep->{NAME}, 'state', ''), 'off', 'identity reset retains saved physical reading');
    MATTERDevice_ProcessGlobalAttribute($ep, 6, 65529, [0, 1]);
    is(CommandAttr(undef, "$ep->{NAME} IODev identityRenamed"), undef, 'move endpoint independently');
    ok(!MATTERDevice_CommandAccepted($ep, 6, 1), 'new IO cannot inherit endpoint commands');
    MATTER_ParseMessage($a, encode_json({message_id => $old_id, result => {software_version => 9}}));
    ok(!exists($root->{helper}{firmware_available}), 'old reply cannot restore another identity offer');
    MATTER_ProcessNode($a, {node_id => 99011, name => 'IdentityReadOwner', available => JSON::true});
    my $read_owner = MATTERDevice_LookupRoot($a, 99011);
    MATTERDevice_Set($read_owner, $read_owner->{NAME}, 'getConfig');
    my $read_id = $sent_a[-1]{message_id};
    my $preferred = $preferred_io;
    $preferred_io = 'identityA';
    MATTER_ProcessNode($b, {node_id => 99011, name => 'IdentityOtherServer', available => JSON::true});
    $preferred_io = $preferred;
    ok(exists($a->{helper}{pending_config}{$read_id}), 'temporary auto-assignment cannot cancel another root read');
};

done_testing();
