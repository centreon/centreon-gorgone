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

package gorgone::modules::centreon::mbi::libs::centreon::ETLProperties;

# Constructor
# parameters:
# $logger: instance of class CentreonLogger
# $centreon: Instance of centreonDB class for connection to Centreon database
# $centstorage: (optionnal) Instance of centreonDB class for connection to Centstorage database
sub new {
    my $class = shift;
    my $self  = {};
    $self->{"logger"}	= shift;
    $self->{"centreon"} = shift;
    if (@_) {
	$self->{"centstorage"}  = shift;
    }
    bless $self, $class;
    return $self;
}

# returns two references to two hash tables => hosts indexed by id and hosts indexed by name
sub getProperties {
    my $self = shift;
    my $centreon = $self->{"centreon"};
    my $activated = 1;
    if (@_) {
	$activated  = 0;
    }
    my (%etlProperties, %dataRetention);

    my $query = "SELECT `opt_key`, `opt_value` FROM `mod_bi_options` WHERE `opt_key` like 'etl.%'";
    my $sth = $centreon->query($query);
    while (my $row = $sth->fetchrow_hashref()) {
	if ($row->{'opt_key'} =~ /etl.retention.(.*)/) {
	    $dataRetention{$1} = $row->{"opt_value"};
	}elsif ($row->{'opt_key'} =~ /etl.list.(.*)/) {
	    my @tab = split (/,/, $row->{"opt_value"});
	    my %hashtab = ();
	    foreach(@tab) {
		$hashtab{$_} = 1;
	    }
	    $etlProperties{$1} = \%hashtab;
	}elsif ($row->{'opt_key'} =~ /etl.(.*)/) {
	    $etlProperties{$1} = $row->{"opt_value"};
	}
    }
    if (defined($etlProperties{'capacity.exclude.metrics'})) {
        $etlProperties{'capacity.exclude.metrics'} =~ s/^/\'/;
        $etlProperties{'capacity.exclude.metrics'} =~ s/$/\'/;
        $etlProperties{'capacity.exclude.metrics'} =~ s/,/\',\'/;
    }
    
    $sth->finish();
    return (\%etlProperties,\%dataRetention);
}

# returns the max retention period defined by type of statistics, monthly stats are excluded
sub getMaxRetentionPeriodFor {
    my $self = shift;
    my $centreon = $self->{"centreon"};
    my $logger = $self->{'logger'};
    
    my $type = shift;
    my $query = "SELECT date_format(NOW(), '%Y-%m-%d') as period_end,";
    $query .= "  date_format(DATE_ADD(NOW(), INTERVAL MAX(CAST(`opt_value` as SIGNED INTEGER))*-1 DAY), '%Y-%m-%d') as period_start";
    $query .= " FROM `mod_bi_options` ";
    $query .= " WHERE `opt_key` IN ('etl.retention.".$type.".hourly','etl.retention.".$type.".daily', 'etl.retention.".$type.".raw')";
    my $sth = $centreon->query($query);
    if (my $row = $sth->fetchrow_hashref()) {
	return ($row->{'period_start'}, $row->{'period_end'}) ;
    } else {
	$logger->writeLog("FATAL", "Cannot get max perfdata retention period. Verify your data retention options");
    }
}

# Returns a start and a end date for each retention period
sub getRetentionPeriods {
    my $self = shift;
    my $centreon = $self->{"centreon"};
    my $logger = $self->{'logger'};
    
    my $query = "SELECT date_format(NOW(), '%Y-%m-%d') as period_end,";
    $query .= "  date_format(DATE_ADD(NOW(), INTERVAL (`opt_value`)*-1 DAY), '%Y-%m-%d') as period_start,";
    $query .= " opt_key ";
    $query .= " FROM `mod_bi_options` ";
    $query .= " WHERE `opt_key` like ('etl.retention.%')";
    my $sth = $centreon->query($query);
    my %periods = ();
    while (my $row = $sth->fetchrow_hashref()) {
	$row->{'opt_key'} =~ s/etl.retention.//; 
        $periods{$row->{'opt_key'}} = {'start' => $row->{'period_start'}, 'end' => $row->{'period_end'}} ;
    }
    if (!scalar(keys %periods)){
	$logger->writeLog("FATAL", "Cannot retention periods information. Verify your data retention options");
    }
    return (\%periods);
}
1;
