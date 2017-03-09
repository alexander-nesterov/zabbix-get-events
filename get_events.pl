#!/usr/bin/perl

#documentation
#https://www.zabbix.com/documentation/3.0/ru/manual/api/reference/event/get
#http://www.onlineconversion.com/unix_time.htm

#event.value
#0 - OK
#1 - PROBLEM

use strict;
use warnings;

use JSON::XS qw(encode_json decode_json);
use Excel::Writer::XLSX;
use MIME::Lite;
use JSON::RPC::Client;
use Data::Dumper;
use utf8;

binmode(STDOUT,':utf8');

#================================================================
#Constants
#================================================================

#ZABBIX
use constant ZABBIX_USER	=> 'Admin';
use constant ZABBIX_PASSWORD	=> 'zabbix';
use constant ZABBIX_SERVER	=> 'zabbix';

#MAIL
use constant FROM		=> 'report\@your_domain';
use constant RECIPIENT		=> 'info\@your_domain';
use constant SUBJECT		=> 'zabbix events';
use constant SMTP_SERVER	=> '127.0.0.1';

#EXCEL
use constant PATH_FOR_SAVING	=> '/home/sa/';

#================================================================
##Global variables
#================================================================
my $ZABBIX_AUTH_ID;
#my $PATH_FOR_SAVING = '/home/sa/';


my %event_value = (
		    0 => 'OK',
		    1 => 'PROBLEM'
);

my %event_source = (
		    0 => 'Trigger',
		    1 => 'Discovery rule',
		    2 => 'Auto-registration',
		    3 => 'Internal event'
);

my %event_acknowledged = (
		    0 => 'NO',
		    1 => 'YES'
);

my %trigger_priority = (
		    0 => 'Not classified',
		    1 => 'Information',
		    2 => 'Warning',
		    3 => 'Average',
		    4 => 'High',
		    5 => 'Disaster'
);

#================================================================
main();

#================================================================
sub main
{
    system('clear');

    if (zabbix_auth() != 0)
    {
	zabbix_get_events();
	zabbix_logout();
        save_to_excel('zabbix_report_events');
    }
}

#================================================================
sub zabbix_auth
{
    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'user.login';
    $data{'params'}{'user'} = ZABBIX_USER;
    $data{'params'}{'password'} = ZABBIX_PASSWORD;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    if (!defined($response))
    {
	print "Authentication failed, zabbix server: ". ZABBIX_SERVER . "\n";
	return 0;
    }

    $ZABBIX_AUTH_ID = $response->content->{'result'};

    print "Authentication successful. Auth ID: $ZABBIX_AUTH_ID\n";

    undef $response;

    return 1;
}

#================================================================
sub zabbix_logout
{
    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'user.logout';
    $data{'params'} = [];
    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    if (!defined($response))
    {
        print "Logout failed, zabbix server: " . ZABBIX_SERVER . "\n";
        return 0;
    }

    print "Logout successful. Auth ID: $ZABBIX_AUTH_ID\n";

    undef $response;
}


#================================================================
sub send_to_zabbix
{
    my $json = shift;

    my $response;

    my $url = "http://" . ZABBIX_SERVER . "/api_jsonrpc.php";

    my $client = new JSON::RPC::Client;

    $response = $client->call($url, $json);

    #print Dumper $response;

    return $response;
}

