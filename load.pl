#!/usr/bin/perl

use DB_File;
use strict;
use POSIX;

use vars qw($ZIP $DEFZIP);
$DEFZIP = "Geo-PostalCode_19991101.txt";
if ($ARGV[0])
{
  $ZIP=$ARGV[0];
}
else
{
  $ZIP=$DEFZIP;
}

use constant ZIPCODEDB => 'postalcode.db';
use constant CELLDB    => 'latlon.db';
use constant CITYDB    => 'city.db';

my (%zipcode, %cell, %city, %lat, %lon);

unlink ZIPCODEDB if -f ZIPCODEDB;
unlink CELLDB    if -f CELLDB;
unlink CITYDB    if -f CITYDB;

tie (%zipcode, 'DB_File', ZIPCODEDB, O_RDWR|O_CREAT, 0666, $DB_BTREE) or die "cannot tie %zipcode to file";
tie (%cell,    'DB_File', CELLDB,    O_RDWR|O_CREAT, 0666, $DB_BTREE) or die "cannot tie %cell to file";
tie (%city,    'DB_File', CITYDB,    O_RDWR|O_CREAT, 0666, $DB_BTREE) or die "cannot tie %city to file";

if (!open ZIP)
{
  if ($ZIP eq $DEFZIP)
  {
    die "Cant find '$DEFZIP' (download from http://tjmather.com/$DEFZIP.gz)\n";
  }
  else
  {
    die "Can't open input file '$ZIP'\n";
  }
}

<ZIP>;
while (<ZIP>) {
  chomp;
  my ($zipcode, $lat, $lon, $city, $state) = split("\t");

  $zipcode{$zipcode} = "$lat,$lon,$city,$state";
  $lat{$zipcode} = $lat;
  $lon{$zipcode} = $lon;

  my $int_lat = floor($lat);
  my $int_lon = floor($lon);

  $cell{"$int_lat-$int_lon"} .= $zipcode;
  $city{"$state$city"} .= $zipcode;
}

foreach my $k (keys %city) {
  my $v = $city{$k};
  my @postal_codes = ($v =~ m!(.{5})!g);
  next unless @postal_codes;
  my ($tot_lat, $tot_lon, $count) = (0,0,0,0);
  for (@postal_codes) {
    $tot_lat += $lat{$_};
    $tot_lon += $lon{$_};
    $count++;
  }
  my $avg_lat = sprintf("%.5f",$tot_lat/$count);
  my $avg_lon = sprintf("%.5f",$tot_lon/$count);
  $city{$k} = "$v|$avg_lat|$avg_lon";
}

untie %zipcode;
untie %cell;
untie %city;
