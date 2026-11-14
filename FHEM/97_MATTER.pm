# $Id$
package main;
use strict;
use warnings;

use HttpUtils;
use Time::Piece;
use JSON;
use IO::Socket::INET;
use MIME::Base64;
use Data::Dumper;

our $readingFnAttributes;

my $MATTER_version = "V0.2 22.08.2026";

my %MATTER_sets = (
    "connect"  => "noArg",
    "discover" => "noArg",
    "commissionCode"   => "textField",
    "setWifiCredentials" => "textField",
    "getCredentials"  => "noArg",
);

my %MATTER_gets = (
);

sub MATTER_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}      = \&MATTER_Define;
    $hash->{UndefFn}    = \&MATTER_Undef;
    $hash->{SetFn}      = \&MATTER_Set;
    $hash->{GetFn}      = \&MATTER_Get;
    $hash->{AttrFn}     = \&MATTER_Attr;
    $hash->{ReadFn}     = \&MATTER_Read;
    $hash->{Clients}    = ":MATTERDevice:";
    $hash->{MatchList}  = { "1" => ".*" };

    $hash->{AttrList} = "disable:0,1 autocreate:0,1 " . $readingFnAttributes;
}

sub MATTER_Define {
    my ($hash, $def) = @_;
    my @param = split('[ \t]+', $def);
    
    if (int(@param) < 4) {
        return "too few parameters: define <name> MATTER <IP> <PORT>";    
    }
    
    my $name = $param[0];
    $hash->{ip}   = $param[2];
    $hash->{port} = $param[3] // 5580;

    $hash->{STATE}    = "defined";
    $hash->{VERSION}  = $MATTER_version;
    
    # Sendefunktion für WebSocket hinterlegen
    $hash->{fhem}{helper}{sendWS} = sub {
        my ($msg) = @_;
        my $socket = $hash->{CD};
        if ($socket) {
            MATTER_SendWebSocketText($socket, $msg);
        } else {
            Log3 $hash->{NAME}, 2, "MATTER: No active WebSocket socket for sending!";
        }
    };

    MATTER_Open($hash);
    return undef;
}

sub MATTER_Undef {
    my ($hash, $arg) = @_; 
    MATTER_Close($hash);
    return undef;
}

sub MATTER_Get {
    my ($hash, $name, $cmd, @args) = @_;
    my @cList = keys %MATTER_gets;
    return "Unknown argument $cmd, choose one of " . join(" ", @cList);

}

