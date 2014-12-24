package PEF::Front::Validator;
use strict;
use warnings;
use utf8;
use Encode;
use YAML::XS;
use Data::Dumper;
use Carp qw(cluck croak);
use Regexp::Common 'RE_ALL';
use PEF::Front::Captcha;
use PEF::Front::Config;
use base 'Exporter';
our @EXPORT = qw{
  validate
  get_model
  get_method_attrs
};

our %model_cache;

sub _collect_base_rules {
	my ($method, $mr, $pr) = @_;
	my %seen;
	my %ret;
	substr ($mr, 0, 1, '') if substr ($mr, 0, 1) eq '$';
	my $entry = $mr;
	while (!exists $seen{$entry}) {
		$seen{$entry} = undef;
		croak {
			result      => 'INTERR',
			answer      => 'Internal server error',
			answer_args => [],
			message     => "Validation $method error: unknow base rule '$entry' for '$pr'",
		  }
		  unless exists $model_cache{'-base-'}{rules}{params}{$entry};
		my $rules = $model_cache{'-base-'}{rules}{params}{$entry};
		last if not defined $rules or (not ref $rules and $rules eq '');
		if (not ref $rules) {
			if (substr ($rules, 0, 1) eq '$') {
				$entry = substr ($rules, 1);
			} else {
				%ret = (regex => $rules, %ret);
			}
		} else {
			%ret = (%$rules, %ret);
			if (exists $ret{base}) {
				if (defined $ret{base} and $ret{base} ne '') {
					$entry = $ret{base};
					substr ($entry, 0, 1, '') if substr ($entry, 0, 1) eq '$';
				}
				delete $ret{base};
			}
		}
	}
	\%ret;
}

