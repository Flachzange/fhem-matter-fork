#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON qw(encode_json);
use IO::Socket::INET;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use vars qw(%defs %attr %modules %selectlist $readingFnAttributes);

BEGIN { $INC{'HttpUtils.pm'} = 1; } # No FHEM network stack is needed by these simulated callbacks.

my @log;
my @timers;
my %bulk_writes;
my $preferred_io = 'ioA';
my $fail_io_for = '';

sub Log3 { push @log, $_[2]; }
sub AttrVal { return exists $attr{$_[0]}{$_[1]} ? $attr{$_[0]}{$_[1]} : $_[2]; }
sub ReadingsVal {
    my ($name, $reading, $default) = @_;
    return $defs{$name}{READINGS}{$reading}{VAL} // $default;
}
sub readingsSingleUpdate {
    my ($device, $reading, $value) = @_;
    $device->{READINGS}{$reading} = { VAL => $value, TIME => 'test-time' };
}
sub readingsBeginUpdate { return; }
sub readingsBulkUpdate {
    $bulk_writes{$_[0]{NAME}}{$_[1]}++;
    readingsSingleUpdate($_[0], $_[1], $_[2]);
}
sub readingsEndUpdate { return; }
sub RemoveInternalTimer {
    my ($owner, $callback) = @_;
    @timers = grep {
        !($_->{owner} eq $owner &&
          (!defined($callback) || $_->{callback} eq $callback))
    } @timers;
}
sub InternalTimer { push @timers, { at => $_[0], callback => $_[1], owner => $_[2] }; }
sub gettimeofday { return 1; }

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
        READINGS => {}, FUUID => "uuid-$name",
    };
    $defs{$name} = $device;
    my $err = MATTERDevice_Define($device, "$name $type " . join(' ', @args));
    if ($err) { delete $defs{$name}; return $err; }
    return undef;
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

require './FHEM/97_MATTERDevice.pm';
require './FHEM/97_MATTER.pm';

# FHEM calls Initialize before Define/CommandAttr; expose the real module AttrList.
MATTERDevice_Initialize($modules{MATTERDevice} ||= {});
MATTER_Initialize($modules{MATTER} ||= {});
like($modules{MATTER}{AttrList}, qr/(?:^|\s)autocreate:0,1(?:\s|$)/,
     'MATTER IO exposes autocreate as a configurable 0/1 attribute');
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
    return { node_id => $id, name => $name, attributes => { '1/6/0' => JSON::true } };
}
sub matter_devices {
    return grep { ($_->{TYPE} // '') eq 'MATTERDevice' } values %defs;
}
sub count_devices { return scalar(matter_devices()); }

MATTER_ProcessNodeList($defs{ioA}, [node(42, 'Hall Light')], 'start_listening');
my $root = $defs{MATTER_Hall_Light};
my $child = $defs{MATTER_Hall_Light_EP1};
ok($root && $child, 'full snapshot creates root and endpoint');
is($root->{IODev}{NAME}, 'ioA', 'root IODev is correct');
is($child->{IODev}{NAME}, 'ioA', 'endpoint IODev is correct');
is($attr{MATTER_Hall_Light}{room}, 'Matter', 'new root gets default room');
is($attr{MATTER_Hall_Light_EP1}{room}, 'Matter', 'new endpoint gets default room');
is($attr{MATTER_Hall_Light}{group}, 'Node 42 (ioA)', 'root gets automatic node group');
is($attr{MATTER_Hall_Light_EP1}{group}, 'Node 42 (ioA)', 'endpoint shares node group');
my $initial_html = MATTERDevice_FWDetail('WEB', 'MATTER_Hall_Light', 'Matter');
like($initial_html, qr/href="\?detail=MATTER_Hall_Light_EP1"/,
    'root detail links to existing endpoint');
ok(!defined(MATTERDevice_FWDetail('WEB', 'MATTER_Hall_Light_EP1', 'Matter')),
    'endpoint detail does not show another endpoint overview');
is(ReadingsVal('MATTER_Hall_Light_EP1', 'state', ''), 'on', 'actual attribute path reaches endpoint');
is($modules{MATTERDevice}{defptr}{'ioA:42'}, $root, 'root registered for owning IO');

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
is($attr{MATTER_Hall_Light_EP1}{group}, 'Node 42 (ioA)',
    'discovery backfills missing group on existing endpoint');

delete $defs{MATTER_Hall_Light};
$root->{NAME} = 'ManuallyRenamedRoot';
$defs{ManuallyRenamedRoot} = $root;
$attr{ManuallyRenamedRoot} = delete $attr{MATTER_Hall_Light}; # FHEM CommandRename moves attributes too.
MATTER_ProcessNode($defs{ioA}, node(42, 'Yet another label'));
is($defs{ManuallyRenamedRoot}, $root, 'renamed root reused by identity');
is($defs{MATTER_Hall_Light_EP1}, $child, 'renamed root reuses existing endpoint');
is($child->{device}, 'ManuallyRenamedRoot', 'endpoint parent internal updated after rename');

# Migration must work without any fresh endpoint attributes.
delete $attr{MATTER_Hall_Light_EP1}{group};
my $prior_devices = count_devices();
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'Metadata only'});
is($attr{MATTER_Hall_Light_EP1}{group}, 'Node 42 (ioA)',
   'group is backfilled on an existing endpoint without an attribute map');
