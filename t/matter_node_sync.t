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
    if (($device->{endpoint_id} // 0) == 0) {
        $modules{MATTERDevice}{defptr}{"$preferred_io:$device->{node_id}"} = $device;
    }
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
    if ($key eq 'IODev') {
        return "Unknown IODev" unless $defs{$value} && $defs{$value}{TYPE} eq 'MATTER';
        $defs{$name}{IODev} = $defs{$value};
        readingsSingleUpdate($defs{$name}, 'IODev', $value);
    }
    # FHEM invokes AttrFn before updating the attribute map.
    if ($defs{$name}{TYPE} eq 'MATTER') {
        my $error = MATTER_Attr('set', $name, $key, $value);
        return $error if defined($error);
    }
    $attr{$name}{$key} = $value;
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
    delete $attr{$name}{$key};
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

# FHEM calls Initialize before Define/CommandAttr; expose the real module AttrList.
MATTERDevice_Initialize($modules{MATTERDevice} ||= {});
MATTER_Initialize($modules{MATTER} ||= {});
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
my $child_state_before_close = ReadingsVal($child->{NAME}, 'state', '');
MATTER_Close($defs{ioA});
ok(!exists($defs{ioA}{helper}{pending_command}), 'close clears pending commands');
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
$defs{ioA}{fhem}{helper}{sendWS} = sub {
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
my $previous_sender = $defs{ioA}{fhem}{helper}{sendWS};
$defs{ioA}{fhem}{helper}{sendWS} = sub { return 0 };
my $pending_before_send_failure = scalar keys %{$defs{ioA}{helper}{pending_config} // {}};
like(MATTERDevice_Set($child, $child->{NAME}, 'on') // '',
     qr/Unable to send device command/, 'failed device send returns a FHEM error');
like(MATTERDevice_Set($child, $child->{NAME}, 'getConfig') // '',
     qr/Unable to send getConfig/, 'failed read send returns a FHEM error');
is(scalar(keys %{$defs{ioA}{helper}{pending_config} // {}}),
   $pending_before_send_failure, 'failed read leaves no dangling pending request');
$defs{ioA}{fhem}{helper}{sendWS} = $previous_sender;

ok(!exists $defs{ioA}{helper}{pending_config}{$read_request->{message_id}},
   'matched getConfig pending request is cleared');

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
$defs{ioA}{fhem}{helper}{sendWS} = sub {
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
        '1/513/65531' => [0, 18, 28],
        '1/513/0' => 2250,
        '1/513/18' => 2100,
        '1/513/28' => 4,
        '2/514/65531' => [0, 2, 3],
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
# device-derived metadata; recovery accepts only fresh individual reports.
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
        '1/6/65532' => 0, # No OffOnly feature: On/Toggle are usable.
        '1/6/0' => JSON::true,
        '1/47/12' => 175,
    }
}));
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
my $recovery_sender = $defs{ioA}{fhem}{helper}{sendWS};
$defs{ioA}{fhem}{helper}{sendWS} = sub { return 0 };
MATTER_ProcessNode($defs{ioA}, {node_id => 2704, available => JSON::true});
ok(!grep({ ref($_) eq 'HASH' && ($_->{node_id} // -1) == 2704 }
         values %{$defs{ioA}{helper}{pending_config} // {}}),
   'failed metadata send leaves no pending request');
$defs{ioA}{fhem}{helper}{sendWS} = $recovery_sender;
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
readingsSingleUpdate($defs{ioA}, 'schema_version', 12, 0);
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

# End-to-end request discipline: do not accept another write before the
# controller has replied to the previous attribute write.
@sent_requests = ();
is(MATTERDevice_Set($therm, $therm->{NAME}, 'mode', 'cool'), undef,
   'first thermostat mode write queued');
my $first_mode_id = $sent_requests[-1]{message_id};
like(MATTERDevice_Set($therm, $therm->{NAME}, 'mode', 'heat') // '',
     qr/already pending/, 'concurrent write to same node is rejected');
MATTER_ParseMessage($defs{ioA}, encode_json({
    message_id => $first_mode_id, result => undef
}));
is(MATTERDevice_Set($therm, $therm->{NAME}, 'mode', 'heat'), undef,
   'write is available again once previous command is acknowledged');

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
    fuuid => $r1->{FUUID}, node_id => 4100
};
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
    fhem => {helper => {sendWS => sub {
        push @limit_commands, JSON::decode_json($_[0]); return 1;
    }}},
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
        $io->{fhem}{helper}{sendWS} = sub {
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

done_testing();
