FROM nginx:stable-alpine

RUN apk add --no-cache gettext bash

COPY nginx/nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
