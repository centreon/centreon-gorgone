##################################################
# CENTREON
#
# Source Copyright 2005 - 2015 CENTREON
#
# Unauthorized reproduction, copy and distribution
# are not allowed.
#
# For more informations : contact@centreon.com
#
##################################################

use strict;
use warnings;
use POSIX;

package gorgone::modules::centreon::mbi::libs::bi::BIHostStateEvents;

# Constructor
# parameters:
# $logger: instance of class CentreonLogger
# $centreon: Instance of centreonDB class for connection to Centreon database
# $centstorage: (optionnal) Instance of centreonDB class for connection to Centstorage database
sub new {
	my $class = shift;
	my $self  = {};
	$self->{"logger"}	= shift;
	$self->{"centstorage"} = shift;
	$self->{'timeperiod'} = shift;
	$self->{'bind_counter'} = 0;
	$self->{'statement'} = undef;
	$self->{'name'} = "mod_bi_hoststateevents";
	$self->{'tmp_name'} = "mod_bi_hoststateevents_tmp";
	$self->{'timeColumn'} = "end_time";
	bless $self, $class;
	return $self;
}

sub getName() {
	my $self = shift;
	return $self->{'name'};
}

sub getTimeColumn() {
	my $self = shift;
	return $self->{'timeColumn'};
}

sub createTempBIEventsTable{
	my ($self) = @_;
	my $db = $self->{"centstorage"};
	$db->query("DROP TABLE IF EXISTS `mod_bi_hoststateevents_tmp`");
	my $createTable = " CREATE TABLE `mod_bi_hoststateevents_tmp` (";
	$createTable .= " `host_id` int(11) NOT NULL,";
	$createTable .= " `modbiliveservice_id` tinyint(4) NOT NULL,";
	$createTable .= " `state` tinyint(4) NOT NULL,";
	$createTable .= " `start_time` int(11) NOT NULL,";
	$createTable .= " `end_time` int(11) DEFAULT NULL,";
	$createTable .= " `duration` int(11) NOT NULL,";
	$createTable .= " `sla_duration` int(11) NOT NULL,";
	$createTable .= " `ack_time` int(11) DEFAULT NULL,";
	$createTable .= " `last_update` tinyint(4) NOT NULL DEFAULT '0',";
	$createTable .= " KEY `modbihost_id` (`host_id`)";
	$createTable .= " ) ENGINE=InnoDB DEFAULT CHARSET=utf8";
	$db->query($createTable);
}

sub prepareTempQuery {
	my $self = shift;
	my $db = $self->{"centstorage"};

	my $query = "INSERT INTO `".$self->{'tmp_name'}."`".
				" (`host_id`, `modbiliveservice_id`,".
				" `state`, `start_time`, `sla_duration`,".
				" `end_time`,  `ack_time`, `last_update`, `duration`) ".
				" VALUES (?,?,?,?,?,?,?,?, TIMESTAMPDIFF(SECOND, FROM_UNIXTIME(?), FROM_UNIXTIME(?)))";
	$self->{'statement'} = $db->prepare($query);
	$self->{'dbinstance'} = $db->getInstance;
	($self->{'dbinstance'})->begin_work;
}

sub prepareQuery {
	my $self = shift;
	my $db = $self->{"centstorage"};

	my $query = "INSERT INTO `".$self->{'name'}."`".
				" (`modbihost_id`, `modbiliveservice_id`,".
				" `state`, `start_time`, `sla_duration`,".
				" `end_time`,  `ack_time`, `last_update`, `duration`) ".
				" VALUES (?,?,?,?,?,?,?,?, TIMESTAMPDIFF(SECOND, FROM_UNIXTIME(?), FROM_UNIXTIME(?)))";
	$self->{'statement'} = $db->prepare($query);
	$self->{'dbinstance'} = $db->getInstance;
	($self->{'dbinstance'})->begin_work;
}

sub bindParam {
	my ($self, $row) = @_;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	
	my $size = scalar(@$row);
	my $sth = $self->{'statement'};
	for (my $i = 0; $i < $size; $i++) {
		$sth->bind_param($i + 1, $row->[$i]);
	}
	$sth->bind_param($size+1, $row->[3]);
	$sth->bind_param($size+2, $row->[5]);
	($self->{'statement'})->execute;
	if (defined(($self->{'dbinstance'})->errstr)) {
  		$logger->writeLog("FATAL", $self->{'name'}." insertion execute error : ".($self->{'dbinstance'})->errstr);
	}
	if ($self->{'bind_counter'} >= 1000) {
		$self->{'bind_counter'} = 0;
		($self->{'dbinstance'})->commit;
		if (defined(($self->{'dbinstance'})->errstr)) {
  			$logger->writeLog("FATAL", $self->{'name'}." insertion commit error : ".($self->{'dbinstance'})->errstr);
		}
		($self->{'dbinstance'})->begin_work;
	}
	$self->{'bind_counter'} += 1;
	
}