sub _build_validator {
	my $rules         = $_[0];
	my $method_rules  = $rules->{params} || {};
	my $params_rule   = $rules->{extra_params} || 'ignore';
	my %known_params  = (method => undef, ip => undef);
	my %must_params   = (method => undef);
	my $validator_sub = "sub { \n";
	my $jsn           = '$_[0]->';
	my $def           = '$_[1]->';
	my @add_use;
	my $pr;
	my $mr;
	my $make_default_sub = sub {
		my ($default) = @_;
		my $check_defaults = '';
		if ($default !~ /^($RE{num}{int}|$RE{num}{real})$/) {
			if ($default =~ /^defaults\.([\w\d].*)/) {
				$default        = "$def {$1}";
				$check_defaults = "exists($def {$1})";
			} elsif ($default =~ /^headers\.(.*)/) {
				my $h = $1;
				$h =~ s/\s*$//;
				$h       = _quote_var($h);
				$default = "$def {headers}->get_header($h)";
			} elsif ($default =~ /^cookies\.(.*)/) {
				my $c = $1;
				$c =~ s/\s*$//;
				$c              = _quote_var($c);
				$default        = "$def {cookies}->{$c}";
				$check_defaults = "exists($def {cookies}->{$c})";
			} elsif ($default =~ /^config\.(.*)/) {
				my $c = $1;
				$c =~ s/\s*$//;
				$c       = _quote_var($c);
				$default = "PEF::Front::Config::cfg($c)";
			} else {
				$default =~ s/\s*$//;
				$default = _quote_var($default);
			}
		}
		($default, $check_defaults);
	};
	my %attr_sub = (
		regex => sub {
			my $re = ref ($mr) ? $mr->{regex} : $mr;
			return '' if !defined ($re) || $re eq '';
			<<ATTR;
		croak {
			result => 'BADPARAM',
			answer => 'Bad parameter \$1',
			answer_args => ['param-$pr']
		} unless $jsn {$pr} =~ m/$re/;
ATTR
		},
		captcha => sub {
			return '' if !defined ($mr->{captcha}) || $mr->{captcha} eq '';
			<<ATTR;
			if($jsn {$pr} ne 'nocheck') {
				croak {
					result => 'BADPARAM', 
					answer => 'Bad parameter \$1: bad captcha', 
					answer_args => ['param-$pr']
				} unless PEF::Front::Captcha::check_captcha($jsn {$pr}, $jsn {$mr->{captcha}});
			}
ATTR
		},
		type => sub {
			return '' if !defined ($mr->{type}) || $mr->{type} eq '';
			my $type = uc (substr ($mr->{type}, 0, 1)) eq 'F' ? 'PEF::Front::File' : uc $mr->{type};
			<<ATTR;
			croak {
				result => 'BADPARAM', 
				answer => 'Bad type parameter \$1', 
				answer_args => ['param-$pr']
			} unless ref ($jsn {$pr}) eq '$type';
ATTR
		},
		'max-size' => sub {
			return '' if !defined ($mr->{'max-size'}) || $mr->{'max-size'} eq '';
			<<ATTR;
			croak {
				result => 'BADPARAM', 
				answer => 'Parameter \$1 is too big', 
				answer_args => ['param-$pr']
			} if (
				!ref($jsn {$pr})
				? length($jsn {$pr})
				: ref($jsn {$pr}) eq 'HASH'
				? scalar(keys \%{$jsn {$pr}})
				: scalar(\@{$jsn {$pr}}) 
				) >  $mr->{'max-size'};
ATTR
		},
		'min-size' => sub {
			return '' if !defined ($mr->{'max-size'}) || $mr->{'max-size'} eq '';
			<<ATTR;
			croak {
				result => 'BADPARAM', 
				answer => 'Parameter \$1 is too small', 
				answer_args => ['param-$pr']
			} if (
				!ref($jsn {$pr})
				? length($jsn {$pr})
				: ref($jsn {$pr}) eq 'HASH'
				? scalar(keys \%{$jsn {$pr}})
				: scalar(\@{$jsn {$pr}}) 
				) <  $mr->{'min-size'};
ATTR
		},
		can => sub {
			my $can = exists ($mr->{can}) ? $mr->{can} : $mr->{can_string};
			return '' if !defined ($can);
			my @can = ref ($can) ? @{$can} : ($can);
			return '' if !@can;
			my $can_list = join ", ", map { _quote_var($_) } @can;
			<<ATTR;
			{
				my \$found = 0;
				local \$_;
				for($can_list) {
					if(\$_ eq $jsn {$pr}) {
						\$found = 1;
						last;
					} 
				}
				croak {
					result => 'BADPARAM',
					answer => 'Parameter \$1 has not allowed value',
					answer_args => ['param-$pr']
				} unless \$found;
			}
ATTR
		},
		can_number => sub {
			return '' if !defined ($mr->{can_number}) || $mr->{can_number} eq '';
			my @can = ref ($mr->{can_number}) ? @{$mr->{can_number}} : ($mr->{can_number});
			return '' if !@can;
			my $can_list = join ", ", map { _quote_var($_) } @can;
			<<ATTR;
			{
				my \$found = 0;
				local \$_;
				for($can_list) {
					if(\$_ == $jsn {$pr}) {
						\$found = 1;
						last;
					} 
				}
				croak {
					result => 'BADPARAM',
					answer => 'Parameter \$1 has not allowed value',
					answer_args => ['param-$pr']
				} unless \$found;
			}
ATTR
		},
		default => sub {
			my ($default, $check_defaults) = $make_default_sub->($mr->{default});
			$check_defaults .= ' and' if $check_defaults;
			<<ATTR;
			$jsn {$pr} = $default if $check_defaults not exists $jsn {$pr};
ATTR
		},
		value => sub {
			my ($default, $check_defaults) = $make_default_sub->($mr->{value});
			if ($check_defaults) {
				<<ATTR;
			$jsn {$pr} = $default if $check_defaults;
ATTR
			} else {
				<<ATTR;
			$jsn {$pr} = $default;
ATTR
			}
		},
		filter => sub {
			return '' if !defined ($mr->{filter}) || $mr->{filter} eq '';
			my $filter_sub = '';
			if ($mr->{filter} =~ /^\w+::/) {
				my $fcall = cfg_app_namespace . "InFilter::$mr->{filter}($jsn {$pr}, \$_[1]);";
				$filter_sub .= <<ATTR;
			eval { $jsn {$pr} = $fcall };
ATTR
				if (exists ($mr->{optional}) && $mr->{optional}) {
					$filter_sub .= <<ATTR;
			if(\$@) {
				delete $jsn {$pr}; 
				cfg_log_level_info()
				&& $def {request}->logger->({
					level => "info", 
					message => "dropped optional parameter $pr: input filter: " . Dumper(\$@)
				});
			}
ATTR
				} else {
					$filter_sub .= <<ATTR;
			if(\$@) {
				cfg_log_level_error()
				&& $def {request}->logger->({
					level => "error", 
					message => "input filter: " . Dumper(\$@)
				});
				croak {
					result => 'BADPARAM', 
					answer => 'Bad parameter \$1', 
					answer_args => ['param-$pr']
				};
			}
ATTR
				}
				my $cl = cfg_app_namespace . "InFilter::$mr->{filter}";
				my $use_module = substr ($cl, 0, rindex ($cl, "::"));
				eval "use $use_module";
				if ($@) {
					croak {
						result      => 'INTERR',
						answer      => 'Error loading method in filter module $1 for method $2: $3',
						answer_args => [$use_module, $rules->{method}, $@]
					};
				}
			} else {
				my $rearr =
				    ref ($mr->{filter}) eq 'ARRAY' ? $mr->{filter}
				  : ref ($mr->{filter})            ? []
				  :                                  [$mr->{filter}];
				for my $re (@$rearr) {
					if ($re =~ /^(s|tr|y)\b/) {
						$filter_sub .= <<ATTR;
				$jsn {$pr} =~ $re;
ATTR
					}
				}
			}
			$filter_sub;
		},
		optional => sub {
			"";
		},
		base => sub {
			"";
		}
	);
	$attr_sub{can_string} = $attr_sub{can};
	for my $par (keys %$method_rules) {
		$pr = $par;
		$mr = $method_rules->{$pr};
		$mr = '' if not defined $mr;
		my $last_sym = substr ($pr, -1, 1);
		if ($last_sym eq '%' || $last_sym eq '@' || $last_sym eq '*') {
			my $type = $last_sym eq '%' ? 'HASH' : $last_sym eq '@' ? 'ARRAY' : 'FILE';
			if (ref ($mr)) {
				$mr->{type} = $type;
			} else {
				$mr = {type => $type};
			}
			substr ($pr, -1, 1, '');
		}
		$known_params{$pr} = undef;
		if (!ref ($mr) and length $mr > 0 and substr ($mr, 0, 1) eq '$') {
			$mr = _collect_base_rules($rules->{method}, $mr, $pr);
		}
		if (    ref $mr
			and exists $mr->{base}
			and defined $mr->{base}
			and $mr->{base} ne '')
		{
			my $bmr = _collect_base_rules($rules->{method}, $mr->{base}, $pr);
			$mr = {%$bmr, %$mr};
		}
		if (not ref $mr) {
			if ($mr eq '') {
				$mr = {};
			} else {
				$mr = {regex => $mr};
			}
		}
		my $sub_test = '';
		for my $attr (keys %$mr) {
			substr ($attr, 0, 1, '') if substr ($attr, 0, 1) eq '^';
			if (exists ($attr_sub{$attr})) {
				$sub_test .= $attr_sub{$attr}();
			} else {
				croak {
					result      => 'INTERR',
					answer      => 'Unknown attribute $1 for paramter $2 method $3',
					answer_args => [$attr, $pr, $rules->{method}]
				};
			}
		}
		if (exists ($mr->{optional}) && $mr->{optional} eq 'empty') {
			$validator_sub .= "if(exists($jsn {$pr}) and $jsn {$pr} ne '') {\n$sub_test\n}\n";
		} elsif (exists ($mr->{optional}) && $mr->{optional}) {
			$validator_sub .= "if(exists($jsn {$pr})) {\n$sub_test\n}\n";
		} else {
			$must_params{$pr} = undef;
			$validator_sub .=
			    "croak {result => 'BADPARAM', answer => 'Mandatory parameter \$1 is absent', "
			  . "answer_args => ['param-$pr']} "
			  . "unless exists $jsn {$pr} ;\n";
			$validator_sub .= $sub_test;
		}
	}
	if ($params_rule ne 'pass') {
		$validator_sub .=
		    "{my \%known_params; \@known_params{"
		  . join (", ", map { "'$_'" } keys %known_params)
		  . "} = undef;\n"
		  . "for my \$pr(keys \%{\$_[0]}) {";
		if ($params_rule eq 'ignore') {
			$validator_sub .= "if(!exists(\$known_params {\$pr})) { delete $jsn {\$pr} }";
		} elsif ($params_rule eq 'disallow') {
			$validator_sub .=
			    "if(!exists(\$known_params {\$pr})) { "
			  . "croak {result => 'BADPARAM', answer => 'Parameter \$1 is not allowed here', answer_args => ['\$pr']} }";
		}
		$validator_sub .= "}\n}\n";
	}
	$validator_sub .= "\$_[0]\n};";
	if (@add_use) {
		my $use = join ("\n", map { "use $_;" } @add_use);
		eval $use;
	}
	$validator_sub;
}

