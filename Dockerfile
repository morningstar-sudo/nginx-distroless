# syntax=docker/dockerfile:1

########################################################################
# Stage 1: build static nginx + ModSecurity on Wolfi (glibc)
########################################################################
FROM cgr.dev/chainguard/wolfi-base:latest AS build

# perl: required by OpenSSL's Configure
RUN apk add --no-cache build-base git autoconf automake libtool \
    linux-headers cmake pkgconf pkgconf-dev coreutils perl

# All sources are cloned from GitHub at build time. Default "latest"
# resolves the newest stable tag via git ls-remote; pin with --build-arg.
ARG NGINX_TAG=latest
ARG MODSEC_TAG=latest
ARG MODSEC_NGINX_TAG=latest
ARG CRS_TAG=latest
ARG ZLIB_TAG=latest
ARG PCRE2_TAG=latest
ARG OPENSSL_TAG=latest
ARG LIBXML2_TAG=latest
ARG YAJL_TAG=latest

# resolve <repo-url> <tag-glob>: newest stable tag, rc/alpha/beta filtered out
COPY <<'EOF' /usr/local/bin/resolve
#!/bin/sh
set -e
git ls-remote --tags --refs "$1" "refs/tags/$2" \
  | awk -F/ '{print $NF}' \
  | grep -Eiv -- '(rc|alpha|beta|dev)[0-9]*$' \
  | sort -V | tail -1
EOF
RUN chmod +x /usr/local/bin/resolve

WORKDIR /src

# zlib (static)
RUN TAG="$ZLIB_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/madler/zlib 'v[0-9]*'); \
    echo "zlib=$TAG" && \
    git clone --depth 1 --branch "$TAG" https://github.com/madler/zlib && \
    cd zlib && ./configure --static && make -j"$(nproc)" && make install

# pcre2 (static) — used by nginx and libmodsecurity
RUN TAG="$PCRE2_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/PCRE2Project/pcre2 'pcre2-[0-9]*'); \
    echo "pcre2=$TAG" && \
    git clone --depth 1 --recursive --branch "$TAG" https://github.com/PCRE2Project/pcre2 && \
    cd pcre2 && ./autogen.sh && \
    ./configure --disable-shared --enable-static --enable-jit && \
    make -j"$(nproc)" && make install

# openssl (source only — nginx builds it statically itself via --with-openssl)
RUN TAG="$OPENSSL_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/openssl/openssl 'openssl-[0-9]*'); \
    echo "openssl=$TAG" && \
    git clone --depth 1 --branch "$TAG" https://github.com/openssl/openssl

# libxml2 (static, cmake — autotools is being phased out upstream)
RUN TAG="$LIBXML2_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/GNOME/libxml2 'v[0-9]*'); \
    echo "libxml2=$TAG" && \
    git clone --depth 1 --branch "$TAG" https://github.com/GNOME/libxml2 && \
    cmake -S libxml2 -B libxml2/build \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_LZMA=OFF \
      -DLIBXML2_WITH_ZLIB=OFF -DLIBXML2_WITH_TESTS=OFF && \
    cmake --build libxml2/build -j"$(nproc)" && cmake --install libxml2/build

# yajl (static; cmake names it libyajl_s.a — alias to libyajl.a for the linker)
RUN TAG="$YAJL_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/lloyd/yajl '[0-9]*'); \
    echo "yajl=$TAG" && \
    git clone --depth 1 --branch "$TAG" https://github.com/lloyd/yajl && \
    sed -i '/ADD_SUBDIRECTORY/{/(src)/!d}' yajl/CMakeLists.txt && \
    cmake -S yajl -B yajl/build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    cmake --build yajl/build -j"$(nproc)" && cmake --install yajl/build && \
    cp /usr/local/lib/libyajl_s.a /usr/local/lib/libyajl.a

# libmodsecurity v3 (static)
RUN TAG="$MODSEC_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/owasp-modsecurity/ModSecurity 'v[0-9]*'); \
    echo "modsecurity=$TAG" && \
    git clone --depth 1 --recursive --branch "$TAG" https://github.com/owasp-modsecurity/ModSecurity && \
    cd ModSecurity && ./build.sh && \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./configure \
      --disable-shared --enable-static \
      --with-pcre2=/usr/local --with-yajl=/usr/local \
      --without-curl --without-lua --without-lmdb --without-maxmind \
      --disable-examples --disable-libtool-lock && \
    make -j"$(nproc)" && make install

