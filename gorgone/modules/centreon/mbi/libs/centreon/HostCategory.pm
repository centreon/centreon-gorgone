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

package gorgone::modules::centreon::mbi::libs::centreon::HostCategory;

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
	$self->{'etlProperties'} = undef;
	if (@_) {
		$self->{"centstorage"}  = shift;
	}
	bless $self, $class;
	return $self;
}

#Set the etl properties as a variable of the class
sub setEtlProperties{
	my $self = shift;
	$self->{'etlProperties'} = shift;
}


sub getAllEntries {
	my $self = shift;
	my $db = $self->{"centreon"};
	my $etlProperties = $self->{'etlProperties'};

	my $query = "SELECT `hc_id`, `hc_name`";
	$query .= " FROM `hostcategories`";
	if(!defined($etlProperties->{'dimension.all.hostcategories'}) && $etlProperties->{'dimension.hostcategories'} ne ''){
		$query .= " WHERE `hc_id` IN (".$etlProperties->{'dimension.hostcategories'}.")"; 
	}
	my $sth = $db->query($query);
	my @entries = ();
	while (my $row = $sth->fetchrow_hashref()) {
		push @entries, $row->{"hc_id"}.";".$row->{"hc_name"};
	}
	$sth->finish();
	return (\@entries);
}

1;
