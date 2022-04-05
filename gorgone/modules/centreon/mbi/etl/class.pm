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

package gorgone::modules::centreon::mbi::etl::class;

use base qw(gorgone::class::module);

use strict;
use warnings;
use gorgone::standard::library;
use gorgone::standard::constants qw(:all);
use gorgone::class::sqlquery;
use gorgone::class::http::http;
use ZMQ::LibZMQ4;
use ZMQ::Constants qw(:all);
use XML::LibXML::Simple;
use JSON::XS;
use gorgone::modules::centreon::mbi::etl::import::pilot;
use gorgone::modules::centreon::mbi::libs::centreon::ETLProperties;
use gorgone::modules::centreon::mbi::libs::bi::Time;
use Try::Tiny;

my %handlers = (TERM => {}, HUP => {});
my ($connector);

sub new {
    my ($class, %options) = @_;
    $connector = $class->SUPER::new(%options);
    bless $connector, $class;

    $connector->{cbis_profile} = (defined($connector->{config}->{cbis_profile}) && $connector->{config}->{cbis_profile} ne '') ?
        $connector->{config}->{cbis_profile} : '/etc/centreon-bi/cbis-profile.xml';
    $connector->{reports_profile} = (defined($connector->{config}->{reports_profile}) && $connector->{config}->{reports_profile} ne '') ?
        $connector->{config}->{reports_profile} : '/etc/centreon-bi/reports-profile.xml';

    $connector->{run} = {
        running => 0,
        token => ''
    };

    $connector->set_signal_handlers();
    return $connector;
}

sub set_signal_handlers {
    my $self = shift;

    $SIG{TERM} = \&class_handle_TERM;
    $handlers{TERM}->{$self} = sub { $self->handle_TERM() };
    $SIG{HUP} = \&class_handle_HUP;
    $handlers{HUP}->{$self} = sub { $self->handle_HUP() };
}

sub handle_HUP {
    my $self = shift;
    $self->{reload} = 0;
}

sub handle_TERM {
    my $self = shift;
    $self->{logger}->writeLogDebug("[nodes] $$ Receiving order to stop...");
    $self->{stop} = 1;
}

sub class_handle_TERM {
    foreach (keys %{$handlers{TERM}}) {
        &{$handlers{TERM}->{$_}}();
    }
}

sub class_handle_HUP {
    foreach (keys %{$handlers{HUP}}) {
        &{$handlers{HUP}->{$_}}();
    }
}

sub runko {
    my ($self, %options) = @_;

    $self->send_log(
        code => GORGONE_ACTION_FINISH_KO,
        token => defined($options{token}) ? $options{token} : $self->{run}->{token},
        data => {
            message => $options{msg}
        }
    );
    $self->{run}->{running} = 0;
    return 1;
}

sub db_parse_xml {
    my ($self, %options) = @_;

    my ($rv, $message, $content) = gorgone::standard::misc::slurp(file => $options{file});
    return (0, $message) if (!$rv);
    eval {
        $SIG{__WARN__} = sub {};
        $content = XMLin($content, ForceArray => [], KeyAttr => []);
    };
    if ($@) {
        die 'cannot read xml file: ' . $@;
    }

    my $dbcon = {};
    if (!defined($content->{profile})) {
        die 'no profile';
    }
    foreach my $profile (@{$content->{profile}}) {
        my $name = lc($profile->{name});
        $dbcon->{$name} = { port => 3306 };
        foreach my $prop (@{$profile->{baseproperties}->{property}}) {
            if ($prop->{name} eq 'odaURL' && $prop->{value} =~ /jdbc\:[a-z]+\:\/\/([^:]*)(\:\d+)?\/(.*)/) {
                $dbcon->{$name}->{host} = $1;
                $dbcon->{$name}->{db} = $3;
                if (defined($2) && $2 ne '') {
                    $dbcon->{$name}->{port} = $2;
                    $dbcon->{$name}->{port} =~ s/\://;
                }
                $dbcon->{$name}->{db} =~ s/\?autoReconnect\=true//;
            } elsif ($prop->{name} eq 'odaUser') {
                $dbcon->{$name}->{user} = $prop->{value};
            } elsif ($prop->{name} eq 'odaPassword') {
                $dbcon->{$name}->{password} = $prop->{value};
            }
        }
    }
    foreach my $profile ('centreon', 'censtorage') {
        die 'cannot find profile ' . $profile if (!defined($dbcon->{$profile}));
        foreach ('host', 'db', 'port', 'user', 'password') {
            die "property $_ for profile $profile must be defined"
                if (!defined($dbcon->{$profile}->{$_}) || $dbcon->{$profile}->{$_} eq '');
        }
    }

    return $dbcon;
}

