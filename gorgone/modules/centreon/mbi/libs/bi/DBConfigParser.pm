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
use XML::LibXML;
use Data::Dumper;

package gorgone::modules::centreon::mbi::libs::bi::DBConfigParser;

# Constructor
# parameters:
# $logger: instance of class CentreonLogger
# $centreon: Instance of centreonDB class for connection to Centreon database
# $centstorage: (optionnal) Instance of centreonDB class for connection to Centstorage database

sub new {
	my $class = shift;
	my $self  = {};
	$self->{"logger"}	= shift;
	bless $self, $class;
	return $self;
}

sub parseFile {
    my $self = shift;
    my $logger =  $self->{"logger"};
    my $file = shift;

    my %connProfiles = ();
    if (! -r $file) {
	$logger->writeLog("ERROR", "Cannot read file ".$file);
    }
    my $parser = XML::LibXML->new();
    my $root  = $parser->parse_file($file);
    foreach my $profile ($root->findnodes('/DataTools.ServerProfiles/profile')) {
		my $base = $profile->findnodes('@name');
		   
		foreach my $property ($profile->findnodes('./baseproperties/property')) {
			my $name = $property->findnodes('@name')->to_literal;
			my $value = $property->findnodes('@value')->to_literal;
			if ($name eq 'odaURL') {
				if ($value =~ /jdbc\:[a-z]+\:\/\/([^:]*)(\:\d+)?\/(.*)/) {
					$connProfiles{$base."_host"} = $1;
					if(defined($2) && $2 ne ''){  
						$connProfiles{$base."_port"} = $2; 
						$connProfiles{$base."_port"} =~ s/\://;
					}else{
						$connProfiles{$base."_port"} = '3306';
					}
					$connProfiles{$base."_db"} = $3;
				   $connProfiles{$base."_db"} =~ s/\?autoReconnect\=true//;
				}
			}
			if ($name eq 'odaUser') {
			$connProfiles{$base."_user"} = sprintf('%s',$value);
			}
			if ($name eq 'odaPassword') {
			$connProfiles{$base."_pass"} = sprintf('%s', $value);
			}
		}
    }
	
    return (\%connProfiles);
}
   
1;
