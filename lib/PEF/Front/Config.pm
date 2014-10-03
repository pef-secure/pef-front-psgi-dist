package PEF::Front::Config;
use warnings;
use strict;
use FindBin;
use File::Basename;
use PEF::Front::RPC;
our $project_dir;
our $app_conf_dir;
our $app_namespace;

sub normalize_path {
	my $path = $_[0];
	if (not $path) {
		return '.';
	} elsif (substr($path, -1, 1) ne '/') {
		return $path;
	} else {
		return substr($path, 0, -1);
	}
}

sub import {
	my ($modname) = grep {/AppFrontConfig\.pm$/} keys %INC;
	die "no config" if 0 && !$modname;
	$modname = 'fakemodule' if !$modname;
	(undef, $app_conf_dir, undef) = fileparse($INC{$modname} || '', ".pm");
	$app_conf_dir = normalize_path($app_conf_dir);
	$modname =~ s|\.pm||;
	$modname =~ s|/|::|g;
	($app_namespace = $modname) =~ s/::[^:]*$/::/;
	my $mp = __PACKAGE__;
	my $cp = caller;
	no strict 'refs';

	for my $method (qw{
		template_dir
		upload_dir
		captcha_db
		captcha_font
		captcha_secret
		model_dir
		cache_file
		cache_size
		cache_expire
		www_static_dir
		www_static_captchas_dir
		in_filter_dir
		out_filter_dir
		db_user
		db_password
		db_name
		db_reconnect_trys
		model_rpc_admin_port
		model_rpc_site_port
		model_rpc_admin_addr
		model_rpc_site_addr
		model_rpc
		model_local_dir
		app_namespace
		default_lang
		url_contains_lang
		template_dir_contains_lang
		no_multilang_support
		location_error
		template_cache
		no_nls
		}
	  )
	{
		my $cref = "$modname"->can($method) || *{$mp . "::std_$method"};
		*{$mp . "::$method"} = $cref;
		*{$cp . "::$method"} = *{$mp . "::$method"};
	}
	if ("$modname"->can("project_dir")) {
		$project_dir = normalize_path("$modname"->project_dir);
	} else {
		my $lpath = $FindBin::Bin;
		$lpath =~ s'(/conf/?$|/bin/?$)'';
		$project_dir = $lpath;
	}
}

sub std_no_nls               {0}
sub std_model_rpc_admin_port {5500}
sub std_model_rpc_site_port  {4500}
sub std_model_rpc_admin_addr {'172.16.0.1'}
sub std_model_rpc_site_addr  {'172.16.0.1'}

sub std_model_rpc {
	if ($_[0] eq 'admin' || $_[0] eq 'rpc_admin') {
		return PEF::Front::RPC->new(
			'Addr' => model_rpc_admin_addr(),
			'Port' => model_rpc_admin_port(),
		);
	} else {
		return PEF::Front::RPC->new(
			'Addr' => model_rpc_site_addr(),
			'Port' => model_rpc_admin_port(),
		);
	}
}

sub std_template_cache             {"$project_dir/var/tt_cache"}
sub std_location_error             {"/appError?msgid=Internal\%20Error"}
sub std_db_reconnect_trys          {30}
sub std_no_multilang_support       {1}
sub std_default_lang               {'en'}
sub std_url_contains_lang          {0}
sub std_template_dir_contains_lang {0}
sub std_app_namespace              {$app_namespace}
sub std_in_filter_dir              {"$app_conf_dir/InFilter"}
sub std_model_local_dir            {"$app_conf_dir/Local"}
sub std_out_filter_dir             {"$app_conf_dir/OutFilter"}
sub std_upload_dir                 {"$project_dir/var/upload"}
sub std_captcha_db                 {"$project_dir/var/captcha-db"}
sub std_captcha_font               {"giant"}
sub std_captcha_secret             {"very secret"}
sub std_cache_file                 {"$project_dir/var/cache/shared.cache"}
sub std_cache_size                 {"8m"}
sub std_cache_expire               {"1h"}
sub std_model_dir                  {"$project_dir/model"}
sub std_www_static_dir             {"$project_dir/www-static"}
sub std_www_static_captchas_dir    {"$project_dir/www-static/captchas"}
sub std_db_user                    {"pef"}
sub std_db_password                {"pef-pass"}
sub std_db_name                    {"pef"}

sub std_template_dir {
	template_dir_contains_lang() ? "$project_dir/templates/$_[1]" : "$project_dir/templates";
}

1;
