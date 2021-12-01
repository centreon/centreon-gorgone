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

get '/' => sub { 
    my $mojo = shift;

    gorgone::standard::library::zmq_send_message(
        socket => $connector->{internal_socket},
        action => 'CONSTATUS',
        token => 'ploptest',
        data => {},
        json_encode => 1
    );
    $connector->read_zmq_events();

    if ($connector->{allowed_hosts_enabled} == 1) {
        if ($connector->check_allowed_host(peer_addr => $mojo->tx->remote_address) == 0) {
            $connector->{logger}->writeLogError("[httpserverng] " . $mojo->tx->remote_address . " Unauthorized");
            return $mojo->render(json => { message => 'unauthorized' }, status => 401);
        }
    }

    if ($connector->{auth_enabled} == 1) {
        my ($hash_ref, $auth_ok) = $mojo->basic_auth(
            'Realm Name' => {
                username => $connector->{config}->{auth}->{user},
                password => $connector->{config}->{auth}->{password}
            }
        );
        if (!$auth_ok) {
            return $mojo->render(json => { message => 'unauthorized' }, status => 401);
        }
    }

    $mojo->render(json => { message => 'ok' });
};

sub construct {
    my ($class, %options) = @_;
    $connector = $class->SUPER::new(%options);
    bless $connector, $class;

    $connector->{api_endpoints} = $options{api_endpoints};
    $connector->{auth_enabled} = (defined($connector->{config}->{auth}->{enabled}) && $connector->{config}->{auth}->{enabled} eq 'true') ? 1 : 0;
    $connector->{allowed_hosts_enabled} = (defined($connector->{config}->{allowed_hosts}->{enabled}) && $connector->{config}->{allowed_hosts}->{enabled} eq 'true') ? 1 : 0;
    $connector->{clients} = {};

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

sub event {
    while (1) {
        my $message = gorgone::standard::library::zmq_dealer_read_message(socket => $connector->{internal_socket});
        last if (!defined($message));

        $connector->{logger}->writeLogDebug("[httpserver] Event: $message");
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
            $self->{logger}->writeLogError("[httpserver] Cannot load subnet: $_");
            next;
        }

        push @{$self->{peer_subnets}}, $subnet;
    }
}

sub read_zmq_events {
    my ($self, %options) = @_;

    while (my $events = gorgone::standard::library::zmq_events(socket => $self->{internal_socket})) {
        if ($events & ZMQ_POLLIN) {
            my $message = gorgone::standard::library::zmq_dealer_read_message(socket => $connector->{internal_socket});
            print "===MESSAGE = zmq received $message ===\n";
        } else {
            last;
        }
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
    my $socket = IO::Handle->new();
    $socket->fdopen($socket_fd, 'r');
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
    my $daemon = Mojo::Server::Daemon->new(
        app    => app,
        listen => [$proto . '://' . $self->{config}->{address} . ':' . $self->{config}->{port} . '?' . $listen]
    );
    #my $loop = Mojo::IOLoop->new();
    #my $reactor = Mojo::Reactor::EV->new();
    #$reactor->io($socket => sub {
    #    print "===la==\n";
    #    my $message = gorgone::standard::library::zmq_dealer_read_message(socket => $connector->{internal_socket}); 
    #    print "===MESSAGE = zmq received $message ===\n";
    #});
    #$reactor->watch($socket, 1, 0);
    #$loop->reactor($reactor);
    #$daemon->ioloop($loop);

    $daemon->run();

=pod
    $self->{poll} = [
        {
            socket  => $connector->{internal_socket},
            events  => ZMQ_POLLIN,
            callback => \&event
        }
    ];

    my $rev = zmq_poll($self->{poll}, 4000);

    $self->init_dispatch();

    # HTTP daemon
    my ($daemon, $message_error);
    if ($self->{config}->{ssl} eq 'false') {
        $message_error = '$@';
        $daemon = HTTP::Daemon->new(
            LocalAddr => $self->{config}->{address} . ':' . $self->{config}->{port},
            ReusePort => 1,
            Timeout => 5
        );
    } elsif ($self->{config}->{ssl} eq 'true') {
        $message_error = '$!, ssl_error=$IO::Socket::SSL::SSL_ERROR';
        $daemon = HTTP::Daemon::SSL->new(
            LocalAddr => $self->{config}->{address} . ':' . $self->{config}->{port},
            SSL_cert_file => $self->{config}->{ssl_cert_file},
            SSL_key_file => $self->{config}->{ssl_key_file},
            SSL_error_trap => \&ssl_error,
            ReusePort => 1,
            Timeout => 5
        );
    }

    if (!defined($daemon)) {
        eval "\$message_error = \"$message_error\"";
        $connector->{logger}->writeLogError("[httpserver] can't construct socket: $message_error");
        exit(1);
    }

    while (1) {
        my ($connection) = $daemon->accept();

        if ($self->{stop} == 1) {
            $self->{logger}->writeLogInfo("[httpserver] $$ has quit");
            $connection->close() if (defined($connection));
            zmq_close($connector->{internal_socket});
            exit(0);
        }

        next if (!defined($connection));

        while (my $request = $connection->get_request) {
            if ($connection->antique_client eq '1') {
                $connection->force_last_request;
                next;
            }

            my $msg = "[httpserver] " . $connection->peerhost() . " " . $request->method . " '" . $request->uri->path . "'";
            $msg .= " '" . $request->header("User-Agent") . "'" if (defined($request->header("User-Agent")) && $request->header("User-Agent") ne '');
            $connector->{logger}->writeLogInfo($msg);
            
            if ($connector->{allowed_hosts_enabled} == 1) {
                if ($connector->check_allowed_host(peer_addr => inet_ntoa($connection->peeraddr())) == 0) {
                    $connector->{logger}->writeLogError("[httpserver] " . $connection->peerhost() . " Unauthorized");
                    $self->send_error(
                        connection => $connection,
                        code => "401",
                        response => '{"error":"http_error_401","message":"unauthorized"}'
                    );
                    next;
                }
            }

            if ($self->authentication($request->header('Authorization'))) { # Check Basic authentication
                my ($root) = ($request->uri->path =~ /^(\/\w+)/);

                if ($root eq "/api") { # API
                    $self->send_response(connection => $connection, response => $self->api_call($request));
                } else { # Forbidden
                    $connector->{logger}->writeLogError("[httpserver] " . $connection->peerhost() . " '" . $request->uri->path . "' Forbidden");
                    $self->send_error(
                        connection => $connection,
                        code => "403",
                        response => '{"error":"http_error_403","message":"forbidden"}'
                    );
                }
            } else { # Authen error
                $connector->{logger}->writeLogError("[httpserver] " . $connection->peerhost() . " Unauthorized");
                $self->send_error(
                    connection => $connection,
                    code => "401",
                    response => '{"error":"http_error_401","message":"unauthorized"}'
                );
            }
            $connection->force_last_request;
        }
        $connection->close;
        undef($connection);
    }
=cut
}

sub api_call {
    my ($self, $request) = @_;

    my $content;
    eval {
        $content = JSON::XS->new->utf8->decode($request->content)
            if ($request->method =~ /POST|PATCH/ && defined($request->content));
    };
    if ($@) {
        return '{"error":"decode_error","message":"POST content must be JSON-formated"}';;
    }

    my %parameters = $request->uri->query_form;
    my $response = gorgone::standard::api::root(
        method => $request->method,
        uri => $request->uri->path,
        parameters => \%parameters,
        content => $content,
        socket => $connector->{internal_socket},
        logger => $self->{logger},
        api_endpoints => $self->{api_endpoints}
    );

    return $response;
}

1;
