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

package gorgone::class::module;

use strict;
use warnings;

use gorgone::standard::constants qw(:all);
use gorgone::standard::library;
use gorgone::standard::misc;
use gorgone::class::tpapi;
use JSON::XS;
use Crypt::Mode::CBC;
use ZMQ::LibZMQ4;
use ZMQ::Constants qw(:all);

my %handlers = (DIE => {});

sub new {
    my ($class, %options) = @_;
    my $self  = {};
    bless $self, $class;

    $self->{internal_socket} = undef;
    $self->{module_id} = $options{module_id};
    $self->{core_id} = $options{core_id};
    $self->{logger} = $options{logger};
    $self->{config} = $options{config};
    $self->{exit_timeout} = (defined($options{config}->{exit_timeout}) && $options{config}->{exit_timeout} =~ /(\d+)/) ? $1 : 30;
    $self->{config_core} = $options{config_core}->{gorgonecore};
    $self->{config_db_centreon} = $options{config_db_centreon};
    $self->{config_db_centstorage} = $options{config_db_centstorage};
    $self->{stop} = 0;

    $self->{internal_crypt} = { enabled => 0 };
    if ($self->{config_core}->{internal_com_crypt} == 1) {
        $self->{cipher} = Crypt::Mode::CBC->new($self->{config_core}->{internal_com_cipher}, $self->{config_core}->{internal_com_padding});

        $self->{internal_crypt} = {
            enabled => 1,
            rotation => $self->{config_core}->{internal_com_rotation},
            cipher => $self->{config_core}->{internal_com_cipher},
            padding => $self->{config_core}->{internal_com_padding},
            iv => $self->{config_core}->{internal_com_iv},
            core_key => $self->{config_core}->{internal_com_core_key},
            identity_keys => $self->{config_core}->{internal_com_identity_keys}
        };
    }

    $self->{tpapi} = gorgone::class::tpapi->new();
    $self->{tpapi}->load_configuration(configuration => $options{config_core}->{tpapi});

    $SIG{__DIE__} = \&class_handle_DIE;
    $handlers{DIE}->{$self} = sub { $self->handle_DIE($_[0]) };

    return $self;
}

sub class_handle_DIE {
    my ($msg) = @_;

    foreach (keys %{$handlers{DIE}}) {
        &{$handlers{DIE}->{$_}}($msg);
    }
}

sub handle_DIE {
    my ($self, $msg) = @_;

    $self->{logger}->writeLogError("[$self->{module_id}] Receiving DIE: $msg");
}

sub generate_token {
   my ($self, %options) = @_;
   
   return gorgone::standard::library::generate_token(length => $options{length});
}

sub read_message {
    my ($self, %options) = @_;

    my $message = gorgone::standard::library::zmq_dealer_read_message(socket => defined($options{socket}) ? $options{socket} : $self->{internal_socket});
    return undef if (!defined($message));
    return $options{message} if ($self->{internal_crypt}->{enabled} == 0);

    my $plaintext;
    eval {
        $plaintext = $self->{cipher}->decrypt($message, $self->{internal_crypt}->{core_key}, $self->{internal_crypt}->{iv});
    };
    if ($@) {
        $self->{logger}->writeLogError("[$self->{module_id}] decrypt issue: " .  $@);
        return undef;
    }

    return $plaintext;
}

sub send_internal_key {
    my ($self, %options) = @_;

    my $message = gorgone::standard::library::build_protocol(
        action => 'SETMODULEKEY',
        data => { key => unpack('H*', $options{key}) },
        json_encode => 1
    );
    eval {
        $message = $self->{cipher}->encrypt($message, $options{encrypt_key}, $self->{internal_crypt}->{iv});
    };
    if ($@) {
        $self->{logger}->writeLogError("[$self->{module_id}] encrypt issue: " .  $@);
        return -1;
    }

    zmq_sendmsg($options{socket}, $message, ZMQ_DONTWAIT);
    return 0;
}

