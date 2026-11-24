#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use JSON qw(encode_json decode_json);
use HTTP::Tiny;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use IO::Socket::INET;
use IO::Select;
use Encode qw(encode);
use Compress::Zlib qw(memGunzip);
use Time::HiRes qw(sleep);

# Execute the actual core, event loop and FHEMWEB, not the callback stubs in
# matter_node_sync.t. CI fetches this exact upstream revision into FHEM_CORE_DIR.
# No Matter server/device or configDB is used; all reports below are synthetic.
my $core = $ENV{FHEM_CORE_DIR};
plan skip_all => 'Set FHEM_CORE_DIR to the pinned FHEM checkout (see CI)' unless $core;
$core = abs_path($core);
my $project = abs_path('.');
my $runtime = tempdir(CLEANUP => 1);
my $encoding = $ENV{FHEM_TEST_ENCODING} // 'unicode';
make_path("$runtime/FHEM");
for my $source (glob("$core/fhem/FHEM/*")) {
    my ($file) = $source =~ m{/([^/]+)$};
    next if $file eq '97_MATTER.pm' || $file eq '97_MATTERDevice.pm';
    symlink $source, "$runtime/FHEM/$file" or die "symlink $file: $!";
}
symlink "$core/fhem/$_", "$runtime/$_" or die "symlink $_: $!" for qw(lib www);
symlink "$project/FHEM/$_", "$runtime/FHEM/$_" or die "symlink $_: $!" for qw(97_MATTER.pm 97_MATTERDevice.pm);
my $reserve = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1) or die $!;
my $port = $reserve->sockport;
close $reserve;
open my $cfg, '>', "$runtime/fhem.cfg" or die $!;
print {$cfg} "attr global modpath $runtime\nattr global logfile $runtime/fhem.log\n";
print {$cfg} "attr global statefile $runtime/state\nattr global pidfilename $runtime/pid\n";
print {$cfg} "attr global nofork 1\nattr global encoding $encoding\nattr global verbose 2\n";
print {$cfg} "define WEB FHEMWEB $port 127.0.0.1\nattr WEB csrfToken none\n";
close $cfg;
my $pid = fork();
die $! unless defined $pid;
if (!$pid) {
    chdir $runtime or die $!;
    open STDOUT, '>', "$runtime/stdout" or die $!;
    open STDERR, '>&', STDOUT or die $!;
    exec $^X, "$core/fhem/fhem.pl", "$runtime/fhem.cfg";
    die $!;
}
END { local $?; if ($pid) { kill 'KILL', $pid; waitpid($pid, 0); } }
my $http = HTTP::Tiny->new(timeout => 5, no_proxy => '127.0.0.1', default_headers => {'Accept-Encoding' => 'gzip'});
my $base = "http://127.0.0.1:$port/fhem";
my $escape = sub { join '', map { sprintf '%%%02X', $_ } unpack 'C*', encode('UTF-8', $_[0]) };
my $ready;
for (1..50) {
    $ready = $http->get("$base?XHR=1");
    last if $ready->{success};
    sleep 0.1;
}
if (!$ready->{success}) {
    for my $file (qw(stdout fhem.log)) {
        if (open my $fh, '<', "$runtime/$file") { local $/; diag(<$fh>); }
    }
    BAIL_OUT('Actual FHEM core failed to start');
}
my $cmd = sub {
    my ($command) = @_;
    my $r = $http->get("$base?XHR=1&cmd=" . $escape->($command));
    die "FHEM HTTP $r->{status}: $r->{content}" unless $r->{success};
    return ($r->{headers}{'content-encoding'} // '') eq 'gzip' ? memGunzip($r->{content}) : $r->{content};
};
# All Perl statements travel through the real FHEM command field. Escape
# required semicolons so AnalyzeCommandChain cannot split the expression.
my $perl = sub {
    my ($code) = @_;
    $code =~ s/;/;;/g;
    my $result = $cmd->("{ $code }");
    $result =~ s/\n\z//;
    return $result;
};
my $literal = sub { my $s = encode_json($_[0]); $s =~ s/([\\'])/\\$1/g; return "JSON::decode_json('$s')"; };
my $device = sub { return decode_json($cmd->("jsonlist2 $_[0]"))->{Results}[0]; };
my $state = sub { return $device->($_[0])->{Internals}{STATE}; };
is($cmd->('define io MATTER 127.0.0.1 9; attr io disable 1'), '', 'local synthetic IO is defined without an external server');

# Every currently named type is explicitly represented, including those with
# only a type label and no functional parser. Values go through real parsers.
my @cases = (
    [0x0076, {'92/0' => 5}, 'hardware_fault'],
    [0x0043, {'69/0' => JSON::true}, 'wet'],
    [0x0044, {'69/0' => JSON::false}, 'dry'],
    [0x000A, {'257/0' => 1}, 'locked'],
    [0x0202, {'258/14' => 6543}, 'lift: 34.57 %'],
    [0x0301, {'513/28' => 4, '513/0' => 2100, '513/18' => 2200}, 'heat; measured: 21 °C; heat: 22 °C'],
    [0x002B, {'514/0' => 3, '514/3' => 45}, 'high; 45 %'],
    (map { [$_, {'6/0' => JSON::true}, 'on'] } (0x0100,0x0101,0x010C,0x010D,0x010A,0x010B)),
    [0x0015, {'69/0' => JSON::true}, 'closed'],
    [0x0107, {'1030/0' => 1}, 'motion'],
    [0x0850, {'69/0' => JSON::true}, '1'],
    (map { [$_, {}, 'unknown'] } (0x000F,0x0103,0x0104,0x0105)),
    [0x002C, {'91/0' => 4}, 'poor'],
    [0x0510, {'144/8' => 123450}, '123.45 W'],
    [0x0302, {'1026/0' => 2234}, '22.34 °C'],
    [0x0307, {'1029/0' => 4800}, '48 %'],
    [0x0305, {'1027/0' => 1013}, '1013 hPa'],
    [0x0106, {'1024/0' => 30001}, '1000 lx'],
    (map { [$_, {}, 'unknown'] } (0x0306,0x000E,0x0013,0x0016,0x0011,0x0012,0x0014,0xFFF0)),
);
open my $source_fh, '<', 'FHEM/97_MATTERDevice.pm' or die $!;
my $source = do { local $/; <$source_fh> };
my ($labels) = $source =~ /my %MATTER_DEVICE_TYPE_LABELS = \((.*?)\n\);/s;
my %covered = map { $_->[0] => 1 } @cases;
is_deeply([grep { !$covered{hex $_} } $labels =~ /(0x[0-9A-F]+)/g], [], 'every named type has a real-core case');
my %attributes;
my (%ep_for, %name_for);
for my $i (0..$#cases) {
    my ($type,$attrs) = @{$cases[$i]};
    my $ep = $i+1;
    $ep_for{$type} = $ep;
    $name_for{$type} = "MATTER_Display_EP$ep";
    $attributes{"$ep/29/0"} = [{deviceType => $type, revision => 1}];
    $attributes{"$ep/$_"} = $attrs->{$_} for keys %$attrs;
}
$cmd->('reload 97_MATTERDevice');

my $snapshot = {node_id => 98900, name => 'Display', available => JSON::true, attributes => \%attributes};
$perl->('MATTER_ProcessNode($defs{io}, ' . $literal->($snapshot) . ')');
for my $case (@cases) {
    my ($type,undef,$expected) = @$case;
    is($state->($name_for{$type}), $expected, sprintf '0x%04X: default after actual reading/notification path', $type);
    ok(!exists $device->($name_for{$type})->{Attributes}{stateFormat}, 'no stateFormat attribute is generated');
}
is($state->('MATTER_Display'), 'online', 'root keeps its native state');
my $report = sub {
    my ($type,$path,$value) = @_;
    my $event = {event=>'attribute_updated',data=>[98900,"$ep_for{$type}/$path",$value]};
    $perl->('MATTER_ParseMessage($defs{io}, JSON::encode_json(' . $literal->($event) . '))');
};
my $temp = $name_for{0x0302};
my $ep = $ep_for{0x0302};
$cmd->("define observed notify $temp:.* { push \@{\$defs{$temp}{test_events}}, [\$EVENT,\$defs{$temp}{STATE}] }");
$report->(0x0302, '1026/0', 0);
is($state->($temp), '0 °C', 'valid zero is presented');
my $events = decode_json($perl->("JSON->new->ascii->encode(\$defs{$temp}{test_events})"));
$events->[0][1] = Encode::decode('UTF-8', $events->[0][1]) if $encoding eq 'bytestream';
is_deeply($events, [['temperature: 0', '0 °C']], 'notify sees the final STATE with exactly the original reading event');
ok(!exists $device->($temp)->{Readings}{state}, 'measurement does not acquire a redundant state reading');
for my $bad (undef, 'invalid', -32768) {
    my $before = $device->($temp)->{Readings};
    $report->(0x0302,'1026/0',$bad);
    is_deeply($device->($temp)->{Readings}, $before, 'invalid report preserves readings and timestamps');
    is($state->($temp), '0 °C', 'invalid report preserves displayed last valid value');
}
$cmd->("attr $temp stateFormat { 'custom ' . ReadingsVal(\$name, 'temperature', '?') }");
is($state->($temp), 'custom 0', 'core evaluates explicit Perl stateFormat immediately');
$report->(0x0302,'1026/0',1234);
is($state->($temp), 'custom 12.34', 'user stateFormat also wins on reports');
$cmd->("deleteattr $temp stateFormat");
is($state->($temp), '12.34 °C', 'deleteattr immediately restores the default');
$cmd->("attr $temp stateFormat temperature");
$report->(0x0302,'1026/0',1450);
is($state->($temp), '14.5', 'plain reading stateFormat is respected');
$cmd->("deleteattr $temp stateF.*");
is($state->($temp), '14.5 °C', 'pattern deleteattr restores the default');
$report->(0x0302,'29/0',[{deviceType=>0x0307},{deviceType=>0x0302}]);
is($state->($temp), '14.5 °C / unknown', 'combined type includes an unknown missing component');
$report->(0x0302,'1029/0',4800);
is($state->($temp), '14.5 °C / 48 %', 'combined temperature/humidity');
$report->(0x0302,'29/0',[{deviceType=>0x0302},{deviceType=>0x0307}]);
is($state->($temp), '14.5 °C / 48 %', 'Descriptor order cannot change presentation');
# FHEMWEB room and detail use FW_devState; compare actual returned markup.
for my $view ("room=Matter", "detail=$temp") {
    my $r=$http->get("$base?$view");
    like(decode_utf8_content(($r->{headers}{'content-encoding'} // '') eq 'gzip' ? memGunzip($r->{content}) : $r->{content}), qr/14\.5 °C \/ 48 %/, "real FHEMWEB $view renders the default");
}

# No extra reading writes or notify events for repeated/suppressed telemetry.
$cmd->("attr $temp event-on-change-reading .*");
$perl->('delete $defs{' . $temp . '}{test_events}');
$report->(0x0302,'1026/0',1450);
is($perl->('scalar @{$defs{' . $temp . '}{test_events} // []}'), '0', 'event-on-change suppresses unchanged data without a synthetic display event');
$cmd->("deleteattr $temp event-on-change-reading");

# Core userReadings must still run before the final display/event publication.
$cmd->("attr $temp userReadings display_copy:temperature:.* { ReadingsVal(\$name,q(temperature),q(?)) }");
$perl->('delete $defs{' . $temp . '}{test_events}');
$report->(0x0302,'1026/0',1500);
my $with_user = decode_json($perl->('JSON->new->ascii->encode($defs{' . $temp . '}{test_events})'));
is_deeply([map { $_->[0] } @$with_user],['temperature: 15','display_copy: 15'], 'original and userReading events are retained exactly once');
is($state->($temp),'15 °C / 48 %','default uses readings after core userReadings');
$cmd->("deleteattr $temp userReadings");

# Real longpoll: subscribe first, then change a measurement through the IO parser.
my $poll = IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$port,Timeout=>5) or die $!;
my $inform = $escape->("type=status;filter=$temp;fmt=JSON");
print {$poll} "GET /fhem?XHR=1&inform=$inform HTTP/1.0\r\nHost: localhost\r\n\r\n";
my $select = IO::Select->new($poll);
my $poll_data = '';
for (1..10) { last unless $select->can_read(0.1); my $n=sysread($poll,my $buf,65536); last unless $n; $poll_data.=$buf; }
$report->(0x0302,'1026/0',1550);
for (1..20) { last if $poll_data =~ /15\.5/; next unless $select->can_read(0.1); my $n=sysread($poll,my $buf,65536); last unless $n; $poll_data.=$buf; }
like(decode_utf8_content($poll_data), qr/15\.5 °C \/ 48 %/, 'actual FHEMWEB longpoll sends the updated default');
close $poll;

# All defined enum values retain their meanings; invalid values do not replace
# a valid reading or refresh its timestamp. Readings and display share the text API.
for my $row (
    [0x000A,'257/0','state',[qw(not_fully_locked locked unlocked unlatched)]],
    [0x0076,'92/0','alarmExpressedState',[qw(normal smoke_alarm co_alarm battery_alert testing hardware_fault end_of_service interconnect_smoke interconnect_co)]],
    [0x002C,'91/0','airQuality',[qw(unknown good fair moderate poor very_poor extremely_poor)]],
) {
    my ($type,$path,$reading,$values)=@$row;
    my $name=$name_for{$type};
    for my $i (0..$#$values) {
        $report->($type,$path,$i);
        is($state->($name),$values->[$i],"$reading enum $i is presented explicitly");
        is($device->($name)->{Readings}{$reading}{Value}, $values->[$i], 'functional enum reading matches its default display');
    }
    my $before=$device->($name)->{Readings};
    for my $bad (undef,-1,999,'bad',{}) { $report->($type,$path,$bad); }
    is_deeply($device->($name)->{Readings},$before,"$reading rejects invalid/null data without rewriting readings");
}
# Coverings: current positions only, including tilt-only and non-position-aware.
my $cover=$name_for{0x0202};
$report->(0x0202,'258/11',10000);
is($state->($cover),'lift: 34.57 %','target position is not displayed as achieved');
$perl->('readingsDelete($defs{' . $cover . '},q(pct))');
$report->(0x0202,'258/15',3000);
is($state->($cover),'tilt: 30 %','tilt-only display uses the current tilt');
$report->(0x0202,'258/15',65535);
is($state->($cover),'tilt: 30 %','null sentinel cannot overwrite the tilt');
$perl->('readingsDelete($defs{' . $cover . '},q(tilt))');
for my $row ([0,'global: stopped / lift: stopped / tilt: stopped'],[1,'global: opening / lift: stopped / tilt: stopped'],[2,'global: closing / lift: stopped / tilt: stopped']) {
    $report->(0x0202,'258/10',$row->[0]); is($state->($cover),$row->[1],'operational status without a current position');
}
$report->(0x0202,'258/10',3);
is($state->($cover),'global: closing / lift: stopped / tilt: stopped','reserved operational status preserves last valid state');
# All bitmap fields are interpreted in the reading, without losing axis data.
$report->(0x0202,'258/10',37);
my $movement = 'global: opening / lift: opening / tilt: closing';
is($device->($cover)->{Readings}{wcOperationalStatus}{Value},$movement,'bitmap reading preserves global/lift/tilt meaning');
is($state->($cover),$movement,'cover fallback uses the same readable bitmap value');
for my $bad (12,48,63,64,undef,'opening') {
    my $before=$device->($cover)->{Readings}{wcOperationalStatus};
    $report->(0x0202,'258/10',$bad);
    is_deeply($device->($cover)->{Readings}{wcOperationalStatus},$before,'invalid/reserved bitmap fields preserve the last reading');
}
my $alarm=$name_for{0x0076};
$cmd->("attr $alarm stateFormat alarmExpressedState");
$report->(0x0076,'92/0',2);
is($state->($alarm),'co_alarm','a plain reading stateFormat gets the same human-readable alarm');
$cmd->("attr $alarm stateFormat { 'alarm: ' . ReadingsVal(\$name,q(alarmExpressedState),q(?)) }");
$report->(0x0076,'92/0',0);
is($state->($alarm),'alarm: normal','Perl stateFormat observes converted reading values');
$cmd->("deleteattr $alarm stateFormat");
is($state->($alarm),'normal','default returns to the same readable source');
$cmd->("define alarmObserved notify $alarm:.* { push \@{\$defs{$alarm}{test_events}}, [\$EVENT,\$defs{$alarm}{STATE}] }");
$report->(0x0076,'92/0',8);
my $alarm_event=decode_json($perl->('JSON->new->ascii->encode($defs{' . $alarm . '}{test_events})'));
is_deeply($alarm_event,[['alarmExpressedState: interconnect_co','interconnect_co']], 'notify sees identical readable alarm reading and display');
# HVAC: no assumption that a setpoint is actual temperature or actual fan speed.
my $thermo=$name_for{0x0301};
for my $row ([3,'cool; measured: 21 °C; cool: unknown'],[1,'auto; measured: 21 °C; heat: 22 °C; cool: unknown'],[0,'off; measured: 21 °C']) {
    $report->(0x0301,'513/28',$row->[0]);is($state->($thermo),$row->[1],'thermostat chooses setpoints by reported mode');
}
$report->(0x0301,'513/17',2400);$report->(0x0301,'513/28',1);
is($state->($thermo),'auto; measured: 21 °C; heat: 22 °C; cool: 24 °C','auto shows separate heat/cool setpoints');
$report->(0x002B,'514/2',90);
is($state->($name_for{0x002B}),'high; 45 %','fan setting cannot replace measured percent');
# Air quality fallback: no manufactured unit; no local thresholds.
my $air=$name_for{0x002C};
$perl->('readingsDelete($defs{' . $air . '},q(airQuality))');
$report->(0x002C,'1037/0',650);
is($state->($air),'co2: 650 unknown','missing concentration unit stays unknown');
$report->(0x002C,'1037/8',3);
is($state->($air),'co2: 650 mg/m3','reported concentration unit is used without conversion');
$report->(0x002C,'1066/8',4);$report->(0x002C,'1066/0',0);
is($state->($air),'co2: 650 mg/m3 / pm25: 0 ug/m3','multiple concentration sources have fixed order and retain zero');
$report->(0x002C,'91/0',0);
is($state->($air),'unknown','reported qualitative unknown is not replaced by an invented numerical rating');
# Electrical source priority, including valid zero and fallback to energy.
my $electric=$name_for{0x0510};
$report->(0x0510,'145/1',{energy=>1_000_000});
is($state->($electric),'123.45 W','power stays primary despite a later energy report');
$report->(0x0510,'144/8',0);
is($state->($electric),'0 W','zero power is a valid primary value');
$perl->('readingsDelete($defs{' . $electric . '},q(power))');
$report->(0x0510,'145/1',{energy=>2_500_000});
is($state->($electric),'2.5 kWh','energy fallback uses the existing scaling');
# Mixed types: structural companions and report ordering cannot displace an
# actuator/alarm with an ancillary measurement.
my $plug=$name_for{0x010A};
$report->(0x010A,'29/0',[{deviceType=>0x0510},{deviceType=>0x0013},{deviceType=>0x010A}]);
$report->(0x010A,'144/8',75000);
is($state->($plug),'on','plug plus electrical sensor stays an actuator');
$report->(0x0076,'29/0',[{deviceType=>0x0302},{deviceType=>0x0076}]);
$report->(0x0076,'1026/0',1900);
is($state->($name_for{0x0076}),'interconnect_co','alarm stays primary despite a temperature report');
# Native eventMap still maps only the presentation/events; raw state is kept.
$cmd->("attr $plug eventMap on:enabled off:disabled");
$report->(0x010A,'6/0',JSON::false);
is($state->($plug),'disabled','native eventMap is respected by the default');
is($device->($plug)->{Readings}{state}{Value},'off','eventMap does not rewrite the physical state reading');
$report->(0x010A,'144/8',50000);
is($state->($plug),'disabled','an ancillary reading cannot remove the eventMap presentation');
$cmd->("deleteattr $plug eventMap");
is($state->($plug),'off','removing eventMap restores the raw default');
# A newly defined measurement has no fabricated value, and deleteattr without
# a pattern still removes a user format using the core's all-attributes path.
$cmd->('define ClearDisplay MATTERDevice 98901 1');
$perl->('MATTERDevice_ProcessAttributeValue($defs{ClearDisplay},29,0,[{deviceType=>770}])');
is($state->('ClearDisplay'),'unknown','new temperature endpoint without data is unknown');
$perl->('MATTERDevice_ProcessAttributeValue($defs{ClearDisplay},1026,0,1234)');
$cmd->('attr ClearDisplay stateFormat custom');
is($state->('ClearDisplay'),'custom','standalone endpoint supports an explicit override');
$cmd->('deleteattr ClearDisplay');
is($state->('ClearDisplay'),'12.34 °C','deleting all attributes restores the default');
# Button events are last-event displays, not actuator states; repeat events
# remain repeat events even under event-on-change-reading.
my $button=$name_for{0x000F};
$cmd->("attr $button event-on-change-reading .*");
$cmd->("define buttons notify $button:button:.* { push \@{\$defs{$button}{test_events}}, \$EVENT }");
for (1..2) {
    my $event={event=>'node_event',data=>{node_id=>98900,endpoint_id=>$ep_for{0x000F},cluster_id=>59,event_id=>3}};
    $perl->('MATTER_ParseMessage($defs{io}, JSON::encode_json(' . $literal->($event) . '))');
}
is($state->($button),'last: short','button display is explicitly the last event');
is($perl->('scalar @{$defs{' . $button . '}{test_events} // []}'),'2','two identical presses still create two notify events');
ok(!exists $device->($button)->{Readings}{state},'button does not acquire a permanent state reading');

# Reading conventions through actual FHEM notification and persistence paths.
my $mapped = {node_id=>98902,name=>'Mapped',available=>JSON::true,attributes=>{
    '1/29/0'=>[{deviceType=>0x0106}], '1/8/0'=>127,
    '2/29/0'=>[{deviceType=>0x0202}], '2/258/14'=>3457,
    '3/29/0'=>[{deviceType=>0x000A}], '3/257/0'=>1,
    '4/29/0'=>[{deviceType=>0x0106}],
}};
$perl->('MATTER_ProcessNode($defs{io},' . $literal->($mapped) . ')');
my ($mixed,$blind,$lock)=map {"MATTER_Mapped_EP$_"} (1..3);
my $mapped_report=sub {
    my ($endpoint,$cluster,$attr,$value)=@_;
    my $event={event=>'attribute_updated',data=>[98902,"$endpoint/$cluster/$attr",$value]};
    $perl->('MATTER_ParseMessage($defs{io},JSON::encode_json(' . $literal->($event) . '))');
};
$perl->('setReadingsVal($defs{' . $mixed . '},q(brightness),127,q(2026-01-01 01:02:03))');
$cmd->("define namedEvents notify $mixed:.* { push \@{\$defs{$mixed}{named_events}}, [\$EVENT,ReadingsVal(q($mixed),q(brightness),q(?)),ReadingsVal(q($mixed),q(level),q(?))] }");
$mapped_report->(1,1024,0,30001);
is($state->($mixed),'1000 lx','lux display uses the renamed reading, not dim level');
my $mixed_readings=$device->($mixed)->{Readings};
is($mixed_readings->{brightness}{Value},1000,'actual core publishes brightness in lux');
is($mixed_readings->{level}{Value},127,'actual core preserves displaced native level');
is($mixed_readings->{level}{Time},'2026-01-01 01:02:03','source relocation preserves measurement timestamp through core API');
my $named_events=decode_json($perl->('JSON->new->ascii->encode($defs{' . $mixed . '}{named_events})'));
is_deeply([map {$_->[0]} @$named_events],['level: 127','brightness: 1000'],
    'only functional reading events are emitted; source metadata stays silent');
is_deeply([map {[@$_[1,2]]} @$named_events],[[1000,127],[1000,127]],
    'all notifications see the completed coherent quantities');
$mapped_report->(1,8,0,254);
is($state->($mixed),'1000 lx','later level report cannot replace lux in overview');
is($device->($mixed)->{Readings}{pct}{Value},100,'dimming percent reads level, not lux');
is($state->($blind),'lift: 65.43 %','cover default uses FHEM open percent');
$mapped_report->(2,258,8,99);
is($state->($blind),'lift: 65.43 %','later coarse position does not degrade fine data');
$cmd->("define lockEvents notify $lock:.* { push \@{\$defs{$lock}{lock_events}}, \$EVENT }");
$mapped_report->(3,257,0,2);
is($device->($lock)->{Readings}{state}{Value},'unlocked','lock has a real textual state reading');
is_deeply(decode_json($perl->('JSON->new->ascii->encode($defs{' . $lock . '}{lock_events})')),
    ['unlocked'],'FHEM state event uses native state-event syntax');
$cmd->("attr $lock stateFormat { 'lock=' . ReadingsVal(\$name,q(state),q(?)) }");
$mapped_report->(3,257,0,1);
is($state->($lock),'lock=locked','user format can consume the new lock state');
$cmd->("deleteattr $lock stateFormat");
$mapped_report->(1,47,14,2); $mapped_report->(1,92,3,0);
is($device->($mixed)->{Readings}{batteryState}{Value},'low','aggregate battery warning survives normal alarm report');
my $mapped_saved=$device->($mixed)->{Readings};
my $mapped_sources=$perl->('ReadingsVal(q(' . $mixed . '),q(.matterReadingSources),q())');

# Retention policy through actual global events, actual save/statefile loader,
# IO loss and disable. There is no real Matter transport connection here.
my $saved=$device->($temp)->{Readings};
$cmd->("attr $temp disable 1");
$report->(0x0302,'1026/0',2000);
is_deeply($device->($temp)->{Readings},$saved,'disabled endpoint preserves readings/timestamps');
is($state->($temp),'15.5 °C / 48 %','disable retains display');
$cmd->("attr $temp disable 0");
$perl->('MATTERDevice_UpdateAvailability($defs{MATTER_Display},0)');
$report->(0x0302,'1026/0',2000);
is($state->($temp),'15.5 °C / 48 %','offline reports cannot change the display');
$perl->('MATTER_Close($defs{io})');
is($state->($temp),'15.5 °C / 48 %','IO loss preserves endpoint display');
is($state->('MATTER_Display'),'unknown','IO loss changes only root reachability');
$perl->('DoTrigger(q(global),q(REREADCFG))');
is($state->($temp),'15.5 °C / 48 %','REREADCFG restores presentation from persisted data');
# A second IO with the same node ID stays isolated.
$cmd->('define ioOther MATTER 127.0.0.1 9; attr ioOther disable 1');
my $other_snapshot={node_id=>98900,name=>'Other',available=>JSON::true,attributes=>{"$ep/29/0"=>[{deviceType=>0x0302}],"$ep/1026/0"=>9900}};
$perl->('MATTER_ProcessNode($defs{ioOther},' . $literal->($other_snapshot) . ')');
is($state->("MATTER_Other_EP$ep"),'99 °C','second IO can use the same node and endpoint IDs');
is($state->($temp),'15.5 °C / 48 %','second IO cannot alter first IO display');
my $humid=$name_for{0x0307};
$cmd->("attr $humid stateFormat { 'saved ' . ReadingsVal(\$name,q(humidity),q(?)) }");
# Actual core save + rereadcfg loads the statefile and emits REREADCFG; no
# simulated restoration of hashes. Offline source readings must remain intact.
like($cmd->('save'),qr/Wrote configuration/,'configuration/statefile can be saved');
# Alter the configured expression after saving, so restoring the old STATE
# alone cannot pass the override check. Startup must evaluate the new expression.
open my $saved_cfg, '<', "$runtime/fhem.cfg" or die $!;
my $config=do { local $/; <$saved_cfg> };
close $saved_cfg;
$config =~ s/'saved '/'restored '/;
open $saved_cfg, '>', "$runtime/fhem.cfg" or die $!;
print {$saved_cfg} $config;
close $saved_cfg;
is($cmd->('rereadcfg'),'','actual rereadcfg runs the loader');
is($state->($humid),'restored 48','startup evaluates the configured override from restored readings');
is($state->($temp),'15.5 °C / 48 %','saved readings/types restore the default without a server report');
is($device->($alarm)->{Readings}{alarmExpressedState}{Value},'interconnect_co','readable alarm survives the actual statefile loader');
is($state->($alarm),'interconnect_co','restored default uses the readable alarm without reinterpreting it');
my $restored=$device->($temp)->{Readings};
is_deeply({map { $_=>$restored->{$_} } qw(temperature humidity deviceTypeIds)},
          {map { $_=>$saved->{$_} } qw(temperature humidity deviceTypeIds)},
          'actual loader preserves source values and timestamps');

is($state->($mixed),'1000 lx','mixed lux display restores without fresh server data');
is_deeply({map {$_=>$device->($mixed)->{Readings}{$_}} qw(brightness level pct batteryState)},
          {map {$_=>$mapped_saved->{$_}} qw(brightness level pct batteryState)},
          'real statefile loader preserves new readings and measurement timestamps');
is($perl->('ReadingsVal(q(' . $mixed . '),q(.matterReadingSources),q())'),$mapped_sources,
    'hidden source provenance is persisted by actual core save/rereadcfg');
$mapped_report->(1,8,0,0);
is($device->($mixed)->{Readings}{level}{Value},254,'unknown root availability still blocks restored mapping updates');
$perl->('MATTERDevice_UpdateAvailability($defs{MATTER_Mapped},1)');
$mapped_report->(1,92,3,0);
is($device->($mixed)->{Readings}{batteryState}{Value},'low','restored warning source cannot be cleared by unrelated normal report');
$mapped_report->(1,8,0,127);
is_deeply([map {$device->($mixed)->{Readings}{$_}{Value}} qw(brightness level pct)],
    [1000,127,50],'restored provenance keeps report quantities distinct');
$mapped_report->(2,258,8,99);
is($state->($blind),'lift: 65.43 %','fine position priority survives restore');

sub decode_utf8_content { return Encode::decode('UTF-8', $_[0]); }
done_testing();
