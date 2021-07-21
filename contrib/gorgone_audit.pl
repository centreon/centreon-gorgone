#!/usr/bin/perl

use warnings;
use strict;
use FindBin;
use lib "$FindBin::Bin";
# to be launched from contrib directory
use lib "$FindBin::Bin/../";

gorgone::script::gorgone_audit->new()->run();

package gorgone::script::gorgone_audit;

use strict;
use warnings;
use Data::Dumper;
use gorgone::standard::misc;
use gorgone::class::http::http;
use JSON::XS;

use base qw(gorgone::class::script);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new('gorgone_audit',
        centreon_db_conn => 0,
        centstorage_db_conn => 0,
        noconfig => 0
    );

    bless $self, $class;
    $self->add_options(
        'url:s'      => \$self->{url},
        'markdown:s' => \$self->{markdown}
    );
    return $self;
}

sub init {
    my $self = shift;
    $self->SUPER::init();

    $self->{url} = 'http://127.0.0.1:8085' if (!defined($self->{url}) || $self->{url} eq '');
    $self->{markdown} = 'audit.md' if (defined($self->{markdown}) && $self->{markdown} eq '');
    $self->{http} = gorgone::class::http::http->new(logger => $self->{logger});
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

sub schedule_audit {
    my ($self) = @_;

    my ($code, $content) = $self->{http}->request(
        http_backend => 'curl',
        method => 'POST',
        hostname => '',
        full_url => $self->{url} . '/api/centreon/audit/schedule',
        query_form_post => '{}',
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

sub get_audit_log {
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
            if ($_->{code} == 500 && $progress < $data->{complete}) {
                $self->{logger}->writeLogInfo("audit completed: $data->{complete}\%");
                $progress = $data->{complete};
            } elsif ($_->{code} == 1) {
                $self->{logger}->writeLogError("audit execution: $data->{message}");
                $stop = 1;
            } elsif ($_->{code} == 2) {
                $self->{audit} = $data->{audit};
                $stop = 1;
            }
        }

        last if ($stop == 1);
        sleep(10);
    }

    if (defined($self->{audit})) {
        $self->{logger}->writeLogInfo("audit result: " . JSON::XS->new->utf8->encode($self->{audit}));
        if (defined($self->{markdown})) {
            $self->md_output();
        }
    }
}

sub md_node_system_cpu {
    my ($self, %options) = @_;

    return '' if (!defined($options{entry}));

    my $cpu = <<"END_CPU";
    <tr>
         <td colspan="2">Cpu</td>
    </tr>
END_CPU

    if ($options{entry}->{status_code} != 0) {
        my $message = '_**Error:** cannot get informations ' . $options{node}->{status_message}; 
        $cpu .= <<"END_CPU";
    <tr>
         <td colspan="2">$message</td>
    </tr>
END_CPU
        return $cpu;
    }

    my $used = sprintf(
        '%s/%s/%s/%s (1m/5m/15m/60m)',
        defined($options{entry}->{avg_used_1min}) && $options{entry}->{avg_used_1min} =~ /\d/ ? $options{entry}->{avg_used_1min} . '%' : '-',
        defined($options{entry}->{avg_used_5min}) && $options{entry}->{avg_used_5min} =~ /\d/ ? $options{entry}->{avg_used_5min} . '%' : '-',
        defined($options{entry}->{avg_used_15min}) && $options{entry}->{avg_used_15min} =~ /\d/ ? $options{entry}->{avg_used_15min} . '%' : '-',
        defined($options{entry}->{avg_used_60min}) && $options{entry}->{avg_used_60min} =~ /\d/ ? $options{entry}->{avg_used_60min} . '%' : '-'
    );
    my $iowait = sprintf(
        '%s/%s/%s/%s (1m/5m/15m/60m)',
        defined($options{entry}->{avg_iowait_1min}) && $options{entry}->{avg_iowait_1min} =~ /\d/ ? $options{entry}->{avg_iowait_1min} . '%' : '-',
        defined($options{entry}->{avg_iowait_5min}) && $options{entry}->{avg_iowait_5min} =~ /\d/ ? $options{entry}->{avg_iowait_5min} . '%' : '-',
        defined($options{entry}->{avg_iowait_15min}) && $options{entry}->{avg_iowait_15min} =~ /\d/ ? $options{entry}->{avg_iowait_15min} . '%' : '-',
        defined($options{entry}->{avg_iowait_60min}) && $options{entry}->{avg_iowait_60min} =~ /\d/ ? $options{entry}->{avg_iowait_60min} . '%' : '-'
    );
    $cpu .= <<"END_CPU";
    <tr>
         <td>number of cores</td>
         <td>$options{entry}->{num_cpu}</td>
    </tr>
    <tr>
         <td>used</td>
         <td>$used</td>
	</tr>
    <tr>
         <td>iowait</td>
         <td>$iowait</td>
    </tr>
END_CPU

    return $cpu;
}

sub md_node_system_load {
    my ($self, %options) = @_;

    return '' if (!defined($options{entry}));

    my $load = <<"END_LOAD";
    <tr>
         <td colspan="2">Load</td>
    </tr>
END_LOAD

    if ($options{entry}->{status_code} != 0) {
        my $message = '_**Error:** cannot get informations ' . $options{node}->{status_message}; 
        $load .= <<"END_LOAD";
    <tr>
         <td colspan="2">$message</td>
    </tr>
END_LOAD
        return $load;
    }

    $load .= <<"END_LOAD";
    <tr>
         <td>load average</td>
         <td>$options{entry}->{load1m}/$options{entry}->{load5m}/$options{entry}->{load15m} (1m/5m/15m)</td>
    </tr>
END_LOAD
    return $load;
}

sub md_node_system_memory {
    my ($self, %options) = @_;

    return '' if (!defined($options{entry}));

    my $memory = <<"END_MEMORY";
    <tr>
         <td colspan="2">Memory</td>
    </tr>
END_MEMORY

    if ($options{entry}->{status_code} != 0) {
        my $message = '_**Error:** cannot get informations ' . $options{node}->{status_message}; 
        $memory .= <<"END_MEMORY";
    <tr>
         <td colspan="2">$message</td>
    </tr>
END_MEMORY
        return $memory;
    }

    $memory .= <<"END_MEMORY";
    <tr>
         <td>memory total</td>
         <td>$options{entry}->{ram_total_human}</td>
    </tr>
    <tr>
         <td>memory available</td>
         <td>$options{entry}->{ram_available_human}</td>
    </tr>
    <tr>
         <td>swap total</td>
         <td>$options{entry}->{swap_total_human}</td>
    </tr>
    <tr>
         <td>swap free</td>
         <td>$options{entry}->{swap_free_human}</td>
    </tr>
END_MEMORY
    return $memory;
}

sub md_node_system_disk {
    my ($self, %options) = @_;

    return '' if (!defined($options{entry}));

    my $disk = "#### Filesystems\n\n";
    if ($options{entry}->{status_code} != 0) {
        $disk .= '_**Error:** cannot get informations ' . $options{node}->{status_message};
        return $disk;
    }

    $disk .= <<"END_DISK";
| Filesystem  | Type  | Size   | Used  | Avail  | Inodes  | Mounted |
| :---------- | :---- | :----- | :---  | :----- | :------ | :------ | 
END_DISK

    foreach my $mount (sort keys %{$options{entry}->{partitions}}) {
        my $values = $options{entry}->{partitions}->{$mount};
        $disk .= <<"END_DISK";
| $values->{filesystem} | $values->{type} | $values->{space_size_human} | $values->{space_used_human} | $values->{space_free_human} | $values->{inodes_used_percent} | $values->{mount} |
END_DISK
    }

    return $disk;
}

sub md_node_system_diskio {
    my ($self, %options) = @_;

    return '' if (!defined($options{entry}));

    my $diskio = "#### Disks I/O\n\n";
    if ($options{entry}->{status_code} != 0) {
        $diskio .= '_**Error:** cannot get informations ' . $options{node}->{status_message};
        return $diskio;
    }

    $diskio .= <<"END_DISK";
| Device      | Read IOPs  | Write IOPs   | Read Time  | Write Time  |
| :---------- | :--------- | :----------- | :--------  | :---------- |
END_DISK

    foreach my $dev (sort keys %{$options{entry}->{partitions}}) {
        my $values = $options{entry}->{partitions}->{$dev};
        $diskio .= "| $dev | " . 
            sprintf(
                '%s/%s/%s/%s', 
                defined($values->{read_iops_1min_human}) && $values->{read_iops_1min_human} =~ /\d/ ? $values->{read_iops_1min_human} : '-',
                defined($values->{read_iops_5min_human}) && $values->{read_iops_5min_human} =~ /\d/ ? $values->{read_iops_5min_human} : '-',
                defined($values->{read_iops_15min_human}) && $values->{read_iops_15min_human} =~ /\d/ ? $values->{read_iops_15min_human} : '-',
                defined($values->{read_iops_60min_human}) && $values->{read_iops_60min_human} =~ /\d/ ? $values->{read_iops_60min_human} : '-',
            ) . '| ' .
            sprintf(
                '%s/%s/%s/%s', 
                defined($values->{write_iops_1min_human}) && $values->{write_iops_1min_human} =~ /\d/ ? $values->{write_iops_1min_human} : '-',
                defined($values->{write_iops_5min_human}) && $values->{write_iops_5min_human} =~ /\d/ ? $values->{write_iops_5min_human} : '-',
                defined($values->{write_iops_15min_human}) && $values->{write_iops_15min_human} =~ /\d/ ? $values->{write_iops_15min_human} : '-',
                defined($values->{write_iops_60min_human}) && $values->{write_iops_60min_human} =~ /\d/ ? $values->{write_iops_60min_human} : '-',
            ) . '| ' .
            sprintf(
                '%s/%s/%s/%s', 
                defined($values->{read_time_1min_ms}) && $values->{read_time_1min_ms} =~ /\d/ ? $values->{read_time_1min_ms} . 'ms' : '-',
                defined($values->{read_time_5min_ms}) && $values->{read_time_5min_ms} =~ /\d/ ? $values->{read_time_5min_ms} . 'ms' : '-',
                defined($values->{read_time_15min_ms}) && $values->{read_time_15min_ms} =~ /\d/ ? $values->{read_time_15min_ms} . 'ms' : '-',
                defined($values->{read_time_60min_ms}) && $values->{read_time_60min_ms} =~ /\d/ ? $values->{read_time_60min_ms} . 'ms' : '-'
            ) . '| ' .
            sprintf(
                '%s/%s/%s/%s', 
                defined($values->{write_time_1min_ms}) && $values->{write_time_1min_ms} =~ /\d/ ? $values->{write_time_1min_ms} . 'ms' : '-',
                defined($values->{write_time_5min_ms}) && $values->{write_time_5min_ms} =~ /\d/ ? $values->{write_time_5min_ms} . 'ms' : '-',
                defined($values->{write_time_15min_ms}) && $values->{write_time_15min_ms} =~ /\d/ ? $values->{write_time_15min_ms} . 'ms' : '-',
                defined($values->{write_time_60min_ms}) && $values->{write_time_60min_ms} =~ /\d/ ? $values->{write_time_60min_ms} . 'ms' : '-'
            ) . "|\n";
    }

    return $diskio;
}

sub md_node_system {
    my ($self, %options) = @_;

    my $os = defined($options{node}->{metrics}->{'system::os'}) ? $options{node}->{metrics}->{'system::os'}->{os}->{value} : '-';
    my $kernel = defined($options{node}->{metrics}->{'system::os'}) ? $options{node}->{metrics}->{'system::os'}->{kernel}->{value} : '-';
    
    my $cpu = $self->md_node_system_cpu(entry => $options{node}->{metrics}->{'system::cpu'});
    my $load = $self->md_node_system_load(entry => $options{node}->{metrics}->{'system::load'});
    my $memory = $self->md_node_system_memory(entry => $options{node}->{metrics}->{'system::memory'});
    my $disks = $self->md_node_system_disk(entry => $options{node}->{metrics}->{'system::disk'});
    my $disks_io = $self->md_node_system_diskio(entry => $options{node}->{metrics}->{'system::diskio'});

    $self->{md_content} .= <<"END_CONTENT";
### System

#### Overall

os: $os

kernel: $kernel

<table>
${cpu}${load}${memory}
</table>

$disks
$disks_io

END_CONTENT
    
}

sub md_node {
    my ($self, %options) = @_;

    $self->{md_content} .= "## " . $options{node}->{name} . "\n\n";
    if ($options{node}->{status_code} != 0) {
        $self->{md_content} .= '_**Error:** cannot get informations ' . $options{node}->{status_message} . "\n\n";
        return ;
    }

    $self->md_node_system(%options);
}

sub md_output {
    my ($self) = @_;

    if (!open(FH, '>', $self->{markdown})) {
        $self->{logger}->writeLogError("cannot open file '" . $self->{markdown} . "': $!");
        exit(1);
    }
    $self->{md_content} = "# Audit\n\n";

    foreach my $node_id (sort { $self->{audit}->{nodes}->{$a}->{name} cmp $self->{audit}->{nodes}->{$b}->{name} } keys %{$self->{audit}->{nodes}}) {
        $self->md_node(node => $self->{audit}->{nodes}->{$node_id});
    }

    print FH $self->{md_content};
    close FH;
}

sub run {
    my $self = shift;

    $self->SUPER::run();
    $self->schedule_audit();
    $self->get_audit_log();
}

__END__

=head1 NAME

gorgone_audit.pl - script to execute and get audit

=head1 SYNOPSIS

gorgone_audit.pl [options]

=head1 OPTIONS

=over 8

=item B<--url>

Specify the api url (default: 'http://127.0.0.1:8085').

=item B<--markdown>

Markdown output format (default: 'audit.md').

=item B<--severity>

Set the script log severity (default: 'info').

=item B<--help>

Print a brief help message and exits.

=back

=head1 DESCRIPTION

B<gorgone_audit.pl>

=cut

