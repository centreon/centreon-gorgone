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

package gorgone::modules::centreon::mbi::libs::bi::MetricMonthCapacity;

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
	$self->{"name"} = "mod_bi_metricmonthcapacity";
	$self->{"timeColumn"} = "time_id";
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

sub insertStats {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger =  $self->{"logger"};
	my ($time_id, $data) = @_;

	my $query = "INSERT INTO `".$self->{"name"}."`".
				"(`time_id`, `servicemetric_id`, `liveservice_id`,".
				" `first_value`, `first_total`, `last_value`, `last_total`)".
				" VALUES (?,?,?,?,?,?,?)";
	my $sth = $db->prepare($query);
	my $inst = $db->getInstance;
	$inst->begin_work;
	my $counter = 0;
	
	while (my ($key, $entry) = each %$data) {
		my $size = scalar(@$entry);
		$sth->bind_param(1, $time_id);
		for (my $j = 0; $j < $size; ++$j) {
			my $value = $entry->[$j];
			$sth->bind_param($j +2, $value);
		}
		$sth->execute;
		if (defined($inst->errstr)) {
	  		$logger->writeLog("FATAL", $self->{"name"}." insertion execute error : ".$inst->errstr);
		}
		if ($counter >= 1000) {
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
1;
