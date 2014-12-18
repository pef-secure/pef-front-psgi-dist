package PEF::Front::Headers;
use strict;
use warnings;
use PEF::Front::Config;
use Time::Duration::Parse;
use Encode;
use utf8;
use URI::Escape;
use POSIX 'strftime';
use List::Util qw(pairgrep pairvalues);

sub new {
	my $self = bless [], $_[0];
	for (my $i = 1 ; $i < @_ ; $i += 2) {
		$self->add_header($_[$i], $_[$i + 1]);
	}
	$self;
}

sub add_header {
	my ($self, $key, $value) = @_;
	push @$self, ($key, $value);
}

sub set_header {
	my ($self, $key, $value) = @_;
	my $set = 0;
	for (my $i = 0 ; $i < @$self ; $i += 2) {
		if ($self->[$i] eq $key) {
			unless ($set) {
				$self->[$i + 1] = $value;
				$set = 1;
			} else {
				splice @$self, $i, 2;
				$i -= 2;
			}
		}
	}
	$self->add_header($key, $value) unless $set;
}

sub remove_header {
	my ($self, $key, $value) = @_;
	for (my $i = 0 ; $i < @$self ; $i += 2) {
		if ($self->[$i] eq $key) {
			if (defined $value) {
				if ($self->[$i + 1] eq $value) {
					splice @$self, $i, 2;
					$i -= 2;
				}
			} else {
				splice @$self, $i, 2;
				$i -= 2;
			}
		}
	}
}

sub get_header {
	my ($self, $key) = @_;
	no warnings 'once';
	my @h = pairgrep { $a eq $key } @$self;
	if (@h == 2) {
		$h[1];
	} else {
		[pairvalues @h];
	}
}

sub get_all_headers {
	my ($self) = @_;
	[@$self];
}

package PEF::Front::HTTPHeaders;
our @ISA = qw(PEF::Front::Headers);

sub new {
	"$_[0]"->SUPER::new(@_[1 .. $#_]);
}

sub _canonical {
	(my $h = lc $_[0]) =~ tr/_/-/;
	$h =~ s/\b(\w)/\u$1/g;
	$h;
}

sub add_header {
	my ($self, $key, $value) = @_;
	$self->SUPER::add_header(_canonical($key), $value);
}

sub set_header {
	my ($self, $key, $value) = @_;
	$self->SUPER::set_header(_canonical($key), $value);
}

sub remove_header {
	my ($self, $key, $value) = @_;
	$self->SUPER::remove_header(_canonical($key), $value);
}

sub get_header {
	my ($self, $key) = @_;
	$self->SUPER::get_header(_canonical($key));
}

1;
