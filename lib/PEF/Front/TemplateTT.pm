package PEF::Front::TemplateTT;

use strict;
use warnings;
use Data::Dumper;
use Scalar::Util qw(blessed);
use Encode;
use URI::Escape;
use Template::Alloy;
use PEF::Front::Config;
use PEF::Front::Cache;
use PEF::Front::Validator;
use PEF::Front::NLS;
use PEF::Front::Response;

sub handler {
	my ($request, $defaults) = @_;
	my $form          = $request->params;
	my $cookies       = $request->cookies;
	my $logger        = $request->logger;
	my $http_response = PEF::Front::Response->new(base => $request->base);
	my $lang          = $defaults->{lang};
	$http_response->set_cookie(lang => $lang);
	my $template = delete $defaults->{method};
	$template =~ tr/ /_/;
	my $template_file = "$template.html";
	if (!-f cfg_template_dir($request->hostname, $lang) . "/" . $template_file) {
		$logger->({level => "info", message => " template '$template_file' not found"});
		$http_response->status(404);
		return $http_response->response();
	}
	$defaults->{template}  = $template;
	$defaults->{time}      = time;
	$defaults->{gmtime}    = [gmtime];
	$defaults->{localtime} = [localtime];
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
			if ($as
				&& (   (!ref ($as) && $as ne 'template')
					|| (ref ($as) eq 'ARRAY' && !grep { $_ eq 'template' } @$as))
			  )
			{
				$logger->({level => "error", message => "not allowed source"});
				return {
					result      => 'INTERR',
					answer      => 'Unallowed calling source',
					answer_args => []
				};
			}
			my $cache_attr = get_method_attrs($vreq => 'cache');
			my $cache_key;
			if ($cache_attr) {
				$cache_attr = {key => 'method', expires => $cache_attr} if not ref $cache_attr;
				my @keys;
				if (ref ($cache_attr->{key}) eq 'ARRAY') {
					@keys = grep { exists $vreq->{$_} } @{$cache_attr->{key}};
				} elsif (not exists $cache_attr->{key}) {
					@keys = ('method');
				} else {
					@keys = ($cache_attr->{key});
				}
				$cache_attr->{expires} = cfg_cache_method_expire
				  unless exists $cache_attr->{expires};
				$cache_key = join (":", @{$vreq}{@keys});
				$logger->({level => "debug", message => "cache key: $cache_key"});
				$response = get_cache("ajax:$cache_key");
			}
			if (not $response) {
				my $model = get_model($vreq);
				$logger->({level => "debug", message => "model: $model"});
				if (index ($model, "::") >= 0) {
					my $class = substr ($model, 0, rindex ($model, "::"));
					eval "use $class;\n\$response = $model(\$vreq)";
				} else {
					$response = cfg_model_rpc($model)->send_message($vreq)->recv_message;
				}
				if ($@) {
					$logger->({level => "error", message => "error: " . Dumper($model, $@, $vreq)});
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
		INCLUDE_PATH => [cfg_template_dir($request->hostname, $lang)],
		COMPILE_DIR  => cfg_template_cache,
		V2EQUALS     => 0,
		ENCODING     => 'UTF-8',
		COMPILE_PERL => 1,
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
	$http_response->content_type('text/html; charset=utf-8');
	$http_response->set_body('');
	return sub {
		my $responder = $_[0];
		$tt->process($template_file, $defaults, \$http_response->get_body->[0])
		  or $logger->({level => "error", message => "error: " . $tt->error()});
		$responder->($http_response->response());
	};
}

1;
