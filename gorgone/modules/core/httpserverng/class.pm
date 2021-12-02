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

package gorgone::modules::core::httpserverng::class;

use base qw(gorgone::class::module);

use strict;
use warnings;
use gorgone::standard::library;
use gorgone::standard::misc;
use gorgone::standard::api;
use ZMQ::LibZMQ4;
use ZMQ::Constants qw(:all);
use Mojolicious::Lite;
use Mojo::Server::Daemon;
use Mojo::Reactor::EV;
use IO::Socket::SSL;
use IO::Handle;
use JSON::XS;
use Socket;

my $time = time();

my %handlers = (TERM => {}, HUP => {});
my ($connector);

plugin('basic_auth_plus');

websocket '/echo' => sub {
    my $mojo = shift;

    print sprintf("Client connected: %s\n", $mojo->tx->connection);
    my $ws_id = sprintf("%s", $mojo->tx->connection);
    $connector->{clients}->{$ws_id} = $mojo->tx;

    $mojo->on(message => sub {
        my ($self, $msg) = @_;

        my $dt   = DateTime->now(time_zone => 'Asia/Tokyo');

        for (keys %{$self->{clients}}) {
            $connector->{clients}->{$_}->send({json => {
                hms  => $dt->hms,
                text => $msg,
            }});
        }
    });

    $mojo->on(finish => sub {
        my ($mojo, $code, $reason) = @_;

        print "Client disconnected: $code\n";
        delete $connector->{clients}->{ $mojo->tx->connection };
    });
};

patch '/*' => sub {
    my $mojo = shift;

    $connector->api_call(
        mojo => $mojo,
        method => 'PATCH'
    );
};

post '/*' => sub {
    my $mojo = shift;

    $connector->api_call(
        mojo => $mojo,
        method => 'POST'
    );
};

get '/*' => sub { 
    my $mojo = shift;

    $connector->api_call(
        mojo => $mojo,
        method => 'GET'
    );
};

