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

package gorgone::modules::centreon::mbi::etl::perfdata::main;

use strict;
use warnings;

use gorgone::modules::centreon::mbi::libs::bi::Time;
use gorgone::modules::centreon::mbi::libs::bi::LiveService;
use gorgone::modules::centreon::mbi::libs::bi::MySQLTables;
use gorgone::modules::centreon::mbi::libs::Utils;

my ($biTables, $utils, $liveService, $time);

sub initVars {
    my ($etl) = @_;

    $biTables = gorgone::modules::centreon::mbi::libs::bi::MySQLTables->new($etl->{run}->{messages}, $etl->{run}->{dbbi_centstorage_con});
    $utils = gorgone::modules::centreon::mbi::libs::Utils->new($etl->{run}->{messages});
    $liveService = gorgone::modules::centreon::mbi::libs::bi::LiveService->new($etl->{run}->{messages}, $etl->{run}->{dbbi_centstorage_con});
    $time = gorgone::modules::centreon::mbi::libs::bi::Time->new($etl->{run}->{messages}, $etl->{run}->{dbbi_centstorage_con});
}

sub emptyTableForRebuild {
    my ($etl, %options) = @_;

    my $sql = [ [ '[CREATE] Deleting table [' . $options{name} . ']', 'DROP TABLE IF EXISTS `' . $options{name} . '`' ] ];

    my $structure = $biTables->dumpTableStructure($options{name});
    $structure =~ s/KEY.*\(\`$options{column}\`\)\,//g;
	$structure =~ s/KEY.*\(\`$options{column}\`\)//g;
	$structure =~ s/\,[\n\s+]+\)/\n\)/g;
    
    if (defined($options{start})) {
        $structure =~ s/\n.*PARTITION.*//g;
        $structure =~ s/\,[\n\s]+\)/\)/;
        $structure .= ' PARTITION BY RANGE(`' . $options{column} . '`) (';

        my $partitionsPerf = $utils->getRangePartitionDate($options{start}, $options{end});

        my $append = '';
        foreach (@$partitionsPerf) {
            $structure .= $append . "PARTITION p" . $_->{name} . " VALUES LESS THAN (" . $_->{epoch} . ")";
            $append = ',';
        }
        $structure .= ');';
    }

    push @$sql,
        [ '[CREATE] Add table [' . $options{name} . ']', $structure ],
        [ "[INDEXING] Adding index [idx_$options{name}_$options{column}] on table [$options{name}]", "ALTER TABLE `$options{name}` ADD INDEX `idx_$options{name}_$options{column}` (`$options{column}`)" ];

    push @{$etl->{run}->{schedule}->{perfdata}->{stages}->[0]}, { type => 'sql', db => 'centstorage', sql => $sql };
}

sub deleteEntriesForRebuild {
    my ($etl, %options) = @_;

    my $sql = [];
    if (!$biTables->isTablePartitioned($options{name})) {
        push @$sql, $utils->getDateEpoch($options{start}, $options{end});

        push @$sql,
            [
                "[PURGE] Delete table [$options{name}] from $options{start} to $options{end}",
                "DELETE FROM $options{name} WHERE time_id >= " . $utils->getDateEpoch($options{start}) . " AND time_id < " . $utils->getDateEpoch($options{end})
            ];
	} else {
        my $partitionsPerf = $utils->getRangePartitionDate($options{start}, $options{end});
        foreach (@$partitionsPerf) {
            push @$sql,
                [
                    "[PURGE] Truncate partition $_->{name} on table [$options{name}]",
                    "ALTER TABLE $options{name} TRUNCATE PARTITION p$_->{name}"
                ];
        }
	}

    push @{$etl->{run}->{schedule}->{event}->{stages}->[0]}, { type => 'sql', db => 'centstorage', sql => $sql };
}

sub purgeTables {
	my ($etl, $periods) = @_;

    my ($daily_start, $daily_end) = ($periods->{'perfdata.daily'}->{'start'}, $periods->{'perfdata.daily'}->{'end'});
    my ($hourly_start, $hourly_end) = ($periods->{'perfdata.hourly'}->{'start'}, $periods->{'perfdata.hourly'}->{'end'});

    #To prevent from purging monthly data when the no-purge rebuild is made inside one month
    my $firstDayOfMonth = $daily_start;
    my $firstDayOfMonthEnd = $daily_end;
    my $startAndEndSameMonth = 0;
    $firstDayOfMonth =~ s/([1-2][0-9]{3})\-([0-1][0-9])\-[0-3][0-9]/$1\-$2\-01/;
    $firstDayOfMonthEnd =~ s/([1-2][0-9]{3})\-([0-1][0-9])\-[0-3][0-9]/$1\-$2\-01/;

    if ($firstDayOfMonth eq $firstDayOfMonthEnd) {
        $startAndEndSameMonth = 1;
    }

    if ($etl->{run}->{options}->{nopurge} == 0) {
        # deleting data that will be rewritten
        if ($etl->{run}->{etlProperties}->{'perfdata.granularity'} ne 'hour' && (!defined($etl->{run}->{options}->{month_only}) || $etl->{run}->{options}->{month_only} == 0)) {
            if ((!defined($etl->{run}->{options}->{centile_only}) || $etl->{run}->{options}->{centile_only} == 0)) {                
                deleteEntriesForRebuild($etl, name => 'mod_bi_metricdailyvalue', start => $daily_start, end => $daily_end);

                if ($etl->{run}->{etlProperties}->{'perfdata.granularity'} ne "day" && (!defined($etl->{run}->{options}->{month_only}) || $etl->{run}->{options}->{month_only} == 0)) {
                    deleteEntriesForRebuild($etl, name => 'mod_bi_metrichourlyvalue', start => $hourly_start, end => $hourly_end);
                }
          
                #Deleting monthly data only if start and end are not in the same month
                if (!$startAndEndSameMonth) {
                    deleteEntriesForRebuild($etl, name => 'mod_bi_metricmonthcapacity', start => $firstDayOfMonth, end => $daily_end);
                }
            }
           
            if ((!defined($etl->{run}->{options}->{no_centile}) || $etl->{run}->{options}->{no_centile} == 0)) {
                if (defined($etl->{run}->{etlProperties}->{'centile.day'}) && $etl->{run}->{etlProperties}->{'centile.day'} eq '1') {
                    deleteEntriesForRebuild($etl, name => 'mod_bi_metriccentiledailyvalue', start => $daily_start, end => $daily_end);
                }
                if (defined($etl->{run}->{etlProperties}->{'centile.week'}) && $etl->{run}->{etlProperties}->{'centile.week'} eq '1') {
                    deleteEntriesForRebuild($etl, name => 'mod_bi_metriccentileweeklyvalue', start => $daily_start, end => $daily_end);
                }
            
                if (defined($etl->{run}->{etlProperties}->{'centile.month'}) && $etl->{run}->{etlProperties}->{'centile.month'} eq '1' && !$startAndEndSameMonth) {
                    deleteEntriesForRebuild($etl, name => 'mod_bi_metriccentilemonthlyvalue', start => $firstDayOfMonth, end => $daily_end);
                }
            }
        }
    } else {
        # deleting and recreating tables, recreating partitions for daily and hourly tables
        if ($etl->{run}->{etlProperties}->{'perfdata.granularity'} ne "hour" && (!defined($etl->{run}->{options}->{month_only}) || $etl->{run}->{options}->{month_only} == 0)) {
            if ((!defined($etl->{run}->{options}->{centile_only}) || $etl->{run}->{options}->{centile_only} == 0)) {
                emptyTableForRebuild($etl, name => 'mod_bi_metricdailyvalue', column => 'time_id', start => $daily_start, end => $daily_end);

                emptyTableForRebuild($etl, name => 'mod_bi_metricmonthcapacity', column => 'time_id');
            }
        
            if ((!defined($etl->{run}->{options}->{no_centile}) || $etl->{run}->{options}->{no_centile} == 0)) {
                #Managing Daily Centile table
                if (defined($etl->{run}->{etlProperties}->{'centile.day'}) && $etl->{run}->{etlProperties}->{'centile.day'} eq '1') {
                    emptyTableForRebuild($etl, name => 'mod_bi_metriccentiledailyvalue', column => 'time_id', start => $daily_start, end => $daily_end);
                }
                #Managing Weekly Centile table
                if (defined($etl->{run}->{etlProperties}->{'centile.week'}) && $etl->{run}->{etlProperties}->{'centile.week'} eq '1') {
                    emptyTableForRebuild($etl, name => 'mod_bi_metriccentileweeklyvalue', column => 'time_id', start => $daily_start, end => $daily_end);
                }
                #Managing Monthly Centile table
                if (defined($etl->{run}->{etlProperties}->{'centile.month'}) && $etl->{run}->{etlProperties}->{'centile.month'} eq '1') {
                    emptyTableForRebuild($etl, name => 'mod_bi_metriccentilemonthlyvalue', column => 'time_id', start => $daily_start, end => $daily_end);
                }
            }
        }
      
        if ($etl->{run}->{etlProperties}->{'perfdata.granularity'} ne "day" && 
            (!defined($etl->{run}->{options}->{month_only}) || $etl->{run}->{options}->{month_only} == 0) && 
            (!defined($etl->{run}->{options}->{no_centile}) || $etl->{run}->{options}->{no_centile} == 0)) {
            emptyTableForRebuild($etl, name => 'mod_bi_metrichourlyvalue', column => 'time_id', start => $hourly_start, end => $hourly_end);
        }
    }
}

sub processByDay {
	my ($etl, $liveServices, $start, $end) = @_;
			
   	while (my ($liveserviceName, $liveserviceId) = each (%$liveServices)) {
   		if (!defined($etl->{run}->{options}->{service_only}) || $etl->{run}->{options}->{service_only} == 0) {
            push @{$etl->{run}->{schedule}->{event}->{stages}->[1]}, {
                type => 'availability_day_hosts',
                liveserviceName => $liveserviceName,
                liveserviceId => $liveserviceId,
                start => $start,
                end => $end
            };
        }
		
        if (!defined($etl->{run}->{options}->{host_only}) || $etl->{run}->{options}->{host_only} == 0) {
            push @{$etl->{run}->{schedule}->{event}->{stages}->[1]}, {
                type => 'availability_day_services',
                liveserviceName => $liveserviceName,
                liveserviceId => $liveserviceId,
                start => $start,
                end => $end
            };
        }
   	}
}

sub processHostgroupAvailability {
	my ($etl, $start, $end) = @_;

	$time->insertTimeEntriesForPeriod($start, $end);
	if (!defined($etl->{run}->{options}->{service_only}) || $etl->{run}->{options}->{service_only} == 0) {
		push @{$etl->{run}->{schedule}->{event}->{stages}->[2]}, {
            type => 'availability_month_services',
            start => $start,
            end => $end
        };
	}
	if (!defined($etl->{run}->{options}->{host_only}) || $etl->{run}->{options}->{host_only} == 0) {
        push @{$etl->{run}->{schedule}->{event}->{stages}->[2]}, {
            type => 'availability_month_hosts',
            start => $start,
            end => $end
        };
	}
}

sub dailyProcessing {
    my ($etl, $liveServices) = @_;

    # getting yesterday start and end date to process yesterday data
    my ($start, $end) = $utils->getYesterdayTodayDate();
    # daily mod_bi_time table filling
    $time->insertTimeEntriesForPeriod($start, $end);

    my ($epoch, $partName) = $utils->getDateEpoch($end);
    push @{$etl->{run}->{schedule}->{perfdata}->{stages}->[0]}, {
        type => 'sql',
        db => 'centstorage',
        sql => [
            '[PARTITIONS] Add partition [p' . $partName . '] on table [mod_bi_metricdailyvalue]',
            "ALTER TABLE `mod_bi_metricdailyvalue` ADD PARTITION (PARTITION `p$partName` VALUES LESS THAN(" . $epoch . "))"
        ]
    };
    if ($etl->{run}->{etlProperties}->{'perfdata.granularity'} ne 'day') {
        push @{$etl->{run}->{schedule}->{event}->{stages}->[0]}, {
            type => 'sql',
            db => 'centstorage',
            sql => [
                '[PARTITIONS] Add partition [p' . $partName . '] on table [mod_bi_metrichourlyvalue]',
                "ALTER TABLE `mod_bi_metrichourlyvalue` ADD PARTITION (PARTITION `p$partName` VALUES LESS THAN(" . $epoch . "))"
            ]
        };
    }
    if (defined($etl->{run}->{etlProperties}->{'centile.day'}) && $etl->{run}->{etlProperties}->{'centile.day'} eq '1') {
        push @{$etl->{run}->{schedule}->{event}->{stages}->[0]}, {
            type => 'sql',
            db => 'centstorage',
            sql => [
                '[PARTITIONS] Add partition [p' . $partName . '] on table [mod_bi_metriccentiledailyvalue]',
                "ALTER TABLE `mod_bi_metriccentiledailyvalue` ADD PARTITION (PARTITION `p$partName` VALUES LESS THAN(" . $epoch . "))"
            ]
        };
    }

    # processing agregation by month. If the day is the first day of the month, also processing agregation by month
    processDayAndMonthAgregation($etl, $liveServices, $start, $end);

    # processing agregation by hour
    processHours($etl, $start, $end); 
}

sub rebuildProcessing {
    my ($etl, $liveServices) = @_;

    # getting rebuild period by granularity of perfdata from data retention rules
    my $periods = $etl->{etlProp}->getRetentionPeriods();

    my ($start, $end);
    if ($etl->{run}->{options}->{start} ne '' && $etl->{run}->{options}->{end} ne '') {
        ($start, $end) = ($etl->{run}->{options}->{start}, $etl->{run}->{options}->{end});
        while (my ($key, $values) = each %$periods) {
            $values->{'start'} = $options->{'start'};
            $values->{'end'} = $options->{'end'};
        }
    } else {
        # getting max perfdata retention period to fill mod_bi_time
        ($start, $end) = $etl->{etlProp}->getMaxRetentionPeriodFor('perfdata');
    }

    # insert entries into table mod_bi_time
    $time->insertTimeEntriesForPeriod($start, $end);

    purgeTables($etl, $periods);

    # rebuilding statistics by day and by month
    ($start, $end) = ($periods->{'perfdata.daily'}->{start}, $periods->{'perfdata.daily'}->{end});

    my $days = $utils->getRangePartitionDate($start, $end);
    foreach (@$days) {
        $end = $_->{date};
        processDayAndMonthAgregation($etl, $liveServices, $start, $end);
        $start = $end;
    }

    # rebuilding statistics by hour
    ($start, $end) = ($periods->{'perfdata.hourly'}->{start}, $periods->{'perfdata.hourly'}->{'end'});
    
    my $days = $utils->getRangePartitionDate($start, $end);
    foreach (@$days) {
        $end = $_->{date};
        processHours($etl, $start, $end);
        $start = $end;
    }
}

sub prepare {
    my ($etl) = @_;

    initVars($etl);

    if (!defined($etl->{run}->{etlProperties}->{'statistics.type'}) || $etl->{run}->{etlProperties}->{'statistics.type'} eq "availability") {
        $etl->send_log(code => GORGONE_MODULE_CENTREON_MBIETL_PROGRESS, token => $self->{run}->{token}, data => { messages => [ ['I', '[SCHEDULER][PERFDATA] Performance statistics calculation disabled' ] ] });
        return ;
    }

    if ((!defined($etl->{run}->{options}->{no_centile}) || $etl->{run}->{options}->{no_centile} == 0) && 
        defined($etl->{run}->{etlProperties}->{'centile.include.servicecategories'}) and $etl->{run}->{etlProperties}->{'centile.include.servicecategories'} eq '') {
        $etl->send_log(code => GORGONE_MODULE_CENTREON_MBIETL_PROGRESS, token => $self->{run}->{token}, data => { messages => [ ['I', '[SCHEDULER][PERFDATA] No service categories selected for centile calculation - centile agregation will not be calculated' ] ] });
    }

    my $liveServiceList = $liveService->getLiveServicesByNameForTpIds($etl->{run}->{etlProperties}->{'liveservices.perfdata'});

    if ($etl->{run}->{options}->{daily} == 1) {
        dailyProcessing($etl, $liveServiceList);
    } elsif ($etl->{run}->{options}->{rebuild} == 1) {
        rebuildProcessing($etl, $liveServiceList);
    }
}

1;
