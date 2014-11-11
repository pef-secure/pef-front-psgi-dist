PEF Front
======

# Overview

There are several components to build a web application: 

* `web-server` -- typically a wery light and fast server accepting http requests to serve static content and passing dynamic to application. `nginx` is probably the best for this purpose but any web-server with psgi support can be used.
* `PSGI-daemon` -- any (pre)forking PSGI-requests manager. `uwsgi` is the best 
* `PEF Front` -- framework serving dynamic content
* Web application using `PEF Front`

This document describes main principles `PEF Front` and how to use them.

# Application structure

`PEF Front` is very flexible. It tries to make some supposition about application structure and when they are neare to your actual structure you can configure less parameters.

## Typical directory structure

```
+ bin/
|- startup.pl
+ app/
|+ Example/
| - example.ini
| - nginx-handlers.conf
| - AppFrontConfig.pm
| + InFilter/
| + Local/
| + OutFilter/
+ log/
+ model/
+ templates/
++ var/
|+ cache/
|+ captcha-db/
|+ tt_cache/
|+ upload/
+ www-static/
|+ captchas/
```

## What is what

* `bin` -- different executables. startup.pl is one of them
* `app` -- main application code and configuration module
* `log` -- logs
* `model` -- YAML-files with descriptions of model methods
* `templates` -- html-templates
* `var` -- different variable data for application
* `www-static` -- static content that is served directly by `web-server`
* `www-static/captchas` -- generated captcha images
* `var/cache` -- caches data
* `var/captcha-db` -- captchas DB
* `var/tt_cache` -- compiled templates
* `var/upload` -- root directory for uploaded files
* `conf/$AppNamespace/InFilter` -- filters of input data
* `conf/$AppNamespace/OutFilter` -- filters of output content
* `conf/$AppNamespace/Local` -- local model method handlers
* `conf/$AppNamespace/AppFrontConfig.pm` -- application configurtion module

# Configuring application

In the beginning `PEF Front` tries to guess some application parameters, then it reads parameters from already loaded module `*::AppFrontConfig`. From exact name before `::AppFrontConfig` `PEF Front` makes "application name" and uses it to load in/out filter and local model handlers. So, 'use Example::AppFrontConfig' must be before any other module from `PEF Front`.

Typical `startup.pl` can look like:

```
use Example::AppFrontConfig;
use PEF::Front::Route ('/' => '/appIndex', qr'/index(.*)' => '/appIndex$1');
PEF::Front::Route->to_app();
```

Root application direcory is guessed from filepath to configuraton module.

## Configuration parameters

* `cfg_app_namespace` -- application namespace to use with filters and local model handlers
* `cfg_cache_expire` -- default global expiring cache time
* `cfg_cache_file` -- cache file
* `cfg_cache_size` -- cache size
* `cfg_captcha_db` -- captcha db directory
* `cfg_captcha_font` -- captcha font
* `cfg_captcha_secret` -- captcha secret shift to randomize your secret md5 sum
* `cfg_db_name` -- local db name for NLS messages
* `cfg_db_password` -- local db password
* `cfg_db_user` -- local db user
* `cfg_db_reconnect_trys` -- number of reconnection attempts if connect to local db is lost. there's 1 sec pause between reconnections.
* `cfg_default_lang` -- default application's messages language
* `cfg_in_filter_dir` -- directory with input data filters
* `cfg_location_error` -- redirect location when internal routing fails
* `cfg_model_dir` -- YAML-files with descriptions of model methods
* `cfg_model_local_dir` -- local model method handlers
* `cfg_model_rpc` -- this function returns object to call remote model
* `cfg_model_rpc_admin_addr` -- remote admin model address
* `cfg_model_rpc_admin_port` -- remote admin model port
* `cfg_model_rpc_site_addr` -- remote site model address
* `cfg_model_rpc_site_port` -- remote site model port
* `cfg_no_multilang_support` -- true when application has no multilanguage support
* `cfg_no_nls` -- true when application dosn't require any NLS support
* `cfg_out_filter_dir` -- filters of output content
* `cfg_template_cache` -- compiled templates
* `cfg_template_dir` -- HTML templates
* `cfg_template_dir_contains_lang` -- true means templates of different languages are located in apropriate directories
* `cfg_upload_dir` -- root directory for uploaded files
* `cfg_url_contains_lang` -- true means there is short language code in the beginning of the path\_info
* `cfg_www_static_captchas_dir` -- generated captcha images
* `cfg_www_static_dir` -- static content that is served directly by `web-server`

_Important:_ parameters `cfg_model_local_dir`, `cfg_in_filter_dir` and `cfg_out_filter_dir` are calculated automatically and can't be changed. 