sub send_internal_action {
    my ($self, %options) = @_;

    my $message = $options{message};
    if (!defined($message)) {
        $message = gorgone::standard::library::build_protocol(
            token => $options{token},
            action => $options{action},
            target => $options{target},
            data => $options{data},
            json_encode => defined($options{data_noencode}) ? undef : 1
        );
    }

    my $socket = defined($options{socket}) ? $options{socket} : $self->{internal_socket};
    if ($self->{internal_crypt}->{enabled} == 1) {
        my $identity = gorgone::standard::library::zmq_get_routing_id(socket => $socket);

        if (!defined($self->{internal_crypt}->{identity_keys}->{$identity})) {
            my ($rv, $key) = gorgone::standard::library::generate_symkey(keysize => $self->{config_core}->{internal_com_keysize});
            ($rv) = $self->send_internal_key(socket => $socket, key => $key, encrypt_key => $self->{internal_crypt}->{core_key});
            return undef if ($rv == -1);
            $self->{internal_crypt}->{identity_keys}->{$identity} = $key;
        }

        eval {
            $message = $self->{cipher}->encrypt($message, $self->{internal_crypt}->{identity_keys}->{$identity}, $self->{internal_crypt}->{iv});
        };
        if ($@) {
            $self->{logger}->writeLogError("[$self->{module_id}] encrypt issue: " .  $@);
            return undef;
        }
    }

    zmq_sendmsg($socket, $message, ZMQ_DONTWAIT);
}

sub send_log_msg_error {
    my ($self, %options) = @_;

    return if (!defined($options{token}));

    $self->{logger}->writeLogError("[$self->{module_id}] -$options{subname}- $options{number} $options{message}");
    $self->send_internal_action(
        socket => (defined($options{socket})) ? $options{socket} : $self->{internal_socket},
        action => 'PUTLOG',
        token => $options{token},
        data => { code => GORGONE_ACTION_FINISH_KO, etime => time(), instant => $options{instant}, token => $options{token}, data => { message => $options{message} } },
        json_encode => 1
    );
}

sub send_log {
    my ($self, %options) = @_;

    return if (!defined($options{token}));

    return if (defined($options{logging}) && $options{logging} =~ /^(?:false|0)$/);

    $self->send_internal_action(
        socket => (defined($options{socket})) ? $options{socket} : $self->{internal_socket},
        action => 'PUTLOG',
        token => $options{token},
        data => { code => $options{code}, etime => time(), instant => $options{instant}, token => $options{token}, data => $options{data} },
        json_encode => 1
    );
}

sub json_encode {
    my ($self, %options) = @_;

    my $encoded_arguments;
    eval {
        $encoded_arguments = JSON::XS->new->utf8->encode($options{argument});
    };
    if ($@) {
        my $container = '';
        $container = 'container ' . $self->{container_id} . ': ' if (defined($self->{container_id}));
        $self->{logger}->writeLogError("[$self->{module_id}] ${container}$options{method} - cannot encode json: $@");
        return 1;
    }

    return (0, $encoded_arguments);
}

sub json_decode {
    my ($self, %options) = @_;

    my $decoded_arguments;
    eval {
        $decoded_arguments = JSON::XS->new->utf8->decode($options{argument});
    };
    if ($@) {
        my $container = '';
        $container = 'container ' . $self->{container_id} . ': ' if (defined($self->{container_id}));
        $self->{logger}->writeLogError("[$self->{module_id}] ${container}$options{method} - cannot decode json: $@");
        if (defined($options{token})) {
            $self->send_log(
                code => GORGONE_ACTION_FINISH_KO,
                token => $options{token},
                data => { message => 'cannot decode json' }
            );
        }
        return 1;
    }

    return (0, $decoded_arguments);
}

sub execute_shell_cmd {
    my ($self, %options) = @_;

    my $timeout = defined($options{timeout}) &&  $options{timeout} =~ /(\d+)/ ? $1 : 30;
    my ($lerror, $stdout, $exit_code) = gorgone::standard::misc::backtick(
        command => $options{cmd},
        logger => $self->{logger},
        timeout => $timeout,
        wait_exit => 1,
    );
    if ($lerror == -1 || ($exit_code >> 8) != 0) {
        my $container = '';
        $container = 'container ' . $self->{container_id} . ': ' if (defined($self->{container_id}));
        $self->{logger}->writeLogError("[$self->{module_id}] ${container}command execution issue $options{cmd} : " . $stdout);
        return -1;
    }

    return 0;
}

sub change_macros {
    my ($self, %options) = @_;

    $options{template} =~ s/%\{(.*?)\}/$options{macros}->{$1}/g;
    if (defined($options{escape})) {
        $options{template} =~ s/([\Q$options{escape}\E])/\\$1/g;
    }
    return $options{template};
}

sub action_bcastlogger {
    my ($self, %options) = @_;

    if (defined($options{data}->{content}->{severity}) && $options{data}->{content}->{severity} ne '') {
        if ($options{data}->{content}->{severity} eq 'default') {
            $self->{logger}->set_default_severity();
        } else {
            $self->{logger}->severity($options{data}->{content}->{severity});
        }
    }
}

1;
