package PEF::Front::Request;
use strict;
use warnings;
use JSON;
use Carp ();
use utf8;
use Encode;
use PEF::Front::Headers;
use PEF::Front::File;

sub new {
	my ($class, $env) = @_;
	Carp::croak(q{$env is required})
	  unless defined $env && ref ($env) eq 'HASH';
	my $self = bless {env => $env}, $class;
	$self->parse;
	$self;
}
sub env              { $_[0]->{env} }
sub remote_ip        { $_[0]->{env}{REMOTE_ADDR} }
sub protocol         { $_[0]->{env}{SERVER_PROTOCOL} }
sub method           { $_[0]->{env}{REQUEST_METHOD} }
sub port             { $_[0]->{env}{SERVER_PORT} }
sub user             { $_[0]->{env}{REMOTE_USER} }
sub request_uri      { $_[0]->{env}{REQUEST_URI} }
sub path_info        { $_[0]->{env}{PATH_INFO} }
sub query_string     { $_[0]->{env}{QUERY_STRING} }
sub script_name      { $_[0]->{env}{SCRIPT_NAME} }
sub scheme           { $_[0]->{env}{'psgi.url_scheme'} }
sub secure           { $_[0]->scheme eq 'https' }
sub input            { $_[0]->{env}{'psgi.input'} }
sub content_length   { $_[0]->{env}{CONTENT_LENGTH} }
sub content_type     { $_[0]->{env}{CONTENT_TYPE} }
sub raw_body         { $_[0]->{raw_body} }
sub content_encoding { $_[0]->headers->get_header("content_encoding") }
sub header           { $_[0]->headers->get_header($_[1]) }
sub referer          { $_[0]->headers->get_header("referer") }
sub user_agent       { $_[0]->headers->get_header("user_agent") }

sub logger {
	$_[0]->{env}{'psgix.logger'} || sub { }
}

sub parse {
	my $self = $_[0];
	$self->_parse_query_params;
	$self->_parse_request_body if $self->method eq 'POST';
}

sub params {
	my $self = $_[0];
	return $self->{params} if exists $self->{params};
	my $q = $self->{query_params} || {};
	my $p = $self->{body_params}  || {};
	$self->{params} = {%$q, %$p};
}

sub path {
	my $self = $_[0];
	return $self->{path} if @_ == 1 and exists $self->{path};
	$self->{path} ||= decode_utf8($self->{env}{PATH_INFO} || '/');
	if (@_ == 2) {
		my $np = (utf8::is_utf8($_[1]) ? $_[1] : decode_utf8 $_[1]);
		if ($np eq '') {
			$self->{path} = '/';
		} else {
			if (substr ($np, 0, 1) ne '/') {
				$self->{path} = substr ($self->{path}, rindex ($self->{path}, '/') + 1) . $np;
			} else {
				$self->{path} = $np;
			}
		}
	}
	return $self->{path};
}

sub param {
	my ($self, $param, $value) = @_;
	return $self->params->{$param} if not defined $value;
	$self->params->{$param} = (utf8::is_utf8($value) ? $value : decode_utf8 $value);
}

sub hostname {
	my $self = $_[0];
	return $self->{hostname} if exists $self->{hostname};
	$self->{hostname} = $self->{env}{HTTP_HOST} || $self->{env}{SERVER_NAME};
	$self->{hostname} =~ s/:\d+//;
	$self->{hostname};
}

sub base {
	my $self = $_[0];
	return $self->{base} if exists $self->{base};
	$self->{base} =
	  $self->scheme . "://" . ($self->{env}{HTTP_HOST} || $self->{env}{SERVER_NAME}) . $self->request_uri;
	$self->{base};
}

