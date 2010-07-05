#!perl

use strict;
use warnings;

use Test::More tests => 4;
#use Test::More 'no_plan';
use HTTP::LoadGen::Logger;

open my $f1, '>', 'log1' or die "Cannot open log1: $!";
open my $f2, '>', 'log2' or die "Cannot open log2: $!";

my @l=map {HTTP::LoadGen::Logger::get $_} $f1, $f2;

isa_ok $l[0], 'CODE', '$l[0]';
isa_ok $l[1], 'CODE', '$l[1]';

for( my $i=0; $i<10; $i++ ) {
  $l[$i&1]->($i);
}

map {$_->()} @l;

{
  local $/;
  local @ARGV=('log1');
  is scalar(readline), <<'EOF', 'log1 content';
0
2
4
6
8
EOF
}

{
  local $/;
  local @ARGV=('log2');
  is scalar(readline), <<'EOF', 'log2 content';
1
3
5
7
9
EOF
}

unlink 'log1', 'log2';