is(count_devices(), $prior_devices, 'group migration never recreates the endpoint');

# Persisted IODev identifies the endpoint even when its runtime pointer is missing.
delete $attr{MATTER_Hall_Light_EP1}{group};
delete $child->{IODev};
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'No endpoint attributes'});
is($attr{MATTER_Hall_Light_EP1}{group}, 'Node 42 (ioA)',
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
is($modules{MATTERDevice}{defptr}{'ioA:42'}, $root, 'other IO root registry restored after temporary AssignIoPort');
is($modules{MATTERDevice}{defptr}{'ioB:42'}, $other_root, 'new IO root registry assigned');
is($defs{MATTER_Other_IO_light_EP1}{IODev}{NAME}, 'ioB', 'new endpoint binds to matching IO');
is($attr{MATTER_Other_IO_light}{group}, 'Node 42 (ioB)',
    'same node ID under another IO gets a different group');
is($attr{MATTER_Other_IO_light_EP1}{group}, 'Node 42 (ioB)',
    'other IO endpoint shares only its own group');
my $io_a_html = MATTERDevice_FWDetail('WEB', 'ManuallyRenamedRoot', 'Matter');
unlike($io_a_html, qr/MATTER_Other_IO_light_EP1/,
    'root details exclude endpoints belonging to another IO');

delete $attr{MATTER_Hall_Light_EP1}{group};
delete $attr{MATTER_Other_IO_light_EP1}{group};
MATTER_ProcessNode($defs{ioA}, {node_id => 42, name => 'Metadata only'});
is($attr{MATTER_Hall_Light_EP1}{group}, 'Node 42 (ioA)',
   'only the matching IO endpoint is grouped during node reconciliation');
ok(!exists($attr{MATTER_Other_IO_light_EP1}{group}),
   'a same-ID endpoint belonging to another IO is not modified');
MATTER_ProcessNode($defs{ioB}, {node_id => 42, name => 'Metadata only'});
is($attr{MATTER_Other_IO_light_EP1}{group}, 'Node 42 (ioB)',
   'second IO independently migrates its own endpoint');

MATTER_ProcessNodeList($defs{ioA}, [], 'get_nodes');
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'removed', 'missing node marked removed');
ok($defs{ManuallyRenamedRoot}, 'removed node not deleted');
is(ReadingsVal('MATTER_Other_IO_light', 'matter_status', ''), 'present', 'other IO status untouched');
MATTER_ParseMessage($defs{ioA}, encode_json({event => 'node_added', data => node(42, 'Hall Light')}));
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'present', 'node_added restores status');

MATTER_ProcessNodeList($defs{ioA}, [{ node_id => 'invalid' }], 'get_nodes');
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'present', 'malformed snapshot cannot mark devices removed');

$defs{ioA}{helper}{pending_command}{17} = 'get_nodes';
MATTER_Close($defs{ioA});
ok(!exists($defs{ioA}{helper}{pending_command}), 'close clears pending commands');

# Restore logical ownership after losing runtime IODev pointers (rereadcfg/reload case).
delete $root->{IODev};
MATTER_ProcessNode($defs{ioA}, node(42, 'Hall Light'));
is($root->{IODev}{NAME}, 'ioA', 'existing root restores configured IODev');
is($defs{ManuallyRenamedRoot}, $root, 'rebind does not replace the root FUUID');
delete $child->{IODev};
MATTER_ProcessNode($defs{ioA}, node(42, 'Hall Light'));
is($child->{IODev}{NAME}, 'ioA', 'existing endpoint restores configured IODev');
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
                    '2/6/0' => JSON::false },
});
my $multiple_html = MATTERDevice_FWDetail('WEB', 'ManuallyRenamedRoot', 'Matter');
like($multiple_html, qr/MATTER_Hall_Light_EP1.*ManuallyRenamedRoot_EP2.*ManuallyRenamedRoot_EP3/s,
    'endpoint links are ordered by numeric endpoint ID after root rename');
