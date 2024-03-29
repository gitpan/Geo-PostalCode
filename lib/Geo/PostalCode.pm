package Geo::PostalCode;

use strict;
use vars qw($VERSION);
use DB_File;
use POSIX;

$VERSION = '0.07';

use constant PI => 3.14159265;
use constant LAT_DEGREES => 180;
use constant LON_DEGREES => 360;

# Earth radius in various units
our %_UNITS = (
	       mi    => 3956,
	       km    => 6376.5,
	      );
# Aliases
$_UNITS{$_} = $_UNITS{mi}
  foreach (qw(mile miles));
$_UNITS{$_} = $_UNITS{km}
  foreach (qw(kilometer kilometers));

sub _max
{
  my $max = shift;
  foreach my $v (@_)
  {
    $max = $v
      if ($v > $max);
  }
  $max;
}

sub new {
  my ($class, %options) = @_;
  my $db_dir = $options{db_dir};
  my $btree;
  if ($options{cachesize}) {
    if ($options{cachesize} eq 'max') {
      $options{cachesize} = _max(map { -s "$db_dir/$_.db"} qw(postalcode city latlon));
    }
    $btree = new DB_File::BTREEINFO;
    $btree->{cachesize} = $options{cachesize};
  } else {
    $btree = $DB_BTREE;
  }

  my (%postalcode, %city, %latlon);

  tie %postalcode, 'DB_File', "$db_dir/postalcode.db", O_RDONLY, 0666, $btree
      or die "Couldn't open postalcode.db in $db_dir: $!\n";
  tie %city,       'DB_File', "$db_dir/city.db",       O_RDONLY, 0666, $btree
      or die "Couldn't open city.db in $db_dir: $!\n";
  tie %latlon,     'DB_File', "$db_dir/latlon.db",     O_RDONLY, 0666, $btree
      or die "Couldn't open latlon.db in $db_dir: $!\n";
  my $self = {postalcode => \%postalcode, city => \%city, latlon => \%latlon};

  if ($options{units} && $_UNITS{lc $options{units}})
  {
    $self->{_earth_radius}=$_UNITS{lc $options{units}}
  }
  elsif ($options{earth_radius})
  {
    $self->{_earth_radius} = $options{earth_radius};
  }
  else
  {
    $self->{_earth_radius} = $_UNITS{mi};
  }
  
  bless $self, $class;
}

sub lookup_postal_code {
  my ($self, %options) = @_;
  my $v = $self->{postalcode}->{$options{postal_code}};
  return unless $v;
  my ($lat, $lon, $city, $state) = split(/,/,$v);
  return {lat => $lat, lon => $lon, city => $city, state => $state};
}

sub lookup_city_state {
  my ($self, %options) = @_;
  my $city_state = uc(join("", $options{state}, $options{city}));
  my $v = $self->{city}->{$city_state};
  return unless $v;
  my ($postal_code_str, $lat, $lon) = split(/\|/,$v);
  my @postal_codes = ($postal_code_str =~ m!(.{5})!g);
  return {lat => $lat, lon => $lon, postal_codes => \@postal_codes};
}

sub calculate_distance {
  my ($self, %options) = @_;
  my ($a, $b) = @{$options{postal_codes}};
  my $ra = $self->lookup_postal_code(postal_code => $a);
  my $rb = $self->lookup_postal_code(postal_code => $b);
  return unless $ra && $rb;
  return _calculate_distance($ra->{lat}, $ra->{lon}, $rb->{lat}, $rb->{lon}, $self->{_earth_radius});
}

# in miles
# in miles
sub _calculate_distance {
  my ($lat_1, $lon_1, $lat_2, $lon_2, $rho) = @_;

  # Convert all the degrees to radians
  $lat_1 *= PI/180;
  $lon_1 *= PI/180;
  $lat_2 *= PI/180;
  $lon_2 *= PI/180;

  # Find the deltas
  my $delta_lat = $lat_2 - $lat_1;
  my $delta_lon = $lon_2 - $lon_1;

  # Find the Great Circle distance
  my $temp = sin($delta_lat/2.0)**2 + cos($lat_1) * cos($lat_2) * sin($delta_lon/2.0)**2;

  return $rho * 2 * atan2(sqrt($temp),sqrt(1-$temp));
}

