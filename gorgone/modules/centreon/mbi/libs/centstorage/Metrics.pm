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

package gorgone::modules::centreon::mbi::libs::centstorage::Metrics;

# Constructor
# parameters:
# $logger: instance of class CentreonLogger
# $centreon: Instance of centreonDB class for connection to Centreon database
# $centstorage: (optionnal) Instance of centreonDB class for connection to Centstorage database
sub new {
    my $class = shift;
    my $self  = {};
    $self->{"logger"}    = shift;
    $self->{"centstorage"} = shift;
    if (@_) {
        $self->{"centreon"}  = shift;
    }
    $self->{'metrics'} = ();
    $self->{"name"} = "data_bin";
    $self->{"timeColumn"} = "ctime";
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

sub createTempTableMetricMinMaxAvgValues {
    my ($self, $useMemory, $granularity) = @_;
    my $db = $self->{"centstorage"};
    $db->query("DROP TABLE IF EXISTS `mod_bi_tmp_minmaxavgvalue`");
    my $createTable = " CREATE TABLE `mod_bi_tmp_minmaxavgvalue` (";
    $createTable .= " id_metric INT NULL,";
    $createTable .= " avg_value FLOAT NULL,";
    $createTable .= " min_value FLOAT NULL,";
    $createTable .= " max_value FLOAT NULL";
    if ($granularity eq "hour") {
        $createTable .= ", valueTime DATETIME NULL";
    }
    if (defined($useMemory) && $useMemory eq "true") {
        $createTable .= ") ENGINE=MEMORY CHARSET=utf8 COLLATE=utf8_general_ci;";
    }else {
        $createTable .= ") ENGINE=MyISAM CHARSET=utf8 COLLATE=utf8_general_ci;";
    }
    $db->query($createTable);
}

sub getMetricValueByHour {
    my $self = shift;
    my $db = $self->{"centstorage"};
    my $logger = $self->{"logger"};
    
    my ($start, $end, $useMemory) = @_;
    my $dateFormat = "%Y-%c-%e %k:00:00";
    
    # Getting min, max, average
    $self->createTempTableMetricMinMaxAvgValues($useMemory, "hour");
    my $query = "INSERT INTO `mod_bi_tmp_minmaxavgvalue` SELECT id_metric, avg(value) as avg_value, min(value) as min_value, max(value) as max_value, ";
    $query .=     " date_format(FROM_UNIXTIME(ctime), '".$dateFormat."') as valueTime ";
    $query .= "FROM data_bin ";
    $query .= "WHERE ";
    $query .= "ctime >=UNIX_TIMESTAMP('".$start."') AND ctime < UNIX_TIMESTAMP('".$end."') ";
    $query .= "GROUP BY id_metric, date_format(FROM_UNIXTIME(ctime), '".$dateFormat."')";
    
    $logger->writeLog("DEBUG", "Getting min, max, avg values by metric into temporary tables");
    $db->query($query);
    $self->addIndexTempTableMetricMinMaxAvgValues("hour");
}

sub getMetricsValueByDay {
    my $self = shift;
    my $db = $self->{"centstorage"};
    my $logger = $self->{"logger"};
    
    my ($period, $useMemory) = @_;
    my $dateFormat = "%Y-%c-%e";
    
    # Getting min, max, average
    $self->createTempTableMetricMinMaxAvgValues($useMemory, "day");
    my $query = "INSERT INTO `mod_bi_tmp_minmaxavgvalue` SELECT id_metric, avg(value) as avg_value, min(value) as min_value, max(value) as max_value ";
    #$query .=     " date_format(FROM_UNIXTIME(ctime), '".$dateFormat."') as valueTime ";
    $query .= "FROM data_bin ";
    $query .= "WHERE ";
    my @tabPeriod = @$period;
    my ($start_date, $end_date);
    my $tabSize = scalar(@tabPeriod);
    for (my $count = 0; $count < $tabSize; $count++) {
        my $range = $tabPeriod[$count];
        if ($count == 0) {
            $start_date = $range->[0];
        }
        if ($count == $tabSize - 1) {
            $end_date = $range->[1];
        }
        $query .= "(ctime >= UNIX_TIMESTAMP(".($range->[0]). ") AND ctime < UNIX_TIMESTAMP(".($range->[1]) .")) OR ";
    }
    
    $query =~  s/OR $//;
    $query .= "GROUP BY id_metric";
    
    $logger->writeLog("DEBUG", "Getting min, max, avg values by metric");
    $db->query($query);
    $self->addIndexTempTableMetricMinMaxAvgValues("day");
    $self->getFirstAndLastValues($start_date, $end_date, $useMemory);
}

sub createTempTableMetricDayFirstLastValues {
    my ($self, $useMemory) = @_;
    my $db = $self->{"centstorage"};
    $db->query("DROP TABLE IF EXISTS `mod_bi_tmp_firstlastvalues`");
    my $createTable = " CREATE TABLE `mod_bi_tmp_firstlastvalues` (";
    $createTable .= " first_value FLOAT NULL,";
    $createTable .= " last_value FLOAT NULL,";
    $createTable .= " id_metric INT NULL";
    if (defined($useMemory) && $useMemory eq "true") {
        $createTable .= ") ENGINE=MEMORY CHARSET=utf8 COLLATE=utf8_general_ci;";
    } else {
        $createTable .= ") ENGINE=MyISAM CHARSET=utf8 COLLATE=utf8_general_ci;";
    }
    $db->query($createTable);
}

sub addIndexTempTableMetricDayFirstLastValues {
    my $self = shift;
    my $db = $self->{"centstorage"};
    $db->query("ALTER TABLE mod_bi_tmp_firstlastvalues ADD INDEX (`id_metric`)");
}

sub addIndexTempTableMetricMinMaxAvgValues {
    my $self = shift;
    my $granularity = shift;
    my $db = $self->{"centstorage"};
    my $index = "id_metric";
    if ($granularity eq "hour") {
        $index .= ", valueTime";
    }
    my $query = "ALTER TABLE mod_bi_tmp_minmaxavgvalue ADD INDEX (" . $index . ")";
    $db->query($query);
}

sub createTempTableCtimeMinMaxValues {
    my ($self, $useMemory) = @_;
    my $db = $self->{"centstorage"};
    $db->query("DROP TABLE IF EXISTS `mod_bi_tmp_minmaxctime`");
    my $createTable = " CREATE TABLE `mod_bi_tmp_minmaxctime` (";
    $createTable .= " min_val INT NULL,";
    $createTable .= " max_val INT NULL,";
    $createTable .= " id_metric INT NULL";
    if (defined($useMemory) && $useMemory eq "true") {
        $createTable .= ") ENGINE=MEMORY CHARSET=utf8 COLLATE=utf8_general_ci;";
    } else {
        $createTable .= ") ENGINE=MyISAM CHARSET=utf8 COLLATE=utf8_general_ci;";
    }
    $db->query($createTable);
}

sub dropTempTableCtimeMinMaxValues {
    my $self = shift;
    my $db = $self->{"centstorage"};
    $db->query("DROP TABLE `mod_bi_tmp_minmaxctime`");
}

sub getFirstAndLastValues {
    my $self = shift;
    my $db = $self->{"centstorage"};
    
    my ($start_date, $end_date, $useMemory) = @_;
    
    $self->createTempTableCtimeMinMaxValues($useMemory);
    my $query = "INSERT INTO `mod_bi_tmp_minmaxctime` SELECT min(ctime) as min_val, max(ctime) as max_val, id_metric ";
    $query .= " FROM `data_bin`";
    $query .= " WHERE ctime >= UNIX_TIMESTAMP(" . $start_date . ") AND ctime < UNIX_TIMESTAMP(" . $end_date . ")";
    $query .= " GROUP BY id_metric";
    $db->query($query);
    
    $self->createTempTableMetricDayFirstLastValues($useMemory);
    $query = "INSERT INTO mod_bi_tmp_firstlastvalues SELECT d.value as first_value, d2.value as last_value, d.id_metric";
    $query .= " FROM data_bin as d, data_bin as d2, mod_bi_tmp_minmaxctime as db";
    $query .= " WHERE db.id_metric=d.id_metric AND db.min_val=d.ctime";
    $query .=         " AND db.id_metric=d2.id_metric AND db.max_val=d2.ctime";
    $query .= " GROUP BY db.id_metric";
    my $sth = $db->query($query);
    $self->addIndexTempTableMetricDayFirstLastValues();
    $self->dropTempTableCtimeMinMaxValues();
}

sub dailyPurge {
    my $self = shift;
    my $db = $self->{"centstorage"};
    my $logger = $self->{"logger"};
    my ($end) = @_;
    
    my $query = "DELETE FROM `data_bin` where ctime < UNIX_TIMESTAMP('" . $end . "')";
    $logger->writeLog("DEBUG", "[PURGE] [data_bin] purging data older than " . $end);
    $db->query($query);
}

1;
