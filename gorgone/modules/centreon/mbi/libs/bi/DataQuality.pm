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

package gorgone::modules::centreon::mbi::libs::bi::DataQuality;

# Constructor
# parameters:
# $logger: instance of class CentreonLogger
# $centreon: Instance of centreonDB class for connection to Centreon database
# $centstorage: (optionnal) Instance of centreonDB class for connection to Centstorage database

sub new {
	my $class = shift;
	my $self  = {};
	$self->{'logger'}	= shift;
	$self->{'centreon'} = shift;
	bless $self, $class;
	return $self;
}


sub searchAndDeleteDuplicateEntries {
	my $self = shift;
	$self->{"logger"}->writeLog("INFO", "Searching for duplicate host/service entries");
	my $relationIDS = $self->getDuplicateRelations();
	if(@$relationIDS){
		$self->deleteDuplicateEntries($relationIDS);
	}
}

# return table of IDs to delete
sub getDuplicateRelations {
	my $self = shift;
	my $db = $self->{'centreon'};
	my @relationIDS;
	#Get duplicated relations and exclude BAM or Metaservices data 
	my $duplicateEntriesQuery = "SELECT host_host_id, service_service_id, count(*) as nbRelations ".
	"FROM host_service_relation t1, host t2 WHERE t1.host_host_id = t2.host_id ".
	"AND t2.host_name not like '_Module%' group by host_host_id, service_service_id HAVING COUNT(*) > 1";

	my $sth = $db->query($duplicateEntriesQuery);
	while (my $row = $sth->fetchrow_hashref()) {
		if (defined($row->{host_host_id})) {
			$self->{"logger"}->writeLog("WARNING", "Found the following duplicate data (host-service) : "
			.$row->{host_host_id}." - ".$row->{service_service_id}." - Cleaning data");
			#Get all relation IDs related to duplicated data
			my $relationIdQuery = "SELECT hsr_id from host_service_relation ".
			"WHERE host_host_id = ".$row->{host_host_id}." AND service_service_id = ".$row->{service_service_id};
			my $sth2 = $self->{centreon}->query($relationIdQuery);
			while (my $hsr = $sth2->fetchrow_hashref()) {
				if (defined($hsr->{hsr_id})) {
					push(@relationIDS,$hsr->{hsr_id});
				}
			}
			$self->deleteDuplicateEntries(\@relationIDS);
			@relationIDS = ();
		}
	}
	return (\@relationIDS);
}

# Delete N-1 duplicate entry
sub deleteDuplicateEntries {
	my $self = shift;
	my $db = $self->{"centreon"};
	my @relationIDS = @{$_[0]};
	#WARNING : very important so at least 1 relation is kept
	pop @relationIDS; 
	foreach (@relationIDS)
	{
		my $idToDelete = $_;
		my $deleteQuery = "DELETE FROM host_service_relation WHERE hsr_id = ".$idToDelete;
		$db->query($deleteQuery)
	}
}
1;
