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

package gorgone::modules::centreon::mbi::etlworkers::perfdata::main;

use strict;
use warnings;
use gorgone::modules::centreon::mbi::libs::centreon::Timeperiod;
use gorgone::modules::centreon::mbi::libs::bi::HostAvailability;
use gorgone::modules::centreon::mbi::libs::bi::ServiceAvailability;
use gorgone::modules::centreon::mbi::libs::bi::HGMonthAvailability;
use gorgone::modules::centreon::mbi::libs::bi::HGServiceMonthAvailability;
use gorgone::modules::centreon::mbi::libs::bi::Time;
use gorgone::modules::centreon::mbi::libs::bi::MySQLTables;
use gorgone::modules::centreon::mbi::libs::bi::BIHostStateEvents;
use gorgone::modules::centreon::mbi::libs::bi::BIServiceStateEvents;
use gorgone::modules::centreon::mbi::libs::bi::LiveService;
use gorgone::modules::centreon::mbi::libs::centstorage::HostStateEvents;
use gorgone::modules::centreon::mbi::libs::centstorage::ServiceStateEvents;
use gorgone::modules::centreon::mbi::libs::Utils;
use gorgone::standard::misc;

my ($utils, $time, $tablesManager, $timePeriod);
my ($hostAv, $serviceAv);
my ($hgAv, $hgServiceAv);
my ($biHostEvents, $biServiceEvents);
my ($hostEvents, $serviceEvents);
my ($liveService);

sub initVars {
    my ($etlwk, %options) = @_;

    $utils = gorgone::modules::centreon::mbi::libs::Utils->new($etlwk->{messages});
    $timePeriod = gorgone::modules::centreon::mbi::libs::centreon::Timeperiod->new($etlwk->{messages}, $etlwk->{dbbi_centreon_con});
    $time = gorgone::modules::centreon::mbi::libs::bi::Time->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con});
    $tablesManager = gorgone::modules::centreon::mbi::libs::bi::MySQLTables->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con});
    $biHostEvents = gorgone::modules::centreon::mbi::libs::bi::BIHostStateEvents->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con}, $timePeriod);
	$biServiceEvents = gorgone::modules::centreon::mbi::libs::bi::BIServiceStateEvents->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con}, $timePeriod);
    $liveService = gorgone::modules::centreon::mbi::libs::bi::LiveService->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con});
    $hostEvents = gorgone::modules::centreon::mbi::libs::centstorage::HostStateEvents->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con}, $biHostEvents, $timePeriod);
	$serviceEvents = gorgone::modules::centreon::mbi::libs::centstorage::ServiceStateEvents->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con}, $biServiceEvents, $timePeriod);
    $hostAv = gorgone::modules::centreon::mbi::libs::bi::HostAvailability->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con});
	$serviceAv = gorgone::modules::centreon::mbi::libs::bi::ServiceAvailability->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con});
    $hgAv = gorgone::modules::centreon::mbi::libs::bi::HGMonthAvailability->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con});
	$hgServiceAv = gorgone::modules::centreon::mbi::libs::bi::HGServiceMonthAvailability->new($etlwk->{messages}, $etlwk->{dbbi_centstorage_con});
}

sub sql {
    my ($etlwk, %options) = @_;

    return if (!defined($options{params}->{sql}));

    foreach (@{$options{params}->{sql}}) {
        $etlwk->{messages}->writeLog('INFO', $_->[0]);
        if ($options{params}->{db} eq 'centstorage') {
            $etlwk->{dbbi_centstorage_con}->query($_->[1]);
        } elsif ($options{params}->{db} eq 'centreon') {
            $etlwk->{dbbi_centreon_con}->query($_->[1]);
        }
    }
}

