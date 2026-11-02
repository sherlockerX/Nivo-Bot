#!/bin/sh
# Puts the project site's mirror on this box, next to the showcase:
#
#   1. the site block  → ../sites.d/nanomuse.cn.caddy   (imported by the Caddyfile)
#   2. sync.sh         → /usr/local/bin/nanomuse-site-mirror, run every minute by a systemd timer
#   3. release-sync.py → /usr/local/bin/nanomuse-release-mirror, every fifteen minutes: the newest
#                        releases' packages under www/dl, served at nanomuse.cn/dl/
#   4. traffic.py      → /usr/local/bin/nanomuse-traffic, every ten minutes: the site's access log
#                        counted by day into /var/lib/nanomuse-traffic/traffic.db (the relay's
#                        admin page reads it; cloud/deploy/nanomuse-hk mounts it)
#   5. a first sync of each, so Caddy has something to serve
#   6. Caddy validated and reloaded (recreated if the mounts are new to it)
#
# Run as root from anywhere: `sudo demo/showcase/mirror/install.sh`. Idempotent; run it again
# after `git pull` to pick up changes to any of these files. DNS is yours: A records for
# nanomuse.cn and www.nanomuse.cn pointing at this box, nothing in front of it.
set -eu

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
showcase=$(dirname "$here")

# WWW_ROOT from the environment or the showcase's .env; the default is ../www, as in docker-compose.yml.
# /etc/default/nanomuse-site-mirror keeps it for the timers, next to whatever else was put there
# by hand (GITHUB_TOKEN, MIRROR_RELEASES_KEEP, TRAFFIC_*): only the WWW_ROOT line is ours.
if [ -z "${WWW_ROOT:-}" ] && [ -f "$showcase/.env" ]; then
	WWW_ROOT=$(sed -n 's/^WWW_ROOT=//p' "$showcase/.env" | tail -n 1)
fi
defaults=/etc/default/nanomuse-site-mirror
kept=$( [ -f "$defaults" ] && grep -v '^WWW_ROOT=' "$defaults" || true)
{
	[ -n "$kept" ] && printf '%s\n' "$kept"
	[ -n "${WWW_ROOT:-}" ] && printf 'WWW_ROOT=%s\n' "$WWW_ROOT"
} >"$defaults.new"
if [ -s "$defaults.new" ]; then mv "$defaults.new" "$defaults"; else rm -f "$defaults.new" "$defaults"; fi
[ -n "${WWW_ROOT:-}" ] && export WWW_ROOT

install -d "$showcase/sites.d"
install -m 644 "$here/nanomuse.cn.caddy" "$showcase/sites.d/nanomuse.cn.caddy"

ln -sfn "$here/sync.sh" /usr/local/bin/nanomuse-site-mirror
ln -sfn "$here/release-sync.py" /usr/local/bin/nanomuse-release-mirror
ln -sfn "$here/traffic.py" /usr/local/bin/nanomuse-traffic
install -m 644 "$here/nanomuse-site-mirror.service" "$here/nanomuse-site-mirror.timer" \
	"$here/nanomuse-release-mirror.service" "$here/nanomuse-release-mirror.timer" \
	"$here/nanomuse-traffic.service" "$here/nanomuse-traffic.timer" /etc/systemd/system/
systemctl daemon-reload
# where Caddy writes the access log (docker-compose.yml mounts it); the relay reads the counts
install -d "$showcase/logs/caddy" /var/lib/nanomuse-traffic

# the first sync before the timer: an elapsed timer fires the moment it is enabled, and two
# clones into the same directory do not mix
echo "first sync"
"$here/sync.sh"
systemctl enable -q --now nanomuse-site-mirror.timer
# the releases take longer (a gigabyte or so the first time): the service does it in the
# background, the timer keeps it current
systemctl enable -q --now nanomuse-release-mirror.timer
systemctl start --no-block nanomuse-release-mirror.service
systemctl enable -q --now nanomuse-traffic.timer

cd "$showcase"
echo "caddy: validating"
docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
echo "caddy: applying"
docker compose up -d caddy
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
echo "done: site timer $(systemctl is-active nanomuse-site-mirror.timer), release timer $(systemctl is-active nanomuse-release-mirror.timer), traffic timer $(systemctl is-active nanomuse-traffic.timer); https://nanomuse.cn once DNS points here, packages at /dl/ once the first fetch is through"
