package Geo::PostalCode;

use strict;
use vars qw($VERSION);
use DB_File;
use POSIX;

$VERSION = '0.01';

use constant EARTH_RADIUS => 3956;
use constant PI => 3.1415;

sub new {
  my ($class, %options) = @_;
  my (%postalcode, %city, %latlon);
  my $db_dir = $options{db_dir};
  tie %postalcode, 'DB_File', "$db_dir/postalcode.db", O_CREAT|O_RDWR, 0666, $DB_BTREE;
  tie %city,       'DB_File', "$db_dir/city.db",       O_CREAT|O_RDWR, 0666, $DB_BTREE;
  tie %latlon,     'DB_File', "$db_dir/latlon.db",     O_CREAT|O_RDWR, 0666, $DB_BTREE;
  bless {postalcode => \%postalcode, city => \%city, latlon => \%latlon}, $class;
}

sub lookup_postal_code {
  my ($self, %options) = @_;
  my $v = $self->{postalcode}->{$options{postal_code}};
  return unless $v;
  my ($lat, $lon, $city, $state) = split(",",$v);
  return {lat => $lat, lon => $lon, city => $city, state => $state};
}

sub lookup_city_state {
  my ($self, %options) = @_;
  my $city_state = uc(join("", $options{state}, $options{city}));
  my $v = $self->{city}->{$city_state};
  return unless $v;
  my ($postal_code_str, $lat, $lon) = split('\|',$v);
  my @postal_codes = ($postal_code_str =~ m!(.{5})!g);
  return {lat => $lat, lon => $lon, postal_codes => \@postal_codes};
}

sub calculate_distance {
  my ($self, %options) = @_;
  my ($a, $b) = @{$options{postal_codes}};
  my $ra = $self->lookup_postal_code(postal_code => $a);
  my $rb = $self->lookup_postal_code(postal_code => $b);
  return unless $ra && $rb;
  return _calculate_distance($ra->{lat}, $ra->{lon}, $rb->{lat}, $rb->{lon});
}

# in miles
sub _calculate_distance {
  my ($lat_1, $lon_1, $lat_2, $lon_2) = @_;

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

  return EARTH_RADIUS * 2 * atan2(sqrt($temp),sqrt(1-$temp));
}

sub nearby_postal_codes {
  my ($self, %options) = @_;
  my ($lat, $lon, $distance) = @options{qw(lat lon distance)};

  my $distance_degrees = (180 / PI) * ($distance / EARTH_RADIUS);
  my $min_lat = floor($lat - $distance_degrees);
  my $min_lon = floor($lon - $distance_degrees);
  my $max_lat = floor($lat + $distance_degrees);
  my $max_lon = floor($lon + $distance_degrees);

  my @postal_codes;
  for my $x ($min_lat .. $max_lat) {
    for my $y ($min_lon .. $max_lon) {
      next unless _calculate_distance($lat, $lon,
				      _test_near($lat, $x),
				      _test_near($lon, $y)) < $distance;
      my $postal_code_str = $self->{latlon}->{"$x-$y"};
      next unless $postal_code_str;
      my @cell_zips = ($postal_code_str =~ m!(.{5})!g);
      if (_calculate_distance($lat, $lon,
			      _test_far($lat, $x),
			      _test_far($lon, $y)) < $distance) {
	# include all of cell
	push @postal_codes, @cell_zips;
      } else {
	# include only postal code with distance
	for (@cell_zips) {
	  my $r = $self->lookup_postal_code(postal_code => $_);
	  next unless $r;
	  my $d = _calculate_distance($lat, $lon, $r->{lat}, $r->{lon});
	  if ($d < $distance) { 
	    push @postal_codes, $_;
	  }
	}
      }
    }
  }
  return \@postal_codes;
}

