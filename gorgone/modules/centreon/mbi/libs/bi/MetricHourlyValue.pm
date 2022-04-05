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

package gorgone::modules::centreon::mbi::libs::bi::MetricHourlyValue;

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
	$self->{'servicemetrics'} = "mod_bi_tmp_today_servicemetrics";
	$self->{"name"} = "mod_bi_metrichourlyvalue";
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

sub insertValues {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger =  $self->{"logger"};
	
	my $query = "INSERT INTO ".$self->{"name"};
	$query .= " SELECT sm.id as servicemetric_id, t.id as time_id, mmavt.avg_value, mmavt.min_value, mmavt.max_value, m.max , m.warn, m.crit";
	$query .= " FROM mod_bi_tmp_minmaxavgvalue mmavt";
	$query .= " JOIN (metrics m, ".$self->{'servicemetrics'}." sm, mod_bi_time t)";
	$query .= " ON (mmavt.id_metric = m.metric_id and mmavt.id_metric = sm.metric_id AND mmavt.valueTime = t.dtime)";
	$db->query($query);
} 

1;
