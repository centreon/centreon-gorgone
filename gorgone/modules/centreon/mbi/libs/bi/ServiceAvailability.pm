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

package gorgone::modules::centreon::mbi::libs::bi::ServiceAvailability;

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
	if (@_) {
		$self->{"centreon"}  = shift;
	}
	$self->{"name"} = "mod_bi_serviceavailability";
	$self->{"timeColumn"} = "time_id";
	$self->{"nbLinesInFile"} = 0;
	$self->{"commitParam"} = 500000;
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

sub saveStatsInFile {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger =  $self->{"logger"};
	my ($data, $time_id, $liveserviceId,$fh) = @_;
	my $query;
	my $row;
	
	while (my ($modBiServiceId, $stats) = each %$data) {
		my @tab = @$stats;
		if ($stats->[0]+$stats->[1]+$stats->[2] == 0) {
			next;
		}
		
		#Filling the dump file with data
		$row = $modBiServiceId."\t".$time_id."\t".$liveserviceId;
		for (my $i = 0; $i < scalar(@$stats); $i++) {
			$row.= "\t".$stats->[$i]
		}
		$row .= "\n";
		
		#Write row into file
		print $fh $row;
		$self->{"nbLinesInFile"}++;
	}
}

sub insertStats {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger =  $self->{"logger"};
	my ($data, $time_id, $liveserviceId) = @_;
	my $commitParam = 25000;
	my $query = "INSERT INTO `".$self->{'name'}."`".
				" (`modbiservice_id`, `time_id`, `liveservice_id`, `available`, ".
				" `unavailable`, `degraded`, `alert_unavailable_opened`, `alert_unavailable_closed`, ".
				" `alert_degraded_opened`, `alert_degraded_closed`, ".
				" `alert_other_opened`, `alert_other_closed`)".
				" VALUES (?,?,?,?,?,?,?,?,?,?,?,?)";

	my $sth = $db->prepare($query);	
	my $inst = $db->getInstance;
	$inst->begin_work;
	my $counter = 0;
	
	while (my ($modBiServiceId, $stats) = each %$data) {
		my @tab = @$stats;
		if ($stats->[0]+$stats->[1]+$stats->[4] == 0) {
			next;
		}
		my $j = 1;
		$sth->bind_param($j++, $modBiServiceId);
		$sth->bind_param($j++, $time_id);
		$sth->bind_param($j++, $liveserviceId);
		for (my $i = 0; $i < scalar(@$stats); $i++) {
			$sth->bind_param($i + $j, $stats->[$i]);
		}
		$sth->execute;
		if (defined($inst->errstr)) {
	  		$logger->writeLog("FATAL", $self->{'name'}." insertion execute error : ".$inst->errstr);
		}

		if ($counter >= $commitParam) {
			$counter = 0;
			$inst->commit;
			if (defined($inst->errstr)) {
	  			$logger->writeLog("FATAL", $self->{'name'}." insertion commit error : ".$inst->errstr);
			}
			$inst->begin_work;
		}
		$counter++;
	}
	$inst->commit;
}

sub getCurrentNbLines{
	my $self = shift;
	return $self->{"nbLinesInFile"};
}

sub getCommitParam{
	my $self = shift;
	return $self->{"commitParam"};
}

sub setCurrentNbLines{
	my $self = shift;
	my $nbLines = shift;
	$self->{"nbLinesInFile"} = $nbLines;
}

