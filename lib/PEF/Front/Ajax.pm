package PEF::Front::Ajax;

use strict;
use warnings;
use Encode;
use JSON;
use URI::Escape;
use Template::Alloy;
use Data::Dumper;
use PEF::Front::Config;
use PEF::Front::Cache;
use PEF::Front::Validator;
use PEF::Front::NLS;
use PEF::Front::Response;

sub ajax {
	my $request       = $_[0];
	my $form          = $request->params;
	my $cookies       = $request->cookies;
	my $log           = $request->logger;
	my $http_response = PEF::Front::Response->new();
	my $lang;
	my ($src, $method, $params);

	if (url_contains_lang) {
		($lang, $src, $method, $params) = $request->path =~ m{^/([\w][\w])/(ajax|submit|get)([^/]+)/?(.*)$};
		if (not defined $lang) {
			$http_response->redirect(301, location_error);
			return $http_response->response();
		}
	} else {
		($src, $method, $params) = $request->path =~ m{^/(ajax|submit|get)([^/]+)/?(.*)$};
		if (not defined $method) {
			$http_response->redirect(301, location_error);
			return $http_response->response();
		}
		$lang = guess_lang($request);
	}
	$http_response->set_cookie(lang => $lang);
	if ($src eq 'get' && defined ($params)) {
		$src = 'submit';
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
	my $ucMethod = $method;
	$method =~ s/[[:lower:]]\K([[:upper:]])/ \l$1/g;
	$method = lcfirst $method;
	my %request = %$form;
	$request{method} = $method;
	my $defaults = {
		ip        => $request->remote_ip,
		lang      => $lang,
		hostname  => $request->hostname,
		path_info => decode_utf8($request->path),
		form      => $form,
		headers   => $request->headers,
		scheme    => $request->scheme,
		cookies   => $cookies,
	};
	my $vreq = eval { validate(\%request, $defaults) };
	my $response;
	my $json = $src eq 'ajax';
	my $new_loc;

	if (!$@) {
		my $as = get_method_attrs($vreq => 'allowed_source');
		if ($as && ((!ref ($as) && $as ne $src) || (ref ($as) eq 'ARRAY' && !grep { $_ eq $src } @$as))) {
			$log->({level => "debug", message => "not allowed source $src"});
			$response = {result => 'INTERR', answer => 'Unallowed calling source', answer_args => []};
			goto out;
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
				eval "use $class;\n\$response = $model(\$vreq, \$defaults)";
			} else {
				$response = model_rpc($model)->send_message($vreq)->recv_message;
			}
			if ($@) {
				$log->({level => "debug", message => "error: " . Dumper($model, $@, $vreq)});
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
				COMPILE_DIR => template_cache,
				V2EQUALS    => 0,
				ENCODING    => "UTF-8"
			);

			# this bug was fixed in Template::Alloy 1.018
			# $stash = JSON->new->decode(JSON->new->utf8->encode($stash));
			$stash->{uri_unescape} = sub { uri_unescape @_ };
			my $eval_result = sub {
				if (substr ($_[0], 0, 3) eq 'TT ') {
					my $url = substr ($_[0], 3);
					my $tmpl = encode_utf8 '[% url(' . $url . ') %]';
					$tt->process_simple(\$tmpl, $stash, \$new_loc) or do {
						$log->({
								level   => "debug",
								message => "error processing resulting url ($vreq->{method}) '$_[0]': " . $tt->error()
							}
						);
						$log->({level => "debug", message => "error: " . Dumper($vreq, $response)});
						$new_loc = location_error;
						return;
					};
				} else {
					$new_loc = $_[0];
				}
				$new_loc =~ s/^\s*//;
				$new_loc =~ s/\s*$//;
				$log->({level => "debug", message => "new location: $new_loc"});
				return $new_loc;
			};
			if (ref ($result)) {
				my $found      = 0;
				my $find_redir = sub {
					return if $json;
					my $arr = $_[0];
					$log->({level => "debug", message => "looking for redirect: " . Dumper($arr)});
					$arr = [$_[0]] if !ref ($arr);
					for my $ru (@$arr) {
						if ($eval_result->($ru)) {
							$found = 1;
							$log->error("found redirect: $ru");
							last;
						}
					}
				};
				my $test_sub = sub {
					my $rc = $_[0];
					$log->({level => "debug", message => "testing return code $rc"});
					if (exists ($result->{$rc})) {
						if (ref ($result->{$rc})) {
							if (ref ($result->{$rc}) eq 'ARRAY') {
								$find_redir->($result->{$rc});
							} else {
								$find_redir->($result->{$rc}{redirect}) if exists ($result->{$rc}{redirect});
								if (exists $result->{$rc}{filter}) {
									my $class = substr ($result->{$rc}{filter}, 0, rindex ($result->{$rc}{filter}, "::"));
									my $func = substr ($result->{$rc}{filter}, rindex ($result->{$rc}{filter}, "::") + 2);
									(my $clf = $class) =~ s|::|/|g;
									my $mrf             = out_filter_dir . "/$clf.pm";
									my $filter_response = eval {
										no strict 'refs';
										require $mrf;
										my $fr = app_namespace . $class . "::$func";
										return {result => 'INTERR', answer => 'Bad output filter', answer_args => []}
										  if not defined &{$fr};
										return $fr->($response, $defaults);
									};
								}
								if (exists $result->{$rc}{answer}) {
									if (substr ($result->{$rc}{answer}, 0, 3) eq 'TT ') {
										my $exp = substr ($result->{$rc}{'answer'}, 3);
										my $tmpl = encode_utf8 '[% ' . $exp . ' %]';
										my $out;
										$response->{answer} = $out if $tt->process_simple(\$tmpl, $stash, \$out);
									}
								}
								if (exists $result->{$rc}{'set-cookie'}) {
									my $cl = $result->{$rc}{'set-cookie'};
									for my $cn (keys %$cl) {
										my $cv = $cl->{$cn};
										my ($value);
										my %other_params;
										if (ref ($cv)) {
											if (exists $cv->{value}) {
												$value = $cv->{value};
											} else {
												$log->({
														level   => "debug",
														message => "error processing set cookie $cn: undefined value"
													}
												);
												$value = '';
											}
											for my $pn (qw/expires domain path secure max-age httponly/) {
												if (exists $cv->{$pn}) {
													$other_params{$pn} = $cv->{$pn};
												}
											}
										} else {
											$value = $cv;
										}
										$other_params{path} = "/" if not exists $other_params{path};
										if (substr ($value, 0, 3) eq 'TT ') {
											my $exp = substr ($value, 3);
											my $tmpl = encode_utf8 '[% ' . $exp . ' %]';
											my $out;
											$tt->process(\$tmpl, $stash, \$out) and do {
												$http_response->set_cookie(
													$cn, {
														value => $out,
														%other_params
													}
												);
												1;
											  }
											  or do {
												$log->({
														level   => "debug",
														message => "error processing set cookie $cn: " . $tt->error() . ": " . Dumper($tmpl, $stash)
													}
												);
											  };
										} else {
											$http_response->set_cookie(
												$cn, {
													value => $value,
													%other_params
												}
											);

										}
									}
								}
								if (exists $result->{$rc}{'unset-cookie'}) {
									$http_response->set_cookie(
										$result->{$rc}{'unset-cookie'}, {
											value   => '',
											expires => -3600
										}
									);
								}
							}
						} else {
							$find_redir->($result->{$rc});
						}
					}
				};
				$test_sub->($response->{result});
				if (!$found && exists ($result->{DEFAULT})) {
					$test_sub->('DEFAULT');
				}
			} else {
				$eval_result->($result);
			}
		}
	} else {
		$log->({level => "debug", message => "validate error: " . Dumper($@, \%request)});
		$response = (ref ($@) eq 'HASH' ? $@ : {result => 'INTERR', answer => 'Internal Error', answer_args => []});
	}
  out:
	if ($json) {
		if (exists $response->{answer} and not exists $response->{answer_no_nls}) {
			my $args = exists ($response->{answer_args}) ? $response->{answer_args} : [];
			$args ||= [];
			$response->{answer} = msg_get($lang, $response->{answer}, @$args)->{message};
		}
		$http_response->content_type('application/json');
		$http_response->set_body(encode_json($response));
		return $http_response->response();
	} else {
		if (exists $response->{answer_headers} and 'ARRAY' eq ref $response->{answer_headers}) {
			while (@{$response->{answer_headers}}) {
				if (ref ($response->{answer_headers}[0])) {
					if (ref ($response->{answer_headers}[0]) eq 'HASH') {
						$http_response->add_header(%{$response->{answer_headers}[0]});
					} else {
						$http_response->add_header(@{$response->{answer_headers}[0]});
					}
					shift @{$response->{answer_headers}};
				} else {
					$http_response->add_header($response->{answer_headers}[0], $response->{answer_headers}[1]);
					splice @{$response->{answer_headers}}, 0, 2;
				}
			}
		}
		if (exists $response->{answer_cookies} and 'ARRAY' eq ref $response->{answer_cookies}) {
			while (@{$response->{answer_cookies}}) {
				if (ref ($response->{answer_cookies}[0])) {
					if (ref ($response->{answer_cookies}[0]) eq 'HASH') {
						$http_response->set_cookie(%{$response->{answer_cookies}[0]});
					} else {
						$http_response->set_cookie(@{$response->{answer_cookies}[0]});
					}
					shift @{$response->{answer_cookies}};
				} else {
					$http_response->set_cookie($response->{answer_headers}[0], $response->{answer_headers}[1]);
					splice @{$response->{answer_cookies}}, 0, 2;
				}
			}
		}
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
			$log->({level => "debug", message => "outputting the answer"});
			if (   exists ($response->{answer_content_type})
				&& defined ($response->{answer_content_type})
				&& $response->{answer_content_type})
			{
				$http_response->content_type($response->{answer_content_type});
			} else {
				$http_response->content_type('text/html');
			}
			$http_response->set_body($response->{answer});
			return $http_response->response();
		} else {
			$log->({level => "debug", message => "setting location: $new_loc"});
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
