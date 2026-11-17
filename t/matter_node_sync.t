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
    return { node_id => $id, name => $name,
             attributes => { '1/6/0' => JSON::true,
                             '1/29/0' => [{ '0' => 0x0100, '1' => 1 }] } };
}
sub matter_devices {
    return grep { ($_->{TYPE} // '') eq 'MATTERDevice' } values %defs;
}
sub count_devices { return scalar(matter_devices()); }

MATTER_ProcessNodeList($defs{ioA}, [node(42, 'Hall Light')], 'start_listening');
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
MATTER_ParseMessage($defs{ioA}, encode_json({event => 'node_added', data => node(42, 'Hall Light')}));
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
# Independent subsequent callback tests model a separately proven fresh
# re-interview. The offline quarantine tests below exercise the persistent
# protection; merely observing available=true does not clear it in production.
delete $root->{helper}{quarantine_snapshots};

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
    result => { '1/47/12' => 110 },
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
   'invalid zero maximum falls back without division by zero');
$attr{$child->{NAME}}{max_brightness} = 200;
ok(MATTERDevice_AttributeUsable($child, 8, 3),
   'legacy min/max attributes remain usable without AttributeList');
ok(grep(/^brightness:slider,0,1,200$/, MATTERDevice_GetSetList($child)),
   'existing max_brightness remains in the brightness slider without metadata');
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => { '1/8/0' => 254 }
}));
is(ReadingsVal($child->{NAME}, 'pct', ''), 100,
   'incoming device level above configured max is clamped to 100 percent');
MATTERDevice_Parse($root, encode_json({
    node_id => 42, attributes => { '1/8/65531' => [0] }
}));
ok(!MATTERDevice_AttributeUsable($child, 8, 3),
   'received AttributeList takes precedence over legacy max attribute');

$attr{$child->{NAME}}{has_hue} = 0;
ok(!grep(/^rgb:/, MATTERDevice_GetSetList($child)),
   'explicit has_hue=0 suppresses the advertised hue command');
delete $attr{$child->{NAME}}{has_hue};

delete $child->{helper}{capabilities}{0x0300}{accepted_commands};
$attr{$child->{NAME}}{has_color} = 1;
ok(grep(/^rgb:/, MATTERDevice_GetSetList($child)),
   'legacy has_color still exposes RGB before the server supplies metadata');
delete $attr{$child->{NAME}}{has_color};


# FHEMWEB endpoint type display: real Descriptor DeviceTypeList takes priority;
# cluster-only fallbacks intentionally describe functions, not assumed hardware.
MATTER_ProcessNode($defs{ioA}, {
    node_id => 88, name => 'TypeDisplay',
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
    node_id => 89, name => 'Unknown type',
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
# not a cached replay after the preceding offline->online transition.
delete $metadata_root->{helper}{quarantine_snapshots};
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
is(ReadingsVal($child->{NAME}, 'state', ''), 'off',
   'partial live node attributes override only matching snapshot attribute');
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
    attributes => { '1/59/0' => 0, '1/29/0' => [{ '0' => 0x000F, '1' => 1 }] }
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
is(MATTERDevice_Set($fan, $fan->{NAME}, 'fan_mode', 'high'), undef,
   'fan mode is set with native attribute write');
is($sent_requests[-1]{args}{value}, 3,
   'fan high maps to native enum value 3');
is(MATTERDevice_Set($identify, $identify->{NAME}, 'identify'), undef,
   'Identify command accepted');
is($sent_requests[-1]{args}{command_name}, 'Identify',
   'native Identify command used');
is($sent_requests[-1]{args}{payload}{identifyTime}, 15,
   'Identify lasts 15 seconds');
like(MATTERDevice_Set($fan, $fan->{NAME}, 'fan_pct', '300') // '',
   qr/between 0 and 100/, 'invalid fan target is rejected');


# Issue #27: cache quarantine is node-wide, preserves manual edits and all
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
MATTER_ProcessNode($defs{ioA}, {
    node_id => 2700, available => JSON::true,
    attributes => { '1/6/0' => JSON::true, '1/47/12' => 190 },
});
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'off',
   'availability true with cached snapshot cannot overwrite manual state');
is(ReadingsVal($offline_child->{NAME}, 'battery_percent', ''), 10,
   'cached battery remains quarantined after available true');
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'attribute_updated', data => [2700, '1/6/0', JSON::true]
}));
is(ReadingsVal($offline_child->{NAME}, 'state', ''), 'on',
   'new live report releases state for its specific attribute');
is(ReadingsVal($offline_child->{NAME}, 'battery_percent', ''), 10,
   'unreported battery still preserves its manual value');
is(ReadingsVal($offline_root->{NAME}, 'state', ''), 'online',
   'root availability remains independent from endpoint state');

done_testing();