sub getHGMonthAvailability {
	my ($self, $start, $end, $eventObj) = @_;
	my $db = $self->{"centstorage"};
	

	$self->{"logger"}->writeLog("INFO","[SERVICE] Calculating availability for services");
	my $query = "SELECT  s.hg_id, s.hc_id, s.sc_id, sa.liveservice_id,";
	$query .= "  hc.id as hcat_id, hg.id as group_id, sc.id as scat_id,";
	$query .= " avg((available+degraded)/(available+unavailable+degraded)) as av_percent,";
	$query .= " sum(available) as av_time, sum(unavailable) as unav_time, sum(degraded) as degraded_time,";
	$query .= "  sum(alert_unavailable_opened) as unav_opened,sum(alert_unavailable_closed) as unav_closed,";
	$query .= "  sum(alert_degraded_opened) as deg_opened,sum(alert_degraded_closed) as deg_closed,";
	$query .= "  sum(alert_other_opened) as other_opened,sum(alert_other_closed) as other_closed ";
	$query .= " FROM ".$self->{'name'}." sa";
	$query .= " STRAIGHT_JOIN mod_bi_time t ON (t.id = sa.time_id )";
	$query .= " STRAIGHT_JOIN mod_bi_services s ON (sa.modbiservice_id = s.id)";
	$query .= " STRAIGHT_JOIN mod_bi_hostgroups hg ON (s.hg_name=hg.hg_name AND s.hg_id=hg.hg_id)";
	$query .= " STRAIGHT_JOIN mod_bi_hostcategories hc ON (s.hc_name=hc.hc_name AND s.hc_id=hc.hc_id)";
	$query .= " STRAIGHT_JOIN mod_bi_servicecategories sc ON (s.sc_id=sc.sc_id AND s.sc_name=sc.sc_name)";
	$query .= " WHERE t.year = YEAR('".$start."') AND t.month = MONTH('".$start."') and t.hour=0";
	$query .= " GROUP BY s.hg_id, s.hc_id, s.sc_id, sa.liveservice_id";
	my $sth = $db->query($query);
	

	$self->{"logger"}->writeLog("INFO","[SERVICE] Calculating MTBF/MTRS/MTBSI for services");
	my @data = ();
	while (my $row = $sth->fetchrow_hashref()) {
		my ($totalwarnEvents, $totalCritEvents, $totalOtherEvents) = $eventObj->getNbEvents($start, $end, $row->{'hg_id'}, $row->{'hc_id'}, $row->{'sc_id'}, $row->{'liveservice_id'}); 

		
		my ($mtrs, $mtbf, $mtbsi) = (undef, undef, undef);
		if (defined($totalCritEvents) && $totalCritEvents != 0) {
			$mtrs = $row->{'unav_time'}/$totalCritEvents;
			$mtbf = $row->{'av_time'}/$totalCritEvents;
			$mtbsi = ($row->{'unav_time'}+$row->{'av_time'})/$totalCritEvents;
		}
		my @tab = ($row->{'group_id'}, $row->{'hcat_id'}, $row->{'scat_id'}, $row->{'liveservice_id'}, 
				$row->{'av_percent'}, $row->{'unav_time'}, $row->{'degraded_time'}, 
				$row->{'unav_opened'}, $row->{'unav_closed'}, $row->{'deg_opened'}, $row->{'deg_closed'}, $row->{'other_opened'}, $row->{'other_closed'}, 
					$totalwarnEvents, $totalCritEvents, $totalOtherEvents, $mtrs, $mtbf, $mtbsi);
		push @data, \@tab;
	}
	return \@data;
}

