=head1 NAME

Algorithm::QuineMcCluskey - solve Quine-McCluskey set-cover problems

=cut

package Algorithm::QuineMcCluskey;

use strict;
use warnings;

use Algorithm::QuineMcCluskey::Util qw(
	bin columns diffpos diffposes hdist maskmatch maskmatches remel stl tobit
	uniqels
);
use Alias 'attr';
use Carp qw(carp croak);
use Data::Dumper;
use List::Compare::Functional qw(:main is_LequivalentR);
use List::MoreUtils qw(pairwise firstidx uniq);
use List::Util qw(sum min);
use Tie::Cycle;

$Alias::AttrPrefix = 'main::';	# Compatibility with use strict 'vars'

=head1 VERSION

This document describes version 0.01 released 24 June 2006.

=cut

our $VERSION = 0.01;

=head1 SYNOPSIS

	use Algorithm::QuineMcCluskey;

	# Five-bit, 12-minterm Boolean expression test with don't-cares
	my $q = new Algorithm::QuineMcCluskey(
		width => 5,
		minterms => [ qw(0 5 7 8 10 11 15 17 18 23 26 27) ],
		dontcares => [ qw(2 16 19 21 24 25) ]
	);
	my @result = $q->solve;
	# @result is (
	# 	"(B'CE) + (C'E') + (AC') + (A'BDE)"
	# );

=head1 DESCRIPTION

NOTE: This module's API is NOT STABLE; the next version should support
multiple-output problems and will add more object-oriented features, but in
doing so will change the API. Upgrade at your own risk.

This module feebly stabs at providing solutions to Quine-McCluskey set-cover
problems, which are used in electrical engineering/computer science to find
minimal hardware implementations for a given input-output mapping. Since this
problem is NP-complete, and since this implementation uses no heuristics, it is
not expected to be useful for real-world problems.

The module is used in an object-oriented fashion; all necessary arguments can
be (and currently must be) provided to the constructor. Unless only a certain
step of is required, the whole algorithm is set off by calling solve() on an
Algorithm::QuineMcCluskey object; this method returns a list of boolean
expressions (as strings) representing valid solutions for the given inputs (see
the C<SYNOPSIS>).

=cut

################################################################################
# Sub / method definitions
################################################################################

=head1 METHODS

=over 4

=item new

Default constructor

=cut

sub new {
	my $type = shift;
	my %def_prefs = (
			minonly	=> 1
	);
	my $self = bless {
		bits		=> [],
		boolean		=> [],
		covers		=> [],
		dc			=> '-',
		dontcares	=> [],
		minterms	=> [],
		maxterms	=> [],
		vars		=> [ 'A'..'Z' ],
		ess			=> {},
		imp			=> {},
		primes		=> {},
		width		=> undef,
		# Accept dash-prefixed or "normal" options
		map { substr($_, /^-/) => {@_}->{$_} } keys %{{ @_ }}
	}, $type;
	
	attr $self;
	# Insert default preferences
	defined $::prefs{$_} or $::prefs{$_} = $def_prefs{$_} for keys %def_prefs;
	
	if (defined %::minterms or defined %::maxterms) {
		$self->prep_mopi;
	}
	attr $self;	# Rebuild new structure
	# Catch errors
	croak "Mixing minterms and maxterms not allowed"
		if @::minterms * @::maxterms;
	croak "Must supply either minterms or maxterms"
		unless @::minterms + @::maxterms;

	# Convert terms to strings of bits if necessary
	unless ((sum map { $::width == length } (@::minterms, @::maxterms))
				== @::minterms + @::maxterms) {
		no strict 'refs';
		@{"::$_"} = map { tobit $_, $::width } @{"::$_"}
			for qw(minterms maxterms dontcares);
	}

	$self;
}

=item find_primes

Finding prime essentials

=cut

