#!/usr/bin/perl
# Local PVE 9 QGA bridge. Request bodies arrive on stdin so credentials and
# binary chunks never enter argv or a pvesh command line.
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(decode_base64 encode_base64);
use PVE::INotify;
use PVE::QemuConfig;
use PVE::QemuServer::Agent;
use PVE::QemuServer::Helpers;
use PVE::RPCEnvironment;

sub reject { die "invalid bridge request\n"; }
sub data_from_base64 {
    my ($encoded) = @_;
    reject() if !defined($encoded) || ref($encoded) || $encoded !~ m{^[A-Za-z0-9+/]*={0,2}$};
    my $data = decode_base64($encoded);
    reject() if encode_base64($data, '') ne $encoded || length($data) > 49152;
    return $data;
}

my $raw = '';
while (read(STDIN, my $chunk, 8192)) {
    $raw .= $chunk;
    reject() if length($raw) > 100000;
}
my $request = eval { decode_json($raw) };
reject() if $@ || ref($request) ne 'HASH';
reject() if ($request->{schema} // 0) ne '1';
my $node = $request->{node};
my $vmid = $request->{vmid};
my $action = $request->{action};
reject() if !defined($node) || ref($node) || $node !~ m/^[A-Za-z0-9][A-Za-z0-9-]*$/;
reject() if !defined($vmid) || ref($vmid) || $vmid !~ m/^[1-9][0-9]{2,8}$/;
reject() if !defined($action) || ref($action) || $action !~ m/^(?:exec|exec-status|file-write)$/;
reject() if $node ne PVE::INotify::nodename();

my $result = eval {
    PVE::RPCEnvironment->setup_default_cli_env();
    reject() if !PVE::QemuServer::Helpers::vm_running_locally($vmid);
    my $config = PVE::QemuConfig->load_config($vmid);
    if ($action eq 'exec') {
        my $command = $request->{command};
        reject() if ref($command) ne 'ARRAY' || @$command < 1 || @$command > 9;
        for my $part (@$command) {
            reject() if !defined($part) || ref($part) || length($part) > 256 || $part =~ m/[\x00-\x1f\x7f]/;
        }
        reject() if $command->[0] !~ m{^/(?:bin/bash|usr/bin/(?:mkdir|chmod|sha256sum|stat))$};
        my $input = exists($request->{input_data_b64}) ? data_from_base64($request->{input_data_b64}) : undef;
        my $response = PVE::QemuServer::Agent::qemu_exec($vmid, $config, $input, [@$command]);
        reject() if ref($response) ne 'HASH' || ($response->{pid} // '') !~ m/^[1-9][0-9]*$/;
        return { pid => int($response->{pid}) };
    }
    if ($action eq 'exec-status') {
        my $pid = $request->{pid};
        reject() if !defined($pid) || ref($pid) || $pid !~ m/^[1-9][0-9]{0,9}$/;
        my $response = PVE::QemuServer::Agent::qemu_exec_status($vmid, $config, int($pid));
        reject() if ref($response) ne 'HASH';
        for my $key ('out-data', 'err-data') {
            reject() if defined($response->{$key}) && length($response->{$key}) > 65536;
        }
        return $response;
    }
    my $file = $request->{file};
    reject() if !defined($file) || ref($file) || $file !~ m{^/run/pve-toolbox-komodo-[a-f0-9]{32}/receiver[.]sh$};
    my $input = data_from_base64($request->{content_b64});
    my $handle = PVE::QemuServer::Agent::agent_cmd($vmid, $config, 'file-open',
        { path => $file, mode => 'wb' }, 'cannot open receiver');
    my $write = eval { PVE::QemuServer::Agent::agent_cmd($vmid, $config, 'file-write',
        { handle => $handle, 'buf-b64' => encode_base64($input, '') }, 'cannot write receiver') };
    my $write_error = $@;
    PVE::QemuServer::Agent::agent_cmd($vmid, $config, 'file-close',
        { handle => $handle }, 'cannot close receiver');
    die $write_error if $write_error;
    reject() if ref($write) ne 'HASH' || ($write->{count} // -1) != length($input);
    return { written => length($input) };
};
if ($@) {
    print STDERR "QGA operation failed\n";
    exit 1;
}
print encode_json($result), "\n";