sub perfdata {
    my ($etlwk, %options) = @_;

    initVars($etlwk, %options);

    my ($startTimeId, $startUtime) = $time->getEntryID($options{params}->{start});
    my ($endTimeId, $endUtime) = $time->getEntryID($options{params}->{end});

    my $liveServices = $liveService->getLiveServicesByTpId();

    if (defined($options{params}->{hosts}) && $options{params}->{hosts} == 1) {
        processEventsHosts($etlwk, start => $startUtime, end => $endUtime, liveServices => $liveServices, %options);
    } elsif (defined($options{params}->{services}) && $options{params}->{services} == 1) {
        processEventsServices($etlwk, start => $startUtime, end => $endUtime, liveServices => $liveServices, %options);
    }
}

sub centile {
    my ($etlwk, %options) = @_;

    $etlwk->{messages}->writeLog("INFO", "[AVAILABILITY] Processing hosts day: $options{params}->{start} => $options{params}->{end} [$options{params}->{liveserviceName}]");
    my $ranges = $timePeriod->getTimeRangesForDay($options{startWeekDay}, $options{params}->{liveserviceName}, $options{startUtime});
    my $dayEvents = $biHostEvents->getDayEvents($options{startUtime}, $options{endUtime}, $options{params}->{liveserviceId}, $ranges);
    $hostAv->insertStats($dayEvents, $options{startTimeId}, $options{params}->{liveserviceId});
}

sub availabilityDayServices {
    my ($etlwk, %options) = @_;

    $etlwk->{messages}->writeLog("INFO", "[AVAILABILITY] Processing services day: $options{params}->{start} => $options{params}->{end} [$options{params}->{liveserviceName}]");
    my $ranges = $timePeriod->getTimeRangesForDay($options{startWeekDay}, $options{params}->{liveserviceName}, $options{startUtime});
    my $dayEvents = $biServiceEvents->getDayEvents($options{startUtime}, $options{endUtime}, $options{params}->{liveserviceId}, $ranges);
    $serviceAv->insertStats($dayEvents, $options{startTimeId}, $options{params}->{liveserviceId});
}

sub availabilityMonthHosts {
    my ($etlwk, %options) = @_;

    $etlwk->{messages}->writeLog("INFO", "[AVAILABILITY] Processing services month: $options{params}->{start} => $options{params}->{end}");
    my $data = $hostAv->getHGMonthAvailability($options{params}->{start}, $options{params}->{end}, $biHostEvents);
    $hgAv->insertStats($options{startTimeId}, $data);
}

sub availabilityMonthServices {
    my ($etlwk, %options) = @_;

    $etlwk->{messages}->writeLog("INFO", "[AVAILABILITY] Processing hosts month: $options{params}->{start} => $options{params}->{end}");
    my $data = $serviceAv->getHGMonthAvailability_optimised($options{params}->{start}, $options{params}->{end}, $biServiceEvents);
    $hgServiceAv->insertStats($options{startTimeId}, $data);
}

sub availability {
    my ($etlwk, %options) = @_;

    initVars($etlwk, %options);

    my ($startTimeId, $startUtime) = $time->getEntryID($options{params}->{start});
    my ($endTimeId, $endUtime) = $time->getEntryID($options{params}->{end});
    my $startWeekDay = $utils->getDayOfWeek($options{params}->{start});

    if ($options{params}->{type} eq 'availability_day_hosts') {
        availabilityDayHosts(
            $etlwk,
            startTimeId => $startTimeId,
            startUtime => $startUtime,
            endTimeId => $endTimeId,
            endUtime => $endUtime,
            startWeekDay => $startWeekDay,
            %options
        );
    } elsif ($options{params}->{type} eq 'availability_day_services') {
        availabilityDayServices(
            $etlwk,
            startTimeId => $startTimeId,
            startUtime => $startUtime,
            endTimeId => $endTimeId,
            endUtime => $endUtime,
            startWeekDay => $startWeekDay,
            %options
        );
    } elsif ($options{params}->{type} eq 'availability_month_services') {
         availabilityMonthServices(
            $etlwk,
            startTimeId => $startTimeId,
            %options
         );
    } elsif ($options{params}->{type} eq 'availability_month_hosts') {
        availabilityMonthHosts(
            $etlwk,
            startTimeId => $startTimeId,
            %options
        );
    }
}

1;
