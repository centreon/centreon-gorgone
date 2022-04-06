# 
# Copyright 2019 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package gorgone::modules::centreon::mbi::etl::import::main;

use strict;
use warnings;

use gorgone::modules::centreon::mbi::libs::bi::Dumper;
use gorgone::modules::centreon::mbi::libs::bi::Loader;
use gorgone::modules::centreon::mbi::libs::bi::MySQLTables;
use gorgone::modules::centreon::mbi::libs::Utils;

my ($biTables, $monTables, $utils);
my ($argsMon, $argsBi);

my ($centstorageBI, $centstorage, $centreon, $logger, $dumper, $loader, $etl, $centreonBI, $time);
my ($hostCentreon, $hostBI);

sub initVars {
    my ($etl) = @_;

    $biTables = gorgone::modules::centreon::mbi::libs::bi::MySQLTables->new($etl->{logger}, $etl->{run}->{dbbi_centstorage_con});
    $monTables = gorgone::modules::centreon::mbi::libs::bi::MySQLTables->new($etl->{logger}, $etl->{run}->{dbmon_centstorage_con});
    $utils = gorgone::modules::centreon::mbi::libs::Utils->new();
    $argsMon = $utils->buildCliMysqlArgs($etl->{run}->{dbmon}->{centstorage});
    $argsBi = $utils->buildCliMysqlArgs($etl->{run}->{dbbi}->{centstorage});
}

=pod
sub dropIndexesFromTable {
    my $table = shift;
    my $indexes = $centstorageBI->query("SHOW INDEX FROM ".$table);
    my $previous = "";
    while (my $row = $indexes->fetchrow_hashref()) {
        if ($row->{"Key_name"} ne $previous) {
            if (lc($row->{"Key_name"}) eq lc("PRIMARY")) {
                $centstorageBI->query("ALTER TABLE `".$table."` DROP PRIMARY KEY");
            }else {
                $centstorageBI->query("ALTER TABLE `".$table."` DROP INDEX ".$row->{"Key_name"});
            }
        }
        $previous = $row->{"Key_name"};
    }
}

sub createNotTimedTables {
    my ($options) = @_;

    foreach (@notTimedTables) {
        my $name = $_;
        $loader->dropTable($name);
        my $structure = $dumper->dumpTableStructure($name);
        $structure =~ s/(CONSTRAINT.*\n)//g;
        $structure =~ s/(\,\n\s+\))/\)/g;
        $structure =~ s/auto_increment\=[0-9]+//i;
        $structure =~ s/auto_increment//i;

        my $tableAlreadyExists = $biTables->createTable($name, $structure);
        if ($tableAlreadyExists){
            if(defined($options->{'rebuild'})) {
                $logger->writeLog("DEBUG", "[CREATE] Table already exists [".$name."]");
            }
        } else {
            if ($name eq "hoststateevents" || $name eq "servicestateevents") {
                dropIndexesFromTable($name);
                $logger->writeLog("DEBUG", "[INDEXING] Adding index [end_time] on table [".$name."]");
                $centstorageBI->query("ALTER TABLE `".$name."` ADD INDEX `idx_".$name."_end_time` (`end_time`)");
                $logger->writeLog("DEBUG", "[INDEXING] Adding index [in_downtime, start_time, end_time] on table [".$name."]");
                $centstorageBI->query("ALTER TABLE `".$name."` ADD INDEX `idx_".$name."_downtime_start_end_time` (in_downtime, start_time, end_time)");
            }
        }
    }
}
=cut

