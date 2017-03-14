#!/usr/bin/perl

#documentation
#https://www.zabbix.com/documentation/3.0/ru/manual/api/reference/event/get
#http://www.onlineconversion.com/unix_time.htm

use strict;
use warnings;

use Excel::Writer::XLSX;
use MIME::Lite;
use JSON::RPC::Client;
use Date::Calc qw(Today_and_Now Add_Delta_Days);
use Time::Local;
use Data::Dumper;
use utf8;

binmode(STDOUT,':utf8');

#================================================================
#Constants
#================================================================
#
use constant DELTA		=> -1;

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

#DEBUG
use constant DEBUG		=> 0; #0 - False, 1 - True
use constant LIMIT		=> 15;

#================================================================
##Global variables
#================================================================
my $ZABBIX_AUTH_ID;
my %EVENTS;

my %EVENT_VALUE = (
		    0 => 'OK',
		    1 => 'PROBLEM'
);

my %COLOR_EVENT_VALUE = (
		    OK 		=> '#00AA00',
		    PROBLEM	=> '#DC0000'
);

my %EVENT_SOURCE = (
		    0 => 'Trigger',
		    1 => 'Discovery rule',
		    2 => 'Auto-registration',
		    3 => 'Internal event'
);

my %EVENT_ACKNOWLEDGED = (
		    0 => 'No',
		    1 => 'Yes'
);

my %TRIGGER_PRIORITY = (
		    0 => 'Not classified',
		    1 => 'Information',
		    2 => 'Warning',
		    3 => 'Average',
		    4 => 'High',
		    5 => 'Disaster'
);

my %COLOR_TRIGGER_PRIORITY = (
		    0 => '#97AAB3',	#Not classified
		    1 => '#7499FF',	#Information
		    2 => '#FFC859',	#Warning
		    3 => '#FFA059',	#Average
		    4 => '#E97659',	#High
		    5 => '#E45959'	#Disaster
);

#================================================================
main();

#================================================================
sub main
{
    system('clear');
	
	print "*** Start ***\n";

    if (zabbix_auth() != 0)
    {
	zabbix_get_events();
	zabbix_logout();
	save_to_excel('zabbix_report_events');
    }

    print "*** Done ***\n";
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
	print "Authentication failed, zabbix server: " . ZABBIX_SERVER . "\n" if DEBUG;

	return 0;
    }

    $ZABBIX_AUTH_ID = $response->content->{'result'};

    print "Authentication successful. Auth ID: $ZABBIX_AUTH_ID\n" if DEBUG;

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
	print "Logout failed, zabbix server: " . ZABBIX_SERVER . "\n" if DEBUG;

	return 0;
    }

    print "Logout successful. Auth ID: $ZABBIX_AUTH_ID\n" if DEBUG;

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
    #$data{'params'}{'time_from'} = '1488931200';
	$data{'params'}{'time_from'} = get_delta_date();

    #Return only events that have been created before or at the given time
    $data{'params'}{'time_till'} = get_current_time();

    $data{'params'}{'sortorder'} = 'DESC'; #DESC or ASC

    #Sort the result by the given properties
    #Possible values are: eventid, objectid and clock
    $data{'params'}{'sortfield'} = ['clock', 'eventid'];

    #for debug
    $data{'params'}{'limit'} = LIMIT if DEBUG;

    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    my $count = 0;
    foreach my $event(@{$response->content->{'result'}}) 
    {
	my $eventid = $event->{'eventid'};
	my $objectid = $event->{'objectid'};
	my $clock = $event->{'clock'}; #Time when the event was created
	my $value =  $EVENT_VALUE{$event->{'value'}};
	my $source = $EVENT_SOURCE{$event->{'source'}};
	my $acknowledged = $EVENT_ACKNOWLEDGED{$event->{'acknowledged'}}; #If set to true return only acknowledged events

	fill_events($count, $eventid, $objectid, $clock, $value, $source, $acknowledged);

	zabbix_get_trigger($count, $objectid, $eventid);

	$count++;

    }

    $EVENTS{'result'}{'total'} = $count;
}

#================================================================
sub zabbix_get_trigger
{
    my ($count, $objectid, $eventid) = @_;
    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'trigger.get';

    $data{'params'}{'output'} = 'extend';
    $data{'params'}{'triggerids'} = $objectid;
    $data{'params'}{'selectHosts'} = ['hostid', 'name', 'status'];

    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

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
	#5 - disaster
	my $priority_name = $TRIGGER_PRIORITY{$trigger->{'priority'}};

	my $host;
	my $priority_number;
	foreach my $hosts(@{$trigger->{'hosts'}})
	{
	    $host = $hosts->{'name'};
	    $priority_number = $trigger->{'priority'};
	}

	fill_triggers($count, $eventid, $host, $description, $priority_name, $priority_number);
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
sub get_delta_date
{
    my ($current_year, $current_month, $current_day, $current_hour, $current_min, $current_sec) = Today_and_Now();

    my ($year, $month, $day) = Add_Delta_Days($current_year, $current_month, $current_day, DELTA);

    my $date_unix = timegm($current_sec, $current_min, $current_hour, $day, $month-1, $year-1900);

    return $date_unix;
}

#================================================================
sub fill_events
{
    my ($count, $eventid, $objectid, $clock, $value, $source, $acknowledged) = @_;

    $EVENTS{'result'}{'events'}[$count]{$eventid}{'objectid'} = $objectid;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'clock'} = unix_time_to_date($clock);
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'value'} = $value;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'source'} = $source;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'acknowledged'} = $acknowledged;
}

