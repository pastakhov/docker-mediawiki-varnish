# Containerized varnish reverse proxy server for MediaWiki

This repo contains [Docker](https://docs.docker.com/) container to run the [Varnish reverse proxy server](https://www.mediawiki.org/wiki/Manual:Varnish_caching).

It is a part of [Containerized Mediawiki install](https://github.com/pastakhov/compose-mediawiki-ubuntu) project.

## Settings

- `PROXY_BACKEND_{name}` defines backend using format 'host:port'. Generally backend name should be the same as container name. Example: `PROXY_BACKEND_web=web:80`.
- `PROXY_RESTBASE_BACKEND` defines backend for the RESTBase service.
- `PROXY_RESTBASE_URL` a regular expression defines uri that should be proxied to the RESTBase service. Example: `PROXY_RESTBASE_URL=^/api/rest_v1`
- `PROXY_RESTBASE_SUB` a string that replaces the regular expression from `PROXY_RESTBASE_URL` variable. String `{backend_hint}` will be replaced by corresponded wiki backend name. Example: `PROXY_RESTBASE_SUB=/{backend_hint}/v1`

### Examples ###

The environment variables
```
- PROXY_BACKEND_web=web:80
- PROXY_BACKEND_restbase=restbase:7231
- PROXY_RESTBASE_BACKEND=restbase
- PROXY_RESTBASE_URL=^/api/rest_v1
- PROXY_RESTBASE_SUB=/{backend_hint}/v1
```

creates config contains:

```
vcl 4.0;
# set web backends
backend restbase {
    .host = "restbase";
    .port = "7231";
}

backend web {
    .host = "web";
    .port = "80";
}

sub vcl_recv {
        set req.http.X-Forwarded-For = client.ip;
        set req.backend_hint = web;

        if (req.url ~ "^/api/rest_v1") {
            set req.url = regsub(req.url, "^/api/rest_v1", regsub("/{backend_hint}/v1", "\{backend_hint\}", req.backend_hint));
            set req.backend_hint = restbase;
            set req.hash_ignore_busy = true;
            return (pass);
        }
...
```