# Create tables for centstorage database on reporting server
sub createTables {
    my ($etl, $periods, $options, $notTimedTables, $timedTables) = @_;

=po
    while (my ($name, $fields) = each %timedTables) {
        if ($name eq "data_bin" || $name eq "mod_bam_reporting_ba_availabilities") {
            next;
        }
        if (defined($options->{'rebuild'}) && !defined($options->{'no-purge'})) {
            $loader->dropTable($name);
        }
        my $structure = $dumper->dumpTableStructure($name);
	    $structure =~ s/(CONSTRAINT.*\n)//g;
        $structure =~ s/(\,\n\s+\))/\)/g;
        my $tableAlreadyExists = $biTables->createTable($name, $structure);
        if ($tableAlreadyExists) {
            $logger->writeLog("DEBUG", "[CREATE] Table already exists [".$name."]");
        }
    }

    #Creating all centreon bi tables exept the one already created
    my $sth = $centstorage->query("SHOW TABLES LIKE 'mod_bi_%'");
    while (my @row = $sth->fetchrow_array()) {
        my $name = $row[0];
        my $tableAlreadyExists = $biTables->createTable($name, $dumper->dumpTableStructure($name));
        if ($tableAlreadyExists) {
            $logger->writeLog("DEBUG", "[CREATE] Table already exists [".$name."]");
        }
    }

    #Create centreon_acl table
    my $tableAlreadyExists = $biTables->createTable('centreon_acl', $dumper->dumpTableStructure('centreon_acl'));
    if ($tableAlreadyExists) {
        $logger->writeLog("DEBUG", "[CREATE] Table already exists [centreon_acl]");
    }

    $sth = $centstorage->query(
        "SELECT TABLE_NAME FROM information_schema.TABLES t1 WHERE t1.TABLE_NAME like 'mod_bam_reporting_%'".
        "AND  t1.TABLE_NAME NOT IN ('mod_bam_reporting_status','mod_bam_reporting_relations_ba_timeperiods','mod_bam_reporting_timeperiods',".
        "'mod_bam_reporting_timeperiods_exceptions','mod_bam_reporting_timeperiods_exclusions');"
    );

    while (my @row = $sth->fetchrow_array()) {
        my $name = $row[0];
        my $tableAlreadyExists = $biTables->createTable($name, $dumper->dumpTableStructure($name));
        if ($tableAlreadyExists) {
            $logger->writeLog("DEBUG", "[CREATE] Table already exists [".$name."]");
        }
    }
=cut
}

=pod
sub loadDataFile {
    my ($name, $file, $options) = @_;

    if (defined($options->{'rebuild'})) {
        if (!defined($options->{'no-purge'})) {
            $loader->truncateTable($name);
            $loader->disableKeys($name);
        }
    }
    $loader->loadData($name, $file);
    if (defined($options->{'rebuild'}) && !defined($options->{'no-purge'})) {
        $loader->enableKeys($name);
    }
#    unlink($file);
    my @rmCmdArgs = ("rm",  "-f", $file);
    system(@rmCmdArgs);
}

# Extract data from Centreon DB server
sub extractData {
    my ($options, $periods) = @_;

    my $excludeEndTime = 0;
    my ($start, $end);
    while (my ($name, $fields) = each %timedTables) {
        if ($name eq "data_bin" || $name eq "mod_bam_reporting_ba_availabilities") {
            $excludeEndTime = 1;
            # update parts for raw perfdata table data_bin
            if ($biTables->isPartitionEnabled) {
                $biTables->updateParts(($periods->{'raw_perfdata'})->{'end'}, "data_bin");
            }
            ($start, $end) = (($periods->{'raw_perfdata'})->{'start'},($periods->{'raw_perfdata'})->{'end'});
        } else {
            $excludeEndTime = 0;
            ($start, $end) = (($periods->{'raw_availabilitydata'})->{'start'},($periods->{'raw_availabilitydata'})->{'end'});
        }
        $logger->writeLog("INFO", "[DUMP] Dumping data of monitoring database to reporting server [".$name."]");
        my $file = $dumper->dumpData($hostCentreon, $name, $fields->[0], $fields->[1], $start, $end, $excludeEndTime);
        loadDataFile ($name, $file, $options);
    }
    createNotTimedTables($options);
    foreach (@notTimedTables) {
        my $name = $_;
        $logger->writeLog("INFO", "[DUMP] Dumping data of monitoring database to reporting server [".$name."]");
        my $file = $dumper->dumpData($hostCentreon, $name);
        loadDataFile ($name, $file, $options);
    }
}

