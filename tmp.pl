#!/usr/bin/perl

use strict;

open ZIP, "Geo-PostalCode_19991101.txt" or die "Cant find Geo-PostalCode_19991101.txt (download from http://tjmather.com/Geo-PostalCode_19991101.txt.gz)\n";
<ZIP>;
while (<ZIP>) {
  chomp;
  my ($zipcode, $lat, $lon, $city, $state) = split("\t");

  if ($ARGV[1]) {
    next unless $state eq uc($ARGV[1]);
  }
  $city = lc($city);

  my $regexp = join('.*',split('',$ARGV[0]));

  if ($city =~ m!^$regexp!) {
    print "$city\t$state\n";
  }
}