sub getHGMonthAvailability_optimised {
	my ($self, $start, $end, $eventObj) = @_;
	my $db = $self->{"centstorage"};
	
	$self->{"logger"}->writeLog("DEBUG","[SERVICE] Calculating availability,MTBF,MTRS,MTBSI for services");
	my $query = "SELECT * from  ( SELECT  s.hg_id, s.hc_id, s.sc_id, sa.liveservice_id,   hc.id as hcat_id, hg.id as group_id, sc.id as scat_id,"; 
	$query .= "avg((available+degraded)/(available+unavailable+degraded)) as av_percent, ";
	$query .= "sum(available) as av_time, sum(unavailable) as unav_time, sum(degraded) as degraded_time, ";
	$query .= "sum(alert_unavailable_opened) as unav_opened,sum(alert_unavailable_closed) as unav_closed, ";
	$query .= "sum(alert_degraded_opened) as deg_opened,sum(alert_degraded_closed) as deg_closed, ";
	$query .= "sum(alert_other_opened) as other_opened,sum(alert_other_closed) as other_closed ";
	$query .= "FROM mod_bi_serviceavailability sa ";
	$query .= "STRAIGHT_JOIN mod_bi_services s ON (sa.modbiservice_id = s.id) ";
	$query .= "STRAIGHT_JOIN mod_bi_hostgroups hg ON (s.hg_name=hg.hg_name AND s.hg_id=hg.hg_id) ";
	$query .= "STRAIGHT_JOIN mod_bi_hostcategories hc ON (s.hc_name=hc.hc_name AND s.hc_id=hc.hc_id) ";
	$query .= "STRAIGHT_JOIN mod_bi_servicecategories sc ON (s.sc_id=sc.sc_id AND s.sc_name=sc.sc_name)";
	$query .= " WHERE YEAR(from_unixtime(time_id)) = YEAR('".$start."') AND MONTH(from_unixtime(time_id))  = MONTH('".$start."') and hour(from_unixtime(time_id)) = 0 ";
	$query .= "GROUP BY s.hg_id, s.hc_id, s.sc_id, sa.liveservice_id ) availability ";
	$query .= "LEFT JOIN (  SELECT s.hg_id,s.hc_id,s.sc_id,e.modbiliveservice_id, ";
	$query .= "SUM(IF(state=1,1,0)) as warningEvents,   SUM(IF(state=2,1,0)) as criticalEvents,  ";
	$query .= "SUM(IF(state=3,1,0)) as unknownEvents  FROM mod_bi_servicestateevents e ";
	$query .= "STRAIGHT_JOIN mod_bi_services s ON (e.modbiservice_id = s.id)  ";
	$query .= "STRAIGHT_JOIN mod_bi_hostgroups hg ON (s.hg_name=hg.hg_name AND s.hg_id=hg.hg_id)  ";
	$query .= "STRAIGHT_JOIN mod_bi_hostcategories hc ON (s.hc_name=hc.hc_name AND s.hc_id=hc.hc_id) ";
	$query .= "STRAIGHT_JOIN mod_bi_servicecategories sc ON (s.sc_id=sc.sc_id AND s.sc_name=sc.sc_name) ";
	$query .= "AND s.id = e.modbiservice_id   AND start_time < UNIX_TIMESTAMP('".$end."') ";
	$query .= "AND end_time > UNIX_TIMESTAMP('".$start."')   AND e.state in (1,2,3) ";
	$query .= "GROUP BY s.hg_id, s.hc_id, s.sc_id, e.modbiliveservice_id ) events  ";
	$query .= "ON availability.hg_id = events.hg_id AND availability.hc_id = events.hc_id ";
	$query .= "AND availability.sc_id = events.sc_id ";
	$query .= "AND availability.liveservice_id = events.modbiliveservice_id";
	
	#Fields returned :
	#hg_id | hc_id | sc_id | liveservice_id | hcat_id | group_id | scat_id | av_percent | av_time    | unav_time | degraded_time | 
	#unav_opened | unav_closed | deg_opened | deg_closed | other_opened | other_closed | hg_id | hc_id | sc_id | 
	#modbiliveservice_id | warningEvents | criticalEvents | unknownEvents 
	my $sth = $db->query($query);
	
	my @data = ();
	while (my $row = $sth->fetchrow_hashref()) {
		my ($totalwarnEvents, $totalCritEvents, $totalUnknownEvents) = ($row->{'warningEvents'},$row->{'criticalEvents'},$row->{'unknownEvents'}); 

		
		my ($mtrs, $mtbf, $mtbsi) = (undef, undef, undef);
		if (defined($totalCritEvents) && $totalCritEvents != 0) {
			$mtrs = $row->{'unav_time'}/$totalCritEvents;
			$mtbf = $row->{'av_time'}/$totalCritEvents;
			$mtbsi = ($row->{'unav_time'}+$row->{'av_time'})/$totalCritEvents;
		}
		my @tab = ($row->{'group_id'}, $row->{'hcat_id'}, $row->{'scat_id'}, $row->{'liveservice_id'}, 
				$row->{'av_percent'}, $row->{'unav_time'}, $row->{'degraded_time'}, 
				$row->{'unav_opened'}, $row->{'unav_closed'}, $row->{'deg_opened'}, $row->{'deg_closed'}, $row->{'other_opened'}, $row->{'other_closed'}, 
					$totalwarnEvents, $totalCritEvents, $totalUnknownEvents, $mtrs, $mtbf, $mtbsi);
		push @data, \@tab;
	}
	return \@data;
}

1;
