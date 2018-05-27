#!/usr/bin/perl

#documentation
#https://www.zabbix.com/documentation/3.0/ru/manual/api/reference/event/get
#http://www.onlineconversion.com/unix_time.htm

=begin comment
example:
perl get_events.pl --server 'http://localhost/api_jsonrpc.php' \
--user 'Admin' \
--pwd 'password' \
--file '/home/sa/report.xlsx' \
--day -100 \
--hour 1 \
--debug 1
=cut

use v5.22;
use strict;
use warnings;
use LWP::UserAgent;
use Getopt::Long qw(GetOptions);
use JSON qw(encode_json decode_json);
use Excel::Writer::XLSX;
use MIME::Lite;
use POSIX qw(strftime);
use Date::Calc qw(Add_Delta_DHMS Localtime);
use Time::Local;
use Data::Dumper;
use utf8;

binmode(STDOUT,':utf8');

my $ZABBIX_SERVER;
my $DEBUG;
my $ZABBIX_AUTH_ID;
my %EVENTS;
my $FROM_TIME;
my $TILL_TIME;
my $DELTA_DAYS = 0;
my $DELTA_HOURS = 0;

#MAIL
use constant FROM	 => 'report\@your_domain';
use constant RECIPIENT	 => 'info\@your_domain';
use constant SUBJECT	 => 'zabbix events';
use constant SMTP_SERVER => '127.0.0.1';

my %EVENT_VALUE;
$EVENT_VALUE{0} = 'OK';
$EVENT_VALUE{1} = 'PROBLEM';

my %COLOR_EVENT_VALUE;
$COLOR_EVENT_VALUE{'OK'}      = '#00AA00';
$COLOR_EVENT_VALUE{'PROBLEM'} = '#DC0000';

my %EVENT_SOURCE;
$EVENT_SOURCE{0} = 'Trigger';
$EVENT_SOURCE{1} = 'Discovery rule';
$EVENT_SOURCE{2} = 'Auto-registration';
$EVENT_SOURCE{3} = 'Internal event';

my %EVENT_ACKNOWLEDGED;
$EVENT_ACKNOWLEDGED{0} = 'No';
$EVENT_ACKNOWLEDGED{1} = 'Yes';

my %TRIGGER_PRIORITY;
$TRIGGER_PRIORITY{0} = 'Not classified';
$TRIGGER_PRIORITY{1} = 'Information';
$TRIGGER_PRIORITY{2} = 'Warning';
$TRIGGER_PRIORITY{3} = 'Average';
$TRIGGER_PRIORITY{4} = 'High';
$TRIGGER_PRIORITY{5} = 'Disaster';

my %COLOR_TRIGGER_PRIORITY;
$COLOR_TRIGGER_PRIORITY{0} = '#97AAB3';
$COLOR_TRIGGER_PRIORITY{1} = '#7499FF';
$COLOR_TRIGGER_PRIORITY{2} = '#FFC859';
$COLOR_TRIGGER_PRIORITY{3} = '#FFA059';
$COLOR_TRIGGER_PRIORITY{4} = '#E97659';
$COLOR_TRIGGER_PRIORITY{5} = '#E45959';

main();

sub parse_argv
{
    my $zbx_server;
    my $zbx_user;
    my $zbx_pwd;
    my $report_file;
    my $day = 0;
    my $hour = 0;
    my $debug = 0;

    GetOptions('server=s'  =>  \$zbx_server,       #Zabbix server
               'user=s'    =>  \$zbx_user,         #User
               'pwd=s'     =>  \$zbx_pwd,          #Password
               'file=s'    =>  \$report_file,      #Name of file
               'day=i'     =>  \$day,      	   #
               'hour=i'    =>  \$hour,             #
               'debug=i'   =>  \$debug             #

    ) or do { exit(-1); };

    return ($zbx_server, $zbx_user, $zbx_pwd, $report_file, $day, $hour, $debug);
}

sub zabbix_auth
{
    my ($user, $pwd) = @_;

    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'user.login';
    $data{'params'}{'user'} = $user;
    $data{'params'}{'password'} = $pwd;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);
 
    $ZABBIX_AUTH_ID = get_result($response);
    do_debug('Auth ID: ' . $ZABBIX_AUTH_ID, 'SUCCESS');
}

sub zabbix_logout
{
    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'user.logout';
    $data{'params'} = [];
    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    my $result = get_result($response);
    do_debug("Logout: $result", 'SUCCESS');
}

