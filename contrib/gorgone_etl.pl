#!/usr/bin/perl

use warnings;
use strict;
use FindBin;
use lib "$FindBin::Bin";
# to be launched from contrib directory
use lib "$FindBin::Bin/../";

gorgone::script::gorgone_etl->new()->run();

package gorgone::script::gorgone_etl;

use strict;
use warnings;
use Data::Dumper;
use gorgone::standard::misc;
use gorgone::class::http::http;
use JSON::XS;

use base qw(gorgone::class::script);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(
        'gorgone_etl',
        centreon_db_conn => 0,
        centstorage_db_conn => 0,
        noconfig => 0
    );

    bless $self, $class;
    
    $self->{moptions}->{rebuild} = 0;
    $self->{moptions}->{daily} = 0;
    $self->{moptions}->{import} = 0;
    $self->{moptions}->{dimensions} = 0;
    $self->{moptions}->{event} = 0;
    $self->{moptions}->{perfdata} = 0;
    $self->{moptions}->{start} = '';
    $self->{moptions}->{end} = '';
    $self->{moptions}->{create_tables} = 0;
    $self->{moptions}->{ignore_databin} = 0;
    $self->{moptions}->{centreon_only} = 0;
    $self->{moptions}->{nopurge} = 0;

    $self->add_options(
        'url:s' => \$self->{url},
        'r'     => \$self->{moptions}->{rebuild},
        'd'     => \$self->{moptions}->{daily},
        'I'     => \$self->{moptions}->{import},
        'D'     => \$self->{moptions}->{dimensions},
        'E'     => \$self->{moptions}->{event},
        'P'     => \$self->{moptions}->{perfdata},
        's:s'   => \$self->{moptions}->{start},
        'e:s'   => \$self->{moptions}->{end},
        'c'     => \$self->{moptions}->{create_tables},
        'i'     => \$self->{moptions}->{ignore_databin},
        'C'     => \$self->{moptions}->{centreon_only},
        'p'     => \$self->{moptions}->{nopurge}
    );
    return $self;
}

sub init {
    my $self = shift;
    $self->SUPER::init();

    $self->{url} = 'http://127.0.0.1:8085' if (!defined($self->{url}) || $self->{url} eq '');
    $self->{http} = gorgone::class::http::http->new(logger => $self->{logger});

    if ($self->{moptions}->{create_tables} == 0 && 
        $self->{moptions}->{import} == 0 &&
        $self->{moptions}->{dimensions} == 0 &&
        $self->{moptions}->{event} == 0 &&
        $self->{moptions}->{perfdata} == 0) {
        $self->{moptions}->{import} = 1;
        $self->{moptions}->{dimensions} = 1;
        $self->{moptions}->{event} = 1;
        $self->{moptions}->{perfdata} = 1;
    }
}

sub json_decode {
    my ($self, %options) = @_;

    my $decoded;
    eval {
        $decoded = JSON::XS->new->utf8->decode($options{content});
    };
    if ($@) {
        $self->{logger}->writeLogError("cannot decode json response: $@");
        exit(1);
    }

    return $decoded;
}

sub run_etl {
    my ($self) = @_;

    my ($code, $content) = $self->{http}->request(
        http_backend => 'curl',
        method => 'POST',
        hostname => '',
        full_url => $self->{url} . '/api/centreon/mbietl/run',
        query_form_post => JSON::XS->new->utf8->encode($self->{moptions}),
        header => [
            'Accept-Type: application/json; charset=utf-8',
            'Content-Type: application/json; charset=utf-8',
        ],
        curl_opt => ['CURLOPT_SSL_VERIFYPEER => 0', 'CURLOPT_POSTREDIR => CURL_REDIR_POST_ALL'],
        warning_status => '',
        unknown_status => '',
        critical_status => ''
    );

    if ($code) {
        $self->{logger}->writeLogError("http request error");
        exit(1);
    }
    if ($self->{http}->get_code() < 200 || $self->{http}->get_code() >= 300) {
        $self->{logger}->writeLogError("Login error [code: '" . $self->{http}->get_code() . "'] [message: '" . $self->{http}->get_message() . "']");
        exit(1);
    }

    my $decoded = $self->json_decode(content => $content);
    if (!defined($decoded->{token})) {
        $self->{logger}->writeLogError('cannot get token');
        exit(1);
    }

    $self->{token} = $decoded->{token};
}