To define configuration parameter in your configuration module `*::AppFrontConfig` you need to define apropriate function returning required value. For example:

```
package Example::AppFrontConfig;
sub cfg_db_user                    {"scott"}
sub cfg_db_password                {""}
sub cfg_db_name                    {"tiger"}
```

_Important:_ `PEF Front` makes back reexport of calculated parameters to your `*::AppFrontConfig` to make possible use of automatically calculated params:
```
sub cfg_www_static_captchas_dir { cfg_www_static_dir() . "/images/captchas" }
```

## Export of application's parameters
`PEF::Front::Config` has some limited functionality of `Exporter` to propagate application's parameters to local model handlers or in/out filters. For example:
```
our @EXPORT = qw(avatar_images_path);
sub avatar_images_path () { cfg_www_static_dir() .'/images/avatars' }
```

Then in your local module `Example::Local::AvatarUpload`:
```
package Example::Local::Avatar;
use PEF::Front::Config;

sub upload {
	my ($msg, $def) = @_;
# ...
	my $upload_path = avatar_images_path;
# ...
	return {
		result => "OK",
	};
}
```

`use PEF::Front::Config` in local module gives access to all `PEF Front` configuration parameters and to all exported application parameters.

_Important:_ You must not write `use PEF::Front::Config` in module `*::AppFrontConfig`! This would make circular dependency: to compile `*::AppFrontConfig` would be required `PEF::Front::Config`, which relies on already loaded `*::AppFrontConfig`.

## Parametrizied configuration parameters

Some configuration parameters are functions with parameters.

* `cfg_model_rpc($model)` -- function accept model name from apropriate parameter of description of model method
* `cfg_template_dir($hosname, $lang)` -- function accept hostname and detected short language to determine template directory

# Typical usage

Here is a one possible way to configure your application.

## Components
### nginx

Nginx config can look like this:

```
server {
	listen 80 default_server;
	root /var/www/www.example.com/www-static;
	index index.html index.htm;
	client_max_body_size 100m;
	server_name www.example.com;
	location =/favicon.ico {}
	location /css/ {}
	location /jss/ {}
	location /fonts/ {}
	location /images/ {}
	location /styles/ {}
	location / {
	    include uwsgi_params;
	    uwsgi_pass 127.0.0.1:3031;
	    uwsgi_modifier1 5;
    }
	location ~ /\. {
		deny all;
	}
}
```

Static content is served by nginx itself so we configured some locations with static content.

### uwsgi

Uwsgi config can look like this:

```
[uwsgi]
plugins = psgi
socket = 127.0.0.1:3031
chdir = /var/www/www.example.com
psgi = bin/startup.pl
master = true
processes = 8
stats = 127.0.0.1:5000
perl-no-plack = true
cheaper-algo = spare
cheaper = 2
cheaper-initial = 5
cheaper-step = 1
```

### PEF Front

`PEF Front` is installed by standard make install way

### Application

When your application is similar to what is expected by `PEF Front` then only minimal configuration is required.

## Start

After starting `nginx` and `uwsgi` your application is fully functional.

# `PEF Front` in details
## Templates

Template engine is implemented by Template::Alloy using TemplateToolkit language. 
Passed GET or POST parameters can be used in template generation. There are also some additional methods to 
query model methods or to change some output headers.

Example:

```
[% news = "get all news".model(limit => 3) %]
<section class="news">
  [% FOREACH n IN news.news %]
    [% IF loop.index != 2 %]
      <article class="ar_news">
    [% ELSE %]
      <article class="ar_news ar_none">
    [% END %]
        <h3>[% n.title %]</h3>
        <p>[% n.body %]</p>
        <div class="button">Next<div class="sm">&gt;</div></div>
      </article>
  [% END %]
</section>
```

Expression `[% news = "get all news".model(limit => 3) %]` calls model method `get all news` with parameter `limit`=3. The result is used to generate HTML content.

Templates are located in `cfg_template_dir`, they are called like $template.html and are accessible by path /app$Template. This path is created automatically when you put template in that directory.

### Provided additional template methods

Besids method implemented by Template::Alloy, there are some additional methods:

* `"method".model(param => value)` -- model method call
* `msg("msgid")` -- NLS message transformatin
* `uri_unescape("hello%20world")` -- URI un-escape
* `strftime('%F', gmtime)` -- formatted time string
* `gmtime(time)` -- converts a time value to a 9-element list with the time in GMT.
* `localtime(time)` -- converts a time value to a 9-element list with the time analyzed for the local time zone.
* `response_content_type("text/plain")` -- set Content-Type response header
* `request_get_header("user-agent")` -- get request header
* `response_set_cookie(hello=>"world")` -- set cookie in response
* `response_set_status(403)` -- set response status