sub find_primes {
	my $self = attr shift;

	# Separate into bins based on number of 1's
	push @{ $::bits[0][ sum stl $_ ] }, $_
		for (@::minterms, @::maxterms, @::dontcares);

	for my $level (0 .. $::width) {
		# Skip if we haven't generated such data
		last unless ref $::bits[$level];
		# Find pairs with Hamming distance of 1
		for my $low (0 .. $#{ $::bits[$level] }) {
			# These nested for-loops get all permutations of adjacent sets
			for my $lv (@{ $::bits[$level][$low] }) {
				$::imp{$lv} ||= 0;	# Initialize the implicant as unused
				# Skip ahead if we don't have this data FIXME: explain
				next unless ref $::bits[$level][$low + 1];
				for my $hv (@{ $::bits[$level][$low + 1] }) {
					$::imp{$hv} ||= 0;	# Initialize the implicant
					if (hdist($lv, $hv) == 1) {
						my $new = $lv;	# or $hv
						substr($new, diffpos($lv, $hv), 1) = $::dc;
						# Save new implicant to next level
						push @{ $::bits[$level + 1][$low + 1] }, $new;
						# Mark two used values as used
						@::imp{$lv,$hv} = (1, 1);
					}
				}
			}
		}
	}
	%::primes = map { $_ => [ maskmatches($_, @::minterms, @::maxterms) ] }
		grep { !$::imp{$_} } keys %::imp;
}


=item row_dom

Row-dominance

=cut

sub row_dom {
	my $self = attr shift;
	my $primes = shift || \%::primes;

	$primes = { map {
		my $o = $_;
		(sum map {
			is_LsubsetR([ $primes->{$o} => $primes->{$_} ])
				&& !is_LequivalentR([ $primes->{$o} => $primes->{$_} ])
			} grep { $_ ne $o } keys %$primes)
		? () : ( $_ => $primes->{$_} )
	} keys %$primes };
	%$primes;
}

=item col_dom

Column-dominance

=cut

sub col_dom {
	my $self = attr shift;
	my $primes = shift || \%::primes;

	my %cols = columns $primes, @::minterms, @::maxterms;
	for my $col1 (keys %cols) {
		for my $col2 (keys %cols) {
			next if $col1 eq $col2;
			
			# If col1 is a non-empty proper subset of col2, remove col2
			if (@{ $cols{$col1} }
					and is_LsubsetR			([ $cols{$col1} => $cols{$col2} ])
					and !is_LequivalentR	([ $cols{$col1} => $cols{$col2} ]))
			{
				remel $col2, $primes->{$_} for keys %$primes;
			}
		}
	}
	%$primes;
}

=item find_essentials

Finding essential prime implicants

=cut

sub find_essentials {
	my $self = attr shift;
	%::ess = ();
	my $primes = @_ ? shift : \%::primes;
	my @terms = @_ ? @{ shift() } : (@::minterms, @::maxterms);

	for my $term (@terms) {
		my $ess = ( map { @$_ == 1 ? @$_ : undef } [ grep {
			grep { $_ eq $term } @{ $primes->{$_} }
		} keys %$primes ] )[0];
		# TODO: It would be nice to track the terms that make this essential
		$::ess{$ess}++ if $ess;
	}
	%::ess;
}

=item purge_essentials

Delete essential primes from table

=cut

sub purge_essentials {
	my $self = attr shift;
	my %ess = @_ ? %{ shift() } : %::ess;
	my $primes = shift || \%::primes;
	# Delete columns associated with this term
	for my $col (keys %$primes) {
		remel $_, $primes->{$col} for keys %ess;
	}
	delete ${$primes}{$_} for keys %ess;
	%ess;
}

=item to_boolean

Generating Boolean expressions

=cut

sub to_boolean {
	my $self = attr shift;

	# Group separators (grouping character pairs)
	my @gs = ('(', ')');
	# Group joiner, element joiner, match condition
	my ($gj, $ej, $cond) = @::minterms ? (' + ', '', 1) : ('', ' + ', 0);
	tie my $var, 'Tie::Cycle', [ @::vars[0 .. $::width - 1] ];

	push @::boolean,
		join $gj, map { $gs[0] . (
			join $ej, map {
				my $var = $var;	# Activate cycle even if not used
				$_ eq $::dc ? () : $var . ($_ == $cond ? '' : "'")
			} stl $_) . $gs[1]
		} @$_
		for @::covers;

	@::boolean;
}

=item solve

