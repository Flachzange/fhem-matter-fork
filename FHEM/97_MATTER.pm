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
    "setWifiCredentials" => "textField textField",
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

    $hash->{AttrList} = "disable:0,1 " . $readingFnAttributes;
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
        my $ssid = $args[0];
        my $credentials = $args[1];
        my $id = $args[2];
        return "Please provide SSID, credentials and ID as arguments." if ((!$ssid) || (!$credentials));

        my $msg_id = int(rand(100000) + 1);
        $hash->{helper}{pending_command}{$msg_id} = "set_wifi_credentials";
        my $payload = undef;
        # Payload für den python-matter-server aufbauen
        if (!$id) {
            $payload = {
                message_id => $msg_id,
                command    => "set_wifi_credentials",
                args       => {
                    ssid         => $ssid,
                    credentials  => $credentials,
                    id           => $id,
                }
            };
        } else {
            $payload = {
                message_id => $msg_id,
                command    => "set_wifi_credentials",
                args       => {
                    ssid         => $ssid,
                    credentials  => $credentials,
                }
            };
        }

        Log3 $name, 3, "MATTER: Set Wifi credentials for $name with SSID $ssid and credentials...";
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

        Log3 $name, 3, "MATTER: Commissioning device with manual code (network_only)...";
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
    
    $hash->{websocket} = 0;
    $hash->{ws_status} = "disconnected";
    $hash->{BUF} = "";
    
    Log3 $name, 3, "[$name] Connection closed.";
    readingsSingleUpdate($hash, "state", "disconnected", 1);
}

sub MATTER_Read {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $socket = $hash->{CD};

    my $buf = "";
    my $n = sysread($socket, $buf, 65536);

    if (!defined($n) || $n == 0) {
        Log3 $name, 2, "[$name] Connection lost, retrying in 30s";
        MATTER_Close($hash);
        InternalTimer(gettimeofday() + 30, "MATTER_Open", $hash, 0); # Automatischer Reconnect
        return;
    }
    $hash->{BUF} .= $buf;

    # 1. Handshake verarbeiten
    if ($hash->{ws_status} eq "handshake") {
        if ($hash->{BUF} =~ m/\x0d\x0a\x0d\x0a/) {
            $hash->{ws_status} = "connected";
            $hash->{websocket} = 1;
            $hash->{BUF} =~ s/(.*?)\x0d\x0a\x0d\x0a//s;
            readingsSingleUpdate($hash, "state", "connected", 1);
            
            # Start listening beim Server anfordern
            MATTER_SendJsonCommand($hash, { message_id => "fhem_init_1", command => "start_listening" });
        }
        return;
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
            my @l_bytes = unpack("x2 N N", substr($hash->{BUF}, 2, 8));
            $payload_len = ($l_bytes[0] * 4294967296) + $l_bytes[1];
            $header_len = 10;
        }

        my $total_len = $header_len + $payload_len;
        return if length($hash->{BUF}) < $total_len;

        my $payload = substr($hash->{BUF}, $header_len, $payload_len);
        substr($hash->{BUF}, 0, $total_len) = "";

        if ($opcode == 0x1) { # Text Frame (JSON)
            MATTER_ParseMessage($hash, $payload);
        } elsif ($opcode == 0x9) { # Ping -> Pong antworten
            my $pong = chr(0x8A) . chr(0x00);
            syswrite($socket, $pong);
        } elsif ($opcode == 0x8) { # Close Frame
            MATTER_Close($hash);
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
    return unless $socket;
    
    my $length = length($msg);
    my $frame = chr(0x81); # Text Frame + FIN

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
        
        # Antwort auf get_nodes (Discover)
        my $cmd_type = delete $hash->{helper}{pending_command}{$msg_id};
        if ($cmd_type && $cmd_type eq "get_nodes") {
            if ($decoded->{result} && ref($decoded->{result}) eq 'ARRAY') {
                Log3 $name, 3, "MATTER: Processing node list from get_nodes response on IO $name...";

                foreach my $node (@{$decoded->{result}}) {
                    my $node_id   = $node->{node_id};
                    my $node_name = $node->{name} // "MatterDevice_$node_id";
                    
                    $node_name =~ s/[^a-zA-Z0-9_\.-]/_/g;
                    $node_name = "MATTER_" . $node_name;

                    # Prüfen, ob das Root-Device (Endpoint 0) für DIESES IO schon existiert
                    my $root_key  = "$name:$node_id";
                    my $root_hash = $modules{MATTERDevice}{defptr}{$root_key};
                    
                    unless ($root_hash) {
                        Log3 $name, 3, "MATTER: Auto-creating root device $node_name for Node ID $node_id on IO $name";
                        
                        # Syntax für Root-Device: define <name> MATTERDevice <node_id>
                        CommandDefine(undef, "$node_name MATTERDevice $node_id");
                        
                        $root_hash = $defs{$node_name};
                        if ($root_hash) {
                            # IODev explizit zuweisen, falls AssignIoPort beim Define nicht reichte
                            $root_hash->{IODev} = $hash;
                            # Im defptr für dieses IO registrieren
                            $modules{MATTERDevice}{defptr}{$root_key} = $root_hash;
                            Log3 $name, 3, "MATTER: Assigned IODev $name to Root-Device $node_name";
                        }
                    }

                    # Initiale Attribute ans Root-Device übergeben (das verteilt es an die Endpoints)
                    if ($root_hash && $node->{attributes}) {
                        MATTERDevice_Parse($root_hash, encode_json({ node_id => $node_id, attributes => $node->{attributes} }));
                    }
                }
            }
            return;
        }
        
        # Antwort auf commission (Paired ein neues Gerät)
        if ($cmd_type && $cmd_type eq "commission") {
            if ($decoded->{result}) {
                Log3 $name, 3, "MATTER: Device successfully commissioned on IO $name! Triggering discover...";
                CommandSet(undef, "$name discover");
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
=item summary    Interface module for Matter protocol via WebSocket/JSON
=item summary_DE Schnittstellenmodul für das Matter-Protokoll via WebSocket/JSON
=begin html

<a name="MATTER"></a>
<h3>MATTER</h3>
<ul>
  The MATTER module serves as the central IO-Device for communicating with a 
  Matter-Server via WebSockets. It handles the raw connection, the WebSocket 
  handshake, and the routing of JSON-based messages to individual MatterDevice 
  instances.<br><br>

  <a name="MATTER-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; MATTER &lt;IP&gt; &lt;PORT&gt;</code><br><br>
    The IP and PORT point to your Matter-Bridge or server implementation (default port: 5580).
  </ul>
  <br>

  <a name="MATTER-set"></a>
  <b>Set</b>
  <ul>
    <li><code>connect</code><br>
        Manually opens/re-establishes the connection to the Matter server.</li>
    <li><code>discover</code><br>
        Queries the server for available nodes and automatically creates corresponding 
        MATTERDevice instances if they do not exist yet.</li>
  </ul>
  <br>

  <a name="MATTER-get"></a>
  <b>Get</b>
  <ul>
    <li><code>update</code><br>
        Placeholder for future functionality.</li>
  </ul>
  <br>

  <a name="MATTER-attr"></a>
  <b>Attributes</b>
  <ul>
    <li>Standard FHEM attributes are supported (e.g., <code>IODev</code>, <code>room</code>).</li>
  </ul>
</ul>

=end html
=cut