### Provided default data in templates 

Every template is called with following data:

* `ip` -- remote client IP
* `lang` -- current short language
* `hostname` -- request's hostname
* `path_info` -- local request's path
* `form` -- hash of all POST and GET parameters
* `cookies` -- hash of cookies
* `template` -- template name
* `scheme` -- scheme `http` or `https`
* `time` -- current UNIX-time
* `gmtime` -- 9-element list with the time in GMT
* `localtime` -- 9-element list with the time for the local time zone

## Model methods

It's possible to use several models in one application. There's must be descrioption to call a model method. 
Model methods descriotions are located in `cfg_model_dir`, one file for every method. File name is made from
method name transformed to CamelCase with `.yaml` extension: `get all news` => `GetAllNews.yaml`.


These descriptions are YAML-files. They can have multidocument structure and model method description must be first document.
There's one special file `-base-.yaml` which can contain common parameters definitions to be used in method documents by reference.

For example, `-base-.yaml`:
```
params:
    ip:
        regex: ^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$
        value: defaults.ip
    limit:
        regex: ^([123456789]\d*)$
        optional: true
        max-size: 3
        default: 5
    offset:
        regex: ^(0|[123456789]\d*)$
        optional: true
        default: 0
        max-size: 10
    textarea:
        filter: [ s/</&lt;/g, s/>/&gt;/g ]
```

`GetAllNews.yaml`:

```
params:
    ip: $ip
    limit: $limit
    offset: $limit
model: admin
allowed_source: [submit, ajax, template]
```

Using `-base-.yaml`, description of the method is much simplier, shorter and requires much less copy-n-paste. 
Also, parameters descriptions are much manageable.

### Description of model method

#### Parameters

Key params describes passed into the method parameters. Every parameter can have some key-attributes or regexp-check.
 Following attributes are recognized:
* `regex` -- checking regexp.
* `captcha` -- defines captcha form field
* `type` -- parameter's type. can be HASH, ARRAY or FILE (for upload)
* `max-size` -- maximum length of scalar or size for array or number of keys of hash
* `min-size` -- minimum length of scalar or size for array or number of keys of hash
* `can` or `can_string` -- array of allowed string values
* `can_number` -- array of allowed number values
* `default` -- default value if not passed in request
* `value` -- unconditional value
* `optional` -- means parameter is optional. special value 'empty' means parameter is optional even when passed but empty.
* `filter` -- input data filter. can be one regexp, array of regexps or filter function from `InFilter`

##### Special values of `default` and `value` attributes

Special prefixes `defaults`, `headers`, `cookie` can be used to retrieve some data into parameter.

* `defaults.param` -- value of some key from hash `defaults`. Possible values: `ip`, `lang`, `hostname`, `path_info`
* `headers.header` -- value of request's header
* `cookies.cookie` -- value of request's cookie


#### Extra parameters

There are three ways to deal with extra request's parameters:
* `ignore` -- ignore undescribed parameters
* `pass` -- pass undescribed parameters into model method as-is without checks
* `disallow` -- no undescribed parameters are allowed
Behaviour is selected by `extra_params` key in method description.

#### Model selection
Key `model` sets calling model type. Model can be local or remote. Local model specified by calling function in some module under `cfg_app_namespace` hierarchy. Local model handlers are located in `cfg_model_local_dir`. `PEF Front` contains some useful handlers also, they have to be specified with full name like `PEF::Front::UploadProgress::get_progress`.

Remote model can be described in almost any way but typically there are two models: site and admin. `Admin` model is for site management and `site` model for client's requests. They are configured by `cfg_model_rpc*` parameters.

#### Filters
##### Input data filters
Parameter's attribute `filter` sets input data filter. For example:

model/Test.yaml:
```
params:
    title:
        filter: [ s/</&lt;/g, s/>/&gt;/g ]
    text:
        filter: Text::filter
model: Test::test
```

Local/Test.pm:
```
package Example::Local::Test;

sub test {
	my ($msg, $def) = @_;
	return {
		result => "OK",
		data   => [1, 2],
		ip     => $def->{ip},
		title  => $msg->{title},
		text   => $msg->{text}
	};
}

1;
```

InFilter/Text.pm:
```
package Example::InFilter::Text;

sub filter {
	my ($field, $def) = @_;
	$field =~ s/</&lt;/g;
	$field =~ s/>/&gt;/g;
	return $field;
}

1;
```

