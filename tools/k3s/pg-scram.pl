#!/usr/bin/env perl
# SCRAM-SHA-256 password verifiers for PostgreSQL, computed on the client (RFC 5802/7677, the
# format of pg_authid.rolpassword), so postgres.sh never sends a plaintext password to the
# server. Core Perl only (Digest::SHA, MIME::Base64): it runs on macOS's /usr/bin/perl (where
# LibreSSL's openssl has no kdf) and on Ubuntu, where git depends on perl.
#
# The password comes on stdin, never on the command line.
#   pg-scram.pl make            stdin: <password>               prints SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>
#   pg-scram.pl check <role>    stdin: <password>\n<verifier>   exit 0 when the password matches the
#                               verifier (SCRAM-SHA-256 with its own salt and iterations, or md5),
#                               1 when it does not, 2 when the verifier is empty or unknown
# The passwords postgres.sh makes are printable ASCII, for which SASLprep changes nothing.
use strict;
use warnings;
use Digest::SHA qw(hmac_sha256 sha256);
use Digest::MD5 qw(md5_hex);
use MIME::Base64 qw(encode_base64 decode_base64);

sub salted_password {
  my ($pw, $salt, $iter) = @_;
  my $u = hmac_sha256($salt . pack('N', 1), $pw);
  my $t = $u;
  for (2 .. $iter) { $u = hmac_sha256($u, $pw); $t ^= $u; }
  return $t;
}

sub verifier {
  my ($pw, $salt, $iter) = @_;
  my $sp = salted_password($pw, $salt, $iter);
  my $stored = sha256(hmac_sha256('Client Key', $sp));
  my $server = hmac_sha256('Server Key', $sp);
  return sprintf('SCRAM-SHA-256$%d:%s$%s:%s', $iter, encode_base64($salt, ''), encode_base64($stored, ''),
                 encode_base64($server, ''));
}

my $mode = shift @ARGV // '';
my $pw = <STDIN>;
defined $pw or exit 2;
chomp $pw;
length $pw or exit 2;

if ($mode eq 'make') {
  open(my $rnd, '<:raw', '/dev/urandom') or die "pg-scram.pl: /dev/urandom: $!\n";
  my $salt = '';
  read($rnd, $salt, 16) == 16 or die "pg-scram.pl: short read from /dev/urandom\n";
  close $rnd;
  print verifier($pw, $salt, 4096), "\n";
  exit 0;
}
if ($mode eq 'check') {
  my $role = shift @ARGV // '';
  my $have = <STDIN> // '';
  chomp $have;
  if ($have =~ /^SCRAM-SHA-256\$(\d+):([A-Za-z0-9+\/=]+)\$([A-Za-z0-9+\/=]+):([A-Za-z0-9+\/=]+)$/) {
    my ($iter, $salt) = ($1, decode_base64($2));
    exit(verifier($pw, $salt, $iter) eq $have ? 0 : 1);
  }
  if ($have =~ /^md5[0-9a-f]{32}$/) {
    exit(('md5' . md5_hex($pw . $role)) eq $have ? 0 : 1);
  }
  exit 2;
}
die "usage: pg-scram.pl make | check <role>   (password on stdin)\n";