sub send_to_zabbix
{
    my $data_ref = shift;

    my $json = encode_json($data_ref);
    my $ua = create_ua();

    my $response = $ua->post($ZABBIX_SERVER,
                            'Content_Type'  => 'application/json',
                            'Content'       => $json,
                            'Accept'        => 'application/json'
    );

    if ($response->is_success)
    {
        my $content_decoded = decode_json($response->content);
        if (is_error($content_decoded))
        {
            do_debug('Error: ' . get_error($content_decoded), 'ERROR');
            exit(-1);
        }
        return $content_decoded;
    }
    else
    {
        do_debug('Error: ' . $response->status_line, 'ERROR');
        exit(-1);
    }
}

sub is_error
{
    my $content = shift;

    if ($content->{'error'})
    {
        return 1;
    }
    return 0;
}

sub get_result
{
    my $content = shift;

    return $content->{'result'};
}

sub get_error
{
    my $content = shift;

    return $content->{'error'}{'data'};
}

sub create_ua
{
    my $ua = LWP::UserAgent->new();

    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0x00);
    return $ua;
}

sub colored
{
    my ($text, $color) = @_;

    my %colors = ('red'     => 31,
                  'green'   => 32,
                  'white'  => 37
    );
    my $c = $colors{$color};
    return "\033[" . "$colors{$color}m" . $text . "\e[0m";
}

sub do_debug
{
    my ($text, $level) = @_;

    if ($DEBUG)
    {
        my %lev = ('ERROR'   => 'red',
                   'SUCCESS' => 'green',
                   'INFO'    => 'white'
        );
        print colored("$text\n", $lev{$level});
    }
}

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
    $data{'params'}{'time_from'} = $FROM_TIME;

    #Return only events that have been created before or at the given time
    $data{'params'}{'time_till'} = $TILL_TIME;

    $data{'params'}{'sortorder'} = 'DESC'; #DESC or ASC

    #Sort the result by the given properties
    #Possible values are: eventid, objectid and clock
    $data{'params'}{'sortfield'} = ['clock', 'eventid'];

    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    my $count = 0;
    foreach my $event(@{$response->{'result'}}) 
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

    foreach my $trigger(@{$response->{'result'}})
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

sub get_date
{
    return strftime '%Y%m%d', localtime;
}

sub get_localtime
{
    my ($current_year, $current_month, $current_day, $current_hour, $current_min, $current_sec) = Localtime();

    return ($current_year-1900, $current_month-1, $current_day, $current_hour, $current_min, $current_sec);
}

sub get_current_epoch_time
{
    my ($current_year, $current_month, $current_day, $current_hour, $current_min, $current_sec) = get_localtime();

    my $time = timegm($current_sec, $current_min, $current_hour, $current_day, $current_month, $current_year);
    do_debug("TILL_TIME: $time = " . epoch_to_normal_date($time), 'INFO');

    return $time;
}

sub epoch_to_normal_date
{
    my $unix_time = shift;

    return gmtime($unix_time);
}

sub get_delta_from_current_date
{
    my ($current_year, $current_month, $current_day, $current_hour, $current_min, $current_sec) = get_localtime();

    my ($year, $month, $day, $hour, $min, $sec) = Add_Delta_DHMS($current_year, $current_month, $current_day, $current_hour, $current_min, $current_sec,
								$DELTA_DAYS, $DELTA_HOURS, 0, 0);

    my $date_unix = timegm($current_sec, $current_min, $hour, $day, $month, $year);

    do_debug("FROM_TIME: $date_unix = " . epoch_to_normal_date($date_unix), 'INFO');

    return $date_unix;
}

sub fill_events
{
    my ($count, $eventid, $objectid, $clock, $value, $source, $acknowledged) = @_;

    $EVENTS{'result'}{'events'}[$count]{$eventid}{'objectid'} = $objectid;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'clock'} = epoch_to_normal_date($clock);
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'value'} = $value;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'source'} = $source;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'acknowledged'} = $acknowledged;
}

sub fill_triggers
{
    my ($count, $eventid, $host, $description, $priority_name, $priority_number) = @_;

    $EVENTS{'result'}{'events'}[$count]{$eventid}{'host'} = $host;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'description'} = $description;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'priority_name'} = $priority_name;
    $EVENTS{'result'}{'events'}[$count]{$eventid}{'priority_number'} = $priority_number;
}

sub create_workbook
{
    my $file_report = shift;
    
    my $workbook  = Excel::Writer::XLSX->new($file_report);

    $workbook->set_properties(
       title    => 'Report about events',
       author   => 'Zabbix',
       comments => ''
    );
    return $workbook
}