`filter` can be one substitutional regexp, array of  substitutional regexps or filtering function which returns changed field value. Recognized substitutional regexp operators are: `s`, `tr`, `y`.

##### Output filters

It's possible to specify filtering function for sending content. Attribute `filter` for given `result code` in `result` section specifies by calling function in some module under `cfg_app_namespace` hierarchy. Local model handlers are located in `cfg_out_filter_dir`.
This filtering function accepts two paramters: ($response, $defaults). $response must be modified "in-pace", return value of the function doesn't matter.
Intended application is to make transofmation from internal data representation to external form, like XML, CSV, XLS and so on.

For example:

model/Test.yaml:
```
params:
    title:
        filter: [ s/</&lt;/g, s/>/&gt;/g ]
    text:
        filter: Text::filter
result:
    OK:
        filter: TestOut::test
model: Test::test
```

OutFilter/TestOut.pm:
```
package Example::OutFilter::TestOut;

sub test {
	my ($resp, $def) = @_;
	push @{$resp->{data}}, 3, 4, 5 if exists $resp->{data};
}

1;
```

#### How captcha works

Example of usage local handler for catptchas.

Captcha.yaml:
```
---
params:
    width:
        default: 35
    height:
        default: 40
    size:
        default: 5
extra_params: ignore
model: PEF::Front::Captcha::make_captcha
```

SendMessage.yaml:
```
---
params:
    ip: $ip
    email: $email
    lang: $lang
    captcha_code:
        min-size: 5
        captcha: captcha_hash
    captcha_hash:
        min-size: 5
    subject: $subject
    message: $message
result:
    OK:
        redirect: /appSentIsOk
model: site
allowed_source:
    - submit # ajax, submit, template
    - ajax
```

There's some HTML-code in template like this:
```
<form method="post" action="/submitSendMessage">
Captcha:
[% captcha="captcha".model %]
<input type="hidden" name="captcha_hash" value="[% captcha.code %]">
<img src="/captchas/[% captcha.code %].jpg">
<input type="text" maxlength="5" name="captcha_code">
...
</form>
```

Capthcha image is made by `PEF::Front::Captcha::make_captcha($message, $defaults)` function. 
This function writes generated images in `cfg_www_static_captchas_dir`, stores some information in its own database in `cfg_captcha_db` and
returns generated md5 sum. When form is submitted, `PEF::Front::Validator` checks the code and when it is right, passes to the model method `send message`.
Captcha code checks are destructive: the code is not valid anymore after successful check. There's some special case:
when user is logged in and should not input captcha code, then  `PEF::Front::Validator` passes to the model method but sets field `captcha_code` to "nocheck". 
In this case model method must check this value by itself.

### AJAX

`PEF Front` recognizes needed action by URL path prefix:
* `ajax` -- response is `application/json` and possible redirects in result section are ignored
* `submit` -- respons is either redirect to another page or some content probably with text/html content-type
* `get` -- synonim of `submit` but with rest URL path parsing. Example: https://domain.com/getConfirmNewEmail/2134242342423.
   Extra path parameters are divided by `/`. Named parameters have form `name`-`value`, unnamed parameters have their name as `cookie`.

### File upload

Uploaded files are stored in `cfg_upload_dir`/$$ direcory, every working process has its own upload directory to not overwrite files from parallel requests.
Uploaded files are objects of `PEF::Front::File` in corresponding form fields. They are deleted after request's end, so local handlers must move or link that files into some permanent storage before that.

#### Upload progress

To obtain upload progress information there's must be special field `file_field_id` put in form before file input field `file_field`. The content of this field `file_field_id` is used as id to get upload progress info by some AJAX-function.
Model method description for this AJAX-request must have `PEF::Front::UploadProgress` as `model` value. This model method returns response like `{result => 'OK', done => $done, size => $size}`. 
When upload is finished or not even started, the response is `{result => 'NOTFOUND', answer => 'File with this id not found'}`.

_Important:_ The `size` data in response can be known aproximately or unknown at all, so don't depend on it.

### Caching model responses

Some methods can return constant or rarely changing data, it makes perfect sense to cache them.
Key `cache` manages caching for a model method. It has to attributes:
* `key` -- one value or array defining key data
* `expires` -- how long the data can be retained in cache. This value is parsed by Time::Duration::Parse.

Example:
```
cache:
    key: method
    expires: 1m
```

## Response result processing
Ключ result определяет действия, который необходимо совершить при получении ответа от ядра. Ядро возвращает, как правило, следующие варианты ответа:
```
{
    result => "OK",
...
}
либо
{
    result => "SOMEERRCODE",
    answer => 'Some $1 Error $2 Message $3',
    answer_args => [$some, $error, $params],
...
}
```

