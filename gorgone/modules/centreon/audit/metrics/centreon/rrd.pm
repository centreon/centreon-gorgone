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

package gorgone::modules::centreon::audit::metrics::centreon::rrd;

use warnings;
use strict;

sub metrics {
    my (%options) = @_;

    return undef if (!defined($options{params}->{rrd_metrics_path}));
    return undef if (! -d $options{params}->{rrd_metrics_path});

    my $metrics = {
        status_code => 0,
        status_message => 'ok',
        rrd_metrics_count => 0,
        rrd_status_count => 0,
        rrd_metrics_bytes => 0,
        rrd_status_bytes => 0
    };

    my $dh;
    foreach my $type (('metrics', 'status')) {
        if (!opendir($dh, $options{params}->{'rrd_' . $type . '_path'})) {
            $metrics->{status_code} = 1;
            $metrics->{status_message} = "Could not open directoy for reading: $!";
            next;
        }
        while (my $file = readdir($dh)) {
            next if ($file !~ /\.rrd/);
            $metrics->{'rrd_' . $type . '_count'}++;
            my $size = -s $options{params}->{'rrd_' . $type . '_path'} . '/' . $file;
            $metrics->{'rrd_' . $type . '_count'} += $size if ($size);
        }
        closedir($dh);
    }

    return $metrics;
}

1;
