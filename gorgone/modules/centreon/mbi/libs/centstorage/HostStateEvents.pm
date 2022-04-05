################################################################################
# Copyright 2005-2015 CENTREON
# Centreon is developped by : Julien Mathis and Romain Le Merlus under
# GPL Licence 2.0.
# 
# This program is free software; you can redistribute it and/or modify it under 
# the terms of the GNU General Public License as published by the Free Software 
# Foundation ; either version 2 of the License.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A 
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with 
# this program; if not, see <http://www.gnu.org/licenses>.
# 
# Linking this program statically or dynamically with other modules is making a 
# combined work based on this program. Thus, the terms and conditions of the GNU 
# General Public License cover the whole combination.
# 
# As a special exception, the copyright holders of this program give CENTREON 
# permission to link this program with independent modules to produce an executable, 
# regardless of the license terms of these independent modules, and to copy and 
# distribute the resulting executable under terms of CENTREON choice, provided that 
# CENTREON also meet, for each linked independent module, the terms  and conditions 
# of the license of that module. An independent module is a module which is not 
# derived from this program. If you modify this program, you may extend this 
# exception to your version of the program, but you are not obliged to do so. If you
# do not wish to do so, delete this exception statement from your version.
# 
# For more information : contact@centreon.com
# 
# SVN : $URL
# SVN : $Id
#
####################################################################################

use strict;
use warnings;

package gorgone::modules::centreon::mbi::libs::centstorage::HostStateEvents;

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
	$self->{"biHostStateEventsObj"} = shift;
	$self->{"timePeriodObj"} = shift;
	if (@_) {
		$self->{"centreon"}  = shift;
	}
	$self->{"name"} = "hoststateevents";
	$self->{"timeColumn"} = "end_time";
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
sub agreggateEventsByTimePeriod {
	my ($self, $timeperiodList, $start, $end, $liveServiceByTpId, $mode) = @_;
	my $logger = $self->{"logger"};
	my $nbEvents;
	if($logger->{"severity"} eq '0'){
	 $nbEvents = $self->getNbEvents($start, $end);
	}
	my $db = $self->{"centstorage"};
	
	my $rangesByTP = ($self->{"timePeriodObj"})->getTimeRangesForPeriodAndTpList($timeperiodList, $start, $end);
	my $query = " SELECT e.host_id, start_time, end_time, ack_time, state, last_update";
	$query .= " FROM `hoststateevents` e";
	$query .= " RIGHT JOIN (select host_id from mod_bi_tmp_today_hosts group by host_id) t2";
	$query .= " ON e.host_id = t2.host_id";
	$query .= " WHERE start_time < ".$end."";
	$query .= " AND end_time > ".$start."";
	$query .= " AND in_downtime = 0 ";
	$query .= " ORDER BY start_time ";
	
	
	my $hostEventObjects = $self->{"biHostStateEventsObj"};
	my $sth = $db->query($query);
	$hostEventObjects->createTempBIEventsTable();
	$hostEventObjects->prepareTempQuery();
	
	#Variables use for live statistics
	my $currentTime = time();
    my $previousTime = time();
    my $nbEventTreated = 1;
	my $previousNbEventsTreated = 0;
    my $speed = 0;


	while (my $row = $sth->fetchrow_hashref()) {
	 
	 if($logger->{"severity"} eq '0'){
		$currentTime = time();
		#Live rebuild statistics
        if($currentTime - $previousTime >= 5 && $nbEventTreated > 0){ 
            $speed = ($nbEventTreated-$previousNbEventsTreated)/($currentTime - $previousTime);
            $previousTime = $currentTime;
			$previousNbEventsTreated = $nbEventTreated;
        }
        #Write every 10sec to a stat file
		if($currentTime%10 == 0){
		  open my $fh, ">", '@CENTREON_BI_LOG@etl-stats.log' 
		  or die "Can't open the following file: $!";
		  if($speed > 0){
			my $msg = sprintf("[".localtime(time)."] [LIVE] [HOST] Events: %d/%d (%.3f events/sec) - Time Remaining : %d min %d sec ( %.2f %% ) \r",$nbEventTreated,$nbEvents, $speed,(($nbEvents-$nbEventTreated)/$speed)/60,(($nbEvents-$nbEventTreated)/$speed)%60,$nbEventTreated*100/$nbEvents);
			print $fh $msg;
		  }else{
			my $msg = sprintf("[".localtime(time)."] [LIVE] [HOST] Events: %d/%d (n/a events/sec)  ( %.2f %% ) \r",$nbEventTreated,$nbEvents, $nbEventTreated*100/$nbEvents);
			print $fh $msg;
		  }
		  	close($fh);
		}
	 }
	#End Profiling
	
		if (!defined($row->{'end_time'})) {
			$row->{'end_time'} = $end;
		}
		while (my ($timeperiodID, $timeRanges) = each %$rangesByTP) {
			my @tab = ();
			$tab[0] = $row->{'host_id'};
			$tab[1] = $liveServiceByTpId->{$timeperiodID};
			$tab[2] = $row->{'state'};
			if ($mode eq "daily") {
				$timeRanges = ($self->{"timePeriodObj"})->getTimeRangesForPeriod($timeperiodID, $row->{'start_time'}, $row->{'end_time'});
			}
			($tab[3], $tab[4]) = $self->processIncidentForTp($timeRanges,$row->{'start_time'}, $row->{'end_time'});
			$tab[5] = $row->{'end_time'};
			$tab[6] = $row->{'ack_time'};
			$tab[7] = $row->{'last_update'};
			if (defined($tab[3]) && $tab[3] != -1) {
				$hostEventObjects->bindParam(\@tab);
			}
		
		}
		$nbEventTreated++;
	}
	($db->getInstance)->commit;
	$sth->finish();
	

}

