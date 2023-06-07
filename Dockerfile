ARG nginx_version=stable
FROM nginx:${nginx_version} AS build

SHELL ["/bin/bash", "-c"]

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-suggests \
       libluajit-5.1-dev libpam0g-dev zlib1g-dev libpcre3 libpcre3-dev libpcre2-dev \
       libexpat1-dev git curl build-essential lsb-release libxml2 libxslt1.1 libxslt1-dev libyajl-dev libcurl4 libcurl4-openssl-dev liblua5.1-0 liblua5.1-0-dev autoconf libtool libssl-dev \
       unzip libmaxminddb-dev libgeoip-dev uuid-dev

ARG modsecurity_version=v3.0.9
RUN set -x \
    && git clone --depth 1 -b ${modsecurity_version} https://github.com/SpiderLabs/ModSecurity.git /usr/local/src/modsecurity \
    && cd /usr/local/src/modsecurity \
    && git submodule init \
    && git submodule update \
    && ./build.sh \
    && ./configure --prefix=/usr/local \
    && make \
    && make install

ARG owasp_modsecurity_crs_version=v3.3.4
RUN set -x \
    && nginx_modsecurity_conf_dir="/usr/local/etc/modsecurity" \
    && mkdir -p ${nginx_modsecurity_conf_dir} \
    && cd ${nginx_modsecurity_conf_dir} \
    && curl -fSL "https://github.com/coreruleset/coreruleset/archive/${owasp_modsecurity_crs_version}.tar.gz" \
    |  tar -xvzf - \
    && mv coreruleset{-${owasp_modsecurity_crs_version#v},} \
    && cd -

ARG openresty_package_version=1.21.4.1-1~bullseye1
RUN set -x \
    && curl -fsSL https://openresty.org/package/pubkey.gpg | apt-key add - \
    && echo "deb https://openresty.org/package/debian bullseye openresty" | tee -a /etc/apt/sources.list.d/openresty.list \
    && apt-get update \
    && apt-get install -y --no-install-suggests openresty=${openresty_package_version} \
    && cd /usr/local/openresty \
    && cp -vr ./luajit/* /usr/local/ \
    && rm -d /usr/local/share/lua/5.1 \
    && ln -sf /usr/local/lib/lua/5.1 /usr/local/share/lua/ \
    && cp -vr ./lualib/* /usr/local/lib/lua/5.1

ENV LUAJIT_LIB=/usr/local/lib \
    LUAJIT_INC=/usr/local/include/luajit-2.1

ARG modules
RUN set -x \
    && nginx_version=$(echo ${NGINX_VERSION} | sed 's/-.*//g') \
    && curl -fSL "https://nginx.org/download/nginx-${nginx_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -s /usr/local/src/nginx-${nginx_version} /usr/local/src/nginx \
    && cd /usr/local/src/nginx \
    && configure_args=$(nginx -V 2>&1 | grep "configure arguments:" | awk -F 'configure arguments:' '{print $2}'); \
    IFS=','; \
    for module in ${modules}; do \
        module_repo=$(echo $module | sed -E 's@^(((https?|git)://)?[^:]+).*@\1@g'); \
        module_tag=$(echo $module | sed -E 's@^(((https?|git)://)?[^:]+):?([^:/]*)@\4@g'); \
        dirname=$(echo "${module_repo}" | sed -E 's@^.*/|\..*$@@g'); \
        git clone "${module_repo}"; \
        cd ${dirname}; \
        git fetch --tags; \
        if [ -n "${module_tag}" ]; then \
            if [[ "${module_tag}" =~ ^(pr-[0-9]+.*)$ ]]; then \
                pr_numbers="${BASH_REMATCH[1]//pr-/}"; \
                IFS=';'; \
                for pr_number in ${pr_numbers}; do \
                    git fetch origin "pull/${pr_number}/head:pr-${pr_number}"; \
                    git merge --no-commit pr-${pr_number} master; \
                done; \
                IFS=','; \
            else \
                git checkout "${module_tag}"; \
           fi; \
        fi; \
        cd ..; \
        configure_args="${configure_args} --add-dynamic-module=./${dirname}"; \
    done; unset IFS \
    && eval ./configure ${configure_args} \
    && make modules \
    && cp -v objs/*.so /usr/lib/nginx/modules/

ARG luarocks_version=3.9.2
RUN set -x \
    && curl -fSL "https://luarocks.org/releases/luarocks-${luarocks_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -s /usr/local/src/luarocks-${luarocks_version} /usr/local/src/luarocks \
    && cd /usr/local/src/luarocks \
    && ./configure && make && make install

ARG lua_modules
RUN set -x \
    && IFS=","; \
      for lua_module in ${lua_modules}; do \
        unset IFS; \
        luarocks install ${lua_module}; \
      done

ARG pagespeed_ngx_version=1.13.35.2-stable
RUN set -x \
    && export NGINX_RAW_VERSION=$(echo ${NGINX_VERSION} | sed 's/-.*//g') \
    && export NPS_VERSION=${pagespeed_ngx_version} \
    && export NPS_RELEASE_NUMBER=${NPS_VERSION/stable/} \
    && cd /usr/local/src/nginx \
    && curl -fSL https://github.com/apache/incubator-pagespeed-ngx/archive/v${NPS_VERSION}.zip -o v${NPS_VERSION}.zip \
    && unzip v${NPS_VERSION}.zip \
    && export nps_dir=$(find . -name "*pagespeed-ngx-${NPS_VERSION}" -type d) \
    && cd "$nps_dir" \
    && export psol_url=https://dl.google.com/dl/page-speed/psol/${NPS_RELEASE_NUMBER}x64.tar.gz \
    && [ -e scripts/format_binary_url.sh ] && psol_url=$(scripts/format_binary_url.sh PSOL_BINARY_URL) \
    && curl -fSL ${psol_url} -o ${NPS_RELEASE_NUMBER}x64.tar.gz \
    && tar -xzvf $(basename ${psol_url}) \
    && cd /usr/local/src/nginx \
    && export configure_args=$(nginx -V 2>&1 | grep "configure arguments:" | awk -F 'configure arguments:' '{print $2}'); \
    IFS=','; \
    configure_args="${configure_args} --add-dynamic-module=./${nps_dir}"; \
    unset IFS \
    && eval ./configure ${configure_args} \
    && make modules \
    && cd /usr/local/src/nginx \
    && cp $(pwd)/objs/ngx_pagespeed*.so /usr/lib/nginx/modules/

RUN set -x \
    && find /usr/lib/nginx/modules -type f -exec chmod 644 {} \;

FROM nginx:${nginx_version}

COPY --from=build /usr/local/bin      /usr/local/bin
COPY --from=build /usr/local/include  /usr/local/include
COPY --from=build /usr/local/lib      /usr/local/lib
COPY --from=build /usr/local/etc      /usr/local/etc
COPY --from=build /usr/local/share    /usr/local/share
COPY --from=build /usr/lib/nginx/modules /usr/lib/nginx/modules

ENV LUAJIT_LIB=/usr/local/lib \
    LUAJIT_INC=/usr/local/include/luajit-2.1

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-suggests \
      ca-certificates \
      curl \
      dnsutils \
      iputils-ping \
      libcurl4-openssl-dev \
      libyajl-dev \
      libxml2 \
      lua5.1-dev \
      net-tools \
      procps \
      tcpdump \
      rsync \
      unzip \
      vim-tiny \
      libmaxminddb0 \
      libgeoip1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && ldconfig -v \
    && ls /etc/nginx/modules/*.so | grep -v debug \
    |  xargs -I{} sh -c 'echo "load_module {};" | tee -a  /etc/nginx/modules/all.conf' \
    && ln -sf /dev/stdout /var/log/modsec_audit.log \
    && touch /var/run/nginx.pid \
    && mkdir -p /var/cache/nginx \
    && mkdir -p /var/cache/cache-heater \
    && mkdir /var/ngx_pagespeed_cache \
    && mkdir /var/ngx_pagespeed_log \
    && chmod 777 /var/ngx_pagespeed_cache /var/ngx_pagespeed_log \
    && chown -R nginx:nginx /etc/nginx /var/log/nginx /var/cache/nginx /var/run/nginx.pid /var/log/modsec_audit.log /var/cache/cache-heater /var/ngx_pagespeed_cache /var/ngx_pagespeed_log

ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 80

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]