#================================================================
sub fill_triggers
{
    my ($count, $eventid, $host, $description, $priority_name, $priority_number) = @_;

    $EVENTS{'result'}{'events'}[$count]{$eventid}{'host'} = $host;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'description'} = $description;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'priority_name'} = $priority_name;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'priority_number'} = $priority_number;
}

#================================================================
sub save_to_excel
{
    my $file = shift;

    my $workbook  = Excel::Writer::XLSX->new(PATH_FOR_SAVING . $file . '.xlsx');
    my $worksheet = $workbook->add_worksheet('Report about events');

    $workbook->set_properties(
				title    => 'Report about events',
				author   => 'Zabbix',
				comments => 'Created by Perl and Excel::Writer::XLSX',
    );

    my $format_header = $workbook->add_format(border => 2);

    #Font for header
    $format_header->set_bold();
    $format_header->set_color('red');
    $format_header->set_size(14);
    $format_header->set_font('Cambria');

    $format_header->set_align('center');

    $format_header->set_bg_color('#FFFFCC');

    #Header
    $worksheet->write("A1", 'Time', $format_header);
    $worksheet->write("B1", 'Host', $format_header);
    $worksheet->write("C1", 'Description', $format_header);
    $worksheet->write("D1", 'Status', $format_header);
    $worksheet->write("E1", 'Severity', $format_header);
    $worksheet->write("F1", 'Ask', $format_header);

    $worksheet->freeze_panes(1, 0);

    #Font for data
    my $format_data = $workbook->add_format(border => 1);

    $format_data->set_color('black');
    $format_data->set_size(14);
    $format_data->set_font('Cambria');
    $format_data->set_text_wrap();

    $format_data->set_align('left');
    $format_data->set_align('vcenter');

    $worksheet->set_column('A:A', 45);
    $worksheet->set_column('B:B', 35);
    $worksheet->set_column('C:C', 100);
    $worksheet->set_column('D:D', 20);
    $worksheet->set_column('E:E', 30);
    $worksheet->set_column('F:F', 15);

    #Enable auto-filter
    $worksheet->autofilter('A1:F1');

    my $total = $EVENTS{'result'}{'total'};

    print "Total events: $total\n" if DEBUG;

    foreach my $result($EVENTS{'result'})
    {
	my $row = 0;
	foreach my $event(@{$result->{'events'}})
	{
	    print Dumper $event if DEBUG;

	    foreach my $eventid(keys $event)
	    {
		my $date = $event->{$eventid}->{'clock'};

		my $host = $event->{$eventid}->{'host'};

		my $description = $event->{$eventid}->{'description'};

		#Status
		my $status = $event->{$eventid}->{'value'};

		#Font for status
		my $format_status = $workbook->add_format(border => 1);

		$format_status->set_color($COLOR_EVENT_VALUE{$status});
		$format_status->set_size(14);
		$format_status->set_font('Cambria');
		$format_status->set_align('vcenter');

		#Priority
		my $priority_name = $event->{$eventid}->{'priority_name'};
		my $priority_number = $event->{$eventid}->{'priority_number'};

		#Font for priority
		my $format_priority = $workbook->add_format(border => 1);

		$format_priority->set_color('black');
		$format_priority->set_size(14);
		$format_priority->set_font('Cambria');
		$format_priority->set_text_wrap();
		$format_priority->set_align('vcenter');
		#print ">>> " . $COLOR_TRIGGER_PRIORITY{$priority_number} . "\n";
		$format_priority->set_bg_color($COLOR_TRIGGER_PRIORITY{$priority_number});

		my $acknowledged = $event->{$eventid}->{'acknowledged'};

		$worksheet->write($row+1, 0, $date, $format_data);

		$worksheet->write($row+1, 1, $host, $format_data);

		$worksheet->write($row+1, 2, $description, $format_data);

		$worksheet->write($row+1, 3, $status, $format_status);

		$worksheet->write($row+1, 4, $priority_name, $format_priority);

		$worksheet->write($row+1, 5, $acknowledged, $format_data);
	    }
	$row++;
	}
    }

    #Close
    $workbook->close;
}

#================================================================
sub send_report
{
}