is($attr{ManuallyRenamedRoot_EP2}{group}, 'Node 42 (ioA)',
    'new endpoint created after root rename joins the correct node group');

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
my $ws = { NAME => 'ioWS', TYPE => 'MATTER', helper => {},
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
my $wire = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n" . $frame;
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
my $http101 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
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
is(CommandAttr(undef, 'disableIO disable 1'), undef,
   'disable=1 is accepted on a running MATTER IO');
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


# Regression coverage for the integrated legacy feature branches.
MATTER_ParseMessage($defs{ioA}, encode_json({
    event => 'node_updated', data => { node_id => 42, available => JSON::false }
}));
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'false',
   'node_updated records physical unavailability on the root');
is(ReadingsVal('ManuallyRenamedRoot', 'matter_status', ''), 'present',
   'availability is independent of server membership');
MATTER_ProcessNode($defs{ioA}, { node_id => 42, name => 'Hall Light', available => JSON::true });
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'true',
   'available flag is restored by a node snapshot');
MATTER_ProcessNode($defs{ioA}, { node_id => 42, name => 'No availability field' });
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'true',
   'missing availability in a snapshot does not overwrite the previous report');
MATTER_ProcessNode($defs{ioA}, { node_id => 42, name => 'Invalid availability',
                                available => 'unknown' });
is(ReadingsVal('ManuallyRenamedRoot', 'available', ''), 'true',
   'malformed availability is ignored');
is(ReadingsVal('MATTER_Hall_Light_EP1', 'available', ''), 'true',
   'node-level availability is mirrored to the existing endpoint');

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
$defs{ioA}{fhem}{helper}{sendWS} = sub {
    push @sent_requests, JSON::decode_json($_[0]);
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
$attr{$child->{NAME}}{max_brightness} = 200;
ok(MATTERDevice_AttributeUsable($child, 8, 3),
   'legacy min/max attributes remain usable without AttributeList');
ok(grep(/^brightness:slider,0,1,200$/, MATTERDevice_GetSetList($child)),
   'existing max_brightness remains in the brightness slider without metadata');
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

MATTERDevice_Parse($types_root, encode_json({
    node_id => 88, attributes => { '10/29/0' => [{deviceType => 'invalid'}] },
}));
$type_html = MATTERDevice_FWDetail('WEB', 'MATTER_TypeDisplay', 'Matter');
like($type_html, qr/<td>10<\/td><td>0xF123<\/td>/,
     'malformed type metadata does not replace the last valid device type');

ok(!exists($defs{MATTER_TypeDisplay_EP10}{READINGS}{device_type}),
   'type presentation does not create additional readings');

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
MATTERDevice_Parse($metadata_root, encode_json({
    event => 'node_updated', data => {node_id => 95, available => 'unknown'},
}));
is(ReadingsVal($metadata_ep1->{NAME}, 'available', ''), 'true',
   'direct MATTERDevice node_updated ignores malformed availability');

# Same node ID under another MATTER IO must remain isolated.
$preferred_io = 'ioA';
MATTER_ProcessNode($defs{ioB}, {
    node_id => 95, name => 'OtherMetadataNode', available => JSON::false,
    attributes => {'0/40/3' => 'Other Model', '1/6/0' => JSON::true},
});
my $other_metadata_ep = $defs{MATTER_OtherMetadataNode_EP1};
ok($other_metadata_ep, 'a second IO may have the same Matter node ID');
is(ReadingsVal($other_metadata_ep->{NAME}, 'model', ''), 'Other Model',
   'same-ID endpoint on another IO keeps its own model');
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
MATTER_ProcessNode($defs{ioA}, {
    node_id => 95, name => 'MetadataNode', available => JSON::false,
    attributes => {'0/40/3' => 'Synthetic Model E', '4/6/0' => JSON::true},
});
is(ReadingsVal($metadata_ep1->{NAME}, 'model', ''), 'Synthetic Model E',
   'existing endpoint model updates with autocreate disabled');
is(ReadingsVal($metadata_ep2->{NAME}, 'available', ''), 'false',
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
is(ReadingsVal($metadata_ep2->{NAME}, 'available', ''), 'false',
   'attribute-free discovery restores availability on an existing endpoint');
is(CommandAttr(undef, 'MATTER_MetadataNode_EP2 IODev ioA'), undef,
   'test restores the endpoint runtime IODev pointer');


done_testing();