sub planning {
    my ($self, %options) = @_;

    if ($self->{run}->{options}->{import} == 1) {
        $self->{run}->{schedule}->{import}->{running} = 0;
        $self->{run}->{schedule}->{steps}++;
    }
    if ($self->{run}->{options}->{dimensions} == 1) {
        $self->{run}->{schedule}->{dimensions}->{running} = 0;
        $self->{run}->{schedule}->{steps}++;
    }
    if ($self->{run}->{options}->{event} == 1) {
        $self->{run}->{schedule}->{event}->{running} = 0;
        $self->{run}->{schedule}->{steps}++;
    }
    if ($self->{run}->{options}->{perfdata} == 1) {
        $self->{run}->{schedule}->{perfdata}->{running} = 0;
        $self->{run}->{schedule}->{steps}++;
    }

    $self->{run}->{schedule}->{planned} = 1;
}

sub run_etl_import {
    my ($self, %options) = @_;

    if ((defined($self->{run}->{etlProperties}->{'host.dedicated'}) && $self->{run}->{etlProperties}->{'host.dedicated'} eq 'false')
        || ($self->{run}->{dbbi}->{censtorage}->{host} . ':' . $self->{run}->{dbbi}->{censtorage}->{port} eq $self->{run}->{dbmon}->{censtorage}->{host} . ':' . $self->{run}->{dbmon}->{censtorage}->{port})
        || ($self->{run}->{dbbi}->{centreon}->{host} . ':' . $self->{run}->{dbbi}->{centreon}->{port} eq $self->{run}->{dbmon}->{centreon}->{host} . ':' . $self->{run}->{dbmon}->{centreon}->{port})) {
        die 'Do not execute this script if the reporting engine is installed on the monitoring server. In case of "all in one" installation, do not consider this message';
    }

    gorgone::modules::centreon::mbi::etl::import::pilot::main($self);
}

sub run_etl {
    my ($self, %options) = @_;

    if ($self->{run}->{schedule}->{import}->{running} == 0) {
        $self->run_etl_import();
        return ;
    } elsif ($self->{run}->{schedule}->{import}->{dimensions} == 0) {
        $self->run_etl_dimensions();
        return ;
    }
    if ($self->{run}->{schedule}->{event}->{running} == 0) {
        $self->run_etl_event();
    }
    if ($self->{run}->{schedule}->{perfdata}->{running} == 0) {
        $self->run_etl_perfdata();
    }
}

sub check_basic_options {
    my ($self, %options) = @_;

    if (($options{daily} == 0 && $options{rebuild} == 0 && $options{create_tables} == 0 && !defined($options{centile}))
        || ($options{daily} == 1 && $options{rebuild} == 1)) {
        die "Specify one execution method";
    }
    if (($options{rebuild} == 1 || $options{create_tables} == 1) 
        && (($options{start} ne '' && $options{end} eq '') 
        || ($options{start} eq '' && $options{end} ne ''))) {
        die "Specify both options start and end or neither of them to use default data retention options";
    }
    if ($options{rebuild} == 1 && $options{start} ne '' && $options{end} ne ''
        && ($options{start} !~ /[1-2][0-9]{3}\-[0-1][0-9]\-[0-3][0-9]/ || $options{end} !~ /[1-2][0-9]{3}\-[0-1][0-9]\-[0-3][0-9]/)) {
        die "Verify period start or end date format";
    }
}