sub cookies {
	my $self = $_[0];
	return {} unless $self->{env}{HTTP_COOKIE};
	return $self->{cookies} if exists $self->{cookies};
	my %results;
	my @pairs = grep m/=/, split "[;,] ?", $self->{env}{HTTP_COOKIE};
	for my $pair (@pairs) {
		$pair =~ s/^\s+//;
		$pair =~ s/\s+$//;
		my ($key, $value) =
		  map { tr/+/ /; s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg; decode_utf8 $_ } split ("=", $pair, 2);
		$results{$key} = $value;
	}
	$self->{cookies} = \%results;
}

sub _parse_urlencoded {
	my $query = $_[0];
	my $form  = {};
	my @pairs = split (/[&;]/, $query);
	foreach my $pair (@pairs) {
		my ($name, $value) =
		  map { tr/+/ /; s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg; $_ }
		  split (/=/, $pair, 2);
		eval { $form->{decode_utf8($name)} = decode_utf8 $value if $name };
	}
	return $form;
}

sub headers {
	my $self = shift;
	if (!defined $self->{headers}) {
		my $env = $self->{env};
		$self->{headers} = PEF::Front::HTTPHeaders->new(
			map {
				(my $field = decode_utf8 $_) =~ s/^HTTPS?_//;
				($field => decode_utf8 $env->{$_});
			  }
			  grep {
				/^HTTP/ || /^CONTENT/
			  } keys %$env
		);
	}
	$self->{headers};
}

sub _parse_query_params {
	my $self = $_[0];
	return {} if !$self->{env}{QUERY_STRING};
	return $self->{query_params} if exists $self->{query_params};
	$self->{query_params} = _parse_urlencoded($self->{env}{QUERY_STRING});
}

sub _parse_request_body {
	my $self = $_[0];
	my $ct   = $self->{env}{CONTENT_TYPE};
	my $cl   = $self->{env}{CONTENT_LENGTH};
	if (!$ct && !$cl) {
		return;
	}
	return $self->{body_params} if exists $self->{body_params};
	if (index ($ct, 'application/x-www-form-urlencoded') == 0) {
		$self->{raw_body} = '';
		my $buffer;
		while ($cl && $self->input->read($buffer, $cl)) {
			$self->{raw_body} .= $buffer;
			$cl -= length $buffer;
		}
		$self->{body_params} = _parse_urlencoded($self->{raw_body});
	} elsif (index ($ct, 'application/json') == 0) {
		$self->{raw_body} = '';
		my $buffer;
		while ($cl && $self->input->read($buffer, $cl)) {
			$self->{raw_body} .= $buffer;
			$cl -= length $buffer;
		}
		my $from_json = $self->{raw_body};
		if (substr ($self->{raw_body}, 0, 2) eq '%7') {
			$from_json =~ tr/+/ /;
			$from_json =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
		}
		$self->{body_params} = eval { decode_json $from_json} || {};
		return $self->{body_params};
	} elsif (index ($ct, 'multipart/form-data') == 0) {
		$self->_parse_multipart_form;
	}
	if (exists $self->{body_params}{json}) {
		my $form = eval { from_json $self->{body_params}{json} } || {};
		$self->{body_params} = {%{$self->{body_params}}, %$form};
	}
	return $self->{body_params};
}

