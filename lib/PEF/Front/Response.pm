package PEF::Front::Response;
use strict;
use warnings;
use PEF::Front::Config;
use Time::Duration::Parse;
use Encode;
use utf8;
use URI::Escape;
use POSIX 'strftime';
use PEF::Front::Headers;

sub new {
	my ($class) = @_;
	my $self = bless {
		status  => 200,
		headers => PEF::Front::HTTPHeaders->new,
		cookies => PEF::Front::Headers->new,
		body    => [],
	}, $class;
	$self;
}

sub add_header {
	my ($self, $key, $value) = @_;
	$self->{headers}->add_header($key, $value);
}

sub set_header {
	my ($self, $key, $value) = @_;
	$self->{headers}->set_header($key, $value);
}

sub remove_header {
	my ($self, $key, $value) = @_;
	$self->{headers}->remove_header($key, $value);
}

sub get_header {
	my ($self, $key) = @_;
	$self->{headers}->get_header($key);
}

sub set_cookie {
	my ($self, $key, $value) = @_;
	$self->{cookies}->set_header($key, $value);
}

sub remove_cookie {
	my ($self, $key) = @_;
	$self->{cookies}->remove_header($key);
}

sub get_cookie {
	my ($self, $key) = @_;
	$self->{cookies}->get_header($key);
}

sub set_body {
	my ($self, $body) = @_;
	$self->{body} = [$body];
}

sub add_body {
	my ($self, $body) = @_;
	push @{$self->{body}}, $body;
}

sub get_body { $_[0]->{body} }

sub status {
	my ($self, $status) = @_;
	$self->{status} = $status if defined $status;
	$self->{status};
}

sub redirect {
	my ($self, $url, $status) = @_;
	if ($url) {
		$self->set_header(Location => $url);
		if (!defined $status) {
			$status ||= $self->status;
			$self->status(302) if $status < 300 || $status > 399;
		} else {
			$self->status($status);
		}
		$self->remove_header('Content-Type');
	}
}

sub content_type {
	my ($self, $type) = @_;
	$self->set_header('Content-Type' => $type) if $type;
	return $self->get_header('Content-Type') if defined wantarray;
}

sub expires {
	my $expires = eval { parse_duration($_[0]) } || 0;
	return strftime("%a, %d-%b-%Y %H:%M:%S GMT", gmtime (time + $expires));
}

sub safe_encode_utf8 {
	return encode_utf8($_[0]) if not ref ($_[0]) && utf8::is_utf8($_[0]);
	$_[0];
}

sub make_headers {
	my ($self) = @_;
	my $headers = $self->{headers}->get_all_headers;
	for (@$headers) {
		$_ = encode_utf8($_) if utf8::is_utf8($_);
	}
	my $cookies = $self->{cookies}->get_all_headers;
	for (my $i = 0 ; $i < @$cookies ; $i += 2) {
		my $name  = safe_encode_utf8($cookies->[$i]);
		my $value = $cookies->[$i + 1];
		$value = {value => $value} unless ref ($value) eq 'HASH';
		no utf8;
		my @cookie =
		  (URI::Escape::uri_escape($name) . "=" . URI::Escape::uri_escape(safe_encode_utf8($value->{value})));
		push @cookie, "domain=" . $value->{domain}            if $value->{domain};
		push @cookie, "path=" . $value->{path}                if $value->{path};
		push @cookie, "expires=" . expires($value->{expires}) if $value->{expires};
		push @cookie, "max-age=" . $value->{"max-age"}        if $value->{"max-age"};
		push @cookie, "secure"                                if $value->{secure};
		push @cookie, "HttpOnly"                              if $value->{httponly};
		push @$headers, ('Set-Cookie' => join "; ", @cookie);
	}
	return [$self->status, $headers];
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
