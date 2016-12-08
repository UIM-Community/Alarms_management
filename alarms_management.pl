# SCRIPT VERSION => 1.4

# Require librairies!
use strict;
use warnings;
use Data::Dumper;
use DBI;
use JSON;
use File::Copy;
use File::Path 'rmtree';

# Nimsoft
use lib "D:/apps/Nimsoft/perllib";
use lib "D:/apps/Nimsoft/Perl64/lib/Win32API";
use Nimbus::API;
use Nimbus::CFG;
use Nimbus::PDS;
use Socket;

# librairies
use perluim::main;
use perluim::alarms;
use perluim::nimdate;
use perluim::ump;
use perluim::log;

#
# Load configuration !
#
my $GBL_ET = time();
my $Console = new perluim::log('alarms_management.log',6);

$Console->print("########################################",5);
$Console->print("### Execution start at ".localtime()." ###",5);
$Console->print("########################################",5);

my $CFG = Nimbus::CFG->new("alarms_management.cfg");

# Ump Configuration
my @ARR_UMP         = split(",",$CFG->{"ump"}->{"servers"});
my $UMP_User 		= $CFG->{"ump"}->{"user"};
my $UMP_Password    = $CFG->{"ump"}->{"password"};
my $UMP_Pool        = new perluim::ump(@ARR_UMP);

# Setup configuration
my $Alarm_maxtime   = $CFG->{"setup"}->{"maxtime"} || 2678400; # Default 31 day
my $AuditMode       = $CFG->{"setup"}->{"audit"} || 0; # 0 == no audit mode
my $output_cache    = $CFG->{"setup"}->{"output_cache"} || 3;
my $login    		= $CFG->{"setup"}->{"login"};
my $password    	= $CFG->{"setup"}->{"password"};

# Retrive CFG value and assign fallback if no value provided!
my $alarms_inactive 		= $CFG->{"alarms"}->{"inactive"} || 0;
my $alarms_probedown 		= $CFG->{"alarms"}->{"probe_down"} || 0;
my $alarms_time 			= $CFG->{"alarms"}->{"time"} || 1;
my $alarms_clear_ip 		= $CFG->{"alarms"}->{"clear_ip"} || 0;

$UMP_Pool->checkPool($UMP_User,$UMP_Password);
if(not $UMP_Pool->isConnected()) {
    $Console->print("Unable to connect on one of the configured ump!",0);
    $Console->close();
    exit(1);
}
else {
    $Console->print("Connection to $UMP_Pool->{active} sucessfull!",6);
}

nimLogin($login,$password) if defined($login) and defined($password);

my $SDK;
$Console->print("Instanciating perluim framework and set UMP authentifcation!");
$SDK = new perluim::main($CFG->{"setup"}->{"domain"});
$SDK->setAuthentification($CFG->{"ump"}->{"user"},$CFG->{"ump"}->{"password"});
$Console->print("Create output directory.");
my $output_date = $SDK->getDate();
$SDK->createDirectory("output/$output_date");
$Console->cleanDirectory("output",$output_cache);

