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

package gorgone::modules::centreon::audit::metrics::centreon::realtime;

use warnings;
use strict;

sub metrics {
    my (%options) = @_;

    return undef if (!defined($options{centstorage_sqlquery}));

    my $metrics = {
        status_code => 0,
        status_message => 'ok',
        num_hosts => 0,
        num_services => 0
    };

    my ($status, $datas) = $options{centstorage_sqlquery}->custom_execute(
        request => "SELECT count(*) FROM instances, hosts, services WHERE instances.running = '1' AND hosts.instance_id = instances.instance_id AND hosts.enabled = '1' AND services.host_id = hosts.host_id AND services.enabled = '1'",
        mode => 2
    );
    if ($status == -1 || !defined($datas->[0])) {
        $metrics->{status_code} = 1;
        $metrics->{status_message} = 'cannot get number of services';
        return $metrics;
    }
    $metrics->{num_services} = $datas->[0]->[0];

    ($status, $datas) = $options{centstorage_sqlquery}->custom_execute(
        request => "SELECT count(*) FROM instances, hosts WHERE instances.running = '1' AND hosts.instance_id = instances.instance_id AND hosts.enabled = '1'",
        mode => 2
    );
    if ($status == -1 || !defined($datas->[0])) {
        $metrics->{status_code} = 1;
        $metrics->{status_message} = 'cannot get number of hosts';
        return $metrics;
    }
    $metrics->{num_hosts} = $datas->[0]->[0];

    return $metrics;
}

1;
