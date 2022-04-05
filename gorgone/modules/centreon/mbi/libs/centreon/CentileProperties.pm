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

package gorgone::modules::centreon::mbi::libs::centreon::CentileProperties;

# Constructor
# parameters:
# $logger: instance of class CentreonLogger
# $centreon: Instance of centreonDB class for connection to Centreon database
# $centstorage: (optionnal) Instance of centreonDB class for connection to Centstorage database
sub new {
    my $class = shift;
    my $self  = {};
    $self->{logger}	= shift;
    $self->{centreon} = shift;
    if (@_) {
        $self->{centstorage}  = shift;
    }
    bless $self, $class;
    return $self;
}

sub getCentileParams {
    my $self = shift;
    my $centreon = $self->{centreon};
    my $logger = $self->{logger};
    
    my $centileParams = [];
    my $query = "SELECT `centile_param`, `timeperiod_id` FROM `mod_bi_options_centiles`";
    my $sth = $centreon->query($query);
    while (my $row = $sth->fetchrow_hashref()) {
    	if (defined($row->{centile_param}) && $row->{centile_param} ne '0' && defined($row->{timeperiod_id}) && $row->{timeperiod_id} ne '0'){
    		push @{$centileParams}, { centile_param => $row->{centile_param}, timeperiod_id => $row->{timeperiod_id} };
    	}
    }

    return $centileParams;
}

1;