sub query_postal_codes {
  my ($self, %options) = @_;
  my ($lat, $lon, $distance, $order_by) = @options{qw(lat lon distance order_by)};
  my %select = map {$_ => 1} @{$options{select}};

  my $distance_degrees = (180 / PI) * ($distance / EARTH_RADIUS);
  my $min_lat = floor($lat - $distance_degrees);
  my $min_lon = floor($lon - $distance_degrees);
  my $max_lat = floor($lat + $distance_degrees);
  my $max_lon = floor($lon + $distance_degrees);

  my @postal_codes;
  for my $x ($min_lat .. $max_lat) {
    for my $y ($min_lon .. $max_lon) {
      next unless _calculate_distance($lat, $lon,
				      _test_near($lat, $x),
				      _test_near($lon, $y)) < $distance;
      my $postal_code_str = $self->{latlon}->{"$x-$y"};
      next unless $postal_code_str;
      my @cell_zips = ($postal_code_str =~ m!(.{5})!g);
      if (_calculate_distance($lat, $lon,
			      _test_far($lat, $x),
			      _test_far($lon, $y)) < $distance) {
	# include all of cell
	for (@cell_zips) {
	  my $r = $self->lookup_postal_code(postal_code => $_);
	  next unless $r;
	  my %h = (postal_code => $_);
	  for my $field (keys %select) {
	    if ($field eq 'distance') {
	      my $d = _calculate_distance($lat, $lon, $r->{lat}, $r->{lon});
	      $h{distance} = $d;
	    } else {
	      $h{$field} = $r->{$field};
	    }
	  }
	  push @postal_codes, \%h;
	}
      } else {
	# include only postal code with distance
	for (@cell_zips) {
	  my $r = $self->lookup_postal_code(postal_code => $_);
	  next unless $r;
	  my $d = _calculate_distance($lat, $lon, $r->{lat}, $r->{lon});
	  if ($d < $distance) { 
	    my %h = (postal_code => $_);
	    for my $field (keys %select) {
	      if ($field eq 'distance') {
		$h{distance} = $d;
	      } else {
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
  } elsif ($cell < $center) {
    return $cell + 1;
  } else {
    return $cell;
  }
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

1;
__END__

=head1 NAME

Geo::PostalCode - Find closest postal codes, distance, latitude, and longitude.

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
  my $postal_codes = $record->{postal_codes}:

  my $postal_codes = $gp->find_nearby_postal_codes($lat, $lon,
                                                   miles => 50);

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

=item $gp = Geo::PostalCode->new(db_dir => $db_dir);

Returns a new Geo::PostalCode object using the postalcode.db, latlon.db, and city.db
Berkeley Database files in $db_dir.

=item $record = $gp->lookup_postal_code(postal_code => $postal_code);

Returns a hash reference containing four keys:

=back
=over 8

=item * lat - Latitude

=item * lon - Longitude

=item * city - City

=item * state - State two-letter abbreviation.

=back
=over 4

=item $record = $gp->lookup_city_state(city => $city, state => $state);

Returns a hash reference containing three keys:

=back
=over 8

=item * lat - Latitude (Average over postal codes in city)

=item * lon - Longitude (Average over postal codes in city)

=item * postal_codes - Array reference of postal codes in city

=back
=over 4

=item $miles = $gp->calculate_distance(postal_codes => \@postal_codes);

Returns the distance in miles between the two postal codes in @postal_codes.

=item $postal_codes = $gp->nearby_postal_codes(lat => $lat, lon => $lon, miles => $miles );

Returns an array reference containing postal codes with $miles miles
of ($lat, $lon).

=item $postal_codes = $gp->query_postal_codes(lat => $lat, lon => $lon, miles => $miles, select => \@select, order_by => $order_by );

Returns an array reference of hash references with $miles miles of ($lat, $lon).
Each hash reference contains the following fields:

=back
=over 8

=item * postal_code - Postal Code

=item * lat - Latitude (If included in @select)

=item * lon - Longitude (If included in @select)

=item * city - City (If included in @select)

=item * state - State two-letter abbreviation (If included in @select)

=back
=over 4

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

Copyright (c) 2001, T.J. Mather, tjmather@tjmather.com

All rights reserved.  This package is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=head1 COPYRIGHT

Copyright (c) 2001 T.J. Mather.  Geo::PostalCode is free software;
you may redistribute it and/or modify it under the same terms as Perl itself. 

=head1 SEE ALSO

=over 4

=item * L<Geo::IP> - Look up country by IP Address

=item * zipdy - Free Zip Code Distance Calculator

=back

=cut
