# $Id$
package main;
use strict;
use warnings;

use HttpUtils;
use Time::Piece;
use Encode qw(encode_utf8);
use JSON;
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_ERROR);
use MIME::Base64;
use Digest::SHA qw(sha1_base64);

our $readingFnAttributes;

my $MATTER_version = "V0.48 27.11.2026";

my $MATTER_connect_timeout = 10; # TCP connection plus WebSocket upgrade
my $MATTER_ping_interval = 30;
my $MATTER_pong_timeout = 15;
my $MATTER_reconnect_delay = 30;

my %MATTER_sets = (
    "connect"  => "noArg",
    "discover" => "noArg",
    "commissionCode"   => "textField",
    "setWifiCredentials" => "textField",
    "getCredentials"  => "noArg",
);

sub MATTER_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}      = \&MATTER_Define;
    $hash->{UndefFn}    = \&MATTER_Undef;
    $hash->{SetFn}      = \&MATTER_Set;
    $hash->{AttrFn}     = \&MATTER_Attr;
    $hash->{RenameFn}   = \&MATTER_Rename;
    $hash->{ReadFn}     = \&MATTER_Read;
    $hash->{Clients}    = ":MATTERDevice:";
    $hash->{MatchList}  = { "1" => ".*" };

    $hash->{AttrList} = "disable:0,1 autocreate:0,1 commissionMode:network,auto " . $readingFnAttributes;

    # CommandReload calls Initialize, not Define, for existing devices.
    for my $device (values %defs) {
        next unless ($device->{TYPE} // '') eq 'MATTER';
        $device->{FVERSION} = $MATTER_version;
        delete $device->{VERSION};
    }
}

sub MATTER_Define {
    my ($hash, $def) = @_;
    my @param = split('[ \t]+', $def);
    
    if (@param != 4 || $param[3] !~ /^\d+$/ || $param[3] < 1 || $param[3] > 65535) {
        return "too few parameters: define <name> MATTER <IP> <PORT>";    
    }
    
    my $name = $param[0];
    $hash->{ip}   = $param[2];
    $hash->{port} = $param[3] // 5580;

    $hash->{STATE}    = "defined";
    $hash->{FVERSION} = $MATTER_version;
    
    # A connection started during FHEM configuration loading cannot be
    # processed by the socket event loop yet. An already-expired handshake
    # timer would cause a needless 30-second reconnect delay after startup.
    # Close previous resources on modify and defer opening until the main loop.
    MATTER_Close($hash);
    InternalTimer(1, 'MATTER_Open', $hash, 0);
    return undef;
}

sub MATTER_Undef {
    my ($hash, $arg) = @_;
    MATTER_Close($hash); # Also removes all connect, heartbeat and retry timers.
    return undef;
}