# load data into the reporting server from files copied from the monitoring server
sub extractCentreonDB {
	my ($etlProperties) = @_;
    my $tables = "host hostgroup_relation hostgroup hostcategories_relation hostcategories " .
                "host_service_relation service service_categories service_categories_relation ".
				"timeperiod mod_bi_options servicegroup mod_bi_options_centiles servicegroup_relation contact contactgroup_service_relation ".
				"host_template_relation command contact_host_relation contactgroup_host_relation contactgroup contact_service_relation";

	my @args = ("mysqldump",
                "--skip-add-drop-table", "--skip-add-locks",
                "--skip-comments", "-u", $hostCentreon->{'Centreon_user'},
                "-p".$hostCentreon->{'Centreon_pass'},
                "-h", $hostCentreon->{'Centreon_host'},
				"-P".$hostCentreon->{'Centreon_port'},
                "-r", $loader->getStorageDir."centreon.sql",
                $hostCentreon->{'Centreon_db'},
                $tables);
    $logger->writeLog("INFO", "[DUMP] Dumping monitoring server database directly on reporting server [".$hostCentreon->{'Centreon_db'}."]");
    my $str ="";
    foreach (@args) {
        $str .= $_." ";
    }
    system($str);
    if (! -r  $loader->getStorageDir."centreon.sql") {
        $logger->writeLog("WARNING", "Cannot dump file for database [".$hostCentreon->{'Centreon_db'}."]");
    }
    # loading Centreon full database into reporting server
    if (-r $loader->getStorageDir."centreon.sql") {
        $centreonBI->dropDatabase();
        $centreonBI->createDatabase();
        my @args = ("mysql", "-u", $hostBI->{'Centreon_user'},
                    "-p".$hostBI->{'Centreon_pass'},
                    "-h", $hostBI->{'Centreon_host'},
					"-P", $hostBI->{'Centreon_port'},
                    $hostBI->{'Centreon_db'},
                    "-e", "source ".$loader->getStorageDir."centreon.sql");
        $logger->writeLog("INFO", "[LOAD] Loading data into reporting database [".$hostBI->{'Centreon_db'}."]");
        system(@args);
        unlink($loader->getStorageDir."centreon.sql");
    }else {
        $logger->writeLog("WARNING", "[LOAD] Cannot find data file for database [".$hostBI->{'Centreon_db'}."]");
    }
}
=cut