sub get_etl_log {
    my ($self) = @_;
    
    my $progress = 0;
    while (1) {
        my ($code, $content) = $self->{http}->request(
            http_backend => 'curl',
            method => 'GET',
            hostname => '',
            full_url => $self->{url} . '/api/log/' . $self->{token},
            header => [
                'Accept-Type: application/json; charset=utf-8'
            ],
            curl_opt => ['CURLOPT_SSL_VERIFYPEER => 0', 'CURLOPT_POSTREDIR => CURL_REDIR_POST_ALL'],
            warning_status => '',
            unknown_status => '',
            critical_status => ''
        );

        if ($code) {
            $self->{logger}->writeLogError("Login error [code: '" . $self->{http}->get_code() . "'] [message: '" . $self->{http}->get_message() . "']");
            exit(1);
        }
        if ($self->{http}->get_code() < 200 || $self->{http}->get_code() >= 300) {
            $self->{logger}->writeLogError("Login error [code: '" . $self->{http}->get_code() . "'] [message: '" . $self->{http}->get_message() . "']");
            exit(1);
        }

        my $decoded = $self->json_decode(content => $content);
        if (!defined($decoded->{data})) {
            $self->{logger}->writeLogError("Cannot get log information");
            exit(1);
        }

        my $stop = 0;
        foreach (@{$decoded->{data}}) {
            my $data = $self->json_decode(content => $_->{data});
            if ($_->{code} == 600) {
                $self->{logger}->writeLogInfo("etl completed: $data->{message}\%");
                $progress = $data->{complete};
            } elsif ($_->{code} == 1) {
                $self->{logger}->writeLogError("etl execution: $data->{message}");
                $stop = 1;
            } elsif ($_->{code} == 2) {
                print "==la==\n";
                $stop = 1;
            }
        }

        last if ($stop == 1);
        sleep(10);
    }
}

sub run {
    my $self = shift;

    $self->SUPER::run();
    $self->run_etl();
    $self->get_etl_log();
}

__END__

=head1 NAME

gorgone_etl.pl - script to execute mbi etl

=head1 SYNOPSIS

gorgone_etl.pl [options]

=head1 OPTIONS

=over 8

=item B<--url>

Specify the api url (default: 'http://127.0.0.1:8085').

=item B<--severity>

Set the script log severity (default: 'info').

=item B<--help>

Print a brief help message and exits.

Execution modes

    -c  Create the reporting database model
    -d  Daily execution to calculate statistics on yesterday
    -r  Rebuild mode to calculate statitics on a historical period. Can be used with:
        Extra arguments for options -d and -r (if none of the following is specified, these one are selected by default: -IDEP):
        -I  Extract data from the monitoring server
            Extra arguments for option -I:
            -C  Extract only Centreon configuration database only. Works with option -I.
            -i  Ignore perfdata extraction from monitoring server
            -o  Extract only perfdata from monitoring server

        -D  Calculate dimensions
        -E  Calculate event and availability statistics
        -P  Calculate perfdata statistics
            Common options for -rIDEP:
            -s  Start date in format YYYY-MM-DD.
                By default, the program uses the data retention period from Centreon BI configuration
            -e  End date in format YYYY-MM-DD.
                By default, the program uses the data retention period from Centreon BI configuration
            -p  Do not empty statistic tables, delete only entries for the processed period.
                Does not work on raw data tables, only on Centreon BI statistics tables.

=back

=head1 DESCRIPTION

B<gorgone_etl.pl>

=cut
