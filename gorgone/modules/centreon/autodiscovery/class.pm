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

package gorgone::modules::centreon::autodiscovery::class;

use base qw(gorgone::class::module);

use strict;
use warnings;
use gorgone::standard::library;
use gorgone::standard::constants qw(:all);
use gorgone::modules::centreon::autodiscovery::services::discovery;
use gorgone::class::sqlquery;
use ZMQ::LibZMQ4;
use ZMQ::Constants qw(:all);
use JSON::XS;
use Time::HiRes;
use POSIX qw(strftime);
use Digest::MD5 qw(md5_hex);

use constant JOB_SCHEDULED => 0;
use constant JOB_FINISH => 1;
use constant JOB_FAILED => 2;
use constant JOB_RUNNING => 3;
use constant SAVE_RUNNING => 4;
use constant SAVE_FINISH => 5;
use constant SAVE_FAILED => 6;

use constant MAX_INSERT_BY_QUERY => 100;

my %handlers = (TERM => {}, HUP => {});
my ($connector);

sub new {
    my ($class, %options) = @_;

    $connector  = {};
    $connector->{internal_socket} = undef;
    $connector->{module_id} = $options{module_id};
    $connector->{logger} = $options{logger};
    $connector->{config} = $options{config};
    $connector->{config_core} = $options{config_core};
    $connector->{config_db_centreon} = $options{config_db_centreon};
    $connector->{config_db_centstorage} = $options{config_db_centstorage};
    $connector->{stop} = 0;

    $connector->{global_timeout} = (defined($options{config}->{global_timeout}) &&
        $options{config}->{global_timeout} =~ /(\d+)/) ? $1 : 300;
    $connector->{check_interval} = (defined($options{config}->{check_interval}) &&
        $options{config}->{check_interval} =~ /(\d+)/) ? $1 : 15;

    $connector->{service_discoveries} = {};

    bless $connector, $class;
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
    $self->{logger}->writeLogInfo("[autodiscovery] $$ Receiving order to stop...");
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

=pod

*******************
Host Discovery part
*******************

=cut

sub action_addhostdiscoveryjob {
    my ($self, %options) = @_;
    
    return if (!$self->is_module_installed());

    $options{token} = $self->generate_token() if (!defined($options{token}));
    my $discovery_token = 'discovery_' . $options{data}->{content}->{job_id} . '_' . $self->generate_token(length => 4);
    
    my $uuid_attributes = $options{data}->{content}->{uuid_attributes};

    if (!defined($uuid_attributes)) {
        # Retrieve uuid attributes // to be replaced by parameters in API call
        my $query = "SELECT uuid_attributes " .
            "FROM mod_host_disco_provider mhdp " .
            "JOIN mod_host_disco_job mhdj " .
            "WHERE mhdj.provider_id = mhdp.id AND mhdj.id = " .
            $self->{class_object_centreon}->quote(value => $options{data}->{content}->{job_id});
        my ($status, $result) = $self->{class_object_centreon}->custom_execute(request => $query, mode => 2);
        if ($status == -1 || !defined($result->[0]->[0]) || $result->[0]->[0] eq '') {
            $self->{logger}->writeLogError('[autodiscovery] Failed to retrieve UUID attributes');
            return 1;
        }
        
        $uuid_attributes = JSON::XS->new->utf8->decode($result->[0]->[0]);

        if ($@) {
            $self->update_job_information(                
                values => {
                    status => JOB_FAILED,
                    message => "Failed to decode UUID attributes",
                    duration => 0,
                    discovered_items => 0
                },
                where_clause => [
                    {
                        id => $options{data}->{content}->{job_id}
                    }
                ]
            );
            return 1;
        }
    }

    my $timeout = (defined($options{data}->{content}->{timeout}) && $options{data}->{content}->{timeout} =~ /(\d+)/) ?
        $options{data}->{content}->{timeout} : $self->{global_timeout};

    if ($options{data}->{content}->{execution}->{mode} == 0) {
        # Execute immediately
        $self->action_launchhostdiscovery(
            data => {
                content => {
                    target => $options{data}->{content}->{target},
                    command_line => $options{data}->{content}->{command_line},
                    timeout => $timeout,
                    job_id => $options{data}->{content}->{job_id},
                    uuid_attributes => $uuid_attributes,
                    token => $discovery_token
                }
            }
        );
    } elsif ($options{data}->{content}->{execution}->{mode} == 1) {
        # Schedule with cron
        if (!defined($options{data}->{content}->{execution}->{parameters}->{cron_definition}) ||
            $options{data}->{content}->{execution}->{parameters}->{cron_definition} eq '') {
            $self->{logger}->writeLogError("[autodiscovery] Missing 'cron_definition' parameter");

            $self->update_job_information(
                
                values => {
                    status => JOB_FAILED,
                    message => "Missing 'cron_definition' parameter",
                    duration => 0,
                    discovered_items => 0
                },
                where_clause => [
                    {
                        id => $options{data}->{content}->{job_id}
                    }
                ]
            );

            return 1;
        }

        # TODO: check if already scheduled

        $self->{logger}->writeLogInfo("[autodiscovery] Add cron for job '" . $options{data}->{content}->{job_id} . "'");
        my $definition = {
            id => $discovery_token,
            target => '1',
            timespec => $options{data}->{content}->{execution}->{parameters}->{cron_definition},
            action => 'LAUNCHHOSTDISCOVERY',
            parameters =>  {
                target => $options{data}->{content}->{target},
                command_line => $options{data}->{content}->{command_line},
                timeout => $timeout,
                job_id => $options{data}->{content}->{job_id},
                uuid_attributes => $uuid_attributes,
                token => $discovery_token
            },
            keep_token => 1,
        };
        
        $self->send_internal_action(
            action => 'ADDCRON',
            token => $options{token},
            data => {
                content => [ $definition ],
            }
        );
        
        # TODO: check if addcron ok
    }
    
    # Store discovery token // to be replaced by backend at some point
    return 1 if ($self->update_job_information(
        values => {
            token => $discovery_token
        },
        where_clause => [
            {
                id => $options{data}->{content}->{job_id}
            }
        ]
    ) == -1);

    $self->send_log(
        code => GORGONE_ACTION_FINISH_OK,
        token => $options{token},
        data => {
            message => 'job ' . $options{data}->{content}->{job_id} . ' added',
            discovery_token => $discovery_token
        }
    );
    
    return 0;
}

sub action_deletehostdiscoveryjob {
    my ($self, %options) = @_;
    
    return if (!$self->is_module_installed());
    
    $options{token} = $self->generate_token() if (!defined($options{token}));

    my $discovery_token = $options{data}->{variables}[0];
    if (!defined($discovery_token) || $discovery_token eq '') {
        $self->{logger}->writeLogError("[autodiscovery] Missing ':token' variable to delete discovery");
        $self->send_log(
            code => GORGONE_ACTION_FINISH_KO,
            token => $options{token},
            data => { message => 'missing discovery token' }
        );
        return 1;
    }
    
    $self->send_internal_action(
        action => 'DELETECRON',
        token => $options{token},
        data => {   
            variables => [ $discovery_token ]
        }

        # TODO: check if deletecron ok
    );
    
    $self->send_log(
        code => GORGONE_ACTION_FINISH_OK,
        token => $options{token},
        data => { message => 'job ' . $discovery_token . ' deleted' }
    );
    
    return 0;
}

sub action_launchhostdiscovery {
    my ($self, %options) = @_;
    
    return if (!$self->is_module_installed());

    my $exists = $self->job_exists(job_id => $options{data}->{content}->{job_id});
    if ($exists == 0) {
        $self->{logger}->writeLogError("[autodiscovery] Trying to launch discovery for inexistant job '" . $options{data}->{content}->{job_id} . "'");
        return 0;
    } elsif ($exists == -1) {
        return 1;
    }

    my $running = $self->is_job_running(job_id => $options{data}->{content}->{job_id});
    if ($running > 0) {
        $self->{logger}->writeLogInfo("[autodiscovery] Job '" . $options{data}->{content}->{job_id} . "' is already running or result is being saved");
        return 0;
    } elsif ($running == -1) {
        return 1;
    }

    $self->{logger}->writeLogInfo("[autodiscovery] Launching discovery for job '" . $options{data}->{content}->{job_id} . "'");

    $self->send_internal_action(
        action => 'ADDLISTENER',
        data => [
            {
                identity => 'gorgoneautodiscovery',
                event => 'HOSTDISCOVERYLISTENER',
                target => $options{data}->{content}->{target},
                token => $options{data}->{content}->{token},
                timeout => defined($options{data}->{content}->{timeout}) && $options{data}->{content}->{timeout} =~ /(\d+)/ ? 
                    $1 + $self->{check_interval} + 15 : undef,
                log_pace => $self->{check_interval}
            }
        ]
    );

    $self->send_internal_action(
        action => 'COMMAND',
        target => $options{data}->{content}->{target},
        token => $options{data}->{content}->{token},
        data => {
            content => [
                {
                    instant => 1,
                    command => $options{data}->{content}->{command_line},
                    timeout => $options{data}->{content}->{timeout},
                    metadata => {
                        job_id => $options{data}->{content}->{job_id},
                        uuid_attributes => $options{data}->{content}->{uuid_attributes},
                        source => 'autodiscovery'
                    }
                }
            ]
        }
    );

    # Running
    return 1 if ($self->update_job_information(
        values => {
            status => JOB_RUNNING,
            message => "Running",
            duration => 0,
            discovered_items => 0
        },
        where_clause => [
            {
                id => $options{data}->{content}->{job_id}
            }
        ]
    ) == -1);

    return 0;
}

sub discovery_command_result {
    my ($self, %options) = @_;

    return 1 if (!defined($options{data}->{data}->{metadata}->{job_id}));

    my $exists = $self->job_exists(job_id => $options{data}->{data}->{metadata}->{job_id});
    if ($exists == 0) {
        $self->{logger}->writeLogError("[autodiscovery] Found result for inexistant job '" . $options{data}->{data}->{metadata}->{job_id} . "'");
        return 0;
    } elsif ($exists == -1) {
        return 1;
    }

    $self->{logger}->writeLogInfo("[autodiscovery] Found result for job '" . $options{data}->{data}->{metadata}->{job_id} . "'");
    my $uuid_attributes = $options{data}->{data}->{metadata}->{uuid_attributes};
    my $job_id = $options{data}->{data}->{metadata}->{job_id};
    my $exit_code = $options{data}->{data}->{result}->{exit_code};
    my $output = (defined($options{data}->{data}->{result}->{stderr}) && $options{data}->{data}->{result}->{stderr} ne '') ?
        $options{data}->{data}->{result}->{stderr} : $options{data}->{data}->{result}->{stdout};

    if ($exit_code != 0) {
        # Error
        $self->update_job_information(
            values => {
                status => JOB_FAILED,
                message => $output,
                duration => 0,
                discovered_items => 0
            },
            where_clause => [
                {
                    id => $job_id
                }
            ]
        );
        return 1;
    }

    my $result;
    eval {
        $result = JSON::XS->new->utf8->decode($output);
    };

    if ($@) {
        # Failed
        $self->update_job_information(
            
            values => {
                status => JOB_FAILED,
                message => "Failed to decode discovery plugin response",
                duration => 0,
                discovered_items => 0
            },
            where_clause => [
                {
                    id => $job_id
                }
            ]
        );
        return 1;
    }

    # Finished
    return 1 if ($self->update_job_information(
        values => {
            status => JOB_FINISH,
            message => "Finished",
            duration => $result->{duration},
            discovered_items => $result->{discovered_items}
        },
        where_clause => [
            {
                id => $job_id
            }
        ]
    ) == -1);

    # Delete previous results
    my $query = "DELETE FROM mod_host_disco_host WHERE job_id = " . $self->{class_object_centreon}->quote(value => $job_id);
    my $status = $self->{class_object_centreon}->transaction_query(request => $query);
    if ($status == -1) {
        $self->{logger}->writeLogError('[autodiscovery] Failed to delete previous job results');
        return 1;
    }

    # Add new results
    my $number_of_lines = 0;
    my $values = '';
    my $append = '';
    $query = "INSERT INTO mod_host_disco_host (job_id, discovery_result, uuid) VALUES ";
    foreach my $host (@{$result->{results}}) {
        if ($number_of_lines == MAX_INSERT_BY_QUERY) {
            $status = $self->{class_object_centreon}->transaction_query(request => $query . $values);
            if ($status == -1) {
                $self->{logger}->writeLogError('[autodiscovery] Failed to insert job results');
                return 1;
            }
            $number_of_lines = 0;
            $values = '';
            $append = '';
        }

        # Generate uuid based on attributs
        my $uuid_char = '';
        foreach (@{$uuid_attributes}) {
            $uuid_char .= $host->{$_} if (defined($host->{$_}) && $host->{$_} ne '');
        }
        my $ctx = Digest::MD5->new;
        $ctx->add($uuid_char);
        my $digest = $ctx->hexdigest;
        my $uuid = substr($digest, 0, 8) . '-' . substr($digest, 8, 4) . '-' . substr($digest, 12, 4) . '-' .
            substr($digest, 16, 4) . '-' . substr($digest, 20, 12);
        my $encoded_host = JSON::XS->new->utf8->encode($host);

        # Build bulk insert
        $values .= $append . "(" . $self->{class_object_centreon}->quote(value => $job_id) . ", " . 
            $self->{class_object_centreon}->quote(value => $encoded_host) . ", " . 
            $self->{class_object_centreon}->quote(value => $uuid) . ")";
        $append = ', ';
        $number_of_lines++;
    }

    if ($values ne '') {
        $status = $self->{class_object_centreon}->transaction_query(request => $query . $values);
        if ($status == -1) {
            $self->{logger}->writeLogError('[autodiscovery] Failed to insert job results');
            return 1;
        }
    }

    return 0;
}

sub update_job_information {
    my ($self, %options) = @_;

    return 1 if (!defined($options{where_clause}) || ref($options{where_clause}) ne 'ARRAY' || scalar($options{where_clause}) < 1);
    return 1 if (!defined($options{values}) || ref($options{values}) ne 'HASH' || !keys %{$options{values}});
    
    my $query = "UPDATE mod_host_disco_job SET ";
    my $append = '';
    foreach (keys %{$options{values}}) {
        $query .= $append . $_ . " = " .  $self->{class_object_centreon}->quote(value => $options{values}->{$_});
        $append = ', ';
    }

    $query .= " WHERE ";
    $append = '';
    foreach (@{$options{where_clause}}) {
        my ($key, $value) = each %{$_};
        $query .= $append . $key . " = " . $self->{class_object_centreon}->quote(value => $value);
        $append = 'AND ';
    }

    my $status = $self->{class_object_centreon}->transaction_query(request => $query);
    if ($status == -1) {
        $self->{logger}->writeLogError('[autodiscovery] Failed to update job information');
        return -1;
    }

    return 0;
}

sub job_exists {
    my ($self, %options) = @_;

    my ($status, $data) = $self->{class_object_centreon}->custom_execute(
        request => "SELECT id, status FROM mod_host_disco_job WHERE id = " . 
            $self->{class_object_centreon}->quote(value => $options{job_id}),
        mode => 2
    );
    if ($status == -1) {
        $self->{logger}->writeLogError('[autodiscovery] Failed to determine if job exists');
        return -1;
    }

    (defined($data->[0]) && scalar($data->[0]) > 0) ? return 1 : return 0;
}

sub is_job_running {
    my ($self, %options) = @_;

    my ($status, $data) = $self->{class_object_centreon}->custom_execute(
        request => "SELECT id, status FROM mod_host_disco_job WHERE id = " . 
            $self->{class_object_centreon}->quote(value => $options{job_id}) . 
            " AND status IN (" .
            $self->{class_object_centreon}->quote(value => JOB_RUNNING) .
            "," .
            $self->{class_object_centreon}->quote(value => SAVE_RUNNING) .
            ")",
        mode => 2
    );
    if ($status == -1) {
        $self->{logger}->writeLogError('[autodiscovery] Failed to determine if job is running');
        return -1;
    }

    (defined($data->[0]) && scalar($data->[0]) > 0) ? return 1 : return 0;
}

sub action_hostdiscoverylistener {
    my ($self, %options) = @_;

    return if (!$self->is_module_installed());
    return 0 if (!defined($options{token}));

    if ($options{data}->{code} == GORGONE_MODULE_ACTION_COMMAND_RESULT) {
        $self->discovery_command_result(%options);
        return 1;
    }
    if ($options{data}->{code} == GORGONE_ACTION_FINISH_KO) {        
        $self->update_job_information(
            values => {
                status => JOB_FAILED,
                message => $options{data}->{message},
                duration => 0,
                discovered_items => 0
            },
            where_clause => [
                {
                    token => $options{token}
                }
            ]
        );
        return 1;
    }

    return 1;
}

sub register_listener {
    my ($self, %options) = @_;
    
    return if (!$self->is_module_installed());
    
    # List running jobs
    my ($status, $data) = $self->{class_object_centreon}->custom_execute(
        request => "SELECT id, monitoring_server_id, token FROM mod_host_disco_job WHERE status = '3'",
        mode => 1,
        keys => 'id'
    );

    # Sync logs and try to retrieve results for each jobs
    foreach my $job_id (keys %$data) {
        $self->{logger}->writeLogDebug("[autodiscovery] Register listener for '" . $job_id . "'");

        $self->send_internal_action(
            action => 'ADDLISTENER',
            data => [
                {
                    identity => 'gorgoneautodiscovery',
                    event => 'HOSTDISCOVERYLISTENER',
                    target => $data->{$job_id}->{monitoring_server_id},
                    token => $data->{$job_id}->{token},
                    log_pace => $self->{check_interval}
                }
            ]
        );
    }
    
    return 0;
}

=pod

**********************
Service Discovery part
**********************

=cut

sub action_servicediscoverylistener {
    my ($self, %options) = @_;

    return 0 if (!defined($options{token}));

    # 'svc-disco-UUID-RULEID-HOSTID' . $self->{service_uuid} . '-' . $service_number . '-' . $rule_id . '-' . $host->{host_id}
    return 0 if ($options{token} !~ /^svc-disco-(.*?)-(\d+)-(\d+)/);

    my ($uuid, $rule_id, $host_id) = ($1, $2, $3);
    return 0 if (!defined($self->{service_discoveries}->{ $uuid }));

    $self->{service_discoveries}->{ $uuid }->discoverylistener(
        rule_id => $rule_id,
        host_id => $host_id,
        %options
    );

    if ($self->{service_discoveries}->{ $uuid }->is_finished()) {
        delete $self->{service_discoveries}->{ $uuid };
    }
}

sub action_launchservicediscovery {
    my ($self, %options) = @_;

    $options{token} = $self->generate_token() if (!defined($options{token}));

    $self->{service_number}++;
    my $svc_discovery = gorgone::modules::centreon::autodiscovery::services::discovery->new(
        module_id => $self->{module_id},
        logger => $self->{logger},
        internal_socket => $self->{internal_socket},
        config => $self->{config},
        config_core => $self->{config_core},
        service_number => $self->{service_number},
        class_object_centreon => $self->{class_object_centreon},
        class_object_centstorage => $self->{class_object_centstorage}
    );
    my $status = $svc_discovery->launchdiscovery(
        token => $options{token},
        data => $options{data}
    );
    if ($status == -1) {
        $self->send_log(
            code => GORGONE_ACTION_FINISH_KO,
            token => $options{token},
            data => { message => 'cannot launch discovery' }
        );
    } elsif ($status == 0) {
        $self->{service_discoveries}->{ $svc_discovery->get_uuid() } = $svc_discovery;
    }
}

sub is_module_installed {
    my ($self) = @_;

    my ($status, $data) = $self->{class_object_centreon}->custom_execute(
        request => "SELECT id FROM modules_informations WHERE name = 'centreon-autodiscovery-server'",
        mode => 2
    );

    (defined($data->[0]) && scalar($data->[0]) > 0) ? return 1 : return 0;
}

sub event {
    while (1) {
        my $message = gorgone::standard::library::zmq_dealer_read_message(socket => $connector->{internal_socket});
        
        $connector->{logger}->writeLogDebug("[autodiscovery] Event: $message");
        if ($message =~ /^\[(.*?)\]/) {
            if ((my $method = $connector->can('action_' . lc($1)))) {
                $message =~ /^\[(.*?)\]\s+\[(.*?)\]\s+\[.*?\]\s+(.*)$/m;
                my ($action, $token) = ($1, $2);
                my $data = JSON::XS->new->utf8->decode($3);
                $method->($connector, token => $token, data => $data);
            }
        }

        last unless (gorgone::standard::library::zmq_still_read(socket => $connector->{internal_socket}));
    }
}

sub run {
    my ($self, %options) = @_;
    
    $self->{db_centreon} = gorgone::class::db->new(
        dsn => $self->{config_db_centreon}->{dsn},
        user => $self->{config_db_centreon}->{username},
        password => $self->{config_db_centreon}->{password},
        force => 2,
        logger => $self->{logger}
    );
    $self->{db_centstorage} = gorgone::class::db->new(
        dsn => $self->{config_db_centstorage}->{dsn},
        user => $self->{config_db_centstorage}->{username},
        password => $self->{config_db_centstorage}->{password},
        force => 2,
        logger => $self->{logger}
    );
    
    $self->{class_object_centreon} = gorgone::class::sqlquery->new(
        logger => $self->{logger},
        db_centreon => $self->{db_centreon}
    );
    $self->{class_object_centstorage} = gorgone::class::sqlquery->new(
        logger => $self->{logger},
        db_centreon => $self->{db_centstorage}
    );

    # Connect internal
    $connector->{internal_socket} = gorgone::standard::library::connect_com(
        zmq_type => 'ZMQ_DEALER',
        name => 'gorgoneautodiscovery',
        logger => $self->{logger},
        type => $self->{config_core}->{internal_com_type},
        path => $self->{config_core}->{internal_com_path}
    );
    $connector->send_internal_action(
        action => 'AUTODISCOVERYREADY',
        data => {}
    );
    $self->{poll} = [
        {
            socket  => $connector->{internal_socket},
            events  => ZMQ_POLLIN,
            callback => \&event,
        }
    ];

    $self->register_listener();

    while (1) {
        # we try to do all we can
        my $rev = zmq_poll($self->{poll}, 5000);
        if (defined($rev) && $rev == 0 && $self->{stop} == 1) {
            $self->{logger}->writeLogInfo("[autodiscovery] $$ has quit");
            zmq_close($connector->{internal_socket});
            exit(0);
        }
    }
}

1;
