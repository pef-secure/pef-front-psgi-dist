package PEF::Front::Route;

use strict;
use warnings;
use Scalar::Util qw(blessed);
use PEF::Front::Config;
use PEF::Front::Request;
use PEF::Front::Response;
use PEF::Front::Ajax;
use PEF::Front::TemplateHtml;

my @rewrite;
my $rulepos = 0;
my $nurlpos = 1;
my $flagpos = 2;
my $tranpos = 3;

sub add_route {
	my @params = @_;
	shift @params if @params & 1;
	for (my $i = 0 ; $i < @params ; $i += 2) {
		my ($rule, $rdest) = @params[$i, $i + 1];
		push @rewrite, [$rule, undef, {}, undef];
		my $ri = $#rewrite;
		if (ref ($rdest) eq 'ARRAY') {
			$rewrite[$ri][$nurlpos] = $rdest->[0];
			my @flags = split /[, ]+/, $rdest->[1] if @$rdest > 1;
			for my $f (@flags) {
				my ($p, $v) = split /=/, $f, 2;
				$rewrite[$ri][$flagpos]{uc $p} = $v;
			}
		} elsif (ref ($rdest) && ref ($rdest) ne 'CODE') {
			die "bad routing rule at $rule";
		} else {
			$rewrite[$ri][$nurlpos] = $rdest;
		}
		if (ref ($rule) eq 'Regexp') {
			if (!ref ($rewrite[$ri][$nurlpos])) {
				$rewrite[$ri][$tranpos] =
				    eval "sub {my \$request = \$_[0]; my \$url = \$request->path; return \$url if \$url =~ s\"$rule\""
				  . $rewrite[$ri][$nurlpos] . "\""
				  . (exists ($rewrite[$ri][$flagpos]{RE}) ? $rewrite[$ri][$flagpos]{RE} : "")
				  . "; return }";
			} else {
				$rewrite[$ri][$tranpos] =
				    eval "sub {my \$request = \$_[0]; "
				  . "my \@params = \$request->path =~ "
				  . (
					exists ($rewrite[$ri][$flagpos]{RE})
					? "m\"$rule\"" . $rewrite[$ri][$flagpos]{RE} . ";"
					: "m\"$rule\"; "
				  )
				  . "return \$rewrite[$ri][$nurlpos]->(\$request, \@params) if \@params;"
				  . "return; }";
			}
		} elsif (ref ($rule) eq 'CODE') {
			if (not defined ($rewrite[$ri][$nurlpos])) {
				$rewrite[$ri][$tranpos] = $rule;
			} elsif (!ref $rewrite[$ri][$nurlpos]) {
				$rewrite[$ri][$tranpos] =
				    eval "sub {my \$request = \$_[0]; "
				  . "return '$rewrite[$ri][$nurlpos]' if \$rewrite[$ri][$rulepos]->(\$request);"
				  . "return; }";
			} else {
				$rewrite[$ri][$tranpos] =
				    eval "sub {my \$request = \$_[0]; "
				  . "my \@params = \$rewrite[$ri][$rulepos]->(\$request);"
				  . "return \$rewrite[$ri][$nurlpos]->(\$request, \@params) if \@params;"
				  . "return; }";
			}
		} else {
			if (!ref $rewrite[$ri][$nurlpos]) {
				$rewrite[$ri][$tranpos] =
				    eval "sub {my \$request = \$_[0]; "
				  . "return '$rewrite[$ri][$nurlpos]' if \$request->path eq '$rule';"
				  . "return; }";
			} else {
				$rewrite[$ri][$tranpos] =
				    eval "sub {my \$request = \$_[0]; "
				  . "return \$rewrite[$ri][$nurlpos]->(\$request) if \$request->path eq '$rule';"
				  . "return; }";
			}
		}
	}
}

sub import {
	return if @rewrite;
	my ($class, @params) = @_;
	add_route(@params);
}

sub rewrite {
	my $request = $_[0];
	my $env     = $request->env;
	for (my $i = 0 ; $i < @rewrite ; ++$i) {
		my $rewrite_func  = $rewrite[$i][$tranpos];
		my $rewrite_flags = $rewrite[$i][$flagpos];
		if ((my $npi = $rewrite_func->($request))) {
			my $http_response;
			if (ref $npi) {
				$http_response = $npi->[2] if @$npi > 2;
				$rewrite_flags = $npi->[1] if @$npi > 1;
				$npi           = $npi->[0];
				$npi ||= '';
			}
			if (%$rewrite_flags and exists $rewrite_flags->{R}) {
				$http_response ||= PEF::Front::Response->new();
				$http_response->redirect($npi, $rewrite_flags->{R});
			}
			if (   !$http_response
				&& exists ($rewrite_flags->{L})
				&& defined ($rewrite_flags->{L})
				&& $rewrite_flags->{L} > 0)
			{
				$http_response = PEF::Front::Response->new();
				$http_response->status($rewrite_flags->{L});
			}
			return $http_response
			  if $http_response && blessed($http_response) && $http_response->isa('PEF::Front::Response');
			$npi = '/' . $npi if !$npi || substr ($npi, 0, 1) ne '/';
			$env->{PATH_INFO} = $npi;
			last if %$rewrite_flags and exists $rewrite_flags->{L};
		}
	}
	return;
}

sub to_app {
	sub {
		my $request  = PEF::Front::Request->new($_[0]);
		my $response = rewrite($request);
		return $response->response() if $response;
		if (url_contains_lang && (substr ($request->path, 0, 1) ne '/' || substr ($request->path, 0, 3) ne '/')) {
			my $lang = guess_lang($request);
			if ($request->method eq 'GET') {
				my $http_response = PEF::Front::Response->new();
				$http_response->redirect("/$lang" . $request->request_uri, 301);
				return $http_response->response();
			} else {
				my $env = $request->env;
				my $path = $env->{PATH_INFO} || '/';
				$path = '/' . $path if substr ($path, 0, 1) ne '/';
				$env->{PATH_INFO} = "/$lang$path";
			}
		}
		my $lang_offset = (url_contains_lang) ? 3 : 0;
		if (substr ($request->path, $lang_offset, 4) eq '/app') {
			return PEF::Front::TemplateHtml::handler($request);
		} elsif (substr ($request->path, $lang_offset, 5) eq '/ajax'
			|| substr ($request->path, $lang_offset, 7) eq '/submit'
			|| substr ($request->path, $lang_offset, 4) eq '/get')
		{
			return PEF::Front::Ajax::handler($request);
		} else {
			my $http_response = PEF::Front::Response->new();
			$http_response->status(404);
			return $http_response->response();
		}
	};
}
1;