sub action_centreonmbietlrun {
    my ($self, %options) = @_;

    try {
        $options{token} = $self->generate_token() if (!defined($options{token}));

        return $self->runko(token => $options{token}, msg => 'etl currently running') if ($self->{run}->{running} == 1);

        $self->{run}->{token} = $options{token};

        $self->check_basic_options(%{$options{data}->{content}});

        $self->{run}->{schedule} = {
            steps_done => 0,
            steps => 0,
            planned => 0,
            import => { running => -1, count => 0, actions => [], tokens => {} },
            dimensions => { running => -1, token => '' },
            event => { running => -1, actions => [] },
            perfdata => { running => -1, actions => [] }
        };
        $self->{run}->{running} = 1;
    
        $self->{run}->{options} = $options{data}->{content};

        $self->send_log(code => GORGONE_ACTION_BEGIN, token => $options{token}, data => { message => 'action etl run started' });

        $self->{run}->{dbmon} = $self->db_parse_xml(file => $self->{cbis_profile}); 
        $self->{run}->{dbbi} = $self->db_parse_xml(file => $self->{reports_profile}); 

        $self->{run}->{dbmon_centreon_con} = gorgone::class::db->new(
            type => 'mysql',
            force => 2,
            logger => $self->{logger},
            tryTiny => 1,
            %{$self->{run}->{dbmon}->{centreon}}
        );
        $self->{etlProp} = gorgone::modules::centreon::mbi::libs::centreon::ETLProperties->new($self->{logger}, $self->{run}->{dbmon_centreon_con});
        ($self->{run}->{etlProperties}, $self->{run}->{dataRetention}) = $self->{etlProp}->getProperties();
    
        $self->{run}->{dbbi_centstorage_con} = gorgone::class::db->new(
            type => 'mysql',
            force => 2,
            logger => $self->{logger},
            tryTiny => 1,
            %{$self->{run}->{dbbi}->{censtorage}}
        );
        $self->{run}->{time} = gorgone::modules::centreon::mbi::libs::bi::Time->new($self->{logger}, $self->{run}->{dbbi_centstorage_con});

        $self->planning();
        $self->run_etl();
    } catch {
        $self->runko(msg => $_)
    };

    use Data::Dumper;
    print Data::Dumper::Dumper($self->{run});

    return 0;
}

sub event {
    while (1) {
        my $message = $connector->read_message();
        last if (!defined($message));

        $connector->{logger}->writeLogDebug("[mbi-etl] Event: $message");
        if ($message =~ /^\[(.*?)\]/) {
            if ((my $method = $connector->can('action_' . lc($1)))) {
                $message =~ /^\[(.*?)\]\s+\[(.*?)\]\s+\[.*?\]\s+(.*)$/m;
                my ($action, $token) = ($1, $2);
                my ($rv, $data) = $connector->json_decode(argument => $3, token => $token);
                next if ($rv);

                $method->($connector, token => $token, data => $data);
            }
        }
    }
}

sub run {
    my ($self, %options) = @_;

    # Connect internal
    $connector->{internal_socket} = gorgone::standard::library::connect_com(
        zmq_type => 'ZMQ_DEALER',
        name => 'gorgone-' . $self->{module_id},
        logger => $self->{logger},
        type => $self->get_core_config(name => 'internal_com_type'),
        path => $self->get_core_config(name => 'internal_com_path')
    );
    $connector->send_internal_action(
        action => 'CENTREONMBIETLREADY',
        data => {}
    );
    $self->{poll} = [
        {
            socket  => $connector->{internal_socket},
            events  => ZMQ_POLLIN,
            callback => \&event
        }
    ];

    while (1) {
        my $rev = scalar(zmq_poll($self->{poll}, 5000));
        if (defined($rev) && $rev == 0 && $self->{stop} == 1) {
            $self->{logger}->writeLogInfo("[" . $self->{module_id} . "] $$ has quit");
            zmq_close($connector->{internal_socket});
            exit(0);
        }
    }
}

1;
