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

package gorgone::modules::centreon::mbi::libs::centreon::ServiceCategory;

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

# returns two references to two hash tables => services indexed by id and services indexed by name
sub getCategory {
	my $self = shift;
	my $db = $self->{"centreon"};
	my $etlProperties = $self->{'etlProperties'};
	my $scName = "";
	if (@_) {
		$scName  = shift;
	}
	
    my $result = "";
	# getting services linked to hosts
	my $query = "SELECT sc_id from service_categories WHERE sc_name='".$scName."'";
	if(!defined($etlProperties->{'dimension.all.servicecategories'}) && $etlProperties->{'dimension.servicecategories'} ne ''){
		$query .= " WHERE `sc_id` IN (".$etlProperties->{'dimension.servicecategories'}.")"; 
	}
	my $sth = $db->query($query);
    if(my $row = $sth->fetchrow_hashref()) {
		$result = $row->{"sc_id"};
	}else {
		($self->{"logger"})->writeLog("error", "Cannot find service category '".."' in database");
	}
	$sth->finish();
		
	return ($result);
}

sub getAllEntries {
	my $self = shift;
	my $db = $self->{"centreon"};
	my $etlProperties = $self->{'etlProperties'};

	my $query = "SELECT `sc_id`, `sc_name`";
	$query .= " FROM `service_categories`";
	if(!defined($etlProperties->{'dimension.all.servicecategories'}) && $etlProperties->{'dimension.servicecategories'} ne ''){
		$query .= " WHERE `sc_id` IN (".$etlProperties->{'dimension.servicecategories'}.")"; 
	}
	my $sth = $db->query($query);
	my @entries = ();
	while (my $row = $sth->fetchrow_hashref()) {
		push @entries, $row->{"sc_id"}.";".$row->{"sc_name"};
	}
	$sth->finish();
	return (\@entries);
}

1;