#================================================================
sub zabbix_get_events
{
    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'event.get';

    #Possible values:
    #0 - event created by a trigger
    #1 - event created by a discovery rule
    #2 - event created by active agent auto-registration
    #3 - internal event
    $data{'source'} = 0;

    $data{'params'}{'output'} = 'extend';

    #Return only events that have been created after or at the given time
    $data{'params'}{'time_from'} = '1488931200';

    #Return only events that have been created before or at the given time
    $data{'params'}{'time_till'} = get_current_time();

    $data{'params'}{'sortorder'} = 'DESC'; #DESC or ASC

    #Sort the result by the given properties
    #Possible values are: eventid, objectid and clock
    $data{'params'}{'sortfield'} = ['clock', 'eventid'];

    #for debug
    $data{'params'}{'limit'} = 2;

    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    #print Dumper \%data;

    my $response = send_to_zabbix(\%data);


   foreach my $event(@{$response->content->{'result'}}) 
   {
	my $eventid = $event->{'eventid'};
	my $objectid = $event->{'objectid'};
	my $clock = $event->{'clock'}; #Time when the event was created
	my $value =  $event_value{$event->{'value'}};
	my $source = $event_source{$event->{'source'}};
	my $acknowledged = $event_acknowledged{$event->{'acknowledged'}}; #If set to true return only acknowledged events

	print "Clock => " . unix_time_to_date($clock) . "\n";
	print "ObjectID => $objectid\n";
	print "Status => $value\n";
	print "Source => $source\n";
	print "Acknowledged => $acknowledged\n";

	zabbix_get_trigger($objectid);

	print "=" x 50 . "\n";
   }
}

#================================================================
sub zabbix_get_trigger
{
    my $triggerid = shift;
    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'trigger.get';

    $data{'params'}{'output'} = 'extend';
    $data{'params'}{'triggerids'} = $triggerid;
    $data{'params'}{'selectHosts'} = ['hostid', 'name', 'status'];

    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    #print Dumper $response;

    foreach my $trigger(@{$response->content->{'result'}})
    {
        my $triggerid = $trigger->{'triggerid'};
	my $description = $trigger->{'description'};
	my $comments = $trigger->{'comments'};

	#Severity of the trigger
	#Possible values are:
	#0 - (default) not classified;
	#1 - information;
	#2 - warning;
	#3 - average;
	#4 - high;
	#5 - disaster.
	my $priority = $trigger_priority{$trigger->{'priority'}};

        my $host;
        foreach my $hosts(@{$trigger->{'hosts'}})
        {
	    $host = $hosts->{'name'};
        }

	print "Host => $host\n";
	print "TriggerID => $triggerid\n";
	print "Description => $description\n";
	print "Comments => $comments\n";
	print "Priority => $priority\n";
   }
}

#================================================================
sub get_current_time
{
    return time;
}

#================================================================
sub unix_time_to_date
{
    my $unix_time = shift;

    return localtime($unix_time);
}

#================================================================
sub save_to_excel
{
    my $file = shift;

    my $workbook  = Excel::Writer::XLSX->new(PATH_FOR_SAVING . $file . '.xlsx');
    my $worksheet = $workbook->add_worksheet('Report');

    $workbook->set_properties(
				title    => 'Report',
				author   => 'Zabbix',
				comments => 'Created by Perl and Excel::Writer::XLSX',
    );

    my $format_header = $workbook->add_format(border => 2);

    #Font for header
    $format_header->set_bold();
    $format_header->set_color('red');
    $format_header->set_size(16);
    $format_header->set_font('Cambria');

    $format_header->set_align('center');

    $format_header->set_bg_color('#FFFFCC');

    #Header
    $worksheet->write("A1", 'Time', $format_header);
    $worksheet->write("B1", 'Host', $format_header);
    $worksheet->write("C1", 'Description', $format_header);
    $worksheet->write("D1", 'Status', $format_header);
    $worksheet->write("E1", 'Severity', $format_header);

    $worksheet->freeze_panes(1, 0);

    my $format = $workbook->add_format(border => 1);

    #Font for data
    $format->set_color('black');
    $format->set_size(14);
    $format->set_font('Cambria');
    $format->set_text_wrap();

    $format->set_align('left');
    $format->set_align('vcenter');

    $worksheet->set_column('A:A', 25);
    $worksheet->set_column('B:B', 35);
    $worksheet->set_column('C:C', 40);
    $worksheet->set_column('D:D', 35);
    $worksheet->set_column('E:E', 35);

    #Enable auto-filter
    $worksheet->autofilter('A1:E1');



    $workbook->close;
}

