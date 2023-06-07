nginx_version ?= stable

DOCKER ?= docker
DOCKER_BUILD_OPTS ?=

.PHONY: all
all:
	flavors=$$(jq -er '.flavors[].name' flavors.json) && \
	for f in $$flavors; do make flavor=$$f image; done

.PHONY: check-required-vars
check-required-vars:
ifndef flavor
	$(error 'You must defined the flavor variable')
endif

ifndef nginx_version
	$(error 'You must define the nginx_version variable')
endif

.PHONY: image
image: check-required-vars
	modules=$$(jq -er '.flavors[] | select(.name == "$(flavor)") | .modules | join(",")' flavors.json) && \
	lua_modules=$$(jq -er '.flavors[] | select(.name == "$(flavor)") | [ .lua_modules[]? ] | join(",")' flavors.json) && \
	$(DOCKER) build -t max4com/nginx-pre-labels-$(flavor):$(nginx_version) --build-arg nginx_version=$(nginx_version) --build-arg modules="$$modules" --build-arg lua_modules="$$lua_modules" .
	module_names=$$($(DOCKER) run --rm max4com/nginx-pre-labels-$(flavor):$(nginx_version) sh -c 'ls /etc/nginx/modules/*.so | grep -v debug | xargs -I{} basename {} .so | paste -sd "," -') && \
	echo "FROM max4com/nginx-pre-labels-$(flavor):$(nginx_version)" | $(DOCKER) build -t max4com/nginx:$(nginx_version) --label "io.max4com.$(nginx_version).nginx-modules=$$module_names" -

.PHONY: test
test: check-required-vars
	$(DOCKER) rm -f test-max4com-nginx-$(flavor)-$(nginx_version) || true
	$(DOCKER) create -p 8888:9080 --name test-max4com-nginx-$(flavor)-$(nginx_version) max4com/nginx-pre-labels-$(flavor):$(nginx_version) bash -c " \
	openssl req -x509 -newkey rsa:4096 -nodes -subj '/CN=localhost' -keyout /etc/nginx/key.pem -out /etc/nginx/cert.pem -days 365; \
	nginx -c /etc/nginx/nginx-$(flavor).conf "
	$(DOCKER) cp $$PWD/test/nginx-$(flavor).conf test-max4com-nginx-$(flavor)-$(nginx_version):/etc/nginx/
	@MS_RULES_DIR=$$(mktemp -d); curl https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended -o $$MS_RULES_DIR/modsecurity_rules.conf; \
	curl https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/unicode.mapping -o $$MS_RULES_DIR/unicode.mapping; \
	$(DOCKER) cp $$PWD/test/GeoIP2-Country-Test.mmdb test-max4com-nginx-$(flavor)-$(nginx_version):/etc/nginx; \
	$(DOCKER) cp $$MS_RULES_DIR/modsecurity_rules.conf test-max4com-nginx-$(flavor)-$(nginx_version):/etc/nginx; \
	$(DOCKER) cp $$MS_RULES_DIR/unicode.mapping test-max4com-nginx-$(flavor)-$(nginx_version):/etc/nginx; \
	rm -r $$MS_RULES_DIR || rm -r $$MS_RULES_DIR
	$(DOCKER) start test-max4com-nginx-$(flavor)-$(nginx_version) && sleep 3
	@if [ "$$($(DOCKER) exec test-max4com-nginx-$(flavor)-$(nginx_version) curl -fsSL http://localhost:9080)" != "nginx config check ok" ]; then \
		echo 'FAIL' >&2; \
		$(DOCKER) logs test-max4com-nginx-$(flavor)-$(nginx_version); \
		exit 1; \
	else \
		echo 'SUCCESS'; \
	fi
