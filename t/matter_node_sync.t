#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON qw(encode_json);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use vars qw(%defs %attr %modules %selectlist $readingFnAttributes);

BEGIN { $INC{'HttpUtils.pm'} = 1; } # No FHEM network stack is needed by these simulated callbacks.

my @log;
my @timers;
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
sub readingsBulkUpdate { readingsSingleUpdate($_[0], $_[1], $_[2]); }
sub readingsEndUpdate { return; }
sub RemoveInternalTimer { return; }
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
    $attr{$name}{$key} = $value;
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
like($multiple_html, qr/MATTER_Hall_Light_EP1.*MATTER_Hall_Light_EP2.*MATTER_Hall_Light_EP3/s,
    'endpoint links are ordered by numeric endpoint ID');
is($attr{MATTER_Hall_Light_EP2}{group}, 'Node 42 (ioA)',
    'new additional endpoint automatically joins node group');

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
ok(!defined(ReadingsVal('MATTER_Hall_Light_EP1', 'available', undef)),
   'node-level availability is not copied to endpoints');

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

done_testing();
