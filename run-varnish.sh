#!/bin/bash
set -e

config=/etc/varnish/mediawiki.vcl

write() {
    if [[ "$2" == '-' && $tabs > 0 ]]; then
        tabs=$(($tabs-1))
    fi

    printf "%$(($tabs*4))s" >> $config
    echo $1 >> $config;

    if [[ "$2" == '+' || "$2" == '-+' || "$2" == '+-' ]]; then
        tabs=$(($tabs+1))
    fi
}

#create varnish config
# see https://www.mediawiki.org/wiki/Manual:Varnish_caching
cat <<EOT > $config
vcl 4.0;
# set web backends
EOT

backends="${!PROXY_BACKEND_*}"

if [ -z "$backends" ]; then
    echo >&2 'You must provite PROXY_BACKEND_* variables, for example: export PROXY_BACKEND_web=web:80'
    exit 2;
fi

for var in $backends
do
    if [[ "${var:14}" =~ ([a-zA-Z0-9]+) ]]; then
        name="${BASH_REMATCH[1]}"
        if [[ -z "$default_backend" && "$name" != "$PROXY_RESTBASE_BACKEND" ]]; then
            default_backend="$name"
        fi
    else
        echo >&2 'You should provide name of backend as postfix string at the end of PROXY_BACKEND_'
        continue
    fi

    if [[ "${!var}" =~ ([a-zA-Z0-9]+):?([0-9]+)? ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    fi

    cat <<EOT >> $config
backend $name {
    .host = "${host:-$name}";
    .port = "${port:-80}";
}

EOT
done

cat <<EOT >> $config
# access control list for "purge": open to only localhost and other local nodes
acl purge {
    "10.0.0.0"/8; # RFC1918 possible internal network
    "172.16.0.0"/12; # RFC1918 possible internal network
    "192.168.0.0"/16; # RFC1918 possible internal network
    "fc00::"/7; # RFC 4193 local private network range
    "fe80::"/10; # RFC 4291 link-local (directly plugged) machines
}

sub vcl_recv {
    # Serve objects up to 2 minutes past their expiry if the backend
    # is slow to respond.
    # set req.grace = 120s;
    set req.http.X-Forwarded-For = client.ip;
    set req.backend_hint = $default_backend;

EOT

tabs=1

if [[ -n "$PROXY_RESTBASE_URL" && -n "$PROXY_RESTBASE_BACKEND" ]]; then
    write 'if (req.url ~ "'$PROXY_RESTBASE_URL'") {' +
    if [ -n "$PROXY_RESTBASE_SUB" ]; then
        write 'set req.url = regsub(req.url, "'$PROXY_RESTBASE_URL'", regsub("'$PROXY_RESTBASE_SUB'", "\{backend_hint\}", req.backend_hint));'
    fi
    write "set req.backend_hint = $PROXY_RESTBASE_BACKEND;"
    write 'set req.hash_ignore_busy = true;'
    write 'return (pass);'
    write '}' -
fi

cat <<EOT >> $config
    # This uses the ACL action called "purge". Basically if a request to
    # PURGE the cache comes from anywhere other than localhost, ignore it.
    if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            return (synth(405, "Not allowed."));
        } else {
            return (purge);
        }
    }

    # Pass any requests that Varnish does not understand straight to the backend.
    if (req.method != "GET" && req.method != "HEAD" &&
        req.method != "PUT" && req.method != "POST" &&
        req.method != "TRACE" && req.method != "OPTIONS" &&
        req.method != "DELETE") {
            return (pipe);
    } /* Non-RFC2616 or CONNECT which is weird. */

    # Pass anything other than GET and HEAD directly.
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }      /* We only deal with GET and HEAD by default */

    # Pass requests from logged-in users directly.
    # Only detect cookies with "session" and "Token" in file name, otherwise nothing get cached.
    if (req.http.Authorization || req.http.Cookie ~ "session" || req.http.Cookie ~ "Token") {
        return (pass);
    } /* Not cacheable by default */

    # Pass any requests with the "If-None-Match" header directly.
    if (req.http.If-None-Match) {
        return (pass);
    }

    # Force lookup if the request is a no-cache request from the client.
    if (req.http.Cache-Control ~ "no-cache") {
        ban(req.url);
    }

    # normalize Accept-Encoding to reduce vary
    if (req.http.Accept-Encoding) {
        if (req.http.User-Agent ~ "MSIE 6") {
        unset req.http.Accept-Encoding;
        } elsif (req.http.Accept-Encoding ~ "gzip") {
        set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate") {
        set req.http.Accept-Encoding = "deflate";
        } else {
        unset req.http.Accept-Encoding;
        }
    }

    return (hash);
}

sub vcl_pipe {
    # Note that only the first request to the backend will have
    # X-Forwarded-For set.  If you use X-Forwarded-For and want to
    # have it set for all requests, make sure to have:
    # set req.http.connection = "close";

    # This is otherwise not necessary if you do not do any request rewriting.

    set req.http.connection = "close";
}

# Called if the cache has a copy of the page.
sub vcl_hit {
    if (req.method == "PURGE") {
        ban(req.url);
        return (synth(200, "Purged"));
    }

    if (!obj.ttl > 0s) {
        return (pass);
    }
}

# Called if the cache does not have a copy of the page.
sub vcl_miss {
    if (req.method == "PURGE")  {
        return (synth(200, "Not in cache"));
    }
}

# Called after a document has been successfully retrieved from the backend.
sub vcl_backend_response {
    # set minimum timeouts to auto-discard stored objects
    set beresp.grace = 120s;

    if (!beresp.ttl > 0s) {
        set beresp.uncacheable = true;
        return (deliver);
    }

    if (beresp.http.Set-Cookie) {
        set beresp.uncacheable = true;
        return (deliver);
    }

#    if (beresp.http.Cache-Control ~ "(private|no-cache|no-store)") {
#        set beresp.uncacheable = true;
#        return (deliver);
#    }

    if (beresp.http.Authorization && !beresp.http.Cache-Control ~ "public") {
        set beresp.uncacheable = true;
        return (deliver);
    }

    return (deliver);
}
EOT

# Start varnish
varnishd \
    -j unix,user=varnish \
    -a :${PROXY_PORT} \
    -f $config \
    -s malloc,256m

# Start varnish log
varnishncsa