sub MATTER_Set {
    my ($hash, $name, $opt, @args) = @_;

    if ($opt eq "connect") {
        MATTER_Open($hash);
        return undef;
    } 
    elsif ($opt eq "discover") {
        my $msg_id = int(rand(100000) + 1);
        $hash->{helper}{pending_command}{$msg_id} = "get_nodes";

        my $payload = {
            message_id => $msg_id,
            command    => "get_nodes"
        };
        
        Log3 $name, 3, "MATTER: Requesting node list from server...";
        MATTER_SendJsonCommand($hash, $payload);
        return undef;
    }
    elsif ($opt eq "commissionCode") {
        my $setup_code = $args[0];
        return "Please provide a Matter manual pairing code (e.g. 35325335079)" if (!$setup_code);

        my $msg_id = int(rand(100000) + 1);
        $hash->{helper}{pending_command}{$msg_id} = "commission";

        # Payload für den python-matter-server aufbauen
        my $payload = {
            message_id => $msg_id,
            command    => "commission_with_code",
            args       => {
                code         => $setup_code,
                network_only => JSON::true # Erzwingt den reinen Netzwerk-Modus ohne BLE-Voraussetzung
            }
        };

        Log3 $name, 3, "MATTER: Commissioning device with manual code (network_only)...";
        MATTER_SendJsonCommand($hash, $payload);
        return undef;
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
        $ssid =~ s/^["']|["']$//g;
        $credentials =~ s/^["']|["']$//g;

        return "Please provide SSID and credentials. Usage: set <dev> setWifiCredentials \"SSID\" Password [ID]" if (!$ssid || !$credentials);

        my $msg_id = int(rand(100000) + 1);
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
        MATTER_SendJsonCommand($hash, $payload);
        return undef;
    }
    elsif ($opt eq "getCredentials") {
        my $msg_id = int(rand(100000) + 1);
        $hash->{helper}{pending_command}{$msg_id} = "get_all_credentials";

        # Payload für den python-matter-server aufbauen
        my $payload = {
            message_id => $msg_id,
            command    => "get_all_credentials",
        };

        Log3 $name, 3, "MATTER: Get credentials...";
        MATTER_SendJsonCommand($hash, $payload);
        return undef;
    }
    else {
        my @cList = keys %MATTER_sets;
        return "Unknown argument $opt, choose one of " . join(" ", @cList);
    }
}

sub MATTER_Attr {
    my ($cmd, $name, $attr_name, $attr_value) = @_;
    return undef;
}

sub MATTER_Open($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $host = $hash->{ip};
    my $port = $hash->{port};

    RemoveInternalTimer($hash);
    MATTER_Close($hash);
    return if (AttrVal($hash->{NAME}, "disable", 0));

    Log3 $name, 3, "[$name] Connecting to $host:$port via raw socket...";

    my $socket = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    unless ($socket) {
        Log3 $name, 1, "[$name] Connection failed: $@";
        InternalTimer(gettimeofday() + 30, "MATTER_Open", $hash, 0);
        return;
    }

    $socket->blocking(0);
    $hash->{CD} = $socket;
    $hash->{FD} = $socket->fileno();
    $hash->{BUF} = "";
    $hash->{websocket} = 0;

    $selectlist{$name} = $hash;

    # WebSocket Handshake vorbereiten
    my $rand_bytes = pack("C*", map { int(rand(256)) } 1 .. 16);
    my $key = encode_base64($rand_bytes, "");
    
    my $handshake = "GET /ws HTTP/1.1\r\n" .
                    "Host: $host:$port\r\n" .
                    "Upgrade: websocket\r\n" .
                    "Connection: Upgrade\r\n" .
                    "Sec-WebSocket-Key: $key\r\n" .
                    "Sec-WebSocket-Version: 13\r\n" .
                    "Origin: http://$host:$port\r\n\r\n";

    syswrite($socket, $handshake);
    $hash->{ws_status} = "handshake";
    Log3 $name, 3, "[$name] WebSocket handshake sent.";
    readingsSingleUpdate($hash, "state", "connecting", 1);
}

sub MATTER_Close($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    delete $selectlist{$name};

    if ($hash->{CD}) {
        close($hash->{CD});
        delete $hash->{CD};
    }
    delete $hash->{FD};
    
    $hash->{websocket} = 0;
    $hash->{ws_status} = "disconnected";
    $hash->{BUF} = "";
    delete $hash->{helper}{pending_command};
    delete $hash->{helper}{pending_config};
    delete $hash->{fhem}{helper}{pending_config};
    
    Log3 $name, 3, "[$name] Connection closed.";
    readingsSingleUpdate($hash, "state", "disconnected", 1);
}

sub MATTER_Reconnect($) {
    my ($hash) = @_;
    MATTER_Close($hash);
    InternalTimer(gettimeofday() + 30, "MATTER_Open", $hash, 0)
        unless AttrVal($hash->{NAME}, "disable", 0);
}

sub MATTER_Read {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $socket = $hash->{CD};

    my $buf = "";
    my $n = sysread($socket, $buf, 65536);

    if (!defined($n) || $n == 0) {
        Log3 $name, 2, "[$name] Connection lost, retrying in 30s";
        MATTER_Reconnect($hash);
        return;
    }
    $hash->{BUF} .= $buf;

    # 1. Handshake verarbeiten
    if ($hash->{ws_status} eq "handshake") {
        unless ($hash->{BUF} =~ m/\x0d\x0a\x0d\x0a/) {
            if (length($hash->{BUF}) > 8192) {
                Log3 $name, 2, "[$name] WebSocket HTTP handshake exceeds 8192 bytes";
                MATTER_Reconnect($hash);
            }
            return;
        }
        unless ($hash->{BUF} =~ m/^HTTP\/1\.[01]\s+101\b/i) {
            Log3 $name, 2, "[$name] WebSocket upgrade was not accepted";
            MATTER_Reconnect($hash);
            return;
        }
        $hash->{ws_status} = "connected";
        $hash->{websocket} = 1;
        $hash->{BUF} =~ s/(.*?)\x0d\x0a\x0d\x0a//s;
        readingsSingleUpdate($hash, "state", "connected", 1);

        # The start_listening response contains the initial complete node list.
        $hash->{helper}{pending_command}{fhem_init_1} = "start_listening";
        MATTER_SendJsonCommand($hash, { message_id => "fhem_init_1", command => "start_listening" });
        # A complete WebSocket frame may already follow the HTTP handshake.
    }

    # 2. WebSocket Frames auslesen
    while (length($hash->{BUF}) >= 2) {
        my ($b1, $b2) = unpack("CC", substr($hash->{BUF}, 0, 2));
        my $opcode = $b1 & 0x0f;
        my $payload_len = $b2 & 0x7f;
        my $header_len = 2;

        if ($payload_len == 126) {
            return if length($hash->{BUF}) < 4;
            $payload_len = unpack("n", substr($hash->{BUF}, 2, 2));
            $header_len = 4;
        } elsif ($payload_len == 127) {
            return if length($hash->{BUF}) < 10;
            my @l_bytes = unpack("NN", substr($hash->{BUF}, 2, 8));
            $payload_len = ($l_bytes[0] * 4294967296) + $l_bytes[1];
            $header_len = 10;
        }

        # A single server snapshot can be large; cap malformed frames to protect FHEM memory.
        if ($payload_len > 32 * 1024 * 1024) {
            Log3 $name, 2, "[$name] WebSocket frame exceeds 32 MiB limit";
            MATTER_Reconnect($hash);
            return;
        }
        my $total_len = $header_len + $payload_len;
        return if length($hash->{BUF}) < $total_len;

        my $payload = substr($hash->{BUF}, $header_len, $payload_len);
        substr($hash->{BUF}, 0, $total_len) = "";

        if ($opcode == 0x1) { # Text Frame (JSON)
            MATTER_ParseMessage($hash, $payload);
        } elsif ($opcode == 0x9) { # Pong echoes the ping body and must be masked by the client.
            MATTER_SendWebSocketFrame($socket, 0xA, $payload);
        } elsif ($opcode == 0x8) { # Close Frame
            Log3 $name, 3, "[$name] WebSocket close received, retrying in 30s";
            MATTER_Reconnect($hash);
            return;
        }
    }
}

sub MATTER_SendJsonCommand($$) {
    my ($hash, $cmd_hash) = @_;
    MATTER_SendWebSocketText($hash->{CD}, encode_json($cmd_hash)) if $hash->{CD};
}

sub MATTER_SendWebSocketText($$) {
    my ($socket, $msg) = @_;
    MATTER_SendWebSocketFrame($socket, 0x1, $msg);
}

sub MATTER_SendWebSocketFrame($$$) {
    my ($socket, $opcode, $msg) = @_;
    return unless $socket;
    my $length = length($msg);
    my $frame = chr(0x80 | $opcode); # FIN and opcode

    if ($length <= 125) {
        $frame .= chr(0x80 | $length);
    } elsif ($length <= 65535) {
        $frame .= chr(0x80 | 126) . pack("n", $length);
    } else {
        $frame .= chr(0x80 | 127) . pack("Q>", $length);
    }

    my $mask = pack("N", int(rand(2**32)));
    $frame .= $mask;

    my $masked_payload = "";
    for (my $i = 0; $i < $length; $i++) {
        my $m_byte = ord(substr($mask, $i % 4, 1));
        my $p_byte = ord(substr($msg, $i, 1));
        $masked_payload .= chr($p_byte ^ $m_byte);
    }

    $frame .= $masked_payload;
    syswrite($socket, $frame);
}


# Keep existing FHEM device names and IO assignments stable during synchronization.
sub MATTER_SetNodeStatus($$$) {
    my ($hash, $node_id, $status) = @_;
    my $io_name = $hash->{NAME};
    foreach my $device (values %defs) {
        next unless ($device->{TYPE} // '') eq 'MATTERDevice';
        next unless defined($device->{node_id}) && $device->{node_id} eq $node_id;
        next unless $device->{IODev} && $device->{IODev}{NAME} eq $io_name;
        next if ReadingsVal($device->{NAME}, 'matter_status', '') eq $status;
        readingsSingleUpdate($device, 'matter_status', $status, 1);
    }
}

sub MATTER_ProcessNode($$) {
    my ($hash, $node) = @_;
    my $io_name = $hash->{NAME};
    return unless ref($node) eq 'HASH';
    my $node_id = $node->{node_id};
    unless (defined($node_id) && !ref($node_id) && $node_id =~ /^\d+$/) {
        Log3 $io_name, 2, 'MATTER: Ignoring node without a valid node_id';
        return;
    }

    my $root_key = "$io_name:$node_id";
    my $root = $modules{MATTERDevice}{defptr}{$root_key};
    if ($root && (!$root->{NAME} || !$defs{$root->{NAME}} || $defs{$root->{NAME}} ne $root ||
                  ($root->{node_id} // '') ne $node_id || ($root->{endpoint_id} // 0) != 0 ||
                  !$root->{IODev} || $root->{IODev}{NAME} ne $io_name)) {
        delete $modules{MATTERDevice}{defptr}{$root_key};
        $root = undef;
    }

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

        # MATTERDevice_Define uses AssignIoPort by default. Save other IO owners
        # before defining, as the temporary automatic assignment may reuse their defptr key.
        my %other_roots;
        foreach my $existing (values %defs) {
            next unless ($existing->{TYPE} // '') eq 'MATTERDevice';
            next unless ($existing->{node_id} // '') eq $node_id && ($existing->{endpoint_id} // 0) == 0;
            next unless $existing->{IODev};
            my $existing_io = $existing->{IODev}{NAME};
            next if $existing_io eq $io_name;
            $other_roots{"$existing_io:$node_id"} = $existing;
        }

        my $error = CommandDefine(undef, "$device_name MATTERDevice $node_id");
        $root = $defs{$device_name};
        if ($error || !$root || ($root->{TYPE} // '') ne 'MATTERDevice' ||
            ($root->{node_id} // '') ne $node_id || ($root->{endpoint_id} // 0) != 0) {
            Log3 $io_name, 2, "MATTER: Cannot create root $device_name: " . ($error // 'invalid result');
            foreach my $key (keys %other_roots) {
                $modules{MATTERDevice}{defptr}{$key} = $other_roots{$key};
            }
            return;
        }

        # Use the FHEM core path to set IODev, including its attribute and reading.
        my $old_io = $root->{IODev} ? $root->{IODev}{NAME} : 'no_io';
        my $attr_error = CommandAttr(undef, "$device_name IODev $io_name");
        if ($attr_error || !$root->{IODev} || $root->{IODev}{NAME} ne $io_name) {
            Log3 $io_name, 2, "MATTER: IODev assignment failed for $device_name: " .
                ($attr_error // 'wrong IODev after assignment');
            CommandDelete(undef, $device_name);
            foreach my $key (keys %other_roots) {
                $modules{MATTERDevice}{defptr}{$key} = $other_roots{$key};
            }
            return;
        }
        if ($old_io ne $io_name &&
            ($modules{MATTERDevice}{defptr}{"$old_io:$node_id"} // '') eq $root) {
            delete $modules{MATTERDevice}{defptr}{"$old_io:$node_id"};
        }
        foreach my $key (keys %other_roots) {
            $modules{MATTERDevice}{defptr}{$key} = $other_roots{$key};
        }

        my $room_error = CommandAttr(undef, "$device_name room Matter");
        Log3 $io_name, 3, "MATTER: Cannot set default room on $device_name: $room_error" if $room_error;
        Log3 $io_name, 3, "MATTER: Created root device $device_name for node $node_id";
    }
    $modules{MATTERDevice}{defptr}{$root_key} = $root;
    MATTERDevice_EnsureNodeGroup($root);

    # Apply the reported node availability before endpoint creation to avoid
    # briefly inheriting an outdated value during discovery.
    if (exists $node->{available}) {
        my $available = $node->{available};
        my $valid_boolean = defined($available) &&
            ((!ref($available) && $available =~ /^(?:0|1)$/) ||
             ref($available) =~ /Boolean$/);
        if ($valid_boolean) {
            my $value = $available ? 'true' : 'false';
            readingsSingleUpdate($root, 'available', $value, 1)
                if ReadingsVal($root->{NAME}, 'available', '') ne $value;
        }
    }
    if (ref($node->{attributes}) eq 'HASH') {
        MATTERDevice_Parse($root, encode_json({ node_id => $node_id, attributes => $node->{attributes} }));
    }
    # Synchronize already defined endpoints even without endpoint attributes.
    foreach my $child (MATTERDevice_NodeChildren($root)) {
        MATTERDevice_EnsureNodeGroup($child);
    }
    MATTERDevice_SyncNodeReadings($root);
    MATTER_SetNodeStatus($hash, $node_id, 'present');
    return 1;
}

sub MATTER_ProcessNodeList($$$) {
    my ($hash, $nodes, $source) = @_;
    my $io_name = $hash->{NAME};
    my %present;
    foreach my $node (@$nodes) {
        unless (ref($node) eq 'HASH' && defined($node->{node_id}) &&
                !ref($node->{node_id}) && $node->{node_id} =~ /^\d+$/) {
            Log3 $io_name, 2, "MATTER: Invalid node in $source response, ignoring incomplete snapshot";
            return;
        }
        $present{$node->{node_id}} = 1;
        MATTER_ProcessNode($hash, $node);
    }

    # Full snapshots are authoritative; mark missing nodes without deleting FHEM devices.
    foreach my $device (values %defs) {
        next unless ($device->{TYPE} // '') eq 'MATTERDevice';
        next unless ($device->{endpoint_id} // 0) == 0;
        next unless $device->{IODev} && $device->{IODev}{NAME} eq $io_name;
        next if $present{$device->{node_id} // ''};
        MATTER_SetNodeStatus($hash, $device->{node_id}, 'removed');
    }
    Log3 $io_name, 3, 'MATTER: Synchronized ' . scalar(keys %present) . " nodes from $source";
}

sub MATTER_ParseMessage($$) {
    my ($hash, $payload) = @_;
    my $name    = $hash->{NAME}; # Name des IO-Moduls (z.B. MATTER_Server1)
    
    my $decoded = eval { decode_json($payload) };
    if ($@) {
        Log3 $name, 3, "MATTER: JSON parse error: $@";
        return;
    }
    
    # A) Server-Informationen beim Connect
    if (exists $decoded->{schema_version} && exists $decoded->{sdk_version}) {
        Log3 $name, 3, "MATTER: Received server_info from Matter server.";
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "state", "connected");
        readingsBulkUpdate($hash, "schema_version", $decoded->{schema_version});
        readingsBulkUpdate($hash, "sdk_version", $decoded->{sdk_version});
        readingsBulkUpdate($hash, "fabric_id", $decoded->{fabric_id});
        readingsBulkUpdate($hash, "bluetooth_enabled", $decoded->{bluetooth_enabled} ? "true" : "false");
        readingsEndUpdate($hash, 1);
        return;
    }

    # Structural node events are pushed by the server after start_listening.
    if (exists $decoded->{event}) {
        my $event = $decoded->{event};
        if (($event eq 'node_added' || $event eq 'node_updated') && ref($decoded->{data}) eq 'HASH') {
            MATTER_ProcessNode($hash, $decoded->{data});
            return;
        }
        if ($event eq 'node_removed') {
            if (defined($decoded->{data}) && $decoded->{data} =~ /^\d+$/) {
                MATTER_SetNodeStatus($hash, $decoded->{data}, 'removed');
                Log3 $name, 3, "MATTER: Node $decoded->{data} removed from server; FHEM devices retained";
            }
            return;
        }
    }

    # B) Live-Events (z.B. attribute_updated) an das Root-Device der Node weiterleiten
    if (exists $decoded->{event} && $decoded->{event} eq "attribute_updated" && ref($decoded->{data}) eq 'ARRAY') {
        my ($node_id, undef, undef) = @{$decoded->{data}};
        if (defined $node_id) {
            # Wir suchen das Root-Device (Endpoint 0) exakt passend zu DIESEM IO und DIESER Node!
            my $root_key  = "$name:$node_id";
            my $root_hash = $modules{MATTERDevice}{defptr}{$root_key};
            
            if ($root_hash) {
                # Das Root-Device verarbeitet das Event (und reicht es an den Endpoint weiter)
                MATTERDevice_Parse($root_hash, $payload);
            } else {
                Log3 $name, 3, "MATTER: Received event for unknown root node $node_id on IO $name";
            }
        }
        return;
    }

    # C) Antworten auf spezifische Befehle (getConfig / get_nodes)
    if (my $msg_id = $decoded->{message_id}) {
        # Antwort auf read_attribute (getConfig)
        if (my $node_id = delete $hash->{helper}{pending_config}{$msg_id}) {
            if ($decoded->{result}) {
                my $root_key  = "$name:$node_id";
                my $root_hash = $modules{MATTERDevice}{defptr}{$root_key};
                if ($root_hash) {
                    MATTERDevice_Parse($root_hash, $payload);
                }
            }
            return;
        }
        
        # start_listening and get_nodes both return a complete node list.
        my $cmd_type = delete $hash->{helper}{pending_command}{$msg_id};
        if ($cmd_type && ($cmd_type eq "get_nodes" || $cmd_type eq "start_listening")) {
            if (ref($decoded->{result}) eq 'ARRAY') {
                MATTER_ProcessNodeList($hash, $decoded->{result}, $cmd_type);
            } else {
                my $details = ref($decoded->{error}) eq 'HASH' ? $decoded->{error}{message} : undef;
                $details //= $decoded->{details} // 'missing or invalid node list';
                Log3 $name, 2, "MATTER: $cmd_type failed on IO $name: $details"
                    . (defined($decoded->{error_code}) ? " (code $decoded->{error_code})" : '');
            }
            return;
        }

        # Antwort auf commission (Paired ein neues Gerät)
        if ($cmd_type && $cmd_type eq "commission") {
            if ($decoded->{result}) {
                Log3 $name, 3, "MATTER: Device successfully commissioned on IO $name; waiting for node_added event";
            } else {
                Log3 $name, 2, "MATTER: Commissioning failed on IO $name: " . ($decoded->{error}{message} // "Unknown error");
            }
            return;
        }
        elsif ($cmd_type && $cmd_type eq "set_wifi_credentials") {
            if ($decoded->{result}) {
                Log3 $name, 3, "MATTER: Wifi credentials set successfully on IO $name!";
            } else {
                Log3 $name, 2, "MATTER: Setting Wifi credentials failed on IO $name: " . ($decoded->{error}{message} // "Unknown error");
            }
            return;
        }
        elsif ($cmd_type && $cmd_type eq "get_all_credentials") {
            # 1. Alle alten Readings mit dem entsprechenden Präfix sauber mit FHEM-Bordmitteln löschen
            foreach my $key (keys %{$hash->{READINGS}}) {
                if ($key =~ /^(wifi|thread)_/) {
                    readingsDelete($hash, $key);
                }
            }
            if ($decoded->{result}) {
                my $result = $decoded->{result};
                
                readingsBeginUpdate($hash);
                
                # Wi-Fi Credentials verarbeiten (falls vorhanden und ein Array)
                if ($result->{wifi} && ref($result->{wifi}) eq 'ARRAY') {
                    my @wifi_credentials = @{$result->{wifi}};
                    foreach my $wifi (@wifi_credentials) {
                        next unless ref($wifi) eq 'HASH';
                        my $id   = $wifi->{id} // 'default';
                        my $ssid = $wifi->{ssid} // 'unknown';
                        readingsBulkUpdate($hash, "wifi_${id}_ssid", $ssid);
                    }
                }
                
                # Thread Credentials verarbeiten (falls vorhanden und ein Array)
                if ($result->{thread} && ref($result->{thread}) eq 'ARRAY') {
                    my @thread_credentials = @{$result->{thread}};
                    foreach my $thread (@thread_credentials) {
                        next unless ref($thread) eq 'HASH';
                        my $id          = $thread->{id} // 'default';
                        my $net_name    = $thread->{networkName} // 'unknown';
                        my $ext_pan_id  = $thread->{extPanId} // '';
                        
                        readingsBulkUpdate($hash, "thread_${id}_name", $net_name);
                        readingsBulkUpdate($hash, "thread_${id}_extPanId", $ext_pan_id);
                    }
                }
                
                readingsEndUpdate($hash, 1);
                Log3 $name, 3, "MATTER: Credentials set successfully on IO $name!";
            } else {
                Log3 $name, 2, "MATTER: Getting credentials failed on IO $name: " . ($decoded->{error}{message} // "Unknown error");
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

<a name="MATTER"></a>
<h3>MATTER</h3>
<p>The MATTER IO device communicates with an external Matter server over WebSocket.
After connecting, <code>start_listening</code> supplies the complete node list.
Subsequent <code>node_added</code>, <code>node_updated</code> and <code>node_removed</code>
events synchronize logical MATTERDevice nodes and their endpoints automatically.</p>
<ul>
  <li><b>Define:</b> <code>define &lt;name&gt; MATTER &lt;IP&gt; &lt;PORT&gt;</code>
      (default server port: 5580)</li>
  <li><b>Set connect:</b> Reconnect the WebSocket to the server.</li>
  <li><b>Set discover:</b> Manually request a complete <code>get_nodes</code> snapshot;
      this is optional under normal operation.</li>
  <li><b>Set commissionCode:</b> Pair a network-commissionable device using its setup code.</li>
  <li><b>Set setWifiCredentials / getCredentials:</b> Configure or inspect available
      network credentials (do not expose secrets in logs).</li>
  <li><b>Attribute disable:</b> Disable or enable the IO connection.</li>
  <li><b>Attribute autocreate (0/1):</b> Default <code>1</code>. Set to
      <code>0</code> to suppress automatic creation of new FHEM root and endpoint
      devices from node discovery, commissioning events and attribute updates.
      Existing devices remain synchronized; the Matter server keeps its nodes.
      Re-enabling autocreate allows missing devices to be created on subsequent
      discovery/events.</li>
</ul>
<p>Newly created logical devices default to room <code>Matter</code>; existing FHEM
names, rooms and user attributes are retained. A removed node is marked with
<code>matter_status=removed</code> rather than deleted. This status describes node
membership on the server, not physical device availability. The root-only
<code>available</code> reading reflects a boolean availability report from the
server, without polling. Incoming WebSocket frames
larger than 32 MiB are rejected and trigger a reconnect.</p>

=end html

=begin html_DE

<a name="MATTER"></a>
<h3>MATTER</h3>
<p>Das MATTER-IO-Device verbindet FHEM per WebSocket mit einem externen Matter-Server.
Beim Verbindungsaufbau liefert <code>start_listening</code> die vollständige Node-Liste.
Danach synchronisieren <code>node_added</code>, <code>node_updated</code> und
<code>node_removed</code> die Matter-Knoten und ihre Endpunkte ereignisgesteuert.</p>
<ul>
  <li><b>Definition:</b> <code>define &lt;name&gt; MATTER &lt;IP&gt; &lt;PORT&gt;</code>
      (Standardport: 5580)</li>
  <li><b>Set connect:</b> Verbindung zum Matter-Server neu aufbauen.</li>
  <li><b>Set discover:</b> Optional eine vollständige Node-Liste per
      <code>get_nodes</code> erneut anfordern.</li>
  <li><b>Set commissionCode:</b> Netzwerkfähiges Matter-Gerät mit Setup-Code koppeln.</li>
  <li><b>Set setWifiCredentials / getCredentials:</b> Netzwerkzugangsdaten
      konfigurieren bzw. auslesen.</li>
  <li><b>Attribut disable:</b> IO-Verbindung deaktivieren oder aktivieren.</li>
  <li><b>Attribut autocreate (0/1):</b> Standard <code>1</code>. Mit
      <code>0</code> werden weder neue Root- noch Endpoint-Devices in FHEM
      automatisch angelegt. Bestehende Devices werden weiterhin synchronisiert;
      die Nodes auf dem Matter-Server bleiben unverändert. Nach dem erneuten
      Aktivieren können fehlende Devices beim nächsten Abgleich oder Event
      angelegt werden.</li>
</ul>
<p>Neue logische Geräte erhalten standardmäßig den Raum <code>Matter</code>.
Vorhandene Namen, Räume und Benutzerattribute bleiben unverändert. Entfernte
Nodes werden mit <code>matter_status=removed</code> markiert und nicht automatisch
gelöscht. Dieses Reading beschreibt die Mitgliedschaft auf dem Matter-Server,
nicht die physische Erreichbarkeit des Geräts. Das nur am Root geführte Reading
<code>available</code> bildet die vom Server ausdrücklich gemeldete Erreichbarkeit ab;
es erfolgt kein Polling. Eingehende WebSocket-Frames
über 32 MiB werden abgewiesen; anschließend wird die Verbindung neu aufgebaut.</p>

=end html
=cut