sub construct {
    my ($class, %options) = @_;
    $connector = $class->SUPER::new(%options);
    bless $connector, $class;

    $connector->{api_endpoints} = $options{api_endpoints};
    $connector->{auth_enabled} = (defined($connector->{config}->{auth}->{enabled}) && $connector->{config}->{auth}->{enabled} eq 'true') ? 1 : 0;
    $connector->{allowed_hosts_enabled} = (defined($connector->{config}->{allowed_hosts}->{enabled}) && $connector->{config}->{allowed_hosts}->{enabled} eq 'true') ? 1 : 0;
    $connector->{clients} = {};
    $connector->{token_watch} = {};

    if (gorgone::standard::misc::mymodule_load(
            logger => $connector->{logger},
            module => 'NetAddr::IP',
            error_msg => "[httpserverng] -class- cannot load module 'NetAddr::IP'. Cannot use allowed_hosts configuration.")
    ) {
        $connector->{allowed_hosts_enabled} = 0;
    }

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
    $self->{logger}->writeLogDebug("[httpserver] $$ Receiving order to stop...");
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

sub check_allowed_host {
    my ($self, %options) = @_;

    my $subnet = NetAddr::IP->new($options{peer_addr} . '/32');
    foreach (@{$self->{peer_subnets}}) {
        return 1 if ($_->contains($subnet));
    }

    return 0;
}

sub load_peer_subnets {
    my ($self, %options) = @_;

    return if ($self->{allowed_hosts_enabled} == 0);

    $self->{peer_subnets} = [];
    return if (!defined($connector->{config}->{allowed_hosts}->{subnets}));

    foreach (@{$self->{config}->{allowed_hosts}->{subnets}}) {
        my $subnet = NetAddr::IP->new($_);
        if (!defined($subnet)) {
            $self->{logger}->writeLogError("[httpserverng] Cannot load subnet: $_");
            next;
        }

        push @{$self->{peer_subnets}}, $subnet;
    }
}

sub run {
    my ($self, %options) = @_;

    $self->load_peer_subnets();

    # Connect internal
    $self->{internal_socket} = gorgone::standard::library::connect_com(
        zmq_type => 'ZMQ_DEALER',
        name => 'gorgone-httpserverng',
        logger => $self->{logger},
        type => $self->{config_core}->{internal_com_type},
        path => $self->{config_core}->{internal_com_path}
    );
    $self->send_internal_action(
        action => 'HTTPSERVERNGREADY',
        data => {}
    );
    $self->read_zmq_events();

    my $socket_fd = gorgone::standard::library::zmq_getfd(socket => $self->{internal_socket});
    my $socket = IO::Handle->new_from_fd($socket_fd, 'r');
    Mojo::IOLoop->singleton->reactor->io($socket => sub {
        print "===ICI===\n";
        $connector->read_zmq_events();
    });
    Mojo::IOLoop->singleton->reactor->watch($socket, 1, 0);

    my $listen = 'reuse=1';
    if ($self->{config}->{ssl} eq 'true') {
        $listen .= '&cert=' . $self->{config}->{ssl_cert_file} . '&key=' . $self->{config}->{ssl_key_file};
    }
    my $proto = 'http';
    if ($self->{config}->{ssl} eq 'true') {
        $proto = 'https';
        if (defined($self->{config}->{passphrase}) && $self->{config}->{passphrase} ne '') {
            IO::Socket::SSL::set_defaults(SSL_passwd_cb => sub { return $connector->{config}->{passphrase} } );
        }
    }
    app->mode('production');
    my $daemon = Mojo::Server::Daemon->new(
        app    => app,
        listen => [$proto . '://' . $self->{config}->{address} . ':' . $self->{config}->{port} . '?' . $listen]
    );
    #my $loop = Mojo::IOLoop->new();
    #my $reactor = Mojo::Reactor::EV->new();
    #$reactor->io($socket => sub {
    #    my $message = gorgone::standard::library::zmq_dealer_read_message(socket => $connector->{internal_socket}); 
    #});
    #$reactor->watch($socket, 1, 0);
    #$loop->reactor($reactor);
    #$daemon->ioloop($loop);

    $daemon->run();
}

sub read_log_event {
    my ($self, %options) = @_;

    my $response = { error => 'no_log', message => 'No log found for token', data => [], token => $options{token} };
    if (defined($options{data})) {
        my $content;
        eval {
            $content = JSON::XS->new->utf8->decode($options{data});
        };
        if ($@) {
            $response = { error => 'decode_error', message => 'Cannot decode response' };
        } elsif (defined($content->{data}->{result}) && scalar(@{$content->{data}->{result}}) > 0) {
            $response = {
                message => 'Logs found',
                token => $options{token},
                data => $content->{data}->{result}
            };
        }
    }

    $self->{token_watch}->{ $options{token} }->render(json => $response);
    delete $self->{token_watch}->{ $options{token} };
}

sub read_zmq_events {
    my ($self, %options) = @_;

    while (my $events = gorgone::standard::library::zmq_events(socket => $self->{internal_socket})) {
        if ($events & ZMQ_POLLIN) {
            my $message = gorgone::standard::library::zmq_dealer_read_message(socket => $connector->{internal_socket});
            print "===MESSAGE = zmq received $message ===\n";
            if ($message =~ /^\[(.*?)\]\s+\[(.*?)\]\s+\[.*?\]\s+(.*)$/m || 
                $message =~ /^\[(.*?)\]\s+\[(.*?)\]\s+(.*)$/m) {
                my ($action, $token, $data) = ($1, $2, $3);
                if (defined($connector->{token_watch}->{$token})) {
                    if ($token =~ /-log$/) {
                        $connector->read_log_event(token => $token, data => $data);
                    }
                }
            }
        } else {
            last;
        }
    }
}

sub api_call {
    my ($self, %options) = @_;

    if ($self->{allowed_hosts_enabled} == 1) {
        if ($self->check_allowed_host(peer_addr => $options{mojo}->tx->remote_address) == 0) {
            $connector->{logger}->writeLogError("[httpserverng] " . $options{mojo}->tx->remote_address . " Unauthorized");
            return $options{mojo}->render(json => { message => 'unauthorized' }, status => 401);
        }
    }

    if ($self->{auth_enabled} == 1) {
        my ($hash_ref, $auth_ok) = $options{mojo}->basic_auth(
            'Realm Name' => {
                username => $self->{config}->{auth}->{user},
                password => $self->{config}->{auth}->{password}
            }
        );
        if (!$auth_ok) {
            return $options{mojo}->render(json => { message => 'unauthorized' }, status => 401);
        }
    }

    my $path = $options{mojo}->tx->req->url->path;
    my $names = $options{mojo}->req->params->names();
    my $params = {};
    foreach (@$names) {
        $params->{$_} = $options{mojo}->param($_);
    }

    my $content = $options{mojo}->req->json();

    $self->api_root(
        mojo => $options{mojo},
        method => $options{method},
        uri => $path,
        parameters => $params,
        content => $content
    );
}

sub get_log {
    my ($self, %options) = @_;

    if (defined($options{target}) && $options{target} ne '') {        
        gorgone::standard::library::zmq_send_message(
            socket => $self->{internal_socket},
            target => $options{target},
            action => 'GETLOG',
            json_encode => 1
        );
        $self->read_zmq_events();
    }

    my $token_log = $options{token} . '-log';
    $self->{token_watch}->{$token_log} = $options{mojo};

    gorgone::standard::library::zmq_send_message(
        socket => $self->{internal_socket},
        action => 'GETLOG',
        token => $token_log,
        data => {
            token => $options{token},
            %{$options{parameters}}
        },
        json_encode => 1
    );
    $self->read_zmq_events();

    $options{mojo}->render_later();
}

sub api_root {
    my ($self, %options) = @_;

    $self->{logger}->writeLogInfo("[api] Requesting '" . $options{uri} . "' [" . $options{method} . "]");

    my $async = 0;
    $async = 1 if (defined($options{parameters}->{async}) && $options{parameters}->{async} == 1);

    # async mode:
    #   provide the token directly and close the connection. need to call GETLOG on the token
    #   not working with GETLOG and internal call (execpt: CONSTATUS, INFORMATION, GETTHUMBPRINT)

    if ($options{method} eq 'GET' && $options{uri} =~ /^\/api\/(nodes\/(\w*)\/)?log\/(.*)$/) {
        $self->get_log(
            mojo => $options{mojo},
            target => $2,
            token => $3,
            parameters => $options{parameters}
        );
    } elsif ($options{uri} =~ /^\/api\/(nodes\/(\w*)\/)?internal\/(\w+)\/?([\w\/]*?)$/
        && defined($options{api_endpoints}->{ $options{method} . '_/internal/' . $3 })) {
        my @variables = split(/\//, $4);
        call_internal(
            action => $options{api_endpoints}->{ $options{method} . '_/internal/' . $3 },
            target => $2,
            data => { 
                content => $options{content},
                parameters => $options{parameters},
                variables => \@variables
            },
            log_wait => (defined($options{parameters}->{log_wait})) ? $options{parameters}->{log_wait} : undef,
            sync_wait => (defined($options{parameters}->{sync_wait})) ? $options{parameters}->{sync_wait} : undef
        );
    } elsif ($options{uri} =~ /^\/api\/(nodes\/(\w*)\/)?(\w+)\/(\w+)\/(\w+)\/?([\w\/]*?)$/
        && defined($options{api_endpoints}->{$options{method} . '_/' . $3 . '/' . $4 . '/' . $5})) {
        my @variables = split(/\//, $6);
        call_action(
            action => $options{api_endpoints}->{$options{method} . '_/' . $3 . '/' . $4 . '/' . $5},
            target => $2,
            data => { 
                content => $options{content},
                parameters => $options{parameters},
                variables => \@variables
            }
        );
    } else {
        $options{mojo}->render(json => { error => 'method_unknown', message => 'Method not implemented' }, status => 200);
        return ;
    }

#    gorgone::standard::library::zmq_send_message(
#        socket => $connector->{internal_socket},
#        action => 'CONSTATUS',
#        token => 'ploptest',
#        data => {},
#        json_encode => 1
#    );
#    $connector->read_zmq_events();

    #$options{mojo}->render(json => { message => 'ok' });
}

1;