sub nearby_postal_codes {
  my $self = shift;
  [ map { $_->{postal_code} } @{$self->query_postal_codes(@_)}];
}

sub query_postal_codes {
  my ($self, %options) = @_;
  my $pcdb = $self->{postalcode};
  my $lldb = $self->{latlon};
  my ($lat, $lon, $distance, $order_by) = @options{qw(lat lon distance order_by)};
  my %select = map {$_ => 1} @{$options{select}};

  my $distance_degrees = _min($distance/(PI * $self->{_earth_radius} / LAT_DEGREES),
			      LAT_DEGREES);
  my $min_lat = floor($lat - $distance_degrees);
  my $max_lat = floor($lat + $distance_degrees);
  my @postal_codes;
  for my $x ($min_lat .. $max_lat) {
    my $lon_rtw; # Latitude wrapped 'round-the-world, so correct longitude

    # Fix absurdly large latitudes.
    while ($x > LAT_DEGREES)
    {
      $x -= LAT_DEGREES;
    }

    # If we wrapped around a pole, fix up the latitude and set a flag
    # to fix the longitude when we get there.
    if ($x > (LAT_DEGREES/2))
    {
      $x = -$x + LAT_DEGREES;
      $lon_rtw = 1;
    }
    elsif ($x < -(LAT_DEGREES/2))
    {
      $x = -$x - LAT_DEGREES;
      $lon_rtw = 1;
    }
    else
    {
      $lon_rtw = 0;
    }

    # Calculate the number of degrees longitude we need to scan
    my($lon_distance_degrees);
    if ($x==90)  # Special case for north pole
    {
      $lon_distance_degrees=LON_DEGREES/2;
    }
    else
    {
      $lon_distance_degrees = _min($distance / _min($self->_lon_miles($x),$self->_lon_miles($x+1)),
				   LON_DEGREES/2);
    }

    # If the latitude wrapped 'round-the-world and the longitude
    # search diameter extends around the entire world, the search
    # areas for one latitude and its round-the-world counterpart will
    # overlap.  Correct this by shrinking the search area of the
    # wrapped latitude.
    # Yes, this is confusing.
    if ($lon_rtw && $lon_distance_degrees > (LON_DEGREES/4))
    {
      $lon_distance_degrees = LON_DEGREES/2 - $lon_distance_degrees;
    }
    my $min_lon = floor($lon - $lon_distance_degrees);
    my $max_lon = floor($lon + $lon_distance_degrees);

    # Special-case hack:
    # Shrink whole-world searches, to prevent overlap.
    if (($max_lon-$min_lon) == LON_DEGREES)
    {
      $max_lon--;
    }

    for my $y ($min_lon .. $max_lon) {
      # Correct longitude for latitude that wrapped 'round-the-world.
      if ($lon_rtw)
      {
	$y += 180;
      }

      # Correct longitudes that wrap around boundaries
      while ($y > (LON_DEGREES/2))
      {
	$y -= LON_DEGREES;
      }
      while ($y < -(LON_DEGREES/2))
      {
	$y += LON_DEGREES;
      }

      next unless _calculate_distance($lat, $lon,
				      _test_near($lat, $x),
				      _test_near($lon, $y),
				      $self->{_earth_radius}) <= $distance;
      my $postal_code_str = $lldb->{"$x-$y"};
      next unless $postal_code_str;
      my @cell_zips = ($postal_code_str =~ m!(.{5})!g);
      if (_calculate_distance($lat, $lon,
			      _test_far($lat, $x),
			      _test_far($lon, $y),
			      $self->{_earth_radius}) <= $distance) {
	# include all of cell
	for (@cell_zips) {
	  my %h = (postal_code => $_);
	  if ($select{distance}||$select{lat}||$select{lon}||$select{city}||$select{state})
	  {
	    my($rlat,$rlon,undef)=split(/,/,$pcdb->{$_},3);
	    my $r;
	    for my $field (keys %select) {
	      if ($field eq 'distance') {
		$h{distance} = _calculate_distance($lat,$lon,$rlat,$rlon,$self->{_earth_radius});
	      } elsif ($field eq 'postal_code') {
		; # Do Nothing.
	      } elsif ($field eq 'lat') {
		$h{lat} = $rlat;
	      } elsif ($field eq 'lon') {
		$h{lon} = $rlon;
  	      } else {
                $r = $self->lookup_postal_code(postal_code => $_)
		    unless $r;
		$h{$field} = $r->{$field};
	      }
	    }
	  }
	  push @postal_codes, \%h;
	}
      } else {
	# include only postal code with distance
	for (@cell_zips) {
	  # Can we guarantee this will never be undef?...
	  my($rlat,$rlon,undef)=split(/,/,$pcdb->{$_},3);
          my $r;
	  my $d = _calculate_distance($lat, $lon, $rlat, $rlon,$self->{_earth_radius});
	  if ($d <= $distance) { 
	    my %h = (postal_code => $_);
	    for my $field (keys %select) {
	      if ($field eq 'distance') {
		$h{distance} = $d;
	      } elsif ($field eq 'postal_code') {
		; # Do Nothing.
	      } elsif ($field eq 'lat') {
		$h{lat} = $rlat;
	      } elsif ($field eq 'lon') {
		$h{lon} = $rlon;
	      }
	      else { 
                $r = $self->lookup_postal_code(postal_code => $_)
		    unless $r;
		$h{$field} = $r->{$field};
	      }
	    }
	    push @postal_codes, \%h;
	  }
	}
      }
    }
  }
  if ($order_by) {
    if ($order_by eq 'city' || $order_by eq 'state') {
      @postal_codes = sort { $a->{$order_by} cmp $b->{$order_by} } @postal_codes;
    } else {
      @postal_codes = sort { $a->{$order_by} <=> $b->{$order_by} } @postal_codes;
    }
  }
  return \@postal_codes;
}