sub create_worksheets
{
    my ($workbook, $worksheet_name_info, $worksheet_name_data) = @_;
    
    my $worksheet_info = $workbook->add_worksheet($worksheet_name_info);
    my $worksheet_data = $workbook->add_worksheet($worksheet_name_data);

    return ($worksheet_info, $worksheet_data);
}

sub close_workbook
{
    my $workbook = shift;
    
    $workbook->close;
}

sub set_header_info
{
    my $workbook = shift;

    my $format_header_info = $workbook->add_format(border => 2);

    $format_header_info->set_bold();
    $format_header_info->set_color('red');
    $format_header_info->set_size(14);
    $format_header_info->set_font('Cambria');
    $format_header_info->set_align('center');
    $format_header_info->set_bg_color('#FFFFCC');

    return $format_header_info;
}

sub set_header_data
{
    my $workbook = shift;

    my $format_header_data = $workbook->add_format(border => 1);

    $format_header_data ->set_color('black');
    $format_header_data ->set_size(14);
    $format_header_data ->set_font('Cambria');
    $format_header_data ->set_text_wrap();
    $format_header_data ->set_align('left');
    $format_header_data ->set_align('vcenter');

    return $format_header_data ;
}

sub set_font_data_for_level
{
    my ($workbook, $color_trigger_proitity) = @_;

    my $format_data = $workbook->add_format();
    $format_data->set_color('black');
    $format_data->set_size(14);
    $format_data->set_font('Cambria');
    $format_data->set_bg_color($color_trigger_proitity);

    return $format_data;
}