sub dataBin {
    my ($etl, $etlProperties, $options, $periods) = @_;

    return if ($options->{ignore_databin} == 1 || $options->{centreon_only} == 1 || (defined($options->{bam_only}) && $options->{bam_only} == 1));

    my $action = { run => 0, type => 1, db => 'centstorage', sql => [], actions => [] };

    my $drop = 0;
    if ($options->{rebuild} == 1 && $options->{nopurge} == 0) {
        push @{$action->{sql}}, [ 'drop table data_bin', 'DROP TABLE data_bin' ]
        $drop = 1;
    }

    my $isExists = 0;
    $isExists = 1 if ($biTables->tableExists('data_bin'));

    my $partitionsPerf = $utils->getRangePartitionDate($periods->{raw_perfdata}->{start}, $periods->{raw_perfdata}->{end});

    if ($isExists == 0 || $action->{drop} == 1) {
        $action->{create} = 1;

        my $structure = $monTables->dumpTableStructure('data_bin');
        $structure =~ s/KEY.*\(\`id_metric\`\)\,//g;
        $structure =~ s/KEY.*\(\`id_metric\`\)//g;
        $structure =~ s/\n.*PARTITION.*//g;
        $structure =~ s/\,[\n\s]+\)/\)/;
        $structure .= " PARTITION BY RANGE(`ctime`) (";

        
        my $append = '';
        foreach (@$partitionsPerf) {
            $structure .= $append . "PARTITION p" . $_->{name} . " VALUES LESS THAN (" . $_->{epoch} . ")";
            $append = ',';
        }
        $structure .= ';';

        push @{$action->{sql}},
            [ 'create table data_bin', $structure ],
            [ 'create index data_bin ctime', "ALTER TABLE `".$name."` ADD INDEX `idx_data_bin_ctime` (`ctime`)" ],
            [ 'create index data_bin id_metric/ctime', "ALTER TABLE `".$name."` ADD INDEX `idx_data_bin_idmetric_ctime` (`id_metric`,`ctime`)" ];
    }

    if ($isExists == 1 && $drop == 0) {
        my $start = $biTables->getLastPartRange('data_bin');
        my $partitions = $utils->getRangePartitionDate($start, $periods->{raw_perfdata}->{end});
        foreach (@$partitions) {
            push @{$action->{sql}}, 
                [ 'create data_bin partition ' . $_->{name}, "ALTER TABLE `data_bin` ADD PARTITION (PARTITION `p$_->{name}` VALUES LESS THAN($_->{epoch}))"];
        }
    }

    if ($etlProperties->{'statistics.type'} eq 'all' || $etlProperties->{'statistics.type'} eq 'perfdata') {
        my $overCond = '';
        foreach (@$partitionsPerf) {
            my $cmd = sprintf(
                "mysqldump --skip-add-drop-table --skip-add-locks --skip-comments %s --databases '%s' --tables %s --where=\"%s\" | mysql %s '%s'",
                $argsMon,
                $etl->{run}->{dbmon}->{centstorage}->{db},
                'data_bin',
                $overCond . 'ctime < ' . $_->{epoch},
                $argsBi,
                $etl->{run}->{dbbi}->{centstorage}->{db}
            );
            $overCond = 'ctime >= $_->{epoch} AND ';
            push @{$action->{actions}}, { type => 2, message => 'import data_bin partition ' . $_->{name}, command => $cmd };
        }
    }
}

sub selectTables {
    my ($etl, $etlProperties, $options) = @_;

    my @notTimedTables = ();
    my %timedTables = ();

    my @ctime = ('ctime', 'ctime');
    my @startEnd = ('date_start', 'date_end');
    my @timeId = ('time_id', 'time_id');
    my $importComment = $etlProperties->{'import.comments'};
	my $importDowntimes = $etlProperties->{'import.downtimes'};

    push @notTimedTables, 'centreon_acl';

    if (!defined($etlProperties->{'statistics.type'})) {
        die 'cannot determine statistics type or compatibility mode for data integration';
    }
    if (!defined($options->{databin_only}) || $options->{databin_only} == 0) {
	  if (!defined($options->{bam_only}) || $options->{bam_only} == 0) {
        if ($etlProperties->{'statistics.type'} eq 'all') {
            push @notTimedTables, 'index_data';
            push @notTimedTables, 'metrics';
            push @notTimedTables, 'hoststateevents';
            push @notTimedTables, 'servicestateevents';
            push @notTimedTables, 'instances';
            push @notTimedTables, 'hosts';

            if ($importComment eq 'true'){
                push @notTimedTables, 'comments';
            }
            if ($importDowntimes eq 'true'){
                push @notTimedTables, 'downtimes';
            }

            push @notTimedTables, 'acknowledgements';
        }
        if ($etlProperties->{'statistics.type'} eq 'availability') {
            push @notTimedTables, 'hoststateevents';
            push @notTimedTables, 'servicestateevents';
            push @notTimedTables, 'instances';
            push @notTimedTables, 'hosts';
            if ($importComment eq 'true'){
                push @notTimedTables, 'comments';
            }
            push @notTimedTables, 'acknowledgements';
        }
        if ($etlProperties->{'statistics.type'} eq "perfdata") {
            push @notTimedTables, 'index_data';
            push @notTimedTables, 'metrics';
            push @notTimedTables, 'instances';
            push @notTimedTables, 'hosts';
            push @notTimedTables, 'acknowledgements';

        }
    }

	my $sth = $etl->{run}->{dbmon_centreon_con}->query("SELECT id FROM modules_informations WHERE name='centreon-bam-server'");
	if (my $row = $sth->fetchrow_array() && $etlProperties->{'statistics.type'} ne 'perfdata') {
            $timedTables{mod_bam_reporting_ba_availabilities} = \@timeId;
			push @notTimedTables, "mod_bam_reporting_ba";
            push @notTimedTables, "mod_bam_reporting_ba_events";
            push @notTimedTables, "mod_bam_reporting_ba_events_durations";
            push @notTimedTables, "mod_bam_reporting_bv";
            push @notTimedTables, "mod_bam_reporting_kpi";
            push @notTimedTables, "mod_bam_reporting_kpi_events";
            push @notTimedTables, "mod_bam_reporting_relations_ba_bv";
            push @notTimedTables, "mod_bam_reporting_relations_ba_kpi_events";
			push @notTimedTables, "mod_bam_reporting_timeperiods";
        }

    }
    return (\@notTimedTables, \%timedTables);
}

sub prepare {
    my ($etl) = @_;

    initVars($etl);

    # define data extraction period based on program options --start & --end or on data retention period
    my %periods;
    if ($etl->{run}->{options}->{rebuild} == 1 || $etl->{run}->{options}->{create_tables}) {
        if ($etl->{run}->{options}->{start} eq '' && $etl->{run}->{options}->{end} eq '') {
            # get max values for retention by type of statistics in order to be able to rebuild hourly and daily stats
            my ($start, $end) = $etl->{etlProp}->getMaxRetentionPeriodFor('perfdata');

            $periods{raw_perfdata} = { start => $start, end => $end };
            ($start, $end)= $etl->{etlProp}->getMaxRetentionPeriodFor('availability');
            $periods{raw_availabilitydata} = { start => $start, end => $end};
        } elsif ($etl->{run}->{options}->{start} ne '' && $etl->{run}->{options}->{end} ne '') {
            # set period defined manually
            my %dates = (start => $etl->{run}->{options}->{start}, end => $etl->{run}->{options}->{end});
            $periods{raw_perfdata} = \%dates;
            $periods{raw_availabilitydata} = \%dates;
        }
    } else {
        # set yesterday start and end dates as period (--daily)
        my %dates;
        ($dates{start}, $dates{end}) = $etl->{time}->getYesterdayTodayDate();
        $periods{raw_perfdata} = \%dates;
        $periods{raw_availabilitydata} = \%dates;
    }

    # identify the Centreon Storage DB tables to extract based on ETL properties
    my ($notTimedTables, $timedTables) = selectTables(
        $etl,
        $etl->{run}->{etlProperties},
        $etl->{run}->{options}
    );

    dataBin(
        $etl,
        $etl->{run}->{etlProperties},
        $etl->{run}->{options},
        \%periods
    );

    # create non existing tables
    createTables($etl, \%periods, $etl->{run}->{options}, $notTimedTables, $timedTables);

    return ;
    
    # If we only need to create empty tables, create them then exit program
    if ($etl->{run}->{options}->{create_tables} == 1) {
      return ;
    }
    # extract raw availability and perfdata from monitoring server and insert it into reporting server
    if ($etl->{run}->{options}->{centreon_only} == 0) {
        extractData($etl->{run}->{options}, \%periods);
    }
    # extract Centreon configuration DB from monitoring server and insert it into reporting server
    if ($etl->{run}->{options}->{databin_only} == 0 && (!defined($etl->{run}->{options}->{bam_only}) || $etl->{run}->{options}->{bam_only} == 0)) {
        extractCentreonDB($etl->{run}->{etlProperties});
    }

	#Update centreon_acl table each time centreon-only is started - not the best way but need for Widgets
=pod
    my $centreonAcl = "centreon_acl";
    my $structure = $dumper->dumpTableStructure($centreonAcl);
    my $tableAlreadyExists = $biTables->createTable($centreonAcl, $structure);
    $logger->writeLog("INFO", "[DUMP] Update Centreon ACL data");
    my $file = $dumper->dumpData($hostCentreon, 'centreon_acl');
    loadDataFile('centreon_acl', $file,\%options);
=cut
}

1;