sub _test_near {
  my ($center, $cell) = @_;
  if (floor($center) == $cell) {
    return $center;
  } elsif ($cell < $center and (_sign($cell)==_sign($center) or $center < (LON_DEGREES/4))) {
    return $cell + 1;
  } else {
    return $cell;
  }
}  

sub _sign
{
  return $_[0]==0?0:($_[0]/abs($_[0]));
}

sub _test_far {
  my ($center, $cell) = @_;
  if (floor($center) == $cell) {
    if ($center - $cell < 0.5) {
      return $cell + 1;
    } else {
      return $cell;
    }
  } elsif ($cell < $center) {
    return $cell;
  } else {
    return $cell + 1;
  }
}

sub _lon_miles
{
  my $self = shift;
  my($lat)=@_;

  # Formula from:
  #   http://www.malaysiagis.com/related_technologies/mapping/basics1b.cfm
  my $r = cos($lat*PI/180)*(2*PI*$self->{_earth_radius}/LON_DEGREES);
  $r;
}

sub _min
{
  return $_[0]<$_[1]?$_[0]:$_[1];
}

1;
__END__

=head1 NAME

Geo::PostalCode - Find closest zipcodes, distance, latitude, and longitude.

=head1 SYNOPSIS

  use Geo::PostalCode;

  my $gp = Geo::PostalCode->new(db_dir => ".");

  my $record = $gp->lookup_postal_code(postal_code => '07302');
  my $lat   = $record->{lat};
  my $lon   = $record->{lon};
  my $city  = $record->{city};
  my $state = $record->{state};

  my $distance = $gp->calculate_distance(postal_codes => ['07302','10004']);

  my $record = $gp->lookup_city_state(city => "Jersey City",state => "NJ");
  my $lat          = $record->{lat};
  my $lon          = $record->{lon};
  my $postal_codes = $record->{postal_codes};

  my $postal_codes = $gp->nearby_postal_codes(lat => $lat, lon => $lon,
                                                   distance => 50);

