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
use Time::Local;

package gorgone::modules::centreon::mbi::libs::bi::HostAvailability;

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
	$self->{"name"} = "mod_bi_hostavailability";
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

#Only for daily mode
sub insertStats {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger =  $self->{"logger"};
	my ($data, $time_id, $liveserviceId)  = @_;
	my $commitParam = 25000;

	my $query = "INSERT INTO `".$self->{"name"}."`".
				" (`modbihost_id`, `time_id`, `liveservice_id`, `available`, ".
				" `unavailable`,`unreachable`, `alert_unavailable_opened`,  `alert_unavailable_closed`, ".
				" `alert_unreachable_opened`,  `alert_unreachable_closed`) ".
				" VALUES (?,?,?,?,?,?,?,?,?,?)";
	my $sth = $db->prepare($query);	
	my $inst = $db->getInstance;
	$inst->begin_work;
	my $counter = 0;
	
	while (my ($modBiHostId, $stats) = each %$data) {
		my @tab = @$stats;
		if ($stats->[0]+$stats->[1]+$stats->[2] == 0) {
			next;
		}
		my $j = 1;
		$sth->bind_param($j++, $modBiHostId);
		$sth->bind_param($j++, $time_id);
		$sth->bind_param($j++, $liveserviceId);
		for (my $i = 0; $i < scalar(@$stats); $i++) {
			$sth->bind_param($i + $j, $stats->[$i]);
		}
		$sth->execute;
		if (defined($inst->errstr)) {
	  		$logger->writeLog("FATAL", $self->{"name"}." insertion execute error : ".$inst->errstr);
		}
		if ($counter >= $commitParam) {
			
			$counter = 0;
			$inst->commit;
			
			if (defined($inst->errstr)) {
	  			$logger->writeLog("FATAL", $self->{"name"}." insertion commit error : ".$inst->errstr);
			}
			$inst->begin_work;
		}
		$counter++;
	}
	$inst->commit;
}

sub saveStatsInFile {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger =  $self->{"logger"};
	my ($data, $time_id, $liveserviceId,$fh)  = @_;
	my $query;
	my $row;
	
	while (my ($modBiHostId, $stats) = each %$data) {
		my @tab = @$stats;
		if ($stats->[0]+$stats->[1]+$stats->[4] == 0) {
			next;
		}
		
		#Filling the dump file with data
		$row = $modBiHostId."\t".$time_id."\t".$liveserviceId;
		for (my $i = 0; $i < scalar(@$stats); $i++) {
			$row.= "\t".$stats->[$i]
		}
		$row .= "\n";
		
		#Write row into file
		print $fh $row;
		$self->{"nbLinesInFile"}+=1;
	}
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
	
	$self->{"logger"}->writeLog("DEBUG","[HOST] Calculating availability for hosts");
	my $query = "SELECT h.hg_id, h.hc_id, hc.id as cat_id, hg.id as group_id, ha.liveservice_id, avg(available/(available+unavailable+unreachable)) as av_percent,";
	$query .= " sum(available) as av_time, sum(unavailable) as unav_time, sum(alert_unavailable_opened) as unav_opened, sum(alert_unavailable_closed) as unav_closed,";
	$query .= " sum(alert_unreachable_opened) as unr_opened, sum(alert_unreachable_closed) as unr_closed";
	$query .= " FROM ".$self->{"name"}." ha";
	$query .= " STRAIGHT_JOIN mod_bi_time t ON (t.id = ha.time_id )";
	$query .= " STRAIGHT_JOIN mod_bi_hosts h ON (ha.modbihost_id = h.id)";
	$query .= " STRAIGHT_JOIN mod_bi_hostgroups hg ON (h.hg_name=hg.hg_name AND h.hg_id=hg.hg_id)";
	$query .= " STRAIGHT_JOIN mod_bi_hostcategories hc ON (h.hc_name=hc.hc_name AND h.hc_id=hc.hc_id)";
	$query .= " WHERE t.year = YEAR('".$start."') AND t.month = MONTH('".$start."') and t.hour=0";
	$query .= " GROUP BY h.hg_id, h.hc_id, ha.liveservice_id";
	my $sth = $db->query($query);
	
	$self->{"logger"}->writeLog("DEBUG","[HOST] Calculating MTBF/MTRS/MTBSI for Host");	
	my @data = ();
	while (my $row = $sth->fetchrow_hashref()) {
		my ($totalDownEvents, $totalUnrEvents) = $eventObj->getNbEvents($start, $end, $row->{'hg_id'}, $row->{'hc_id'}, $row->{'liveservice_id'}); 
		my ($mtrs, $mtbf, $mtbsi) = (undef, undef, undef);
		if (defined($totalDownEvents) && $totalDownEvents != 0) {
			$mtrs = $row->{'unav_time'}/$totalDownEvents;
			$mtbf = $row->{'av_time'}/$totalDownEvents;
			$mtbsi = ($row->{'unav_time'}+$row->{'av_time'})/$totalDownEvents;
		}
		my @tab = ($row->{'group_id'}, $row->{'cat_id'}, $row->{'liveservice_id'}, $row->{'av_percent'}, $row->{'unav_time'}, 
					$row->{'unav_opened'}, $row->{'unav_closed'}, $row->{'unr_opened'}, $row->{'unr_closed'}, 
					$totalDownEvents, $totalUnrEvents, $mtrs, $mtbf, $mtbsi);
		push @data, \@tab;
	}
	
	return \@data;
}
1;