#!/bin/bash

LD_PRELOAD=/usr/lib/libhardened_malloc.so chromium \
	--disable-background-networking \
	--disable-client-side-phishing-detection \
	--disable-component-update \
	--disable-default-apps \
	--disable-domain-reliability \
	--disable-extensions \
	--disable-infobars \
	--disable-ping \
	--disable-predict-network-actions \
	--disable-preconnect \
	--disable-ntp-popular-sites \
	--disable-ntp-remote-suggestions \
	--disable-translate \
	--dns-prefetch-disable \
	--no-pings \
	--safebrowsing-disable-auto-update \
	--safebrowsing-disable-download-protection \
	--url-blacklist='https://*.google-analytics.com/*,https://*.googleadservices.com/*,https://*.googletagservices.com/*' \
	"$@"