# ModSecurity-nginx connector + nginx itself (both from GitHub)
RUN TAG="$MODSEC_NGINX_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/owasp-modsecurity/ModSecurity-nginx 'v[0-9]*'); \
    echo "modsecurity-nginx=$TAG" && \
    git clone --depth 1 --branch "$TAG" https://github.com/owasp-modsecurity/ModSecurity-nginx && \
    # static link: libmodsecurity.a's own deps must come AFTER -lmodsecurity
    sed -i 's|-lmodsecurity|-lmodsecurity -lstdc++ -lxml2 -lyajl -lpcre2-8 -lm -lpthread|' \
      ModSecurity-nginx/config

RUN TAG="$NGINX_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/nginx/nginx 'release-[0-9]*'); \
    echo "nginx=$TAG" && \
    git clone --depth 1 --branch "$TAG" https://github.com/nginx/nginx && \
    cd nginx && \
    MODSECURITY_INC=/usr/local/modsecurity/include \
    MODSECURITY_LIB=/usr/local/modsecurity/lib \
    ./auto/configure \
      --prefix=/etc/nginx \
      --sbin-path=/usr/sbin/nginx \
      --conf-path=/etc/nginx/nginx.conf \
      --pid-path=/tmp/nginx.pid \
      --lock-path=/tmp/nginx.lock \
      --http-client-body-temp-path=/tmp/client_temp \
      --http-proxy-temp-path=/tmp/proxy_temp \
      --error-log-path=/dev/stderr \
      --http-log-path=/dev/stdout \
      --user=nonroot --group=nonroot \
      --with-http_ssl_module \
      --with-openssl=/src/openssl \
      --with-openssl-opt="no-module no-engine no-tests" \
      --with-http_v2_module \
      --with-http_gzip_static_module \
      --with-http_realip_module \
      --with-http_stub_status_module \
      --with-mail \
      --with-mail_ssl_module \
      --with-stream \
      --with-stream_ssl_module \
      --with-stream_ssl_preread_module \
      --without-http_fastcgi_module \
      --without-http_uwsgi_module \
      --without-http_scgi_module \
      --without-http_memcached_module \
      --without-http_ssi_module \
      --without-http_autoindex_module \
      --add-module=/src/ModSecurity-nginx \
      --with-cc-opt="-static -Os -I/usr/local/include" \
      --with-ld-opt="-static -L/usr/local/lib -L/usr/local/modsecurity/lib" && \
    make -j"$(nproc)" && make install && \
    strip /usr/sbin/nginx && \
    if readelf -d /usr/sbin/nginx 2>/dev/null | grep -q NEEDED; then \
      echo "ERROR: nginx is not statically linked"; readelf -d /usr/sbin/nginx; exit 1; \
    fi

# OWASP Core Rule Set
RUN TAG="$CRS_TAG"; [ "$TAG" = latest ] && TAG=$(resolve https://github.com/coreruleset/coreruleset 'v[0-9]*'); \
    echo "crs=$TAG" && \
    git clone --depth 1 --branch "$TAG" https://github.com/coreruleset/coreruleset /opt/crs && \
    cp /opt/crs/crs-setup.conf.example /opt/crs/crs-setup.conf

# Static entrypoint (distroless has no shell to read IS_MS_ON)
COPY entrypoint.c /src/entrypoint.c
RUN gcc -static -Os -o /entrypoint /src/entrypoint.c && strip /entrypoint

# Skeleton for /tmp, writable by nonroot when not using tmpfs
RUN mkdir -p /tmp-skel

########################################################################
# Stage 2: distroless runtime (no shell, no package manager, nonroot)
########################################################################
FROM cgr.dev/chainguard/static:latest

COPY --from=build /usr/sbin/nginx /usr/sbin/nginx
COPY --from=build /entrypoint /entrypoint
COPY --from=build /src/nginx/conf/mime.types /etc/nginx/mime.types
COPY --from=build /src/ModSecurity/unicode.mapping /etc/nginx/unicode.mapping
COPY --from=build /opt/crs/crs-setup.conf /etc/nginx/crs/crs-setup.conf
COPY --from=build /opt/crs/rules /etc/nginx/crs/rules
COPY --from=build --chown=65532:65532 /tmp-skel /tmp
COPY nginx/ /etc/nginx/
COPY html/ /usr/share/nginx/html/

EXPOSE 8080
ENTRYPOINT ["/entrypoint"]