sub _quote_var {
	my $s = $_[0];
	my $d = Data::Dumper->new([$s]);
	$d->Terse(1);
	my $qs = $d->Dump;
	substr ($qs, -1, 1, '') if substr ($qs, -1, 1) eq "\n";
	return $qs;
}

sub make_value_parser {
	my $value = $_[0];
	my $ret   = _quote_var($value);
	if (substr ($value, 0, 3) eq 'TT ') {
		my $exp = substr ($value, 3);
		$exp = _quote_var($exp);
		if (substr ($exp, 0, 1) eq "'") {
			substr ($exp, 0,  1, '');
			substr ($exp, -1, 1, '');
		}
		$ret = qq~do {
			my \$tmpl = '[% $exp %]';
			my \$out;
			\$tt->process_simple(\\\$tmpl, \$stash, \\\$out) 
			or
				cfg_log_level_error()
				&& 
				\$logger->({level => \"error\", message => 'error: $exp - ' . \$tt->error});\n
			\$out;
		}~;
	}
	return $ret;
}

sub _make_cookie_parser {
	my ($name, $value) = @_;
	$value = {value => $value} if not ref $value;
	$name = _quote_var($name);
	$value->{path} = '/' if not $value->{path};
	my $ret = qq~\t\$http_response->set_cookie($name, {\n~;
	for my $pn (qw/value expires domain path secure max-age httponly/) {
		if (exists $value->{$pn}) {
			$ret .=
			  "\t\t" . _quote_var($pn) . ' => ' . make_value_parser($value->{$pn}) . ",\n";
		}
	}
	$ret .= "\t\t(\$defaults->{scheme} eq 'https'?(secure => 1): ()),\n"
	  if not exists $value->{secure};
	$ret .= qq~\t});\n~;
	return $ret;
}

sub _make_rules_parser {
	my ($start) = @_;
	$start = {redirect => $start} if not ref $start or 'ARRAY' eq ref $start;
	my $sub_int = "sub {\n";
	for my $cmd (keys %$start) {
		if ($cmd eq 'redirect') {
			my $redir = $start->{$cmd};
			$redir = [$redir] if 'ARRAY' ne ref $redir;
			my $rw = "\t{\n";
			for my $r (@$redir) {
				$rw .= "\t\t\$new_location = " . make_value_parser($r) . ";\n\t\tlast if \$new_location;\n";
			}
			$rw      .= "\t}\n";
			$sub_int .= "\tif(\$defaults->{src} ne 'ajax') { $rw }";
		} elsif ($cmd eq 'set-cookie') {
			for my $c (keys %{$start->{$cmd}}) {
				$sub_int .= _make_cookie_parser($c => $start->{$cmd}{$c});
			}
		} elsif ($cmd eq 'unset-cookie') {
			my $unset = $start->{$cmd};
			if (ref ($unset) eq 'HASH') {
				for my $c (keys %$unset) {
					my $ca = {%{$start->{$cmd}{$c}}};
					$ca->{expires} = cfg_cookie_unset_negative_expire
					  if not exists $ca->{expires};
					$ca->{value} = '' if not exists $ca->{value};
					$sub_int .= _make_cookie_parser($c => $ca);
				}
			} else {
				$unset = [$unset] if not ref $unset;
				for my $c (@$unset) {
					$sub_int .= _make_cookie_parser(
						$c => {
							value   => '',
							expires => cfg_cookie_unset_negative_expire
						}
					);
				}
			}
		} elsif ($cmd eq 'add-header') {
			for my $h (keys %{$start->{$cmd}}) {
				my $value = make_value_parser($start->{$cmd}{$h});
				$sub_int .= "\t\$http_response->add_header(~ . _quote_var($h) . qq~, $value);\n";
			}
		} elsif ($cmd eq 'set-header') {
			for my $h (keys %{$start->{$cmd}}) {
				my $value = make_value_parser($start->{$cmd}{$h});
				$sub_int .= "\t\$http_response->set_header(~ . _quote_var($h) . qq~, $value);\n";
			}
		} elsif ($cmd eq 'filter') {
			my $full_func;
			my $use_class;
			if (index ($start->{$cmd}, 'PEF::Core::') == 0) {
				$full_func = $start->{$cmd};
				$use_class = substr ($full_func, 0, rindex ($full_func, "::"));
				$sub_int .= "\teval {use $use_class; $full_func(\$response, \$defaults)};\n";
			} else {
				$full_func = cfg_app_namespace . "OutFilter::" . $start->{$cmd};
				$use_class = substr ($full_func, 0, rindex ($full_func, "::"));
				eval "use $use_class;";
				croak {
					result  => 'INTERR',
					answer  => 'Internal server error',
					message => $@,
				  }
				  if $@;
				$sub_int .= "\teval {$full_func(\$response, \$defaults)};\n";
			}
			$sub_int .= <<MRP;
			if (\$@) {
				cfg_log_level_error()
				&& \$logger->({level => "error", message => "output filter: " . Dumper(\$@)});
				\$response = {result => 'INTERR', answer => 'Bad output filter'};
				return;
			}
MRP
		} elsif ($cmd eq 'answer') {
			$sub_int .= qq~\t\$response->{answer} = ~ . make_value_parser($start->{$cmd}) . qq~;\n~;
		}
	}
	$sub_int .= "\t}";
	return $sub_int;
}

sub _build_result_processor {
	my $result_rules = $_[0];
	my $result_sub   = <<RSUB;
	sub {
		my (\$response, \$defaults, \$stash, \$http_response, \$tt, \$logger) = \@_;
		my \$new_location;
		my \%rc = (
RSUB
	my %rc_array;
	for my $rc (keys %{$result_rules}) {
		my $qrc = _quote_var($rc);
		my $rsub = _make_rules_parser($result_rules->{$rc} || {});
		$result_sub .= <<RSUB;
		  $qrc => $rsub,
RSUB
	}
	$result_sub .= <<RSUB;
		);
		my \$rc;
		if (not exists \$rc{\$response->{result}}) {
			if(exists \$rc{DEFAULT}) { 
				\$rc = 'DEFAULT';
			} else {
				cfg_log_level_error()
				&& \$logger->({level => "error", 
					message => "error: Unexpected result code: '\$response->{result}'"});
				return (undef, {result => 'INTERR', answer => 'Bad result code'});
			}
		} else {
			\$rc = \$response->{result};
		}
		\$rc{\$rc}->();
		return (\$new_location, \$response);
	}
RSUB
	#print $result_sub;
	return eval $result_sub;
}

sub load_validation_rules {
	my ($method) = @_;
	my $mrf = $method;
	$mrf =~ s/ ([[:lower:]])/\u$1/g;
	$mrf = ucfirst ($mrf);
	my $rules_file = cfg_model_dir . "/$mrf.yaml";
	my @stats      = stat ($rules_file);
	croak {
		result => 'INTERR',
		answer => 'Unknown rules file'
	} if !@stats;
	my $base_file = cfg_model_dir . "/-base-.yaml";
	my @bfs       = stat ($base_file);
	if (@bfs
		&& (!exists ($model_cache{'-base-'}) || $model_cache{'-base-'}{modified} != $bfs[9]))
	{
		%model_cache = ('-base-' => {modified => $bfs[9]});
		open my $fi, "<",
		  $base_file
		  or croak {
			result      => 'INTERR',
			answer      => 'cant read base rules file: $1',
			answer_args => ["$!"],
		  };
		my $raw_rules;
		read ($fi, $raw_rules, -s $fi);
		close $fi;
		my @new_rules = eval { Load $raw_rules};
		if ($@) {
			cluck $@;
			croak {
				result      => 'INTERR',
				answer      => 'Base rules validation error: $1',
				answer_args => ["$@"]
			};
		} else {
			my $new_rules = $new_rules[0];
			$model_cache{'-base-'}{rules} = $new_rules;
		}
	}
	if (!exists ($model_cache{$method}) || $model_cache{$method}{modified} != $stats[9]) {
		open my $fi, "<",
		  $rules_file
		  or croak {
			result      => 'INTERR',
			answer      => 'cant read rules file: $1',
			answer_args => ["$!"],
		  };
		my $raw_rules;
		read ($fi, $raw_rules, -s $fi);
		close $fi;
		my @new_rules = eval { Load $raw_rules};
		croak {
			result      => 'INTERR',
			answer      => 'Validator $1 description error: $2',
			answer_args => [$method, "$@"]
		  }
		  if $@;
		my $new_rules = $new_rules[0];
		$new_rules->{method} = $method;
		my $validator_sub = _build_validator($new_rules);
		$model_cache{$method}{code_text} = $validator_sub;
		eval "\$model_cache{\$method}{code} = $validator_sub";
		croak {
			result        => 'INTERR',
			answer        => 'Validator $1 error: $2',
			answer_args   => [$method, "$@"],
			validator_sub => $validator_sub
		  }
		  if $@;
		for (keys %$new_rules) {
			$model_cache{$method}{$_} = $new_rules->{$_} if $_ ne 'code';
		}
		my $model;
		if (!exists $new_rules->{model}) {
			$model = 'rpc_site';
		} else {
			if ($new_rules->{model} =~ /::/) {
				if ($new_rules->{model} =~ /^PEF::Front/) {
					$model = $new_rules->{model};
				} else {
					$model = cfg_app_namespace . "Local::$new_rules->{model}";
				}
			} else {
				$model = $new_rules->{model};
			}
		}
		$model_cache{$method}{model} = $model;
		if (exists $new_rules->{result}) {
			$model_cache{$method}{result_sub} =
			  _build_result_processor($new_rules->{result} || {});
		}
		$model_cache{$method}{modified} = $stats[9];
	}
}

sub validate {
	my ($request, $defaults) = @_;
	my $method = $request->{method}
	  or croak(
		{   result => 'INTERR',
			answer => 'Unknown method'
		}
	  );
	load_validation_rules($method);
	$model_cache{$method}{code}->($request, $defaults);
}

sub get_method_attrs {
	my $request = $_[0];
	my $method = ref ($request) ? $request->{method} : $request;
	if (exists $model_cache{$method}{$_[1]}) {
		return $model_cache{$method}{$_[1]};
	} else {
		return;
	}
}

sub get_model {
	get_method_attrs($_[0] => 'model');
}
1;