=head1 DESCRIPTION

Geo::Postalcode is a module for calculating the distance between two postal
codes.  It can find the postal codes within a specified distance of another
postal code or city and state.  It can lookup the city, state, latitude and longitude by
postal code.

The data is from the 1999 US Census database of U.S. Postal Codes,
available from http://www.census.gov/geo/www/tiger/zip1999.html.

To access the data, it uses Berkeley DB, which is fast and portable
(most Linux/Unix servers have it pre-installed.)

=head1 METHODS

=over 4

=item $gp = Geo::PostalCode->new(db_dir => $db_dir,
                                 [cachesize => btree_cache_size | max ,]
                                 [units => mi | km ,]
                                 [earth_radius => earth_radius_in_desired_units ,]
                                );

Returns a new Geo::PostalCode object using the postalcode.db, latlon.db, and city.db
Berkeley Database files in $db_dir.

You can override the cache used by the BTree in L<DB_File|DB_File> by
setting the C<cachesize> parameter to the desired size of the cache,
in bytes.  You can set it to C<max> to set it to the size of the
largest of the databases used.

You can control the distance units used by providing a C<units>
option, which can be C<mi> for miles (the default) or C<km> for
kilometers, or by providing a C<earth_radius> option set to the radius
of the Earth in your desired unit.  The Earth's radius is
approximately 3956 miles.


=item $record = $gp->lookup_postal_code(postal_code => $postal_code);

Returns a hash reference containing four keys:

  * lat - Latitude
  * lon - Longitude
  * city - City
  * state - State two-letter abbreviation.

=item $record = $gp->lookup_city_state(city => $city, state => $state);

Returns a hash reference containing three keys:

  * lat - Latitude (Average over postal codes in city)
  * lon - Longitude (Average over postal codes in city)
  * postal_codes - Array reference of postal codes in city

=item $miles = $gp->calculate_distance(postal_codes => \@postal_codes);

Returns the distance in miles between the two postal codes in @postal_codes.

=item $postal_codes = $gp->nearby_postal_codes(lat => $lat, lon => $lon, distance => $distance );

Returns an array reference containing postal codes with $distance miles
of ($lat, $lon).

=item $postal_codes = $gp->query_postal_codes(lat => $lat, lon => $lon, distance => $distance, select => \@select, order_by => $order_by );

Returns an array reference of hash references with $distance miles of ($lat, $lon).
Each hash reference contains the following fields:

  * postal_code - Postal Code
  * lat - Latitude (If included in @select)
  * lon - Longitude (If included in @select)
  * city - City (If included in @select)
  * state - State two-letter abbreviation (If included in @select)

If $order_by is specified, then the records are sorted by the $order_by field.


=back

=head1 NOTES

This module is in early alpha stage.  It is suggested that you look over
the source code and test cases before using the module.  In addition,
the API is subject to change.

The distance routine is based in the distance routine in Zipdy.
Zipdy is another free zipcode distance calculator, which supports PostgreSQL.
It is available from http://www.cryptnet.net/fsp/zipdy/

=head1 AUTHOR

Copyright (c) 2006, MaxMind LLC, http://www.maxmind.com/

All rights reserved.  This package is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=head1 CREDITS

Thanks to Scott Gifford of http://homesurfusa.com/ for contributing multiple bug fixes and code cleanup.

=head1 SEE ALSO

=over 4

L<Geo::IP> - Look up country and city by IP Address

zipdy - Free Zip Code Distance Calculator

=back

=cut