sub save_to_excel
{
    my ($workbook, $worksheet_info, $format_header_info, $worksheet_data, $format_header_data) = @_;

    my ($status_OK,
	$status_PROBLEM,
	$not_classified,
	$information,
	$warning,
	$average,
	$high,
	$disaster) = (0,0,0,0,0,0,0,0);

    #Header
    $worksheet_data->write("A1", 'Time', $format_header_info);
    $worksheet_data->write("B1", 'Host', $format_header_info);
    $worksheet_data->write("C1", 'Description', $format_header_info);
    $worksheet_data->write("D1", 'Status', $format_header_info);
    $worksheet_data->write("E1", 'Severity', $format_header_info);
    $worksheet_data->write("F1", 'Ask', $format_header_info);

    $worksheet_data->freeze_panes(1, 0);

    $worksheet_data->set_column('A:A', 45);
    $worksheet_data->set_column('B:B', 35);
    $worksheet_data->set_column('C:C', 100);
    $worksheet_data->set_column('D:D', 20);
    $worksheet_data->set_column('E:E', 30);
    $worksheet_data->set_column('F:F', 15);

    #Enable auto-filter
    $worksheet_data->autofilter('A1:F1');

    my $total = $EVENTS{'result'}{'total'};

    do_debug("Total events: $total", 'INFO');

    foreach my $result($EVENTS{'result'})
    {
	my $row = 0;
	foreach my $event(@{$result->{'events'}})
	{
	    foreach my $eventid(keys %$event)
	    {
		my $date = $event->{$eventid}->{'clock'};
		my $host = $event->{$eventid}->{'host'};
		my $description = $event->{$eventid}->{'description'};

		#Status
		my $status = $event->{$eventid}->{'value'};

		if ($status eq 'OK') { $status_OK++; }
		if ($status eq 'PROBLEM') { $status_PROBLEM++; }

		#Font for status
		my $format_status = $workbook->add_format(border => 1);

		$format_status->set_color($COLOR_EVENT_VALUE{$status});
		$format_status->set_size(14);
		$format_status->set_font('Cambria');
		$format_status->set_align('vcenter');

		#Priority
		my $priority_name = $event->{$eventid}->{'priority_name'};
		my $priority_number = $event->{$eventid}->{'priority_number'};

		if ($priority_number == 0) {$not_classified++;}
		if ($priority_number == 1) {$information++;}
		if ($priority_number == 2) {$warning++;}
		if ($priority_number == 3) {$average++;}
		if ($priority_number == 4) {$high++;}
		if ($priority_number == 5) {$disaster++;}

		#Font for priority
		my $format_priority = $workbook->add_format(border => 1);

		$format_priority->set_color('black');
		$format_priority->set_size(14);
		$format_priority->set_font('Cambria');
		$format_priority->set_text_wrap();
		$format_priority->set_align('vcenter');
		$format_priority->set_bg_color($COLOR_TRIGGER_PRIORITY{$priority_number});

		my $acknowledged = $event->{$eventid}->{'acknowledged'};

		$worksheet_data->write($row+1, 0, $date, $format_header_data);
		$worksheet_data->write($row+1, 1, $host, $format_header_data);
		$worksheet_data->write($row+1, 2, $description, $format_header_data);
		$worksheet_data->write($row+1, 3, $status, $format_status);
		$worksheet_data->write($row+1, 4, $priority_name, $format_priority);
		$worksheet_data->write($row+1, 5, $acknowledged, $format_header_data);
	    }
	$row++;
	}
    }

    #Information
    $format_header_info = $workbook->add_format();
    $format_header_info->set_bold();
    $format_header_info->set_color('black');
    $format_header_info->set_size(14);
    $format_header_info->set_font('Cambria');
    $format_header_info->set_align('left');


    my $format_not_classified = set_font_data_for_level($workbook, $COLOR_TRIGGER_PRIORITY{0});
    my $format_information = set_font_data_for_level($workbook, $COLOR_TRIGGER_PRIORITY{1});
    my $format_warning = set_font_data_for_level($workbook, $COLOR_TRIGGER_PRIORITY{2});
    my $format_average = set_font_data_for_level($workbook, $COLOR_TRIGGER_PRIORITY{3});
    my $format_high = set_font_data_for_level($workbook, $COLOR_TRIGGER_PRIORITY{4});
    my $format_disaster = set_font_data_for_level($workbook, $COLOR_TRIGGER_PRIORITY{5});
    my $format_OK = set_font_data_for_level($workbook, $COLOR_EVENT_VALUE{'OK'});
    my $format_PROBLEM = set_font_data_for_level($workbook, $COLOR_EVENT_VALUE{'PROBLEM'});

    $worksheet_info->set_column('A:A', 25);
    $worksheet_info->set_column('B:B', 40);

    $worksheet_info->write("A1", 'From:', $format_header_info);
    $worksheet_info->write("A2", 'Till:', $format_header_info);
    $worksheet_info->write("A4", 'Not classified:', $format_not_classified);
    $worksheet_info->write("A5", 'Information:', $format_information);
    $worksheet_info->write("A6", 'Warning:', $format_warning);
    $worksheet_info->write("A7", 'Average:', $format_average);
    $worksheet_info->write("A8", 'High:', $format_high);
    $worksheet_info->write("A9", 'Disaster:', $format_disaster);

    $worksheet_info->write("A11", 'OK:', $format_OK);
    $worksheet_info->write("A12", 'PROBLEM:', $format_PROBLEM);

    $worksheet_info->write(0, 1, scalar epoch_to_normal_date($FROM_TIME), $format_header_info);
    $worksheet_info->write(1, 1, scalar epoch_to_normal_date($TILL_TIME), $format_header_info);

    $worksheet_info->write(3, 1, $not_classified, $format_header_info);
    $worksheet_info->write(4, 1, $information, $format_header_info);
    $worksheet_info->write(5, 1, $warning, $format_header_info);
    $worksheet_info->write(6, 1, $average, $format_header_info);
    $worksheet_info->write(7, 1, $high, $format_header_info);
    $worksheet_info->write(8, 1, $disaster, $format_header_info);
    $worksheet_info->write(10, 1, $status_OK, $format_header_info);
    $worksheet_info->write(11, 1, $status_PROBLEM, $format_header_info);
}

sub main
{
    my ($zbx_server, $zbx_user, $zbx_pwd, $report_file, $day, $hour, $debug) = parse_argv();

    $ZABBIX_SERVER = $zbx_server;
    $DELTA_DAYS = $day;
    $DELTA_HOURS = $hour;
    $DEBUG = $debug;

    do_debug("Zabbix server: $zbx_server\n" .
    		 "Zabbix user: $zbx_user\n" .
    		 "Zabbix pwd: $zbx_pwd\n" .
    	     "Report file: $report_file\n" .
    	     "Day: $day\n" .
    	     "Hour: $hour",
    	     'INFO'
    );

    $FROM_TIME = get_delta_from_current_date();
    $TILL_TIME = get_current_epoch_time();

    #Auth
    zabbix_auth($zbx_user, $zbx_pwd);

    #Get events
    zabbix_get_events();

    #Logout
    zabbix_logout();

    my $workbook = create_workbook($report_file);
    my ($worksheet_info, $worksheet_data) = create_worksheets($workbook, 'Information', 'Report about events');
    my $format_header_info = set_header_info($workbook);
    my $format_header_data = set_header_data($workbook);

    #Save
    save_to_excel($workbook, $worksheet_info, $format_header_info, $worksheet_data, $format_header_data);

    close_workbook($workbook);
}