sub getDayEvents {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $timeperiod = $self->{'timeperiod'};
	my ($start, $end, $liveserviceId, $ranges) = @_;
	my %results = ();
	
	# Profiling >>>>>
	my $baseTime = time();
	my $diffTime = 0;
	my $countEvent = 0;
	# <<<< Profiling
	
	my $query = "SELECT start_time, end_time, state, modbihost_id";
	$query .= " FROM `".$self->{'name'}."`";
	$query .= " WHERE `start_time` < ".$end."";
    $query .= " AND `end_time` > ".$start."";
    $query .= " AND `state` in (0,1,2)";
    $query .= " AND modbiliveservice_id = ".$liveserviceId;
	my $sth = $db->query($query);
	
	# Profiling >>>>>
	$diffTime = time() - $baseTime;
	$self->{"logger"}->writeLog("DEBUG","[".localtime(time)."][PROFILING][HOST] Get all events for period between ".$start." and ".$end. " for liveservice_id ".$liveserviceId." :[".$diffTime."]sec");
	$baseTime = time();
	# <<<< Profiling
	
	#For each events, for the current day, calculate statistics for the day
	while (my $row = $sth->fetchrow_hashref()) {
	 
		my $entryID = $row->{"modbihost_id"};
		
		my ($started, $ended) = (0, 0);
		my $rangeSize = scalar(@$ranges);
		my $eventDuration = 0;
		for(my $count = 0; $count < $rangeSize; $count++) {
			my $currentStart = $row->{"start_time"};
			my $currentEnd = $row->{"end_time"};
				
	    	my $range = $ranges->[$count];
			my ($rangeStart, $rangeEnd) = ($range->[0], $range->[1]);
				if ($currentStart < $rangeEnd && $currentEnd > $rangeStart) {
			    	if ($currentStart < $rangeStart) {
		    			$currentStart = $rangeStart;
		    		}elsif ($count == 0) { 
		    			$started = 1;
			    	}
			    	if ($currentEnd > $rangeEnd) {
		    			$currentEnd = $rangeEnd;
		    		}elsif ($count == $rangeSize - 1) {
			    		$ended = 1;
			    	}
		    		$eventDuration += $currentEnd - $currentStart;
		    	}
			}
			if (!defined($results{$entryID})) {
				my @tab = (0, 0, 0, 0, 0, 0, 0);
			
				#New version - sync with tables in database
				#  0: UP,  1: DOWN time,  2:  Unreachable time , 3 : DOWN alerts opened
				#  4: Down time alerts closed, 5: unreachable alerts started, 6 : unreachable alerts ended
				$results{$entryID} = \@tab;			
			}
			
		my $stats = $results{$entryID};
		my $state = $row->{'state'};
		
		if ($state == 0) {
			$stats->[0] += $eventDuration;
		}elsif ($state == 1) {
			$stats->[1] += $eventDuration;
			$stats->[3] += $started;
			$stats->[4] += $ended;
		}elsif ($state == 2) {
			$stats->[2] += $eventDuration;
			$stats->[5] += $started;
			$stats->[6] += $ended;
		}

		$results{$entryID} = $stats;
		
		# Profiling >>>>>
		$countEvent++;
    }
	$diffTime = time() - $baseTime;
	$self->{"logger"}->writeLog("DEBUG","[".localtime(time)."][PROFILING][HOST] ".$countEvent." events have been calculated in :[".$diffTime."]sec");
	# <<<< Profiling
    return (\%results);
}

#Deprecated
sub getNbEvents {
	my ($self, $start, $end, $groupId, $catId, $liveServiceID) = @_;
	my $db = $self->{"centstorage"};
	
	my $query = "SELECT count(state) as nbEvents, state";
	$query .= " FROM mod_bi_hosts h, ".$self->{'name'}." e";
	$query .= " WHERE h.hg_id = ".$groupId." AND h.hc_id=".$catId;
	$query .= " AND h.id = e.modbihost_id";
	$query .= " AND e.modbiliveservice_id=".$liveServiceID;
	$query .= " AND start_time < UNIX_TIMESTAMP('".$end."')";
	$query .= " AND end_time > UNIX_TIMESTAMP('".$start."')";
	$query .= " AND state in (1,2)";
	$query .= " GROUP BY state";
	my $sth = $db->query($query);
	
	my ($downEvents, $unrEvents) = (undef, undef);
	while (my $row = $sth->fetchrow_hashref()) {
		if ($row->{'state'} == 1) {
			$downEvents = $row->{'nbEvents'};
		}else {
			$unrEvents = $row->{'nbEvents'};
		}
	}
	return ($downEvents, $unrEvents);
}

sub deleteUnfinishedEvents {
	my $self = shift;
	my $db = $self->{"centstorage"};
	
	my $query = "DELETE FROM `mod_bi_hoststateevents`";
	$query .= " WHERE last_update = 1 OR end_time is null";
	$db->query($query);
}

1;
