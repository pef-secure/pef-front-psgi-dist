package PEF::Front::TemplateHtml;

use strict;
use warnings;
use Data::Dumper;
use Encode;
use URI::Escape;
use Template::Alloy;
use PEF::Front::Config;
use PEF::Front::Cache;
use PEF::Front::Validator;
use PEF::Front::NLS;
use PEF::Front::Response;

sub handler {
	my $request       = $_[0];
	my $form          = $request->params;
	my $cookie        = $request->cookies;
	my $log           = $request->logger;
	my $http_response = PEF::Front::Response->new();
	my $lang;
	my ($template, $params);
	if (url_contains_lang) {
		($lang, $template, $params) = $request->path =~ m{^/([\w][\w])/app([^/]+)/?(.*)$};
		if (not defined $lang) {
			$http_response->redirect(301, location_error);
			return $http_response->response();
		}
	} else {
		($template, $params) = $request->path =~ m{^/app([^/]+)/?(.*)$};
		if (not defined $template) {
			$http_response->redirect(301, location_error);
			return $http_response->response();
		}
		$lang = guess_lang($request);
	}
	$http_response->set_cookie(lang => $lang);
	if ($params) {
		my @params = split /\//, $params;
		for my $pv (@params) {
			my ($p, $v) = map { tr/+/ /; decode_utf8 $_} split /-/, uri_unescape($pv), 2;
			if (!defined ($v)) {
				$v = $p;
				$p = 'cookie';
			}
			if (not exists $form->{$p}) {
				$form->{$p} = $v;
			} else {
				if (ref ($form->{$p})) {
					push @{$form->{$p}}, $v;
				} else {
					$form->{$p} = [$form->{$p}, $v];
				}
			}
		}
	}
	$template = decode_utf8($template);
	$template =~ s/[[:lower:]]\K([[:upper:]])/_\l$1/g;
	$template = lcfirst $template;
	my $template_file = "$template.html";
	if (!-f template_dir($request->hostname, $lang) . "/" . $template_file) {
		$log->({level => "debug", message => " template '$template_file' not found"});
		$http_response->redirect(301, location_error);
		return $http_response->response();
	}
	my $defaults = {
		ip        => $request->remote_ip,
		lang      => $lang,
		domain    => $request->hostname,
		path_info => decode_utf8($request->path),
		form      => $form,
		cookie    => $cookie,
		headers   => $request->headers,
		template  => $template,
		time      => time,
		gmtime    => [gmtime],
		localtime => [localtime],
		(exists ($cookie->{auth})     ? (auth     => $cookie->{auth})     : ()),
		(exists ($cookie->{auth_adm}) ? (auth_adm => $cookie->{auth_adm}) : ()),
	};
	my $model = sub {
		my %req;
		my $method;
		for (@_) {
			if (ref) {
				%req = (%$_, %req);
			} else {
				$method = $_;
			}
		}
		$req{method} = $method if defined $method;
		my $vreq = eval { validate(\%req, $defaults) };
		my $response;
		if (!$@) {
			my $as = get_method_attrs($vreq => 'allowed_source');
			if ($as && ((!ref ($as) && $as ne 'template') || (ref ($as) eq 'ARRAY' && !grep { $_ eq 'template' } @$as))) {
				$log->({level => "debug", message => "not allowed source"});
				return {result => 'INTERR', answer => 'Unallowed calling source', answer_args => []};
			}
			my $cache_attr = get_method_attrs($vreq => 'cache');
			my $cache_key;
			if ($cache_attr) {
				my @keys;
				if (not exists $cache_attr->{key}) {
					@keys = ('method');
				} elsif (ref ($cache_attr->{key}) eq 'ARRAY') {
					@keys = grep { exists $vreq->{$_} } @{$cache_attr->{key}};
				} elsif (ref ($cache_attr->{key}) eq '') {
					@keys = ($cache_attr->{key});
				} else {
					@keys = ('method');
				}
				$cache_attr->{expires} = 60 unless exists $cache_attr->{expires};
				$cache_key = join (":", @{$vreq}{@keys});
				$log->({level => "debug", message => "cache key: $cache_key"});
				$response = get_cache("ajax:$cache_key");
			}
			if (not $response) {
				my $model = get_model($vreq);
				$log->({level => "debug", message => "model: $model"});
				if (index ($model, "::") >= 0) {
					my $class = substr ($model, 0, rindex ($model, "::"));
					eval "use $class;\n\$response = $model(\$vreq)";
				} else {
					$response = model_rpc($model)->send_message($vreq)->recv_message;
				}
				if ($@) {
					$log->({level => "debug", message => "error: " . Dumper($model, $@, $vreq)});
					return {result => 'INTERR', answer => 'Internal error', answer_args => []};
				}
				if ($response->{result} eq 'OK' && $cache_attr) {
					set_cache("ajax:$cache_key", $response, $cache_attr->{expires});
				}
			}
		}
		return $response;
	};
	my $tt = Template::Alloy->new(
		INCLUDE_PATH => [template_dir($request->hostname, $lang)],
		COMPILE_DIR  => template_cache,
		V2EQUALS     => 0,
		ENCODING     => 'UTF-8',

	);
	$tt->define_vmethod('text', model => $model);
	$tt->define_vmethod('hash', model => $model);
	$tt->define_vmethod(
		'text',
		msg => sub {
			my ($msgid, @params) = @_;
			msg_get($lang, $msgid, @params)->{message};
		}
	);
	$tt->define_vmethod(
		'text',
		uri_unescape => sub {
			uri_unescape(@_);
		}
	);
	$tt->define_vmethod(
		'text',
		strftime => sub {
			return if ref $_[1] ne 'ARRAY';
			strftime($_[0], @{$_[1]});
		}
	);
	$tt->define_vmethod(
		'text',
		gmtime => sub {
			return [gmtime ($_[0])];
		}
	);
	$tt->define_vmethod(
		'text',
		localtime => sub {
			return [localtime ($_[0])];
		}
	);
	$tt->define_vmethod(
		'text',
		response_content_type => sub {
			$http_response->content_type($_[0]);
			return;
		}
	);
	$tt->define_vmethod(
		'text',
		request_get_header => sub {
			return $request->headers->get_header($_[0]);
		}
	);
	$tt->define_vmethod(
		'text',
		response_set_header => sub {
			$http_response->set_header(@_);
			return;
		}
	);
	$tt->define_vmethod(
		'text',
		response_set_cookie => sub {
			$http_response->set_cookie(@_);
			return;
		}
	);
	$tt->define_vmethod(
		'text',
		response_set_status => sub {
			$http_response->status(@_);
			return;
		}
	);
	$http_response->content_type('text/html');
	$http_response->set_body('');
	return sub {
		my $responder = $_[0];
		$tt->process($template_file, $defaults, \$http_response->get_body->[0])
		  or $log->({level => "debug", message => "error: " . $tt->error()});
		$responder->($http_response->response());
	};
}

1;