# FHEM changes the IO name before RenameFn and does not rewrite client IODev
# attributes or custom defptr keys. Keep the existing connection and ownership.
sub MATTER_Rename {
    my ($new, $old) = @_;
    my $hash = $defs{$new};
    return unless $hash;
    if (($selectlist{$old} // '') eq $hash) {
        delete $selectlist{$old};
        $selectlist{$new} = $hash if defined $hash->{FD};
    }
    foreach my $device (values %defs) {
        next unless ($device->{TYPE} // '') eq 'MATTERDevice';
        my $configured = AttrVal($device->{NAME}, 'IODev', '');
        next unless (($device->{IODev} // '') eq $hash) || $configured eq $old;
        if (($device->{endpoint_id} // 0) == 0 && ($device->{IODev} // '') eq $hash) {
            my $node_id = $device->{node_id};
            my $old_key = "$old:$node_id";
            delete $modules{MATTERDevice}{defptr}{$old_key}
                if ($modules{MATTERDevice}{defptr}{$old_key} // '') eq $device;
            $modules{MATTERDevice}{defptr}{"$new:$node_id"} = $device;
        }
        if ($configured eq $old || (!$configured && ($device->{IODev} // '') eq $hash)) {
            # A previously auto-assigned client needs an explicit new IODev
            # name so restart cannot silently select a different Matter IO.
            my $error = CommandAttr(undef, "$device->{NAME} IODev $new");
            Log3 $new, 2, "MATTER: Cannot update IODev for $device->{NAME}: $error" if $error;
        }

    }
    return undef;
}

# Shared, monotonic request IDs avoid collisions across discovery, reads,
# commissioning and device commands on the same WebSocket.
sub MATTER_NextMessageId {
    my ($hash) = @_;
    return undef unless $hash;
    for (1 .. 1000) {
        my $id = ($hash->{helper}{next_message_id} // 0) + 1;
        $id = 1 if $id > 2147483647;
        $hash->{helper}{next_message_id} = $id;
        next if exists($hash->{helper}{pending_command}{$id}) ||
                exists($hash->{helper}{pending_config}{$id});
        return $id;
    }
    return undef;
}

sub MATTER_Set {
    my ($hash, $name, $opt, @args) = @_;

    if ($opt eq "connect") {
        MATTER_Open($hash);
        return undef;
    } 
    elsif ($opt eq "discover") {
        return "MATTER: No active WebSocket connection on $name"
            unless $hash->{CD} && $hash->{websocket} && ($hash->{ws_status} // '') eq 'connected';
        my $msg_id = MATTER_NextMessageId($hash);
        return "MATTER: Cannot allocate request ID" unless defined($msg_id);
        $hash->{helper}{pending_command}{$msg_id} = "get_nodes";

        my $payload = {
            message_id => $msg_id,
            command    => "get_nodes"
        };
        
        Log3 $name, 3, "MATTER: Requesting node list from server...";
        unless (MATTER_SendJsonCommand($hash, $payload)) {
            delete $hash->{helper}{pending_command}{$msg_id};
            return "MATTER: Cannot send discovery request on $name";
        }
        # Only the latest discovery snapshot may be applied. Supersede
        # unanswered previous snapshots without adding another timeout.
        foreach my $previous_id (keys %{$hash->{helper}{pending_command}}) {
            next if $previous_id eq $msg_id;
            my $previous = $hash->{helper}{pending_command}{$previous_id};
            next unless $previous eq 'get_nodes' || $previous eq 'start_listening';
            delete $hash->{helper}{pending_command}{$previous_id};
            delete $hash->{helper}{pending_snapshot_touched}{$previous_id};
        }
        return undef;
    }
    elsif ($opt eq "commissionCode") {
        # A configured IO attribute determines the default; explicit mode wins.
        # 'auto' allows the server to discover the device via BLE as well as IP.
        my ($setup_code, $mode) = @args;
        my $usage = "Usage: set $name commissionCode <manual-code|MT:QR-code> [network|auto]";
        return $usage unless defined($setup_code) && @args <= 2;
        $mode //= AttrVal($name, 'commissionMode', 'network');
        return $usage unless $mode eq 'network' || $mode eq 'auto';

        # Matter manual codes have 11 or 21 decimal digits; QR payloads use
        # Base38. Do not echo an invalid pairing code in errors or logs.
        my $valid_manual = $setup_code =~ /\A(?:[0-9]{11}|[0-9]{21})\z/;
        my $valid_qr = length($setup_code) <= 2048 &&
            $setup_code =~ /\AMT:[0-9A-Z.\-]+\z/;
        return "Invalid Matter pairing code; expected 11/21 digits or an MT: QR code"
            unless $valid_manual || $valid_qr;

        # One in-flight attempt per IO keeps status and result unambiguous.
        return "MATTER: Commissioning already in progress on $name"
            if $hash->{helper}{commissioning_active};
        return "MATTER: No active WebSocket connection for commissioning on $name"
            unless $hash->{CD} && $hash->{websocket} &&
                ($hash->{ws_status} // '') eq 'connected';

        my $msg_id = MATTER_NextMessageId($hash);
        return "MATTER: Cannot allocate request ID" unless defined($msg_id);
        $hash->{helper}{pending_command}{$msg_id} = "commission";
        $hash->{helper}{commissioning_active} = {
            message_id => $msg_id, mode => $mode, started_at => gettimeofday()
        };

        my $payload = {
            message_id => $msg_id,
            command    => "commission_with_code",
            args       => {
                code         => $setup_code,
                network_only => $mode eq 'network' ? JSON::true : JSON::false
            }
        };

        MATTER_CommissioningReadings($hash, 'running', $mode, '', '', '');
        Log3 $name, 3, "MATTER: Commissioning requested (mode=$mode; BLE " .
            ($mode eq 'auto' ? "allowed" : "disabled") . ")";
        unless (MATTER_SendJsonCommand($hash, $payload)) {
            # A synchronous FHEM event may have closed the socket after the
            # preflight check. Do not leave a running request with no send.
            if (my $active = delete $hash->{helper}{commissioning_active}) {
                delete $hash->{helper}{pending_command}{$msg_id};
                MATTER_CommissioningReadings($hash, 'interrupted', $mode, '',
                    MATTER_CommissioningDuration($active->{started_at}),
                    'Commissioning could not be sent; outcome unknown');
            }
            return "MATTER: Unable to send commissioning request on $name";
        }
        # FHEM's DoSet would otherwise synthesize a "set commissionCode <code>"
        # event and expose the setup code to event consumers and DbLog.
        return wantarray ? (undef, 1) : undef;
    }
    elsif ($opt eq "setWifiCredentials") {
        # Wir holen den kompletten String aus @args
        my $full_arg_string = join(" ", @args);
        
        # Beispiel-Input: "FRITZ!Box 7530" geheim_passwort 1
        # Wir trennen am ersten Leerzeichen, es sei denn es ist in Anführungszeichen
        my ($ssid, $credentials, $id);
        
        if ($full_arg_string =~ /^"(.*?)"\s+(.*)$/ || $full_arg_string =~ /^'(.*?)'\s+(.*)$/) {
            $ssid = $1;
            my $rest = $2;
            # Rest aufteilen in Passwort und optionale ID
            my @parts = split(" ", $rest);
            $id = pop @parts if (@parts > 1 && $parts[-1] =~ /^\d+$/);
            $credentials = join(" ", @parts);
        } else {
            # Fallback, falls keine Anführungszeichen da waren
            my @parts = split(" ", $full_arg_string);
            $ssid = shift @parts;
            $id = pop @parts if (@parts > 1 && $parts[-1] =~ /^\d+$/);
            $credentials = join(" ", @parts);
        }

        # Zur Sicherheit: Falls doch irgendwo Anführungszeichen hängen geblieben sind, hart entfernen
        $ssid =~ s/^["']|["']$//g if defined($ssid);
        $credentials =~ s/^["']|["']$//g if defined($credentials);

        return "Please provide SSID and credentials. Usage: set <dev> setWifiCredentials \"SSID\" Password [ID]" if (!$ssid || !$credentials);

        return "MATTER: No active WebSocket connection on $name"
            unless $hash->{CD} && $hash->{websocket} && ($hash->{ws_status} // '') eq 'connected';
        my $msg_id = MATTER_NextMessageId($hash);
        return "MATTER: Cannot allocate request ID" unless defined($msg_id);
        $hash->{helper}{pending_command}{$msg_id} = "set_wifi_credentials";
        
        my $payload = {
            message_id => $msg_id,
            command    => "set_wifi_credentials",
            args       => {
                ssid        => $ssid,
                credentials => $credentials,
            }
        };
        
        $payload->{args}{id} = int($id) if (defined($id) && $id ne '');

        Log3 $name, 3, "MATTER: Sending Wi-Fi credentials (ID: " . ($id // 'default') . ")";
        unless (MATTER_SendJsonCommand($hash, $payload)) {
            delete $hash->{helper}{pending_command}{$msg_id};
            return "MATTER: Cannot send Wi-Fi credentials on $name";
        }
        # DoSet would otherwise publish the plaintext SSID/password as a set event.
        return wantarray ? (undef, 1) : undef;
    }
    elsif ($opt eq "getCredentials") {
        return "MATTER: No active WebSocket connection on $name"
            unless $hash->{CD} && $hash->{websocket} && ($hash->{ws_status} // '') eq 'connected';
        my $msg_id = MATTER_NextMessageId($hash);
        return "MATTER: Cannot allocate request ID" unless defined($msg_id);
        $hash->{helper}{pending_command}{$msg_id} = "get_all_credentials";

        # Payload für den python-matter-server aufbauen
        my $payload = {
            message_id => $msg_id,
            command    => "get_all_credentials",
        };

        Log3 $name, 3, "MATTER: Get credentials...";
        unless (MATTER_SendJsonCommand($hash, $payload)) {
            delete $hash->{helper}{pending_command}{$msg_id};
            return "MATTER: Cannot send credential request on $name";
        }
        return undef;
    }
    else {
        my @cList = keys %MATTER_sets;
        return "Unknown argument $opt, choose one of " . join(" ", @cList);
    }
}

# Commissioning status is independent of the IO's connection state.
sub MATTER_CommissioningReadings {
    my ($hash, $status, $mode, $node_id, $duration, $error) = @_;
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'commissioningStatus', $status);
    readingsBulkUpdate($hash, 'commissioningMode', $mode);
    readingsBulkUpdate($hash, 'commissioningNodeId', $node_id);
    readingsBulkUpdate($hash, 'commissioningDuration', $duration);
    readingsBulkUpdate($hash, 'commissioningError', $error);
    readingsEndUpdate($hash, 1);
}

sub MATTER_CommissioningDuration {
    my ($started_at) = @_;
    my $elapsed = gettimeofday() - $started_at;
    return $elapsed > 0 ? int($elapsed + 0.5) : 0;
}

sub MATTER_Attr {
    my ($cmd, $name, $attr_name, $attr_value) = @_;
    if ($attr_name eq 'commissionMode') {
        return "commissionMode must be network or auto"
            if $cmd eq 'set' &&
               (!defined($attr_value) || ($attr_value ne 'network' && $attr_value ne 'auto'));
        return undef;
    }
    return undef unless $attr_name eq 'disable';
    my $hash = $defs{$name};
    return undef unless $hash;

    # FHEM calls AttrFn before storing the attribute. Reconnect from a timer
    # so MATTER_Open sees the updated AttrVal rather than the previous value.
    if ($cmd eq 'set' && defined($attr_value) && $attr_value eq '1') {
        $hash->{helper}{disable_requested} = 1;
        MATTER_Close($hash);
        delete $hash->{helper}{connect_attempts};
        Log3 $name, 3, "[$name] Disabled: connection closed, pending timers cancelled";
    } elsif (($cmd eq 'set' && defined($attr_value) && $attr_value eq '0')
             || $cmd eq 'del') {
        delete $hash->{helper}{disable_requested};
        unless ($hash->{CD}) {
            RemoveInternalTimer($hash);
            InternalTimer(gettimeofday() + 0.01, 'MATTER_Open', $hash, 0);
            Log3 $name, 3, "[$name] Enabled: connection attempt scheduled";
        }
    }
    return undef;
}

sub MATTER_Open($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $host = $hash->{ip};
    my $port = $hash->{port};

    return if $hash->{helper}{closing} || $hash->{helper}{disable_requested};
    MATTER_Close($hash);
    return if AttrVal($name, 'disable', 0);

    my $attempt = ++$hash->{helper}{connect_attempts};
    Log3 $name, 3, "[$name] TCP connect attempt $attempt to $host:$port";
    # Blocking=>0 returns during EINPROGRESS instead of waiting for TCP.
    # FHEM uses directWriteFn to finish the asynchronous connection.
    # A numeric IP avoids a potentially blocking DNS lookup.
    my $socket = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Blocking => 0,
    );
    unless ($socket) {
        Log3 $name, 2, "[$name] TCP connect failed: $!";
        InternalTimer(gettimeofday() + $MATTER_reconnect_delay, 'MATTER_Open', $hash, 0);
        return;
    }

    $hash->{CD} = $socket;
    $hash->{FD} = $socket->fileno();
    $hash->{BUF} = '';
    $hash->{websocket} = 0;
    $hash->{ws_status} = 'tcp_connecting';
    $hash->{directWriteFn} = \&MATTER_ConnectWritable;
    $selectlist{$name} = $hash;
    readingsSingleUpdate($hash, 'state', 'connecting', 1);
    InternalTimer(gettimeofday() + $MATTER_connect_timeout,
                  'MATTER_ConnectTimeout', $hash, 0);
}

sub MATTER_ConnectWritable($) {
    my ($hash) = @_;
    my $socket = $hash->{CD};
    return unless $socket && ($hash->{ws_status} // '') eq 'tcp_connecting';

    # A writable socket may mean a failed connect; inspect SO_ERROR.
    my $error = getsockopt($socket, SOL_SOCKET, SO_ERROR);
    my $code = defined($error) ? unpack('i', $error) : undef;
    if (!defined($code) || $code || !getpeername($socket)) {
        my $reason = 'socket has no connected peer';
        if (!defined($code)) {
            $reason = "SO_ERROR failed: $!";
        } elsif ($code) {
            local $! = $code;
            $reason = "$! (errno $code)";
        }
        Log3 $hash->{NAME}, 2, "[$hash->{NAME}] TCP connect failed: $reason";
        MATTER_Reconnect($hash);
        return;
    }
    Log3 $hash->{NAME}, 4, "[$hash->{NAME}] TCP connected; starting WebSocket upgrade";

    delete $hash->{directWriteFn};
    $hash->{ws_status} = 'handshake';
    my $host = $hash->{ip};
    my $port = $hash->{port};
    my $key = encode_base64(pack('C*', map { int(rand(256)) } 1 .. 16), '');
    $hash->{helper}{ws_expected_accept} = sha1_base64(
        $key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
    ) . '=';
    my $request = "GET /ws HTTP/1.1\r\n" .
                  "Host: $host:$port\r\n" .
                  "Upgrade: websocket\r\n" .
                  "Connection: Upgrade\r\n" .
                  "Sec-WebSocket-Key: $key\r\n" .
                  "Sec-WebSocket-Version: 13\r\n" .
                  "Origin: http://$host:$port\r\n\r\n";
    Log3 $hash->{NAME}, 4, "[$hash->{NAME}] WebSocket upgrade request queued";
    MATTER_QueueBytes($hash, $request);
}

sub MATTER_ConnectTimeout($) {
    my ($hash) = @_;
    return unless $hash->{CD} &&
        ($hash->{ws_status} // '') =~ /^(?:tcp_connecting|handshake)$/;
    my $phase = $hash->{ws_status} eq 'tcp_connecting'
        ? 'TCP connect' : 'WebSocket upgrade';
    Log3 $hash->{NAME}, 2, "[$hash->{NAME}] $phase timed out after $MATTER_connect_timeout seconds";
    MATTER_Reconnect($hash);
}

sub MATTER_Close($) {
    my ($hash) = @_;
    return if $hash->{helper}{closing};
    $hash->{helper}{closing} = 1;
    my $name = $hash->{NAME};
    my $previous = $hash->{CD} ? ($hash->{ws_status} // 'unknown') : undef;
    my $active = delete $hash->{helper}{commissioning_active};

    # Release all transport ownership before publishing an event: FHEM notify
    # callbacks may reenter MATTER_Set or MATTER_Open synchronously.
    RemoveInternalTimer($hash);
    delete $selectlist{$name} if ($selectlist{$name} // '') eq $hash;
    if ($hash->{CD}) {
        close($hash->{CD});
        delete $hash->{CD};
    }
    delete $hash->{FD};
    delete $hash->{directWriteFn};
    delete $hash->{wantWrite};
    delete $hash->{helper}{write_buffer};
    delete $hash->{helper}{pending_pong};
    delete $hash->{helper}{ws_expected_accept};
    delete $hash->{helper}{ws_fragment_opcode};
    delete $hash->{helper}{ws_fragment_buffer};
    delete @{$hash->{helper}}{qw(icd_api_supported ota_api_supported)};
    $hash->{websocket} = 0;
    $hash->{ws_status} = 'disconnected';
    $hash->{BUF} = '';
    my @incomplete_node_ops = grep {
        ref($_) eq 'HASH' && ($_->{type} // '') eq 'node_operation'
    } values %{$hash->{helper}{pending_command} // {}};
    delete $hash->{helper}{pending_command};
    delete $hash->{helper}{pending_config};
    delete $hash->{helper}{pending_snapshot_touched};
    Log3 $name, 4, "[$name] Connection closed (was $previous)" if defined($previous);
    # A lost IO connection invalidates current reachability, but not the last
    # server-reported 'available' reading or any endpoint's device state.
    # Invalidate all owned roots before publishing the first reading event.
    my @roots = grep {
        ($_->{TYPE} // '') eq 'MATTERDevice' &&
        ($_->{endpoint_id} // 0) == 0 &&
        ($_->{IODev} ? $_->{IODev} eq $hash
                     : AttrVal($_->{NAME}, 'IODev', '') eq $name)
    } values %defs;
    MATTERDevice_InvalidateAvailability($_) for @roots;
    readingsSingleUpdate($hash, 'state', 'disconnected', 1)
        if ReadingsVal($name, 'state', '') ne 'disconnected';
    MATTERDevice_SetRootState($_, 'unknown') for @roots;
    # A server reconnect invalidates old OTA offers even if no update request
    # was pending. Installing a version requires a fresh server check.
    for my $dev (@roots) {
        my $offer = delete $dev->{helper}{firmware_available};
        my $target = delete $dev->{helper}{firmware_update_in_flight};
        readingsSingleUpdate($dev, 'firmwareUpdate', 'unknown (server disconnected)', 1)
            if defined($offer) || defined($target);
    }
    MATTERDevice_CompleteRequest($hash, $_, undef,
        'interrupted (outcome unknown)') for @incomplete_node_ops;
    if ($active) {
        MATTER_CommissioningReadings($hash, 'interrupted', $active->{mode}, '',
            MATTER_CommissioningDuration($active->{started_at}),
            'Connection lost before commissioning result; outcome unknown');
    }
    delete $hash->{helper}{closing};
}

sub MATTER_Reconnect($) {
    my ($hash) = @_;
    MATTER_Close($hash);
    unless (AttrVal($hash->{NAME}, 'disable', 0)) {
        InternalTimer(gettimeofday() + $MATTER_reconnect_delay, 'MATTER_Open', $hash, 0);
        Log3 $hash->{NAME}, 3,
             "[$hash->{NAME}] Reconnect scheduled in $MATTER_reconnect_delay seconds";
    }
}

sub MATTER_Heartbeat($) {
    my ($hash) = @_;
    return unless $hash->{CD} && ($hash->{ws_status} // '') eq 'connected';

    # Reject timed-out asynchronous node operations; late replies are ignored.
    for my $id (keys %{$hash->{helper}{pending_command} // {}}) {
        my $p = $hash->{helper}{pending_command}{$id};
        next unless ref($p) eq 'HASH' &&
                    ($p->{type} // '') eq 'node_operation';
        next unless gettimeofday() - ($p->{started_at} // 0) >
                    ($p->{timeout} // 120);
        delete $hash->{helper}{pending_command}{$id};
        MATTERDevice_CompleteRequest($hash, $p, undef,
            'timeout (outcome unknown)');
    }
    if (defined($hash->{helper}{pending_pong})) {
        Log3 $hash->{NAME}, 2, "[$hash->{NAME}] WebSocket pong timeout after $MATTER_pong_timeout seconds; reconnecting";
        MATTER_Reconnect($hash);
        return;
    }

    my $token = pack('N', int(rand(4294967296)));
    $hash->{helper}{pending_pong} = $token;
    MATTER_SendWebSocketFrame($hash, 0x9, $token);
    return unless $hash->{CD} && ($hash->{ws_status} // '') eq 'connected';
    InternalTimer(gettimeofday() + $MATTER_pong_timeout,
                  'MATTER_Heartbeat', $hash, 0);
}

# Handle partial writes on nonblocking sockets in FHEM's writable event loop.
sub MATTER_QueueBytes($$) {
    my ($hash, $bytes) = @_;
    return 0 unless $hash->{CD};
    $hash->{helper}{write_buffer} .= $bytes;
    MATTER_FlushWrite($hash);
    return $hash->{CD} && ($hash->{ws_status} // '') ne 'disconnected' ? 1 : 0;
}

sub MATTER_FlushWrite($) {
    my ($hash) = @_;
    return unless $hash->{CD};
    my $pending = $hash->{helper}{write_buffer} // '';
    unless (length($pending)) {
        delete $hash->{directWriteFn};
        return;
    }

    # Limit each write callback to one chunk to avoid monopolizing FHEM's loop.
    my $chunk = substr($pending, 0, 65536);
    my $sent = syswrite($hash->{CD}, $chunk);
    if (!defined($sent)) {
        if ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR}) {
            $hash->{directWriteFn} = \&MATTER_FlushWrite;
            return;
        }
        Log3 $hash->{NAME}, 2, "[$hash->{NAME}] WebSocket write failed: $!";
        MATTER_Reconnect($hash);
        return;
    }
    unless ($sent) {
        Log3 $hash->{NAME}, 2, "[$hash->{NAME}] WebSocket write returned EOF";
        MATTER_Reconnect($hash);
        return;
    }
    substr($hash->{helper}{write_buffer}, 0, $sent, '');
    if (length($hash->{helper}{write_buffer})) {
        $hash->{directWriteFn} = \&MATTER_FlushWrite;
    } else {
        delete $hash->{directWriteFn};
    }
}

sub MATTER_Read {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $socket = $hash->{CD};
    return unless $socket;

    my $buf = '';
    my $n = sysread($socket, $buf, 65536);
    return if !defined($n) && ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR});
    if (!defined($n) || $n == 0) {
        Log3 $name, 2, "[$name] Connection lost, retrying in $MATTER_reconnect_delay seconds";
        MATTER_Reconnect($hash);
        return;
    }
    $hash->{BUF} .= $buf;

    if (($hash->{ws_status} // '') eq 'handshake') {
        unless ($hash->{BUF} =~ m/\x0d\x0a\x0d\x0a/) {
            if (length($hash->{BUF}) > 8192) {
                Log3 $name, 2, "[$name] WebSocket HTTP handshake exceeds 8192 bytes";
                MATTER_Reconnect($hash);
            }
            return;
        }
        my $header_end = index($hash->{BUF}, "\r\n\r\n");
        if ($header_end > 8192) {
            Log3 $name, 2, "[$name] WebSocket HTTP handshake exceeds 8192 bytes";
            MATTER_Reconnect($hash);
            return;
        }
        my $headers = substr($hash->{BUF}, 0, $header_end + 4, '');
        my $accept = $hash->{helper}{ws_expected_accept} // '';
        unless ($headers =~ m/^HTTP\/1\.[01]\s+101\b/i &&
                $headers =~ m/^Upgrade:\s*websocket\s*\r?$/im &&
                $headers =~ m/^Connection:\s*[^\r\n]*\bUpgrade\b[^\r\n]*\r?$/im &&
                $headers =~ m/^Sec-WebSocket-Accept:\s*\Q$accept\E\s*\r?$/im &&
                length($accept)) {
            Log3 $name, 2, "[$name] Invalid WebSocket upgrade response";
            MATTER_Reconnect($hash);
            return;
        }
        delete $hash->{helper}{ws_expected_accept};
        RemoveInternalTimer($hash, 'MATTER_ConnectTimeout');
        $hash->{ws_status} = 'connected';
        $hash->{websocket} = 1;
        readingsSingleUpdate($hash, 'state', 'connected', 1);
        return unless $hash->{CD} && ($hash->{ws_status} // '') eq 'connected';
        my $attempts = delete($hash->{helper}{connect_attempts}) // 1;
        Log3 $name, 3, "[$name] WebSocket connected (attempt $attempts); restarting node listening";
        InternalTimer(gettimeofday() + $MATTER_ping_interval,
                      'MATTER_Heartbeat', $hash, 0);
        $hash->{helper}{pending_command}{fhem_init_1} = 'start_listening';
        MATTER_SendJsonCommand($hash, { message_id => 'fhem_init_1', command => 'start_listening' });
    }

    while (length($hash->{BUF}) >= 2) {
        my ($b1, $b2) = unpack('CC', substr($hash->{BUF}, 0, 2));
        my $fin = ($b1 & 0x80) != 0;
        my $opcode = $b1 & 0x0f;
        my $payload_len = $b2 & 0x7f;
        my $header_len = 2;
        if (($b1 & 0x70) || ($b2 & 0x80)) {
            Log3 $name, 2, "[$name] Invalid WebSocket frame flags or server masking";
            MATTER_Reconnect($hash);
            return;
        }
        if ($payload_len == 126) {
            return if length($hash->{BUF}) < 4;
            $payload_len = unpack('n', substr($hash->{BUF}, 2, 2));
            $header_len = 4;
        } elsif ($payload_len == 127) {
            return if length($hash->{BUF}) < 10;
            my @l_bytes = unpack('NN', substr($hash->{BUF}, 2, 8));
            $payload_len = ($l_bytes[0] * 4294967296) + $l_bytes[1];
            $header_len = 10;
        }
        if ($payload_len > 32 * 1024 * 1024 ||
            ($opcode >= 0x8 && (!$fin || $payload_len > 125))) {
            Log3 $name, 2, "[$name] Invalid or oversized WebSocket frame";
            MATTER_Reconnect($hash);
            return;
        }
        my $total_len = $header_len + $payload_len;
        return if length($hash->{BUF}) < $total_len;
        my $payload = substr($hash->{BUF}, $header_len, $payload_len);
        substr($hash->{BUF}, 0, $total_len) = '';

        if ($opcode == 0x1) {
            if (exists $hash->{helper}{ws_fragment_opcode}) {
                Log3 $name, 2, "[$name] Unexpected WebSocket text frame during fragmentation";
                MATTER_Reconnect($hash);
                return;
            }
            if ($fin) {
                MATTER_ParseMessage($hash, $payload);
            } else {
                $hash->{helper}{ws_fragment_opcode} = 0x1;
                $hash->{helper}{ws_fragment_buffer} = $payload;
            }
        } elsif ($opcode == 0x0) {
            unless (exists $hash->{helper}{ws_fragment_opcode}) {
                Log3 $name, 2, "[$name] Unexpected WebSocket continuation frame";
                MATTER_Reconnect($hash);
                return;
            }
            $hash->{helper}{ws_fragment_buffer} .= $payload;
            if (length($hash->{helper}{ws_fragment_buffer}) > 32 * 1024 * 1024) {
                Log3 $name, 2, "[$name] Fragmented WebSocket message exceeds 32 MiB";
                MATTER_Reconnect($hash);
                return;
            }
            if ($fin) {
                my $message = delete $hash->{helper}{ws_fragment_buffer};
                delete $hash->{helper}{ws_fragment_opcode};
                MATTER_ParseMessage($hash, $message);
            }
        } elsif ($opcode == 0x9) {
            MATTER_SendWebSocketFrame($hash, 0xA, $payload);
        } elsif ($opcode == 0xA) {
            if (defined($hash->{helper}{pending_pong}) &&
                $payload eq $hash->{helper}{pending_pong}) {
                delete $hash->{helper}{pending_pong};
                RemoveInternalTimer($hash, 'MATTER_Heartbeat');
                InternalTimer(gettimeofday() + $MATTER_ping_interval,
                              'MATTER_Heartbeat', $hash, 0);
            }
        } elsif ($opcode == 0x8) {
            Log3 $name, 3, "[$name] WebSocket close received, retrying in $MATTER_reconnect_delay seconds";
            MATTER_Reconnect($hash);
            return;
        } else {
            Log3 $name, 2, "[$name] Unsupported WebSocket opcode $opcode";
            MATTER_Reconnect($hash);
            return;
        }
        # A synchronous FHEM notification may have closed the socket while
        # parsing the previous frame. Never continue on a stale buffer.
        return unless $hash->{CD} && ($hash->{ws_status} // '') eq 'connected';
    }
}

sub MATTER_SendJsonCommand($$) {
    my ($hash, $cmd_hash) = @_;
    return 0 unless $hash->{CD} && $hash->{websocket} &&
        ($hash->{ws_status} // '') eq 'connected';
    return MATTER_SendWebSocketText($hash, encode_json($cmd_hash));
}

sub MATTER_SendWebSocketText($$) {
    my ($hash, $msg) = @_;
    return MATTER_SendWebSocketFrame($hash, 0x1, $msg);
}

sub MATTER_SendWebSocketFrame($$$) {
    my ($hash, $opcode, $msg) = @_;
    return unless $hash->{CD};
    my $length = length($msg);
    my $frame = chr(0x80 | $opcode);
    if ($length <= 125) {
        $frame .= chr(0x80 | $length);
    } elsif ($length <= 65535) {
        $frame .= chr(0x80 | 126) . pack('n', $length);
    } else {
        $frame .= chr(0x80 | 127) . pack('Q>', $length);
    }
    my $mask = pack('N', int(rand(4294967296)));
    $frame .= $mask;
    my $masked_payload = '';
    for (my $i = 0; $i < $length; $i++) {
        my $m_byte = ord(substr($mask, $i % 4, 1));
        my $p_byte = ord(substr($msg, $i, 1));
        $masked_payload .= chr($p_byte ^ $m_byte);
    }
    return MATTER_QueueBytes($hash, $frame . $masked_payload);
}


# Keep existing FHEM device names and IO assignments stable during synchronization.
sub MATTER_SetNodeStatus($$$) {
    my ($hash, $node_id, $status) = @_;
    my $io_name = $hash->{NAME};
    my @devices = grep {
        ($_->{TYPE} // '') eq 'MATTERDevice' &&
        defined($_->{node_id}) && $_->{node_id} eq $node_id &&
        $_->{IODev} && $_->{IODev}{NAME} eq $io_name
    } values %defs;
    if ($status eq 'removed') {
        MATTERDevice_InvalidateAvailability($_)
            for grep { ($_->{endpoint_id} // 0) == 0 } @devices;
    }
    foreach my $device (@devices) {
        next if MATTERDevice_IsDisabled($device);
        MATTERDevice_ReadingsSingleUpdate($device, 'matterStatus', $status, 1)
            if ReadingsVal($device->{NAME}, 'matterStatus', '') ne $status;
        next unless ($device->{endpoint_id} // 0) == 0;
        if ($status eq 'removed') {
            MATTERDevice_SetRootState($device, 'removed');
        } elsif ($status eq 'present' &&
                 ReadingsVal($device->{NAME}, 'state', '') eq 'removed') {
            # Reappearance alone does not prove physical reachability.
            MATTERDevice_SetRootState($device, 'unknown');
        }
    }
}

sub MATTER_ProcessNode($$;$) {
    my ($hash, $node, $partial) = @_;
    my $io_name = $hash->{NAME};
    return unless ref($node) eq 'HASH';
    my $node_id = $node->{node_id};
    unless (defined($node_id) && !ref($node_id) && $node_id =~ /^\d+$/) {
        Log3 $io_name, 2, 'MATTER: Ignoring node without a valid node_id';
        return;
    }

    my $root_key = "$io_name:$node_id";
    my $root = MATTERDevice_LookupRoot($hash, $node_id);
    my $reconcile = !$partial || !$root;

    unless ($root) {
        # Reuse renamed roots by identity, never by the server-provided label.
        foreach my $device (values %defs) {
            next unless ($device->{TYPE} // '') eq 'MATTERDevice';
            next unless defined($device->{node_id}) && $device->{node_id} eq $node_id;
            next unless ($device->{endpoint_id} // 0) == 0;
            my $configured_io = AttrVal($device->{NAME}, 'IODev', '');
            next if $configured_io && $configured_io ne $io_name;
            next unless ($device->{IODev} && $device->{IODev}{NAME} eq $io_name)
                || $configured_io eq $io_name;
            $root = $device;
            last;
        }
    }

    if ($root && (!$root->{IODev} || $root->{IODev}{NAME} ne $io_name)) {
        # A configured IODev can survive rereadcfg while its runtime pointer is stale.
        my $error = CommandAttr(undef, "$root->{NAME} IODev $io_name");
        if ($error || !$root->{IODev} || $root->{IODev}{NAME} ne $io_name) {
            Log3 $io_name, 2, "MATTER: Cannot restore IODev of $root->{NAME}: " .
                ($error // 'wrong IODev after assignment');
            return;
        }
    }

    unless ($root) {
        # Disable FHEM device creation only; the Matter server still owns the node.
        # Previously defined nodes continue to receive status/attribute updates.
        return unless AttrVal($io_name, 'autocreate', 1);
        my $base_name = $node->{name};
        $base_name = "MatterDevice_$node_id" unless defined($base_name) && !ref($base_name) && length($base_name);
        $base_name =~ s/[^a-zA-Z0-9_.-]/_/g;
        $base_name = "MatterDevice_$node_id" unless length($base_name);
        $base_name = substr($base_name, 0, 64);
        my $device_name = "MATTER_$base_name";
        if ($defs{$device_name}) {
            $device_name = "MATTER_" . $base_name . "_" . $node_id;
            my $candidate = $device_name;
            my $suffix = 2;
            while ($defs{$device_name}) {
                $device_name = $candidate . "_" . $suffix++;
            }
        }

        my $error = CommandDefine(undef, "$device_name MATTERDevice $node_id");
        $root = $defs{$device_name};
        if ($error || !$root || ($root->{TYPE} // '') ne 'MATTERDevice' ||
            ($root->{node_id} // '') ne $node_id || ($root->{endpoint_id} // 0) != 0) {
            Log3 $io_name, 2, "MATTER: Cannot create root $device_name: " . ($error // 'invalid result');
            return;
        }

        # Use the FHEM core path to set IODev, including its attribute and reading.
        my $old_io = $root->{IODev} ? $root->{IODev}{NAME} : 'no_io';
        my $attr_error = CommandAttr(undef, "$device_name IODev $io_name");
        if ($attr_error || !$root->{IODev} || $root->{IODev}{NAME} ne $io_name) {
            Log3 $io_name, 2, "MATTER: IODev assignment failed for $device_name: " .
                ($attr_error // 'wrong IODev after assignment');
            CommandDelete(undef, $device_name);
            return;
        }
        if ($old_io ne $io_name &&
            ($modules{MATTERDevice}{defptr}{"$old_io:$node_id"} // '') eq $root) {
            delete $modules{MATTERDevice}{defptr}{"$old_io:$node_id"};
        }

        my $room_error = CommandAttr(undef, "$device_name room Matter");
        Log3 $io_name, 3, "MATTER: Cannot set default room on $device_name: $room_error" if $room_error;
        Log3 $io_name, 3, "MATTER: Created root device $device_name for node $node_id";
    }
    $modules{MATTERDevice}{defptr}{$root_key} = $root;
    MATTERDevice_EnsureTypeGroup($root) if $reconcile;

    # Parse node-wide availability and endpoint attributes through the same
    # device path. Missing availability never revives stale persisted values.
    if (exists($node->{available}) || ref($node->{attributes}) eq 'HASH') {
        my %payload = (node_id => $node_id);
        $payload{available} = $node->{available} if exists($node->{available});
        $payload{attributes} = $node->{attributes}
            if ref($node->{attributes}) eq 'HASH';
        MATTERDevice_ProcessMessage($root, \%payload);
    } else {
        MATTERDevice_RecordReceive($root, {});
    }
    # Full discovery also repairs endpoints omitted from the attribute map.
    if ($reconcile) {
        foreach my $child (MATTERDevice_NodeChildren($root)) {
            $child->{device} = $root->{NAME};
            MATTERDevice_EnsureTypeGroup($child);
            MATTERDevice_SyncNodeReadings($root, $child);
        }
    }
    MATTER_SetNodeStatus($hash, $node_id, 'present');
    return 1;
}

# Only valid live attributes can supersede a valid earlier snapshot.
# This is shared by node_updated and attribute_updated ordering checks.
sub MATTER_ValidLiveAttribute {
    my ($path, $value) = @_;
    return 0 unless defined($path) && !ref($path) &&
        $path =~ m{^(\d+)/(\d+)/(\d+)$} && defined($value);
    return defined MATTERDevice_AttributeValue($2, $3, $value, $1);
}

# Keep newer reports with the reads whose endpoints they cover.
sub MATTER_RecordPendingReadValues {
    my ($hash, $node_id, $attributes) = @_;
    return unless ref($attributes) eq 'HASH';
    foreach my $pending (values %{$hash->{helper}{pending_config} // {}}) {
        next unless $pending->{node_id} eq $node_id;
        foreach my $path (keys %$attributes) {
            next unless MATTER_ValidLiveAttribute($path, $attributes->{$path});
            my ($endpoint) = split('/', $path);
            next unless $pending->{all_endpoints} ||
                (defined($pending->{endpoint_id}) && $pending->{endpoint_id} == $endpoint);
            $pending->{live_values}{$path} = $attributes->{$path};
        }
    }
}

# Record only fields changed after a discovery request. Partial node_updated
# events (for example availability-only) must not suppress unrelated endpoint
# attributes from the older but otherwise useful full snapshot.
sub MATTER_RecordSnapshotEvent {
    my ($hash, $node_id, $event, $data) = @_;
    foreach my $id (keys %{$hash->{helper}{pending_command} // {}}) {
        my $command = $hash->{helper}{pending_command}{$id};
        next unless $command eq 'get_nodes' || $command eq 'start_listening';
        my $changed = ($hash->{helper}{pending_snapshot_touched}{$id}{$node_id} //= {});
        if ($event eq 'node_removed') {
            %$changed = (removed => 1);
            next;
        }
        delete $changed->{removed};
        next unless ref($data) eq 'HASH';
        $changed->{available} = 1
            if exists($data->{available}) &&
               defined(MATTERDevice_NormalizeBoolean($data->{available}));
        if (ref($data->{attributes}) eq 'HASH') {
            foreach my $path (keys %{$data->{attributes}}) {
                next unless MATTER_ValidLiveAttribute($path, $data->{attributes}{$path});
                $changed->{attributes}{$path} = 1;
                # Reapply the newer structural list after older cluster data,
                # so an obsolete ICD FeatureMap cannot revive removed support.
                $changed->{server_lists}{$path} = $data->{attributes}{$path}
                    if $path =~ m{/29/1$};
            }
        }
    }
}

sub MATTER_ProcessNodeList($$$;$) {
    my ($hash, $nodes, $source, $touched) = @_;
    my $io_name = $hash->{NAME};
    my %present;
    # Validate the whole snapshot before performing any mutation.
    foreach my $node (@$nodes) {
        unless (ref($node) eq 'HASH' && defined($node->{node_id}) &&
                !ref($node->{node_id}) && $node->{node_id} =~ /^\d+$/) {
            Log3 $io_name, 2, "MATTER: Invalid node in $source response, ignoring incomplete snapshot";
            return;
        }
    }
    foreach my $node (@$nodes) {
        my $node_id = $node->{node_id};
        $present{$node_id} = 1;
        my $updated = $touched ? $touched->{$node_id} : undef;
        next if $updated && $updated->{removed};
        my $to_apply = $node;
        if ($updated) {
            my %filtered = %$node;
            delete $filtered{available} if $updated->{available};
            if (ref($filtered{attributes}) eq 'HASH') {
                my %attributes = %{$filtered{attributes}};
                delete @attributes{keys %{$updated->{attributes} // {}}};
                @attributes{keys %{$updated->{server_lists} // {}}} =
                    values %{$updated->{server_lists} // {}};
                if ($updated->{excluded_endpoints}) {
                    for my $path (keys %attributes) {
                        my ($ep) = split('/', $path);
                        delete $attributes{$path} if $updated->{excluded_endpoints}{$ep};
                    }
                }
                $filtered{attributes} = \%attributes;
            }
            $to_apply = \%filtered;
        }
        MATTER_ProcessNode($hash, $to_apply);
    }

    # Full snapshots are authoritative; mark missing nodes without deleting FHEM devices.
    foreach my $device (values %defs) {
        next unless ($device->{TYPE} // '') eq 'MATTERDevice';
        next unless ($device->{endpoint_id} // 0) == 0;
        next unless $device->{IODev} && $device->{IODev}{NAME} eq $io_name;
        next if $present{$device->{node_id} // ''};
        # A later event for this same node wins; events on other nodes
        # must not suppress missing-node detection.
        my $change = $touched ? $touched->{$device->{node_id} // ''} : undef;
        # A local endpoint exclusion is not evidence that the node is present.
        next if $change && (!exists($change->{excluded_endpoints}) || keys(%$change) > 1);
        MATTER_SetNodeStatus($hash, $device->{node_id}, 'removed');
    }
    Log3 $io_name, 3, 'MATTER: Synchronized ' . scalar(keys %present) . " nodes from $source";
}

# Credential IDs form one reading-name component. Numeric IDs remain readable;
# arbitrary scalar IDs use an injective ASCII encoding rather than separators.
sub MATTER_CredentialReadingId {
    my ($id) = @_;
    return 'Default' unless defined $id;
    return $id if $id =~ /\A[0-9]+\z/;
    return 'Id' . unpack('H*', encode_utf8("$id"));
}

sub MATTER_ParseMessage($$) {
    my ($hash, $payload) = @_;
    my $name    = $hash->{NAME}; # Name des IO-Moduls (z.B. MATTER_Server1)
    
    my $decoded = eval { decode_json($payload) };
    if ($@ || ref($decoded) ne 'HASH') {
        Log3 $name, 3, "MATTER: Invalid JSON object in server response";
        return;
    }

    # A) Server-Informationen beim Connect
    if (exists $decoded->{schema_version} && exists $decoded->{sdk_version}) {
        Log3 $name, 3, "MATTER: Received server_info from Matter server.";
        # ICD controller operations are an OHF matterjs-server extension.
        # Establish support from this connection, never restored readings.
        my ($schema, $sdk) = @{$decoded}{qw(schema_version sdk_version)};
        my $js = defined($sdk) && !ref($sdk) &&
            $sdk =~ /\Amatter-server\/[^\s()]+ \(matter\.js\/[^\s()]+\)\z/;
        # Python Matter Server identifies its CHIP SDK by the package version.
        my $python_sdk = defined($sdk) && !ref($sdk) &&
            $sdk =~ /\A20[0-9]{2}\.[0-9]+\.[0-9]+(?:[a-z0-9.+-]*)\z/;
        my $valid_schema = defined($schema) && !ref($schema) && $schema =~ /\A[0-9]+\z/;
        $hash->{helper}{icd_api_supported} = $valid_schema && $js && $schema >= 12;
        $hash->{helper}{ota_api_supported} = $valid_schema &&
            (($js && $schema >= 11) || ($python_sdk && $schema >= 10));
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "state", "connected");
        readingsBulkUpdate($hash, "schemaVersion", $decoded->{schema_version});
        readingsBulkUpdate($hash, "sdkVersion", $decoded->{sdk_version});
        readingsBulkUpdate($hash, "fabricId", $decoded->{fabric_id});
        readingsBulkUpdate($hash, "bluetoothEnabled", $decoded->{bluetooth_enabled} ? "true" : "false");
        readingsEndUpdate($hash, 1);
        return;
    }

    # Structural node events are pushed by the server after start_listening.
    if (exists $decoded->{event}) {
        my $event = $decoded->{event};
        if (($event eq 'node_added' || $event eq 'node_updated') && ref($decoded->{data}) eq 'HASH') {
            my $node_id = $decoded->{data}{node_id};
            if (defined($node_id) && !ref($node_id) && $node_id =~ /^\d+$/) {
                MATTER_RecordSnapshotEvent($hash, $node_id, $event, $decoded->{data});
                MATTER_RecordPendingReadValues($hash, $node_id, $decoded->{data}{attributes})
                    if $event eq 'node_updated';
            }
            MATTER_ProcessNode($hash, $decoded->{data}, $event eq 'node_updated');
            return;
        }
        if ($event eq 'node_event' && ref($decoded->{data}) eq 'HASH') {
            my $node_id = $decoded->{data}{node_id};
            if (defined($node_id) && !ref($node_id) && $node_id =~ /^\d+$/) {
                my $root = MATTERDevice_LookupRoot($hash, $node_id);
                MATTERDevice_ProcessMessage($root, $decoded) if $root;
            }
            return;
        }
        if ($event eq 'node_removed') {
            if (defined($decoded->{data}) && !ref($decoded->{data}) && $decoded->{data} =~ /^\d+$/) {
                MATTERDevice_RecordReceive(
                    MATTERDevice_LookupRoot($hash, $decoded->{data}), {}
                );
                MATTER_RecordSnapshotEvent($hash, $decoded->{data}, $event);
                MATTER_SetNodeStatus($hash, $decoded->{data}, 'removed');
                Log3 $name, 3, "MATTER: Node $decoded->{data} removed from server; FHEM devices retained";
            }
            return;
        }
    }

    # B) Live-Events (z.B. attribute_updated) an das Root-Device der Node weiterleiten
    if (exists $decoded->{event} && $decoded->{event} eq "attribute_updated" && ref($decoded->{data}) eq 'ARRAY') {
        my ($node_id, undef, undef) = @{$decoded->{data}};
        if (defined($node_id) && !ref($node_id) && $node_id =~ /^\d+$/) {
            my $path = $decoded->{data}[1];
            if (defined($path) && !ref($path) && $path =~ m{^\d+/\d+/\d+$}) {
                my $attributes = { $path => $decoded->{data}[2] };
                MATTER_RecordSnapshotEvent($hash, $node_id, $decoded->{event},
                    { attributes => $attributes });
                MATTER_RecordPendingReadValues($hash, $node_id, $attributes);
            }
            # Wir suchen das Root-Device (Endpoint 0) exakt passend zu DIESEM IO und DIESER Node!
            my $root_hash = MATTERDevice_LookupRoot($hash, $node_id);
            
            if ($root_hash) {
                # Das Root-Device verarbeitet das Event (und reicht es an den Endpoint weiter)
                MATTERDevice_ProcessMessage($root_hash, $decoded);
            } else {
                Log3 $name, 3, "MATTER: Received event for unknown root node $node_id on IO $name";
            }
        }
        return;
    }

    # C) Antworten auf spezifische Befehle (getConfig / get_nodes)
    if (my $msg_id = $decoded->{message_id}) {
        # Antwort auf read_attribute (getConfig)
        if (my $pending = $hash->{helper}{pending_config}{$msg_id}) {
            return if $pending->{processing}; # Ignore a reentrant duplicate.
            delete $hash->{helper}{pending_config}{$msg_id};
            # Keep this reply cancellable during synchronous reading events.
            # local restores the absent entry on every exit, including errors.
            local $hash->{helper}{pending_config}{$msg_id} = $pending;
            local $pending->{processing} = 1;
            my $node_id = $pending->{node_id};
            my $received = {};
            my $owner = MATTERDevice_LookupRoot($hash, $node_id);
            my $target = exists($pending->{owner})
                ? MATTERDevice_RequestOwner($hash, $pending) : undef;
            # Correlated replies (including errors/empty results) are received
            # messages even when their device values are blocked or stale.
            # A replacement device must never inherit an old request's traffic.
            if ($owner && (!defined($pending->{root_fuuid}) ||
                ($owner->{FUUID} // '') eq $pending->{root_fuuid})) {
                MATTERDevice_RecordReceive($owner, $received);
                return if exists($pending->{owner}) && !$target;
                my %endpoints;
                $endpoints{$pending->{endpoint_id}} = 1
                    if defined($pending->{endpoint_id}) && $pending->{endpoint_id} > 0;
                if (ref($decoded->{result}) eq 'HASH') {
                    for my $path (keys %{$decoded->{result}}) {
                        next unless $path =~ m{^(\d+)/\d+/\d+$};
                        $endpoints{0 + $1} = 1 if !$target || $1 == $pending->{endpoint_id};
                    }
                }
                # Later freshness reconciliation can inject previous live
                # values. Those are not new endpoint traffic in this reply.
                $received->{endpoints} = \%endpoints;
                for my $child (MATTERDevice_NodeChildren($owner)) {
                    MATTERDevice_RecordReceive($child, $received)
                        if $endpoints{$child->{endpoint_id}};
                }
            }
            if ($owner && ref($decoded->{result}) eq 'HASH') {
                # Replies from another availability generation or a
                # replaced root cannot revive obsolete metadata.
                return if defined($pending->{root_fuuid}) &&
                    ($owner->{FUUID} // '') ne $pending->{root_fuuid};
                return if defined($pending->{availability_epoch}) &&
                    ($owner->{helper}{availability_epoch} // 0) !=
                    $pending->{availability_epoch};
                # A newer manual read or live report can complete command
                # discovery while this automatic read is still pending.
                # Never let its older reply replace already usable metadata.
                return if $pending->{capability_only} &&
                    !MATTERDevice_NeedsCapabilityRefresh($owner);
                my %fresh = %{$decoded->{result}};
                if ($pending->{live_values}) {
                    # A later live report supersedes the matching read path.
                    for my $path (keys %{$pending->{live_values}}) {
                        $fresh{$path} = $pending->{live_values}{$path};
                    }
                }
                if ($pending->{excluded_endpoints}) {
                    for my $path (keys %fresh) {
                        my ($ep) = split('/', $path);
                        delete $fresh{$path} if $pending->{excluded_endpoints}{$ep};
                    }
                }
                if ($target) {
                    for my $path (keys %fresh) {
                        my ($ep) = split('/', $path);
                        delete $fresh{$path} if $ep ne $pending->{endpoint_id};
                    }
                    $received->{request} = [$hash, $pending];
                }
                if ($pending->{capability_only}) {
                    # Automatic recovery requested global metadata only.
                    MATTERDevice_ApplyCapabilityMetadata(
                        $owner, \%fresh,
                        $pending->{all_endpoints} ? undef :
                            $pending->{endpoint_id}
                    ) if keys %fresh;
                } else {
                    MATTERDevice_ProcessMessage($target // $owner, {
                        message_id => $msg_id, result => \%fresh
                    }, $received) if keys %fresh;
                }
            }
            return;
        }
        
        # start_listening and get_nodes both return a complete node list.
        my $cmd_type = delete $hash->{helper}{pending_command}{$msg_id};
        if (ref($cmd_type) eq 'HASH' &&
            ($cmd_type->{type} // '') eq 'node_operation') {
            MATTERDevice_CompleteRequest($hash, $cmd_type, $decoded);
            return;
        }
        if ($cmd_type && ($cmd_type eq "get_nodes" || $cmd_type eq "start_listening")) {
            my $touched = delete $hash->{helper}{pending_snapshot_touched}{$msg_id};
            if (ref($decoded->{result}) eq 'ARRAY') {
                MATTER_ProcessNodeList($hash, $decoded->{result}, $cmd_type, $touched);
            } else {
                my $details = ref($decoded->{error}) eq 'HASH' ? $decoded->{error}{message} : undef;
                $details //= $decoded->{details} // 'missing or invalid node list';
                Log3 $name, 2, "MATTER: $cmd_type failed on IO $name: $details"
                    . (defined($decoded->{error_code}) ? " (code $decoded->{error_code})" : '');
            }
            return;
        }

        # A transport-accepted request is not a successful commission; only
        # the correlated server response confirms the operation.
        if ($cmd_type && $cmd_type eq "commission") {
            my $active = $hash->{helper}{commissioning_active};
            return unless $active && $active->{message_id} eq $msg_id;
            delete $hash->{helper}{commissioning_active};
            my $duration = MATTER_CommissioningDuration($active->{started_at});
            if ($decoded->{result}) {
                my $node_id = ref($decoded->{result}) eq 'HASH'
                    ? $decoded->{result}{node_id} : undef;
                $node_id = '' unless defined($node_id) && !ref($node_id) &&
                    $node_id =~ /^\d+$/;
                MATTER_CommissioningReadings($hash, 'success', $active->{mode},
                    $node_id, $duration, '');
                Log3 $name, 3, "MATTER: Device successfully commissioned on IO $name; waiting for node_added event";
            } else {
                my $details = ref($decoded->{error}) eq 'HASH'
                    ? $decoded->{error}{message} : undef;
                $details //= $decoded->{details};
                $details = "Unknown error" unless defined($details) && !ref($details);
                # Sanitize both the log and the event-visible error reading.
                $details =~ s/MT:[0-9A-Z.\-]+/[QR code redacted]/gi;
                $details =~ s/(?<![0-9])[0-9]{8,21}(?![0-9])/[code redacted]/g;
                $details =~ s/[\x00-\x1f\x7f]/ /g;
                $details = substr($details, 0, 320);
                my $reason = $decoded->{reason};
                if (defined($reason) && !ref($reason) &&
                    $reason =~ /^(?:not-discovered|passcode-mismatch|invalid-payload|attestation-rejected|timeout|other)$/) {
                    $details = "$reason: $details";
                }
                MATTER_CommissioningReadings($hash, 'failed', $active->{mode},
                    '', $duration, $details);
                Log3 $name, 2, "MATTER: Commissioning failed on IO $name: $details";
            }
            return;
        }
        elsif ($cmd_type && $cmd_type eq "set_wifi_credentials") {
            if ($decoded->{result}) {
                Log3 $name, 3, "MATTER: Wifi credentials set successfully on IO $name!";
            } else {
                Log3 $name, 2, "MATTER: Setting Wifi credentials failed on IO $name (server rejected request)";
            }
            return;
        }
        elsif ($cmd_type && $cmd_type eq "get_all_credentials") {
            my $result = $decoded->{result};
            if (ref($result) eq 'HASH' &&
                (!exists($result->{wifi}) || ref($result->{wifi}) eq 'ARRAY') &&
                (!exists($result->{thread}) || ref($result->{thread}) eq 'ARRAY')) {
                # Validate entries before deleting any old readings. Even a
                # single malformed item must not destroy the last good list.
                for my $type (qw(wifi thread)) {
                    foreach my $entry (@{$result->{$type} // []}) {
                        if (ref($entry) ne 'HASH') {
                            Log3 $name, 2, "MATTER: Invalid $type credential entry on IO $name";
                            return;
                        }
                        for my $field (qw(id ssid networkName extPanId)) {
                            if (defined($entry->{$field}) && ref($entry->{$field})) {
                                Log3 $name, 2, "MATTER: Invalid $type credential field on IO $name";
                                return;
                            }
                        }
                    }
                }
                # A rejected or malformed response must not erase the
                # last known credential inventory.
                foreach my $key (keys %{$hash->{READINGS} // {}}) {
                    readingsDelete($hash, $key) if $key =~ /\A(?:wifi(?:[0-9]+|Default|Id[0-9a-f]*)Ssid|thread(?:[0-9]+|Default|Id[0-9a-f]*)(?:Name|ExtPanId))\z/;
                }
                
                readingsBeginUpdate($hash);
                
                # Wi-Fi Credentials verarbeiten (falls vorhanden und ein Array)
                if ($result->{wifi} && ref($result->{wifi}) eq 'ARRAY') {
                    my @wifi_credentials = @{$result->{wifi}};
                    foreach my $wifi (@wifi_credentials) {
                        next unless ref($wifi) eq 'HASH';
                        my $id   = MATTER_CredentialReadingId($wifi->{id});
                        my $ssid = $wifi->{ssid} // 'unknown';
                        readingsBulkUpdate($hash, "wifi${id}Ssid", $ssid);
                    }
                }
                
                # Thread Credentials verarbeiten (falls vorhanden und ein Array)
                if ($result->{thread} && ref($result->{thread}) eq 'ARRAY') {
                    my @thread_credentials = @{$result->{thread}};
                    foreach my $thread (@thread_credentials) {
                        next unless ref($thread) eq 'HASH';
                        my $id          = MATTER_CredentialReadingId($thread->{id});
                        my $net_name    = $thread->{networkName} // 'unknown';
                        my $ext_pan_id  = $thread->{extPanId} // '';
                        
                        readingsBulkUpdate($hash, "thread${id}Name", $net_name);
                        readingsBulkUpdate($hash, "thread${id}ExtPanId", $ext_pan_id);
                    }
                }
                
                readingsEndUpdate($hash, 1);
                Log3 $name, 3, "MATTER: Credential inventory updated on IO $name";
            } else {
                Log3 $name, 2, "MATTER: Credentials request rejected or returned invalid data on IO $name";
            }
            return;
        }
    }
}

1;

=pod
=item device
=item summary    IO module for the Matter-server WebSocket/JSON API
=item summary_DE IO-Modul für die WebSocket/JSON-API des Matter-Servers

=begin html

<a id="MATTER" name="MATTER"></a>
<h3>MATTER</h3>
<p>The <code>FVERSION</code> internal identifies the loaded MATTER IO module.
MATTERDevice has its own module version, shared by all roots and endpoints.
Both modules are distributed and tested together; module versions are separate
from server and device firmware versions.</p>
<p>Module-defined readings use lowerCamelCase, including commissioningStatus, schemaVersion and credential families wifi&lt;id&gt;Ssid / thread&lt;id&gt;Name / thread&lt;id&gt;ExtPanId. Protocol JSON field names remain unchanged.</p>
<p>The MATTER IO device communicates with an external Matter server over WebSocket.
After connecting, <code>start_listening</code> supplies the complete node list.
Subsequent <code>node_added</code>, <code>node_updated</code> and <code>node_removed</code>
events synchronize logical MATTERDevice nodes and their endpoints automatically.</p>
<ul>
  <li><b>Define:</b> <code>define &lt;name&gt; MATTER &lt;IP&gt; &lt;PORT&gt;</code>
      (port required, typically 5580). The initial connection is scheduled for
      FHEM's event loop after configuration loading, so the 10-second
      handshake deadline does not run during startup.</li>
  <li><b>Set connect:</b> Reconnect the WebSocket to the server.</li>
  <li><b>Set discover:</b> Manually request a complete <code>get_nodes</code> snapshot;
      this is optional under normal operation.</li>
  <li><b>Set commissionCode:</b> <code>set &lt;IO&gt; commissionCode &lt;manual-code|MT:QR-code&gt; [network|auto]</code>.
      Without an explicit mode, IO attribute <code>commissionMode</code>
      applies (default <code>network</code> for IP-only commissioning).
      Set it to <code>auto</code> to allow BLE as well as IP discovery by
      default. Explicit <code>network</code> or <code>auto</code> overrides
      the attribute for that request. The server selects the transport
      and uses its stored Thread/Wi-Fi credentials.
      The setup code is not written to module logs; the synthetic FHEM
      set event is suppressed. Command input/history remains sensitive.
      The IO reports <code>commissioningStatus</code> (running/success/failed/interrupted),
      <code>commissioningMode</code>, <code>commissioningNodeId</code>,
      <code>commissioningDuration</code> (seconds) and <code>commissioningError</code>.
      One commissioning request can be active per IO. On connection loss
      the result is unknown; no BLE/PASE intermediate progress is exposed.</li>
  <li><b>Set setWifiCredentials:</b> Supply the Wi-Fi SSID and password to the Matter server, optionally with a numeric credential ID. The synthetic FHEM set event is suppressed for
      Wi-Fi credentials; FHEM command history and plaintext WebSocket traffic
      remain sensitive.</li>
  <li><b>Set getCredentials:</b> Request the credential inventory. FHEM publishes the Wi-Fi SSID, Thread network name and Extended PAN ID as readings.</li>
  <li><a id="MATTER-attr-commissionMode"></a><b>Attribute commissionMode (network/auto):</b> Persistent default
      for <code>commissionCode</code> when no mode argument is supplied.
      <code>network</code> uses IP discovery only; <code>auto</code> also
      allows BLE through a connected proxy when enabled on the server.
      Without the attribute, <code>network</code> applies. Explicit mode
      arguments take priority.</li>
  <li><a id="MATTER-attr-disable"></a><b>Attribute disable (0/1):</b> Default <code>0</code> (enabled).
      Disable or enable the IO connection. Setting
      <code>1</code> immediately closes the socket and cancels all pending timers;
      setting <code>0</code> or removing the attribute reconnects.</li>
  <li><a id="MATTER-attr-autocreate"></a><b>Attribute autocreate (0/1):</b> Default <code>1</code>. Set to
      <code>0</code> to suppress automatic creation of new FHEM root and endpoint
      devices from node discovery, commissioning events and attribute updates.
      Existing devices remain synchronized; the Matter server keeps its nodes.
      Re-enabling autocreate allows missing devices to be created on subsequent
      discovery/events.</li>
</ul>
<p><b>Hardware test status:</b> IP / BLE-assisted commissioning and credential
operations depend on the external Matter server and BLE proxy. Their variants
are <strong>untested</strong> in this repository unless a specific real-device
commissioning path has separately documented hardware evidence. Automated
WebSocket tests do not replace end-to-end hardware verification.</p>
<p>Newly created logical devices default to room <code>Matter</code>; existing FHEM
names and rooms are retained. Endpoint groups follow the MATTERDevice grouping rules. A removed node is marked with
<code>matterStatus=removed</code> rather than deleted. This status describes node
membership on the server, not physical device availability. The root and its endpoints mirror
<code>available</code> when the server reports a valid node-wide boolean.
The root <code>state</code> displays <code>online/offline</code> for confirmed
availability, <code>removed</code> for absent server membership, and
<code>unknown</code> after IO disconnect until a new server report arrives;
endpoint states and last reported <code>available</code> values are preserved.
The retained reading never authorizes device updates after a disconnect;
current-session availability must be reported again. See MATTERDevice's
offline protection for restart and normal online synchronization.
There is no polling. The TCP/WebSocket handshake has a 10-second deadline;
while connected, WebSocket Ping/Pong checks run every 30 seconds with a 15-second
Pong deadline. Any connection failure triggers a new attempt after 30 seconds,
without manual intervention. Numeric IPv4 addresses avoid blocking DNS lookup.
Incoming WebSocket frames larger than 32 MiB are rejected and trigger a reconnect.</p>

=end html

=begin html_DE

<a id="MATTER" name="MATTER"></a>
<h3>MATTER</h3>
<p>Das Internal <code>FVERSION</code> zeigt die Version des geladenen MATTER-IO-Moduls.
MATTERDevice hat eine eigene Modulversion für alle Roots und Endpunkte.
Beide Module werden gemeinsam ausgeliefert und geprüft; die Modulversionen
sind unabhängig von Server- und Gerätefirmwareversionen.</p>
<p>Moduleigene Readings verwenden lowerCamelCase, einschließlich commissioningStatus, schemaVersion und den Credential-Familien wifi&lt;id&gt;Ssid / thread&lt;id&gt;Name / thread&lt;id&gt;ExtPanId. JSON-Feldnamen des Protokolls bleiben unverändert.</p>
<p>Das MATTER-IO-Device verbindet FHEM per WebSocket mit einem externen Matter-Server.
Beim Verbindungsaufbau liefert <code>start_listening</code> die vollständige Node-Liste.
Danach synchronisieren <code>node_added</code>, <code>node_updated</code> und
<code>node_removed</code> die Matter-Knoten und ihre Endpunkte ereignisgesteuert.</p>
<ul>
  <li><b>Definition:</b> <code>define &lt;name&gt; MATTER &lt;IP&gt; &lt;PORT&gt;</code>
      (Portangabe erforderlich, üblicherweise 5580). Der erste Verbindungsversuch wird erst in
      FHEMs Ereignisschleife nach dem Einlesen der Konfiguration gestartet.
      Damit läuft die 10-Sekunden-Frist nicht schon während des Starts.</li>
  <li><b>Set connect:</b> Verbindung zum Matter-Server neu aufbauen.</li>
  <li><b>Set discover:</b> Optional eine vollständige Node-Liste per
      <code>get_nodes</code> erneut anfordern.</li>
  <li><b>Set commissionCode:</b> <code>set &lt;IO&gt; commissionCode &lt;Manual-Code|MT:QR-Code&gt; [network|auto]</code>.
      Ohne Modusangabe gilt das IO-Attribut <code>commissionMode</code>
      (Standard <code>network</code>, nur IP). <code>auto</code> erlaubt
      zusätzlich BLE-Discovery über einen verbundenen BLE-Proxy, sofern
      BLE am Matter-Server aktiviert ist. Ein ausdrücklich angegebenes
      <code>network</code> oder <code>auto</code> übersteuert das Attribut
      für den jeweiligen Auftrag. Der Server wählt den Transport und
      verwendet seine gespeicherten Thread-/WLAN-Zugangsdaten. Der Setup-Code wird nicht im Modul-Log
      ausgegeben; das automatische FHEM-set-Event wird unterdrückt.
      Kommandoeingabe und -verlauf bleiben vertraulich zu behandeln.
      Der IO meldet <code>commissioningStatus</code> (running/success/failed/interrupted),
      <code>commissioningMode</code>, <code>commissioningNodeId</code>,
      <code>commissioningDuration</code> (Sekunden) und <code>commissioningError</code>.
      Pro IO ist nur ein Vorgang gleichzeitig aktiv. Bei Verbindungsabbruch
      ist das Ergebnis unbekannt; einzelne BLE-/PASE-Phasen meldet der Server nicht.</li>
  <li><b>Set setWifiCredentials:</b> Übermittelt WLAN-SSID und Passwort an den Matter-Server, optional mit numerischer Zugangsdaten-ID. Das synthetische FHEM-set-Event für WLAN-
      Zugangsdaten wird unterdrückt; Eingabeverlauf und unverschlüsselter
      WebSocket-Verkehr bleiben vertraulich zu behandeln.</li>
  <li><b>Set getCredentials:</b> Fragt die hinterlegten Netzwerke ab. FHEM übernimmt WLAN-SSID, Thread-Netzname und Extended PAN ID als Readings.</li>
  <li><a id="MATTER-attr-commissionMode"></a><b>Attribut commissionMode (network/auto):</b> Dauerhafter
      Standard für <code>commissionCode</code> ohne Modusangabe.
      <code>network</code> nutzt nur IP-Discovery; <code>auto</code> erlaubt
      zusätzlich BLE über einen verbundenen Proxy, sofern am Server aktiviert.
      Ohne Attribut gilt <code>network</code>. Eine explizite Modusangabe
      im Befehl hat Vorrang.</li>
  <li><a id="MATTER-attr-disable"></a><b>Attribut disable (0/1):</b> Standard <code>0</code> (aktiviert).
      IO-Verbindung deaktivieren oder aktivieren.
      Bei <code>1</code> werden die Verbindung und alle Timer sofort beendet;
      <code>0</code> oder das Entfernen des Attributs startet einen neuen Verbindungsversuch.</li>
  <li><a id="MATTER-attr-autocreate"></a><b>Attribut autocreate (0/1):</b> Standard <code>1</code>. Mit
      <code>0</code> werden weder neue Root- noch Endpoint-Devices in FHEM
      automatisch angelegt. Bestehende Devices werden weiterhin synchronisiert;
      die Nodes auf dem Matter-Server bleiben unverändert. Nach dem erneuten
      Aktivieren können fehlende Devices beim nächsten Abgleich oder Event
      angelegt werden.</li>
</ul>
<p><b>Hardware-Teststatus:</b> IP-/BLE-Commissioning und Zugangsdatenoperationen
hängen vom externen Matter-Server und ggf. vom BLE-Proxy ab. Diese Varianten
gelten ohne dokumentierten, gerätespezifischen Hardwaretest als
<strong>ungetestet</strong>. Automatisierte WebSocket-Tests ersetzen
keinen End-to-End-Test an echter Hardware.</p>
<p>Nach einem IO-Abbruch bleibt <code>available</code> als letzte Servermeldung
erhalten, gibt aber keine Geräteupdates frei. Dafür ist eine neue gültige
Availability-Meldung in der aktuellen Verbindung erforderlich. Die
MATTERDevice-Offline-Sperre schützt auch den Wiederanlauf nach FHEM-Neustart.</p>
<p>Neue logische Geräte erhalten standardmäßig den Raum <code>Matter</code>.
Vorhandene Namen und Räume bleiben erhalten. Für Endpunktgruppen gelten die Gruppierungsregeln von MATTERDevice. Entfernte
Nodes werden mit <code>matterStatus=removed</code> markiert und nicht automatisch
gelöscht. Dieses Reading beschreibt die Mitgliedschaft auf dem Matter-Server,
nicht die physische Erreichbarkeit des Geräts. Das am Root und seinen Endpunkten geführte Reading
<code>available</code> bildet die letzte ausdrücklich gemeldete knotenweite
Erreichbarkeit ab. Der Root-<code>state</code> ist <code>online/offline</code>
bei bestätigter Verfügbarkeit, <code>removed</code> bei Entfernung aus der
Serverliste und <code>unknown</code> nach einem IO-Verbindungsverlust bis
zur nächsten gültigen Servermeldung. Die technischen Readings und Endpunkt-
Zustände bleiben erhalten; es erfolgt kein Polling. TCP-Aufbau und WebSocket-Handshake haben zusammen
10 Sekunden Zeit. Danach prüfen Ping/Pong alle 30 Sekunden die Verbindung,
wobei ein Pong spätestens nach weiteren 15 Sekunden eintreffen muss. Bei Fehlern
erfolgt automatisch alle 30 Sekunden ein Wiederverbindungsversuch. Numerische
IPv4-Adressen vermeiden eine blockierende DNS-Auflösung. Eingehende WebSocket-
Frames über 32 MiB werden abgewiesen; anschließend wird neu verbunden.</p>

=end html_DE
=cut
