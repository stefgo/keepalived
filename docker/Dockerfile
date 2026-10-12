FROM alpine:3

ENV KEEPALIVED_ROUTER_ID="" \
    KEEPALIVED_SCRIPT_USER=root \
    TZ=""

# The sample configuration shipped with the package would be mistaken for a
# mounted custom configuration by the entrypoint
RUN apk add --no-cache keepalived tzdata \
 && rm -f /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.sample \
 && mkdir -p /etc/keepalived/scripts

COPY --chmod=0755 entrypoint.sh notify-log.sh /usr/local/bin/

# The parent process and its VRRP child must both be running
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD [ "$(pidof keepalived | wc -w)" -ge 2 ] || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
