package PEF::Front::Ajax;

use strict;
use warnings;
use Encode;
use JSON;
use URI::Escape;
use Template::Alloy;
use Data::Dumper;
use Scalar::Util qw(blessed);
use PEF::Front::Config;
use PEF::Front::Cache;
use PEF::Front::Validator;
use PEF::Front::NLS;
use PEF::Front::Response;

sub ajax {
	my ($request, $defaults) = @_;
	my $form          = $request->params;
	my $cookies       = $request->cookies;
	my $logger        = $request->logger;
	my $http_response = PEF::Front::Response->new(base => $request->base);
	my $lang          = $defaults->{lang};
	my %request       = %$form;
	my $src           = $defaults->{src};
	$request{method} = $defaults->{method};
	$http_response->set_cookie(lang => $lang);
	my $vreq = eval { validate(\%request, $defaults) };
	my $response;
	my $json = $src eq 'ajax';
	my $new_loc;

	if (!$@) {
		my $as = get_method_attrs($vreq => 'allowed_source');
		if ($as
			&& (   (!ref ($as) && $as ne $src)
				|| (ref ($as) eq 'ARRAY' && !grep { $_ eq $src } @$as))
		  )
		{
			$logger->({level => "error", message => "not allowed source $src"});
			$response =
			  {result => 'INTERR', answer => 'Unallowed calling source', answer_args => []};
			goto out;
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
			$cache_attr->{expires} = 60 unless exists $cache_attr->{expires};
			$cache_key = join (":", @{$vreq}{@keys});
			$logger->({level => "debug", message => "cache key: $cache_key"});
			$response = get_cache("ajax:$cache_key");
		}
		if (not $response) {
			my $model = get_model($vreq);
			$logger->({level => "debug", message => "model: $model"});
			if (index ($model, "::") >= 0) {
				my $class = substr ($model, 0, rindex ($model, "::"));
				eval "use $class;\n\$response = $model(\$vreq, \$defaults)";
			} else {
				$response = cfg_model_rpc($model)->send_message($vreq)->recv_message;
			}
			if ($@) {
				$logger->({level => "error", message => "error: " . Dumper($model, $@, $vreq)});
				$response = {result => 'INTERR', answer => 'Internal error', answer_args => []};
				goto out;
			}
			if ($response->{result} eq 'OK' && $cache_attr) {
				set_cache("ajax:$cache_key", $response, $cache_attr->{expires});
			}
		}
		my $result = get_method_attrs($vreq => 'result');
		if (defined ($result)) {
			my $stash = {
				response => $response,
				form     => $form,
				cookies  => $cookies,
				defaults => $defaults,
				request  => $vreq,
				result   => $response->{result},
			};
			my $tt = Template::Alloy->new(
				COMPILE_DIR => cfg_template_cache,
				V2EQUALS    => 0,
				ENCODING    => "UTF-8"
			);
			$stash->{uri_unescape} = sub { uri_unescape @_ };
			my $err;
			($new_loc, $response) =
			  get_method_attrs($vreq => 'result_sub')
			  ->($response, $defaults, $stash, $http_response, $tt, $logger);
		}
	} else {
		$logger->(
			{level => "error", message => "validate error: " . Dumper($@, \%request)});
		$response = (
			ref ($@) eq 'HASH'
			? $@
			: {result => 'INTERR', answer => 'Internal Error', answer_args => []}
		);
	}
	if (exists $response->{answer_headers}
		and 'ARRAY' eq ref $response->{answer_headers})
	{
		while (@{$response->{answer_headers}}) {
			if (ref ($response->{answer_headers}[0])) {
				if (ref ($response->{answer_headers}[0]) eq 'HASH') {
					$http_response->add_header(%{$response->{answer_headers}[0]});
				} else {
					$http_response->add_header(@{$response->{answer_headers}[0]});
				}
				shift @{$response->{answer_headers}};
			} else {
				$http_response->add_header($response->{answer_headers}[0],
					$response->{answer_headers}[1]);
				splice @{$response->{answer_headers}}, 0, 2;
			}
		}
	}
	if (exists $response->{answer_cookies}
		and 'ARRAY' eq ref $response->{answer_cookies})
	{
		while (@{$response->{answer_cookies}}) {
			if (ref ($response->{answer_cookies}[0])) {
				if (ref ($response->{answer_cookies}[0]) eq 'HASH') {
					$http_response->set_cookie(%{$response->{answer_cookies}[0]});
				} else {
					$http_response->set_cookie(@{$response->{answer_cookies}[0]});
				}
				shift @{$response->{answer_cookies}};
			} else {
				$http_response->set_cookie($response->{answer_headers}[0],
					$response->{answer_headers}[1]);
				splice @{$response->{answer_cookies}}, 0, 2;
			}
		}
	}
  out:
	if ($json) {
		if (exists $response->{answer} and not exists $response->{answer_no_nls}) {
			my $args = exists ($response->{answer_args}) ? $response->{answer_args} : [];
			$args ||= [];
			$response->{answer} = msg_get($lang, $response->{answer}, @$args)->{message};
		}
		$http_response->content_type('application/json; charset=utf-8');
		$http_response->set_body(encode_json($response));
		return $http_response->response();
	} else {
		if (exists $response->{answer_status} and $response->{answer_status} > 100) {
			$http_response->status($response->{answer_status});
			if (   $response->{answer_status} > 300
				&& $response->{answer_status} < 400
				&& (my $loc = $http_response->get_header('Location')))
			{
				$new_loc = $loc;
			}
		}
		if (!defined ($new_loc) || $new_loc eq '') {
			$logger->({level => "debug", message => "outputting the answer"});
			my $ct = 'text/html; charset=utf-8';
			if (   exists ($response->{answer_content_type})
				&& defined ($response->{answer_content_type})
				&& $response->{answer_content_type})
			{
				$ct = $response->{answer_content_type};
			} elsif (defined (my $yct = $http_response->content_type)) {
				$ct = $yct;
			}
			$http_response->content_type($ct);
			$http_response->set_body($response->{answer});
			return $http_response->response();
		} else {
			$logger->({level => "debug", message => "setting location: $new_loc"});
			$http_response->redirect($new_loc);
			return $http_response->response();
		}
	}
}

sub handler {
	my $request = $_[0];
	return sub {
		my $responder = $_[0];
		$responder->(ajax($request));
	};
}

1;