На основании ключа ответа result, выбирается действие из соответственного описания result. Плюс есть специальное описание DEFAULT, которое используется, когда никакое другое не подошло. В аттрибутах действия можно опиисать:
* `redirect` -- временный редирект браузера для submit и get запросов.
* `set-cookie` -- установить куку. ключами выступают названия устанавливаемых кук, которым можно добавить соответсвтующие атрибуты 
* `unset-cookie` -- сбросить куку браузера.
* `filter` -- специальный фильтр, обрабатывающий ответ
* `answer` -- прямое значение ключа answer в ответе
* `set-header` -- устанавливает заголовок в ответе
* `add-header` -- добавляет заголовок. в отличии от `set-header`, можно в ответе выдать несколько заголовков с одинаковым именем.

_Замечание:_ при установке куки, атрибут `secure` может быть вычислен автоматически исходя из схемы запроса: `https` значит secure => 1, `http` значит не устанавливать признак `secure`

Директива `unset-cookie` может использоваться в том же виде, что и `set-cookie`, т.е. с указанием дополнительных атрибутов у сбрасываемой куки. Это может потребоваться, если какие-либо дополнительные параметры были заданы при установке куки. Например, если при установке куки был задан домен, то чтобы куку сбросить, надо браузеру передать не только то же название, но и тот же домен куки. Вместо придумывания общего не обязательно эффективного решения с сохранением всех выданных кук в базу фреймворка, предлагается прогаммисту просто указать нужные аттрибуты при сбрасывании. Если никаких атрибутов не было использовано, то `unset-cookie` сможет сбросить куку самостоятельно, при этом можно указывать куку одиночным значением или массивом.

## Рутинг

Стандартная схема путей доступа фреймворка выглядит так:
* `/app$Template` -- шаблонизированные страницы
* `/ajax$Method` -- вызов метода модели аяксом, результат JSON-сообщение
* `/submit$Method` -- то же, что и ajax, но подразумевается в ответе перенаправление на новое место или возврат информации, вроде HTML
* `/get$Method/$id...` -- то же, что и submit, но подразумевается наличие дополнительных параметров в пути

Вся эта замечательная схема не всем нравится. Иногда хочется иметь "красивые" пути, вроде `/product/smartphone/Samsung` вместо `/appProduct?id_product=9300`. Для преобразования путей, что используются в браузере в те, что полнимаются во фреймворке, используется рутинг.

Рутинг задаётся до старта приложения. Его можно импортировать в модуль `PEF::Front::Route` или добавить через функцию `PEF::Front::Route::add_route`:
```
use PEF::Front::Route ('/index' => ['/appIndex', 'R']);
```

Рутинг всегда задаётся парами: правило => назначение. Назначение может иметь дополнительные флаги. Флаги могут иметь параметр через знак `=`. Флаги разделяются запятыми. Поддерживаются следующие флаги:
* `R` -- редирект. Можно задать параметром статус редиректа. Например, `R=301` для перманентного редиректа
* `L` -- это правило последнее, если сработало. Можно задать статус ответа, если не передан полный ответ `$http_response`. Например, `L=404`, чтобы прервать обработку и показать пользователю, что информация не найдена
* `RE` -- флаги для Regexp, Например, `RE=g`

Поддерживаются следующие комбинации типов правил и назначения:
* Regexp => строка. В этом случае преобразование будет иметь вид `s"$regexp"$string"$flags`. Например: qr"/index(.*)" => '/appIndex$1'
* Regexp => CODE. При совпадении `m"$regexp"$flags` будет вызвана указанная функция с параметрами ($request, @params), где @params -- массив совпавших групп из сработавшего $regexp
* строка => строка. Проверяется буквальное совпадение строки и если произошло, то путь заменяется на другую строку
* строка => CODE. Проверяется буквальное совпадение строки и если произошло, вызывается функция с параметром ($request)
* CODE => строка. В случае, когда фунцкия возвращает истину, путь заменяется на строку
* CODE => CODE. Если правило сработало, то в функцию назначения передаются параметры ($request, @params), где @params -- массив, который вернула функция совпадения
* CODE => undef. В этом случае функция, отвечающая за правило, является так же и функцией, возвращающей новый путь

Функции назначения могут вернуть простую строку или массив, в котором будут:
* `[$dest_url]`
* `[$dest_url, $flags]`
* `[$dest_url, $flags, $http_response]`

В случае флагов `R` или `L` это правило будет последним, дальнейших преобразований пути не происходит.

Итогом преобразования пути должен быть путь из "стандартной схемы" или редирект.