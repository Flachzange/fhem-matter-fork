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

for my $name (qw(ioA ioB)) {
    $defs{$name} = { NAME => $name, TYPE => 'MATTER', READINGS => {}, helper => {} };
}

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
is(ReadingsVal('MATTER_Hall_Light_EP1', 'state', ''), 'on', 'actual attribute path reaches endpoint');
is($modules{MATTERDevice}{defptr}{'ioA:42'}, $root, 'root registered for owning IO');

$attr{MATTER_Hall_Light}{room} = 'LivingRoom';
my $count = count_devices();
MATTER_ProcessNodeList($defs{ioA}, [node(42, 'Different server label')], 'get_nodes');
is(count_devices(), $count, 'repeated snapshot does not duplicate devices');
is($attr{MATTER_Hall_Light}{room}, 'LivingRoom', 'existing room is preserved');

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

done_testing();
