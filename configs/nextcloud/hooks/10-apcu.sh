#!/bin/sh
set -eu
su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set memcache.local --value='\\OC\\Memcache\\APCu'"
su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set memcache.distributed --value='\\OC\\Memcache\\Redis'"
su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set memcache.locking --value='\\OC\\Memcache\\Redis'"
