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

package gorgone::modules::centreon::statistics::rrds;

use strict;
use warnings;
use RRDs;

sub rrd_create {
    my (%options) = @_;

    my @ds;
    foreach my $ds (@{$options{ds}}) {
        push @ds, "DS:" . $ds . ":GAUGE:" . $options{interval} . ":0:U";
    }
    
    RRDs::create(
        $options{file},
        "-s" . $options{interval},
        @ds,
        "RRA:AVERAGE:0.5:1:" . $options{number},
        "RRA:AVERAGE:0.5:12:" . $options{number}
    );
    if (RRDs::error()) {
        my $error = RRDs::error();
        print Dumper $error;
        # $self->{logger}->writeLogError($error);
    }
    
    foreach my $ds (@{$options{ds}}) {
        RRDs::tune($options{file}, "-h",  $ds . ":" . $options{heartbeat});
    }
}

sub rrd_update {
    my (%options) = @_;

    my $append = '';
    my $ds;
    foreach (@{$options{ds}}) {
        $ds .= $append . $_;
        $append = ':';
    }
    my $values;
    foreach (@{$options{values}}) {
        $values .= $append . $_;
    }
    RRDs::update(
        $options{file},
        "--template",
        $ds,
        "N" . $values
    );
}

1;
