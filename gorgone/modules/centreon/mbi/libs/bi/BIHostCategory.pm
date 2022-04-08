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

package gorgone::modules::centreon::mbi::libs::bi::BIHostCategory;

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
	bless $self, $class;
	return $self;
}

sub getAllEntries {
	my $self = shift;
	my $db = $self->{"centstorage"};

	my $query = "SELECT `hc_id`, `hc_name`";
	$query .= " FROM `mod_bi_hostcategories`";
	my $sth = $db->query($query);
	my @entries = ();
	while (my $row = $sth->fetchrow_hashref()) {
		push @entries, $row->{"hc_id"}.";".$row->{"hc_name"};
	}
	$sth->finish();
	return (\@entries);
}

sub getEntryIds {
	my $self = shift;
	my $db = $self->{"centstorage"};

	my $query = "SELECT `id`, `hc_id`, `hc_name`";
	$query .= " FROM `mod_bi_hostcategories`";
	my $sth = $db->query($query);
	my %entries = ();
	while (my $row = $sth->fetchrow_hashref()) {
		$entries{$row->{"hc_id"}.";".$row->{"hc_name"}} = $row->{"id"};
	}
	$sth->finish();
	return (\%entries);
}

sub entryExists {
	my $self = shift;
	my ($value, $entries) = (shift, shift);
	foreach(@$entries) {
		if ($value eq $_) {
			return 1;
		}
	}
	return 0;
}
sub insert {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger =  $self->{"logger"};
	my $data = shift;
	my $query = "INSERT INTO `mod_bi_hostcategories`".
				" (`hc_id`, `hc_name`)".
				" VALUES (?,?)";
	my $sth = $db->prepare($query);	
	my $inst = $db->getInstance;
	$inst->begin_work;
	my $counter = 0;
	
	my $existingEntries = $self->getAllEntries;
	foreach (@$data) {
		if (!$self->entryExists($_, $existingEntries)) {
			my ($hc_id, $hc_name) = split(";", $_);
			$sth->bind_param(1, $hc_id);
			$sth->bind_param(2, $hc_name);
			$sth->execute;
			if (defined($inst->errstr)) {
		  		$logger->writeLog("FATAL", "hostcategories insertion execute error : ".$inst->errstr);
			}
			if ($counter >= 1000) {
				$counter = 0;
				$inst->commit;
				if (defined($inst->errstr)) {
		  			$logger->writeLog("FATAL", "hostcategories insertion commit error : ".$inst->errstr);
				}
				$inst->begin_work;
			}
			$counter++;
		}
	}
	$inst->commit;
}

sub truncateTable {
	my $self = shift;
	my $db = $self->{"centstorage"};
	
	my $query = "TRUNCATE TABLE `mod_bi_hostcategories`";
	$db->query($query);
	$db->query("ALTER TABLE `mod_bi_hostcategories` AUTO_INCREMENT=1");
}

1;