sub processIncidentForTp {
	my ($self, $timeRanges, $start, $end) = @_;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	
	my $rangeSize = scalar(@$timeRanges);
	my $duration = 0;
	my $slaDuration = 0;
	my $range = 0;
	my $i = 0;
	my $processed = 0;
	my $slaStart = $start;
	my $slaStartModified = 0;
	
	foreach(@$timeRanges) {
		my $currentStart = $start;
		my $currentEnd = $end;
		
    	$range = $_;
		my ($rangeStart, $rangeEnd) = ($range->[0], $range->[1]);
		
		if ($currentStart < $rangeEnd && $currentEnd > $rangeStart) {
			$processed = 1;
			if ($currentStart > $rangeStart) {
				$slaStartModified = 1;
			} elsif ($currentStart < $rangeStart) {
    			$currentStart = $rangeStart;
    			if (!$slaStartModified) {
    				$slaStart = $currentStart;
    				$slaStartModified = 1;
    			}
    		}
	    	if ($currentEnd > $rangeEnd) {
    			$currentEnd = $rangeEnd;
    		}
    		$slaDuration += $currentEnd - $currentStart;
    	}
	}
	if (!$processed) {
		return (-1, -1, -1);
	}
	
	return ($slaStart, $slaDuration);
}


sub dailyPurge {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my ($end) = @_;
	
	$logger->writeLog("DEBUG", "[PURGE] [hoststateevents] purging data older than ".$end);
	my $query = "DELETE FROM `hoststateevents` where end_time < UNIX_TIMESTAMP('".$end."')";
	$db->query($query);
}

sub getNbEvents{
	my $self = shift;
	my $db = $self->{"centstorage"};
	my ($start, $end) = @_;
	my $logger = $self->{"logger"};
	my $nbEvents = 0;
	
	my $query = "SELECT count(*) as nbEvents";
	$query .= " FROM `hoststateevents` e";
	$query .= " RIGHT JOIN (select host_id from mod_bi_tmp_today_hosts group by host_id) t2";
	$query .= " ON e.host_id = t2.host_id";
	$query .= " WHERE start_time < ".$end."";
	$query .= " AND end_time > ".$start."";
	$query .= " AND in_downtime = 0 ";
	
	
	my $sth = $db->query($query);

	while (my $row = $sth->fetchrow_hashref()) {
		$nbEvents = $row->{'nbEvents'};
	}
	return $nbEvents;
}

1;
