################################################################################
# Copyright 2005-2015 CENTREON
# Centreon is developped by : Julien Mathis and Romain Le Merlus under
# GPL Licence 2.0.
# 
# This program is free software; you can redistribute it and/or modify it under 
# the terms of the GNU General Public License as published by the Free Software 
# Foundation ; either version 2 of the License.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A 
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with 
# this program; if not, see <http://www.gnu.org/licenses>.
# 
# Linking this program statically or dynamically with other modules is making a 
# combined work based on this program. Thus, the terms and conditions of the GNU 
# General Public License cover the whole combination.
# 
# As a special exception, the copyright holders of this program give CENTREON 
# permission to link this program with independent modules to produce an executable, 
# regardless of the license terms of these independent modules, and to copy and 
# distribute the resulting executable under terms of CENTREON choice, provided that 
# CENTREON also meet, for each linked independent module, the terms  and conditions 
# of the license of that module. An independent module is a module which is not 
# derived from this program. If you modify this program, you may extend this 
# exception to your version of the program, but you are not obliged to do so. If you
# do not wish to do so, delete this exception statement from your version.
# 
# For more information : contact@centreon.com
# 
# SVN : $URL
# SVN : $Id
#
####################################################################################

use strict;
use warnings;
use POSIX;
use Time::Local;
use Tie::File;
use DateTime;

package gorgone::modules::centreon::mbi::libs::Utils;

sub new {
	my $class = shift;
}

sub checkBasicOptions {
    my ($self, $logger, $options) = @_;

    if (!defined($options->{'returnCode'}) || !$options->{'returnCode'}) {
        $logger->writeLog("ERROR", "Check --help to see available options");
    }

    # check execution mode daily to extract yesterday data or rebuild to get more historical data
    if ((!defined($options->{'daily'}) && !defined($options->{'rebuild'}) && !defined($options->{'create-tables'}) && !defined($options->{'centile'}))
        || (defined($options->{'daily'}) && defined($options->{'rebuild'}))) {
        $logger->writeLog("ERROR", "Specify one execution method. Check program help for more informations");
    }
    # check if options are set correctly for rebuild mode
    if ((defined($options->{'rebuild'}) || defined($options->{'create-tables'})) 
        && (defined($options->{'start'}) && !defined($options->{'end'})) 
        ||(!defined($options->{'start'}) && defined($options->{'end'}))) {
        $logger->writeLog("ERROR", "Specify both options --start and --end or neither of them to use default data retention options");
    }
    # check start and end dates format
    if (defined($options->{'rebuild'}) && defined($options->{'start'}) && defined($options->{'end'}) 
        && !$self->checkDateFormat($options->{'start'}, $options->{'end'})) {
        $logger->writeLog("ERROR", "Verify period start or end date format");
    }
    # set the log level, can be usefull to debug the program
    if (defined($options->{'log-level'})) {
        $logger->severity($options->{'log-level'});
    }
}

sub buildCliMysqlArgs {
    my ($self, $con) = @_;

    my $args = '-u "' . $con->{user} . '" ' .
        '-p"' . $con->{password} . '" ' . 
        '-h "' $con->{host} . '" ' .
		'-P ' . $con->{port};
    return $args;
}

sub getRangePartitionDate {
    my ($self, $start, $end) = @_;

    if ($start !~ /(\d{4})-(\d{2})-(\d{2})/) {
        die "Verify period start format";
    }
    my $dt1 = DateTime->new(year => $1, month => $2, day => $3, hour => 0, minute => 0, second => 0);

    if ($end !~ /(\d{4})-(\d{2})-(\d{2})/) {
        die "Verify period end format";
    }
    my $dt2 = DateTime->new(year => $1, month => $2, day => $3, hour => 0, minute => 0, second => 0);

    my $epoch = $dt1->epoch();
    my $epoch_end = $dt2->epoch();
    if ($epoch_end <= $epoch) {
        die "Period end date is older";
    }

    my $partitions = [];
    while ($epoch <= $epoch_end) {
        $dt1->add(days => 1);

        $epoch = $dt1->epoch();
        my $month = $dt1->month();
        $month = '0' . $month if ($month < 10);
        my $day = $dt1->day();
        $day = '0' . $day if ($day < 10);

        push @$partitions, {
            name => $dt1->year() . $month . $day,
            epoch => $epoch
        };
    }

    return $partitions;
}

sub checkDateFormat {
	my ($self, $start, $end)= @_;

	if (defined($start) && $start =~  /[1-2][0-9]{3}\-[0-1][0-9]\-[0-3][0-9]/
        && defined($end) && $end =~  /[1-2][0-9]{3}\-[0-1][0-9]\-[0-3][0-9]/) {
        return 1;
	}
	return 0;
}

sub getRebuildPeriods {
	my ($self, $start, $end)= @_;
	
	my ($day,$month,$year) = (localtime($start))[3,4,5];
	$start = POSIX::mktime(0,0,0,$day,$month,$year,0,0,-1);
	my $previousDay = POSIX::mktime(0,0,0,$day - 1,$month,$year,0,0,-1);
	my @days = ();
	while ($start < $end) {
	    # if there is few hour gap (time change : winter/summer), we also readjust it
		if ($start == $previousDay) {
		    $start = POSIX::mktime(0,0,0, ++$day, $month, $year,0,0,-1);
		}
		my $dayEnd = POSIX::mktime(0, 0, 0, ++$day, $month, $year, 0, 0, -1);
		
		my %period = ("start" => $start, "end" => $dayEnd);
		$days[scalar(@days)] = \%period;
		$previousDay = $start;
		$start = $dayEnd;
    }
    return (\@days);
}

#parseFlatFile (file, key,value) : replace a line with a  key by a value (entire line) to the specified file
sub parseAndReplaceFlatFile{
	my $self = shift;
    my $logger =  shift;
    my $file = shift;
    my $key = shift;
    my $value = shift;
    
 	if (!-e $file) {
 		$logger->writeLog("ERROR", "File missing [".$file."]. Make sure you installed all the pre-requisites before executing this script");
 	} 
   
    tie my @flatfile, 'Tie::File', $file or die $!;
	
	foreach my $line(@flatfile)
    {
		if( $line =~ m/$key/ ) {
			my $previousLine = $line;
			$line =~ s/$key/$value/g;
			$logger->writeLog("DEBUG", "[".$file."]");
			$logger->writeLog("DEBUG", "Replacing [".$previousLine."] by [".$value."]");
		}
    }
}


1;