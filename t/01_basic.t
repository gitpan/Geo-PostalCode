use strict;
use Test;

$^W = 1;

BEGIN { plan tests => 15 }

use Geo::PostalCode;
use Data::Dumper;

my $gp = Geo::PostalCode->new(db_dir => '.');

my $r = $gp->lookup_postal_code(postal_code => '07302');

ok($r->{state}, 'NJ');
ok($r->{lat}, '+40.726001');
ok($r->{city}, 'JERSEY CITY');
ok($r->{lon}, '-74.047304');

ok(substr($gp->calculate_distance(postal_codes => ['08540','08544']), 0, 4), '2.19');

my @postal_codes = sort @{$gp->nearby_postal_codes(lat => $r->{lat}, lon => $r->{lon}, distance => 2)};

my @expected = qw(07030 07096 07097 07099 07302 07304 07306 07307 07310 07311 07399 10281 10282 10285);

ok(compare_arrays(\@expected, \@postal_codes));

@postal_codes = sort @{$gp->nearby_postal_codes(lat => $r->{lat}, lon => $r->{lon}, distance => 200)};

ok(@postal_codes, 4239);

my $postal_codes = $gp->query_postal_codes(lat => $r->{lat}, lon => $r->{lon}, distance => 2, select => ['distance','city','state','lat','lon'], order_by => 'distance');

my @states = map { $_->{state} } @$postal_codes;

@expected = qw(NJ NJ NJ NJ NJ NJ NJ NJ NJ NJ NJ NY NY NY);

ok(compare_arrays(\@states, \@expected));

$r = $gp->lookup_city_state(city => 'Jersey City', state => 'NJ');

ok(compare_arrays($r->{postal_codes}, [qw(07097 07302 07304 07305 07306 07307 07310 07311 07399)]));
ok($r->{lat}, '40.72819');
ok($r->{lon}, '-74.06449');

$r = $gp->lookup_city_state(city => 'New York', state => 'NY');

$postal_codes = $gp->query_postal_codes(lat => $r->{lat}, lon => $r->{lon}, distance => 26,
	select => ['distance','lat','lon'], order_by => 'distance');

my @a = map { $_->{postal_code} } grep { int($_->{distance}) == 25 } @$postal_codes;
my @b = map { $_->{postal_code} } grep { int($_->{distance}) > 26 } @$postal_codes;

ok (@b, 0);

$postal_codes = $gp->query_postal_codes(lat => $r->{lat}, lon => $r->{lon}, distance => 60,
	select => ['distance','lat','lon'], order_by => 'distance');

my @c = map { $_->{postal_code} } grep { int($_->{distance}) == 25 } @$postal_codes;
@b = map { $_->{postal_code} } grep { int($_->{distance}) > 60 } @$postal_codes;

ok(compare_arrays(\@a,\@c));
ok (@b, 0);

$r = $gp->lookup_city_state(city => 'Asheville', state => 'NC');

$postal_codes = $gp->query_postal_codes(lat => $r->{lat}, lon => $r->{lon}, distance => 60,
	select => ['distance','lat','lon'], order_by => 'distance');
@b = grep { int($_->{distance}) > 60 } @$postal_codes;
ok (@b, 0);
#print Dumper(@b);

sub compare_arrays {
  my ($a, $b) = @_;
  return 0 unless @$a == @$b;
  for my $i (0 .. $#$a){
    return 0 unless $$a[$i] = $$b[$i];
  }
  return 1;
}
