package PEF::Front::Response;
use strict;
use warnings;
use PEF::Front::Config;
use Time::Duration::Parse;
use Encode;
use utf8;
use URI::Escape;
use POSIX 'strftime';

sub new {
	my ($class) = @_;
	my $self = bless {
		status  => 200,
		headers => [],
		body    => [],
		cookies => [],
	}, $class;
	$self;
}

sub add_header {
	my ($self, $key, $value, $intkey) = @_;
	$intkey ||= 'headers';
	push @{$self->{$intkey}}, ($key, $value);
}

sub set_header {
	my ($self, $key, $value, $intkey) = @_;
	$intkey ||= 'headers';
	my $set = 0;
	for (my $i = 0; $i < @{$self->{$intkey}}; $i += 2) {
		if ($self->{$intkey}[$i] eq $key) {
			unless ($set) {
				$self->{$intkey}[$i + 1] = $value;
				$set = 1;
			} else {
				splice(@{$self->{$intkey}}, $i, 2);
				$i -= 2;
			}
		}
	}
	$self->add_header($key, $value, $intkey) unless $set;
}

sub remove_header {
	my ($self, $key, $value, $intkey) = @_;
	$intkey ||= 'headers';
	for (my $i = 0; $i < @{$self->{$intkey}}; $i += 2) {
		if ($self->{$intkey}[$i] eq $key) {
			if (defined $value) {
				if ($self->{$intkey}[$i + 1] eq $value) {
					splice(@{$self->{$intkey}}, $i, 2);
					$i -= 2;
				}
			} else {
				splice(@{$self->{$intkey}}, $i, 2);
				$i -= 2;
			}
		}
	}
}

sub get_header {
	my ($self, $key, $intkey) = @_;
	$intkey ||= 'headers';
	my $value;
	for (my $i = 0; $i < @{$self->{$intkey}}; $i += 2) {
		if ($self->{$intkey}[$i] eq $key) {
			if (defined $value) {
				if (ref($value)) {
					push @{$value}, $self->{$intkey}[$i + 1];
				} else {
					$value = [$value, $self->{$intkey}[$i + 1]];
				}
			} else {
				$value = $self->{$intkey}[$i + 1];
			}
		}
	}
	return $value;
}

sub set_cookie {
	my ($self, $key, $value) = @_;
	$self->set_header($key, $value, 'cookies');
}

sub remove_cookie {
	my ($self, $key) = @_;
	$self->remove_header($key, undef, 'cookies');
}

sub get_cookie {
	my ($self, $key) = @_;
	$self->get_header($key, 'cookies');
}

sub set_body {
	my ($self, $body) = @_;
	$self->{body} = [$body];
}

sub add_body {
	my ($self, $body) = @_;
	push @{$self->{body}}, $body;
}

sub get_body {$_[0]->{body}}

sub status {
	my ($self, $status) = @_;
	$self->{status} = $status if defined $status;
	$self->{status};
}

sub redirect {
	my ($self, $url, $status) = @_;
	if ($url) {
		$status ||= 302;
		$self->set_header(Location => $url);
		$self->status($status);
	}
}

sub content_type {
	my ($self, $type) = @_;
	$self->set_header('Content-Type' => $type) if $type;
	return $self->get_header('Content-Type') if defined wantarray;
}

sub expires {
	my $expires = eval {parse_duration($_[0])} || 0;
	return strftime("%a, %d-%b-%Y %H:%M:%S GMT", gmtime(time + $expires));
}

sub make_headers {
	my ($self) = @_;
	my @headers = map {utf8::is_utf8($_) ? encode_utf8($_) : $_} @{$self->{headers}};
	for (my $i = 0; $i < @{$self->{cookies}}; $i += 2) {
		my $value = $self->{cookies}[$i + 1];
		$value = {value => $value} unless ref($value) eq 'HASH';
		my @cookie =
		  (     URI::Escape::uri_escape($self->{cookies}[$i]) . "="
			  . URI::Escape::uri_escape(utf8::is_utf8($value->{value}) ? encode_utf8($value->{value}) : $value->{value}));
		push @cookie, "domain=" . $value->{domain}            if $value->{domain};
		push @cookie, "path=" . $value->{path}                if $value->{path};
		push @cookie, "expires=" . expires($value->{expires}) if $value->{expires};
		push @cookie, "max-age=" . $value->{"max-age"}        if $value->{"max-age"};
		push @cookie, "secure"                                if $value->{secure};
		push @cookie, "HttpOnly"                              if $value->{httponly};
		push @headers, ('Set-Cookie' => join "; ", @cookie);
	}
	return [$self->status, \@headers];
}

sub response {
	my ($self) = @_;
	my $out = $self->make_headers;
	for (@{$self->{body}}) {
		$_ = encode_utf8($_) if utf8::is_utf8($_);
	}
	push @$out, $self->{body};
	return $out;

}

1;