sub _parse_multipart_form {
	my $self   = $_[0];
	my $buffer = '';
	my $input  = $self->input;
	my $cl     = $self->{env}{CONTENT_LENGTH};
	my $ct     = $self->{env}{CONTENT_TYPE};
	$self->{body_params} = {};
	my $form = $self->{body_params};
	my ($boundary) = $ct =~ /boundary=\"?([^\";,]+)\"?/;
	return if not defined $boundary;
	my $start_boundary = "--" . $boundary . "\x0d\x0a";
	my $end_boundary   = "--" . $boundary . "--\x0d\x0a";
	my $chl            = 65536;
	my $lchnk          = 0;
	my $current_field;

	while (1) {
		my $chunk;
		my $start = index ($buffer, $start_boundary);
		$start = index ($buffer, $end_boundary) if $start == -1;
		$buffer .= $chunk if $start == -1 && $input->read($chunk, $chl);
		last if $buffer eq '';
		$start = index ($buffer, $start_boundary) if $start == -1;
		$start = index ($buffer, $end_boundary)   if $start == -1;
		my $field_sub = sub {

			if (   $buffer ne ''
				&& $buffer =~ /^Content-Disposition:/
				&& (my $body_start = index ($buffer, "\x0d\x0a\x0d\x0a")))
			{
				my $header = substr ($buffer, 0, $body_start);
				substr ($buffer, 0, $body_start + 4, '');
				my $next_start = index ($buffer, $start_boundary);
				$next_start = index ($buffer, $end_boundary) if $next_start == -1;
				my $current_value;
				if ($next_start >= 0) {
					$current_value = substr ($buffer, 0, $next_start - 2);
					substr ($buffer, 0, $next_start, '');
				} else {
					$current_value = '';
				}
				my ($name) = ($header =~ /name="?([^";\x0d\x0a]*)[";]?/);
				my ($file) = ($header =~ /filename="?([^";\x0d\x0a]*)[";\x0d\x0a]?/);
				my ($type) = ($header =~ /Content-Type:\s*(\S+)/);
				$name ||= '';
				if (defined ($file) && $file ne '') {
					($file) = ($file =~ /([^\/\\:]*)$/);
					$current_field = decode_utf8($name);
					$form->{$current_field} = PEF::Front::File->new(
						filename => decode_utf8($file),
						size     => $cl,
						content_type => $type || 'application/octet-stream', (
							exists ($form->{$current_field . '_id'})
							  && !ref ($form->{$current_field . '_id'})
							? (
								id => $self->remote_ip . "/" . $self->scheme . "/" . $self->hostname . "/" . $form->{$current_field . '_id'})
							: ()
						)
					);
					$current_field = $form->{$current_field};
					$current_field->append($current_value);
				} else {
					$current_field = decode_utf8($name);
					$form->{$current_field} = $current_value;
				}
				$current_field = undef if $next_start >= 0;
				return 1;
			}
			return;
		};
		if ($start >= 0) {
			last if (my $end = index ($buffer, $end_boundary)) == 0;
			my $be = $end == $start ? 2 : 0;
			if (defined $current_field and ref $current_field eq 'PEF::Front::File' and $start > 1) {
				$current_field->append(substr ($buffer, 0, $start - 2));
				$current_field->finish;
				$current_field = undef;
				substr ($buffer, 0, $start + length ($start_boundary) + $be, '');
			} elsif (defined $current_field and $start > 1) {
				$form->{$current_field} .= substr ($buffer, 0, $start - 2);
				$current_field = undef;
				substr ($buffer, 0, $start + length ($start_boundary) + $be, '');
			}
			if (not $field_sub->()) {
				substr ($buffer, 0, $start + length ($start_boundary) + $be, '');
			}
		} else {
			my $store_chunk = $lchnk;
			if (length ($buffer) < $store_chunk + 256) {
				if (length ($buffer) > 512) {
					$store_chunk = length ($buffer) - 256;
				} else {
					$store_chunk = 0;
				}
			}
			if (defined $current_field and ref $current_field eq 'PEF::Front::File') {
				if ($store_chunk) {
					$current_field->append(substr ($buffer, 0, $store_chunk));
					substr ($buffer, 0, $store_chunk, '');
				}
			} elsif (defined $current_field) {
				if ($store_chunk) {
					$form->{$current_field} .= substr ($buffer, 0, $store_chunk);
					substr ($buffer, 0, $store_chunk, '');
				}
			} else {
				$field_sub->();
			}
		}
		$lchnk = length $buffer;
	}
	for my $k (keys %$form) {
		$form->{$k} = decode_utf8 $form->{$k} if not ref $form->{$k};
	}
	return $form;
}
1;
