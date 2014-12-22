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
	} elsif (substr ($path, -1, 1) ne '/') {
		return $path;
	} else {
		return substr ($path, 0, -1);
	}
}

my @std_const_params = qw{
  cfg_upload_dir
  cfg_captcha_db
  cfg_captcha_font
  cfg_captcha_secret
  cfg_model_dir
  cfg_cache_file
  cfg_cache_size
  cfg_cache_global_expire
  cfg_cache_method_expire
  cfg_cookie_unset_negative_expire
  cfg_www_static_dir
  cfg_www_static_captchas_dir
  cfg_in_filter_dir
  cfg_out_filter_dir
  cfg_db_user
  cfg_db_password
  cfg_db_name
  cfg_db_reconnect_trys
  cfg_model_rpc_admin_port
  cfg_model_rpc_site_port
  cfg_model_rpc_admin_addr
  cfg_model_rpc_site_addr
  cfg_model_local_dir
  cfg_app_namespace
  cfg_default_lang
  cfg_url_contains_lang
  cfg_template_dir_contains_lang
  cfg_no_multilang_support
  cfg_location_error
  cfg_template_cache
  cfg_no_nls
  cfg_handle_static
  cfg_log_level_info
  cfg_log_level_error
  cfg_log_level_debug
};

my @std_var_params = qw{
  cfg_template_dir
  cfg_model_rpc
};

sub import {
	my ($modname) = grep { /AppFrontConfig\.pm$/ } keys %INC;
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
	for my $method (@std_const_params, @std_var_params) {
		(my $bmn = $method) =~ s/^cfg_//;
		my $cref = "$modname"->can($method) || *{$mp . "::std_$bmn"};
		*{$mp . "::$method"}      = $cref;
		*{$cp . "::$method"}      = *{$mp . "::$method"};
		*{$modname . "::$method"} = $cref if not "$modname"->can($method);
	}
	my $exports = \@{$modname . "::EXPORT"};
	for my $e (@$exports) {
		if ((my $cref = "$modname"->can($e))) {
			*{$cp . "::$e"} = $cref;
		}
	}
	if ("$modname"->can("project_dir")) {
		$project_dir = normalize_path("$modname"->project_dir);
	} else {
		my $lpath = $FindBin::Bin;
		$lpath =~ s'(/app$|/conf$|/bin$)'';
		$project_dir = $lpath;
	}
}

sub std_no_nls                       { 0 }
sub std_model_rpc_admin_port         { 5500 }
sub std_model_rpc_site_port          { 4500 }
sub std_model_rpc_admin_addr         { '172.16.0.1' }
sub std_model_rpc_site_addr          { '172.16.0.1' }
sub std_template_cache               { "$project_dir/var/tt_cache" }
sub std_location_error               { "/appError?msgid=Internal\%20Error" }
sub std_db_reconnect_trys            { 30 }
sub std_no_multilang_support         { 1 }
sub std_default_lang                 { 'en' }
sub std_url_contains_lang            { 0 }
sub std_template_dir_contains_lang   { 0 }
sub std_handle_static                { 0 }
sub std_app_namespace                { $app_namespace }
sub std_in_filter_dir                { "$app_conf_dir/InFilter" }
sub std_model_local_dir              { "$app_conf_dir/Local" }
sub std_out_filter_dir               { "$app_conf_dir/OutFilter" }
sub std_upload_dir                   { "$project_dir/var/upload" }
sub std_captcha_db                   { "$project_dir/var/captcha-db" }
sub std_captcha_font                 { "giant" }
sub std_captcha_secret               { "very secret" }
sub std_cache_file                   { "$project_dir/var/cache/shared.cache" }
sub std_cache_size                   { "8m" }
sub std_cache_global_expire          { "1h" }
sub std_cache_method_expire          { 60 }
sub std_model_dir                    { "$project_dir/model" }
sub std_www_static_dir               { "$project_dir/www-static" }
sub std_www_static_captchas_dir      { "$project_dir/www-static/captchas" }
sub std_db_user                      { "pef" }
sub std_db_password                  { "pef-pass" }
sub std_db_name                      { "pef" }
sub std_log_level_info               { 1 }
sub std_log_level_error              { 1 }
sub std_log_level_debug              { 0 }
sub std_cookie_unset_negative_expire { -3600 }

sub std_template_dir {
	cfg_template_dir_contains_lang()
	  ? "$project_dir/templates/$_[1]"
	  : "$project_dir/templates";
}

sub std_model_rpc {
	if ($_[0] eq 'admin' || $_[0] eq 'rpc_admin') {
		return PEF::Front::RPC->new(
			'Addr' => cfg_model_rpc_admin_addr(),
			'Port' => cfg_model_rpc_admin_port(),
		);
	} else {
		return PEF::Front::RPC->new(
			'Addr' => cfg_model_rpc_site_addr(),
			'Port' => cfg_model_rpc_site_port(),
		);
	}
}

1;
