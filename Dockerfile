# syntax=docker/dockerfile:1

#
# Stage 1: install PHP (composer) and JS (npm/grunt) dependencies, build assets
#
FROM composer:2 AS composer-deps
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --no-progress --optimize-autoloader --ignore-platform-reqs

FROM node:22-bookworm AS assets-build
WORKDIR /app
# package.json runs a postinstall script (update-design-system.mjs) that
# needs the full source tree, so npm ci must run after COPY . . here.
COPY . .
RUN npm ci
RUN npx grunt --force

#
# Stage 2: runtime image
#
FROM php:8.3-apache AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        unzip \
        git \
    && rm -rf /var/lib/apt/lists/*

# install-php-extensions (https://github.com/mlocati/docker-php-extension-installer)
# resolves inter-extension build dependencies (e.g. xmlreader needs dom's
# generated headers) and installs the required system libraries itself,
# which plain docker-php-ext-install does not handle reliably.
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
        iconv \
        mbstring \
        curl \
        ctype \
        zip \
        gd \
        simplexml \
        dom \
        xml \
        xmlreader \
        intl \
        json \
        soap \
        exif \
        xsl \
        opcache \
        mysqli \
        pgsql \
        pdo_mysql \
        pdo_pgsql \
        sodium

RUN a2enmod rewrite headers expires

# Moodle serves from the public/ subdirectory.
ENV APACHE_DOCUMENT_ROOT=/var/www/html/public
RUN sed -ri -e "s!/var/www/html!${APACHE_DOCUMENT_ROOT}!g" \
        /etc/apache2/sites-available/*.conf \
    && sed -ri -e "s!/var/www/!${APACHE_DOCUMENT_ROOT}!g" \
        /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

RUN { \
        echo 'memory_limit = 256M'; \
        echo 'upload_max_filesize = 100M'; \
        echo 'post_max_size = 100M'; \
        echo 'max_execution_time = 300'; \
        echo 'max_input_vars = 5000'; \
        echo 'opcache.enable = 1'; \
        echo 'opcache.memory_consumption = 128'; \
        echo 'opcache.validate_timestamps = 0'; \
    } > /usr/local/etc/php/conf.d/moodle.ini

WORKDIR /var/www/html

COPY --chown=www-data:www-data . .
COPY --from=composer-deps --chown=www-data:www-data /app/vendor ./vendor
COPY --from=assets-build --chown=www-data:www-data /app/public ./public
COPY --from=assets-build --chown=www-data:www-data /app/node_modules ./node_modules

# Moodledata directory (must live outside the webroot in production; mount a volume here).
RUN mkdir -p /var/www/moodledata \
    && chown -R www-data:www-data /var/www/moodledata /var/www/html

VOLUME ["/var/www/moodledata"]

EXPOSE 80

CMD ["apache2-foreground"]