#
# Get all alarms
#
my $HTTP_Res = $SDK->HTTP("GET","$UMP_Pool->{active}/rest/alarms");
if($HTTP_Res->{"_rc"} == 200) {
    $Console->print("Getting alarms from UMP RESTService OK!");

    $Console->print("Parsing and saving alarms.");
    my $HASH_UMP_Alarms = JSON->new->utf8(1)->decode( $HTTP_Res->decoded_content );
    my @ARR_Alarms = ();
    foreach ( @{ $HASH_UMP_Alarms->{"alarm"} } ) {
        push(@ARR_Alarms,new perluim::alarms($_));
    }
    undef $HASH_UMP_Alarms;
    undef $HTTP_Res;

    my %CleanStats = (
        dead => 0,
        fail_restart => 0,
        inactive_robot => 0,
		clear_ip => 0
    );

    my $Acknowledge = 0;
    my %AcknowledgeID = ();

    sub FN_Acknowledge {
        my ($msg,$var) = @_;
        $Console->print($msg);
        $CleanStats{$var}++;
        $Acknowledge = 1;
    }

	sub addID {
		my ($id) = @_;
		$AcknowledgeID{$id} = 1;
	}

	my $Alarms_count = scalar @ARR_Alarms;
    $Console->print("Detecting alarms which have to be Acknowledge, number of alarms => $Alarms_count",4);
    foreach (@ARR_Alarms) {

		$Acknowledge = 0;

		next if not defined $_->{hostname};
		next if not defined $_->{id};
		next if exists $AcknowledgeID{$_->{id}};

		my $nimDate = new perluim::nimdate($_->{timeLast});
		$Console->print("[$_->{hostname}] Processing AlarmID $_->{id} - date : $_->{timeLast} with a difference of ".abs($nimDate->{diff})." seconds");

        #
        # Date difference
        #
        if($alarms_time eq "1" && not $Acknowledge) {
            FN_Acknowledge("Acknowledge dead alarm in time $_->{id} , last occurence => $_->{timeLast}","dead") if abs($nimDate->{diff}) >= $Alarm_maxtime;
        }

		# Detect if robotname is ip
		if($_->{hostname} =~ /^\d+.\d+.\d+.\d+$/ and $alarms_clear_ip) {
			my $ip = $_->{hostname};
			if($ip ne "127.0.0.1" || index($ip, "169.254") == -1) {
				FN_Acknowledge("Acknowledge ip $ip","clear_ip");
			}
		}

        #
        # Robot is inactive!
        #
        if($alarms_inactive eq "1" && not $Acknowledge) {
            if(index($_->{message}, "is inactive") != -1) {
                my $PDS = pdsCreate();
            	my ($RC, $O) = nimNamedRequest("/$_->{domain}/$_->{hub}/$_->{robot}", "get_info", $PDS,1);
            	pdsDelete($PDS);
                FN_Acknowledge("Acknowledge robot is inactive $_->{id} , the robot is now active!","inactive_robot") if $RC == NIME_OK;
            }
        }

		#
		# Probe failed to start!
		#
		if($alarms_probedown eq "1" && not $Acknowledge) {
			if (index($_->{message}, "FAILED to start") != -1) {
				my $HTTP_RobotNFO = $SDK->HTTP("GET","$UMP_Pool->{active}/rest/hubs/$_->{domain}/$_->{hub}/$_->{robot}");
				if($HTTP_RobotNFO->{"_rc"} == 200) {
					my $HASH_Robots = JSON->new->utf8(1)->decode( $HTTP_RobotNFO->decoded_content );
					foreach my $probe ( @{ $HASH_Robots->{"probes"} } ) {
						if($probe->{command} eq "$_->{suppressionKey}.exe" && $probe->{active} eq "true") {
							FN_Acknowledge("Acknowledge probe failed to start $_->{id}, probe $_->{suppressionKey} on robot $_->{robot}","fail_restart");
							last;
						}
					}
				}
			}
		}

        addID($_->{id}) if $Acknowledge;
    }
    undef $Acknowledge;
    undef $Alarm_maxtime;
    undef @ARR_Alarms;

    #
    # Stats echo...
    #
	$Console->print("--------------------------------------------",5);
    $Console->print("Finals stats :");
    foreach my $StatsKey (keys %CleanStats) {
        $Console->print("$StatsKey => $CleanStats{$StatsKey}",5);
    }
    undef %CleanStats;
	$Console->print("--------------------------------------------",5);
	$Console->print("");

    #
    # Acknowledge alarms
    #
    my $Acknowledge_count = 1;
    my $max = keys %AcknowledgeID;
	my %FailedAcknowLedge = ();
    if($max > 0) {
        $Console->print("Starting acknowledge in bulk, number of acknowledge to do => $max");
        if(not $AuditMode) {
            foreach my $alarmid (keys %AcknowledgeID) {
                $Console->print("Acknowledge now -> $alarmid [count $Acknowledge_count / $max]");
                $Acknowledge_count++;
                my $HTTP_Acknowledge = $SDK->PUT("$UMP_Pool->{active}/rest/alarms/$alarmid/ack");
                if($HTTP_Acknowledge->{"_rc"} != 204) {
                    $Console->print("Fail to acknowledge -> $alarmid");
					$FailedAcknowLedge{$alarmid} = 1;
                }
            }
        }
        else {
            $Console->print("No acknowledge action because AuditMode is activated!",2);
        }
    }
    else {
        $Console->print("No alarms to acknowledge, terminating the script...");
    }

}
else {
    $Console->print("Failed to get alarms list!",0);
}

$Console->finalTime($GBL_ET);
$| = 1; # Fix buffering issue
sleep(2);
$Console->copyTo('output');
$Console->close();
1;