Main solution sub (wraps recurse_solve())

=cut

sub solve {
	my $self = attr shift;
	%::primes or $self->find_primes;
	@::covers = $self->recurse_solve($self->{primes});
	$self->to_boolean;
}

=item recurse_solve

Recursive divide-and-conquer solver

=cut

sub recurse_solve {
	my $self = attr shift;
	my %primes = %{ $_[0] };
	my @prefix;
	my @covers;

	# begin (slightly) optimized block : do not touch without good reason
	my %ess = $self->find_essentials(\%primes);
	$self->purge_essentials(\%ess, \%primes);
	push @prefix, grep { $ess{$_} } keys %ess;
	$self->row_dom(\%primes);
	$self->col_dom(\%primes);
	while (!is_LequivalentR([
			[ keys %ess ] => [ %ess = $self->find_essentials(\%primes) ]
			])) {
		$self->purge_essentials(\%ess, \%primes);
		push @prefix, grep { $ess{$_} } keys %ess;
		$self->row_dom(\%primes);
		$self->col_dom(\%primes);
	}
	# end optimized block
	unless (keys %primes) {
		return [ reverse sort @prefix ];
	}
	# Find the term with the fewest implicant covers
	# Columns actually in %primes
	my @t = grep {
		my $o = $_;
		sum map { sum map { $_ eq $o } @$_ } values %primes
	} (@::minterms, @::maxterms);
	# Flip table so terms are keys
	my %ic = columns \%primes, @t;
	my $term = (sort { @{ $ic{$a} } <=> @{ $ic{$b} } } keys %ic)[0];
	# Rows of %primes that contain $term
	my @ta = grep { sum map { $_ eq $term } @{ $primes{$_} } } keys %primes;
	
	# For each such cover, recursively solve the table with that column removed
	# and add the result(s) to the covers table after adding back the removed
	# term
	for my $ta (@ta) {
		my %reduced = map {
			$_ => [ grep { $_ ne $term } @{ $primes{$_} } ]
		} keys %primes;
		# Use this prime implicant -- delete its row and columns
		remel $ta, $reduced{$_} for keys %reduced;
		delete $reduced{$ta};
		# Remove empty rows (necessary?)
		%reduced = map { $_ => $reduced{$_} } grep { @{ $reduced{$_} } } keys %reduced;
		
		my @c = $self->recurse_solve(\%reduced);
		my @results = $::prefs{sortterms}
			? @c
				? map { [ reverse sort (@prefix, $ta, @$_) ] } @c
				: [ reverse sort (@prefix, $ta) ]
			: @c
				? map { [ @prefix, $ta, @$_ ] } @c
				: [ @prefix, $ta ];
		push @covers, @results;
	}

	# Weed out expensive solutions
	sub cost { sum map { /$::dc/ ? 0 : 1 } stl join '', @{ shift() } }
	my $mincost = min map { cost $_ } @covers;
	@covers = grep { cost($_) == $mincost } @covers if $::prefs{minonly};
	# Return our covers table to be treated similarly one level up
	# FIXME: How to best ensure non-duplicated answers?
	return uniqels @covers;
}

1;
__END__

=back

=head1 BUGS

Probably. The tests aren't complete enough, and the documentation is far from
complete. Features missing include multiple-output support, which is
in-progress but will require at least some rewriting to keep the code minimally
ugly.

Please report any bugs or feature requests to C<bug-algorithm-quinemccluskey at
rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Algorithm-QuineMcCluskey>.  I
will be notified, and then you'll automatically be notified of progress on your
bug as I make changes.

=head1 SUPPORT

Feel free to contact me at the email address below if you have any questions,
comments, suggestions, or complaints with regard to this module.

You can find documentation for this module with the perldoc command.

    perldoc Algorithm::QuineMcCluskey

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Algorithm-QuineMcCluskey>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Algorithm-QuineMcCluskey>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Algorithm-QuineMcCluskey>

=item * Search CPAN

L<http://search.cpan.org/dist/Algorithm-QuineMcCluskey>

=back


=head1 AUTHOR

Darren M. Kulp C<< <darren@kulp.ch> >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2006 by Darren Kulp

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut

