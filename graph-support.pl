#!/usr/bin/perl -w

use strict;
use JSON;
use POSIX;

# List datalink runs in a tar archive
sub list_runs ($) {
  my ( $dirname ) = @_;

  opendir( my $handle, $dirname ) or die qq{$dirname: $!};
  my @ret = grep { m{_datalink_run\d+\.log$} } readdir( $handle );
  closedir $handle or die qq{$!};

  return @ret;
}

sub get_file ($$) {
  my ( $dirname, $inner_filename ) = @_;

  $inner_filename = ($dirname) . q{/} . $inner_filename;

  local $/; # so subsequent <> reads the whole file
  open( my $handle, q{<}, $inner_filename ) or die qq{$inner_filename: $!};
  my $contents = <$handle>;
  close $handle or die qq{$!};

  return $contents;
}

sub get_metadata ($) {
  my ( $dirname ) = @_;
  my $contents = get_file( $dirname, q{pantheon_metadata.json} );

  my $doc = decode_json $contents;

  if ( not defined $doc->{ local_information } ) {
    die qq{Invalid pantheon.json: $contents};
  }

  return $doc;
}

sub analyze_resultset ($) {
  my ( $dirname ) = @_;

  print STDERR qq{Analyzing $dirname.\n};

  # List the datalink runs
  my @runs = list_runs $dirname;

  # Count the schemes, and runs per scheme
  my %schemes;
  for ( @runs ) {
    my ( $scheme, $run_number ) = m{^(.*?)_datalink_run(\d+)\.log$};
    if ( not defined $scheme or not defined $run_number ) {
      die qq{Could not parse run filename: $_};
    }

    $schemes{ $scheme }{ $run_number } = $_;
  }

  print STDERR q{Found } . (scalar @runs ) . qq{ runs in total.\n};
  print STDERR q{Found } . (scalar keys %schemes) . q{ schemes: }
    . (join q{ }, map { qq{$_ (} . (scalar keys %{ $schemes{ $_ } }) . q{)} } keys %schemes )
    . qq{.\n};

  # omit some schemes from analysis
  delete $schemes{ greg_saturator };
  delete $schemes{ saturator };

  # Fetch metadata
  my $metadata = get_metadata $dirname;

  my ( $sender, $receiver );
  if ( $metadata->{ sender_side } eq q{local} ) {
    my $sender_interface = (defined $metadata->{ local_interface })
      ? qq{ ($metadata->{ local_interface })} : q{};
    my $receiver_interface = (defined $metadata->{ remote_interface })
      ? qq{ ($metadata->{ remote_interface })} : q{};
    $sender = qq{$metadata->{ local_information }$sender_interface};
    $receiver = qq{$metadata->{ remote_information }$receiver_interface};
  } else {
    my $sender_interface = (defined $metadata->{ remote_interface })
      ? qq{ ($metadata->{ remote_interface })} : q{};
    my $receiver_interface = (defined $metadata->{ local_interface })
      ? qq{ ($metadata->{ local_interface })} : q{};
    $sender = qq{$metadata->{ remote_information }$sender_interface};
    $receiver = qq{$metadata->{ local_information }$receiver_interface};
  }

  print STDERR qq{Experiment was from $sender => $receiver for $metadata->{ runtime } seconds.\n};

  sub quantile ($@) {
    my ( $quantile, @array ) = @_;
    @array = sort { $a <=> $b } @array;
    my $index_low = floor( $#array * $quantile );
    my $index_high = ceil( $#array * $quantile );
    return ( $array[ $index_low ] + $array[ $index_high ] ) / 2.0;
  }

  sub analyze ($$) {
    my ( $contents, $expected_duration ) = @_;
    my @lines = split m{\n}s, $contents;
    my @timestamps;
    my $total_delivery_bytes = 0;
    my @delays;

  EVENT: for ( @lines ) {
      next EVENT if m{^#};
      my @fields = split m{\s+}, $_;
      my $direction = $fields[ 1 ];
      if ( not defined $direction or ($direction ne q{+} and $direction ne q{-}) ) {
	die qq{Invalid data-link line: $_};
      }

      next EVENT if $direction eq q{+}; # ingress, ignore

      my ( $timestamp, $size, $delay ) = @fields[ 0, 2, 3 ];
      push @timestamps, $timestamp;
      $total_delivery_bytes += $size;
      push @delays, $delay;
    }

    # confirm expected duration
    if ( scalar @timestamps == 0 ) {
      print STDERR qq{(empty) };
      return ( -1, -1 );
    }

    my $duration = ($timestamps[ -1 ] - $timestamps[ 0 ]) / 1000.0;
    if ( $duration < $expected_duration * .9 ) {
      printf STDERR q{(short duration %.0f%%) }, 100 * $duration / $expected_duration;
      return ( -1, -1 );
    } elsif ( $duration > $expected_duration * 1.1 ) {
      printf STDERR q{(long duration %.0f%%) }, 100 * $duration / $expected_duration;
      return ( -1, -1 );
    }

    # calculate throughput and delay
    my $throughput = $total_delivery_bytes / $duration;
    my $p95delay = quantile( .95, @delays );

    return ( $throughput, $p95delay );
  }

  my @all_points;
  my %statistics;
  my %median;
  for my $scheme ( sort keys %schemes ) {
    print STDERR qq{Analyzing $scheme... [ };

  RUN: for my $run_number ( sort { $a <=> $b } keys %{ $schemes{ $scheme } } ) {
      print STDERR qq{$run_number };
      my $log = get_file( $dirname, $schemes{ $scheme }->{ $run_number } );
      my ( $throughput, $p95delay ) = analyze( $log, $metadata->{ runtime } );
      if ( $throughput < 0 ) { # rejected run
	next RUN;
      }

      my $point = { throughput => 8 * 1.e-6 * $throughput, p95delay => $p95delay };
      push @{ $statistics{ $scheme } }, $point;
      push @all_points, $point;
    }

    printf STDERR q{] done (%d/%d used)},
      scalar @{ $statistics{ $scheme } },
      scalar ( keys %{ $schemes{ $scheme } } );

    $median{ $scheme }{ throughput } = quantile( 0.5, map { $_->{ throughput } } @{ $statistics{ $scheme } } );
    $median{ $scheme }{ delay } = quantile( 0.5, map { $_->{ p95delay } } @{ $statistics{ $scheme } } );

    printf STDERR qq{ (median throughput: %.3f Mbit/s, p95delay: %.0f ms)\n},
      $median{ $scheme }{ throughput }, $median{ $scheme }{ delay };
  }

  my $minimum_throughput = quantile( 0.0, map { $_->{ throughput } } @all_points );
  my $maximum_throughput = quantile( 1.0, map { $_->{ throughput } } @all_points );
  my $minimum_delay = quantile( 0.0, map { $_->{ p95delay } } @all_points );
  my $maximum_delay = quantile( 1.0, map { $_->{ p95delay } } @all_points );

  my %ret;
  $ret{ all_points } = \@all_points;
  $ret{ statistics } = \%statistics;
  $ret{ median } = \%median;
  $ret{ limits } = [ $minimum_throughput, $maximum_throughput, $minimum_delay, $maximum_delay ];

  return \%ret;
}

1;