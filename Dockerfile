# syntax=docker/dockerfile:1

#	This Source Code Form is subject to the terms of the Mozilla Public License,
#	v. 2.0. If a copy of the MPL was not distributed with this file, You can
#	obtain one at http://mozilla.org/MPL/2.0/. OpenMRS is also distributed under
#	the terms of the Healthcare Disclaimer located at http://openmrs.org/license.
#
#	Copyright (C) OpenMRS Inc. OpenMRS is a registered trademark and the OpenMRS
#	graphic logo is a trademark of OpenMRS Inc.

### Build stage: Maven multi-module build (Java 21) that produces webapp/target/openmrs.war,
### and the Tomcat 11 distribution the WAR is deployed to.
FROM maven:3.9.4-eclipse-temurin-21 AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /workspace

# The whole repository is the build context (several modules)
COPY . .

# Parent POM first, then every module
RUN mvn -B clean install -N -DskipTests
RUN mvn -B clean package -DskipTests

# Tomcat 11 (OpenMRS is a Jakarta EE 10+ WAR, it needs a servlet container)
ARG TOMCAT_VERSION=11.0.11
ARG TOMCAT_SHA="a26b2269530fd2fc834e9b1544962f6524cf87925de43b05ad050e66b5eaa76a4ad754a2c5fc4f851baf75a0ea1b0ed8f51082300393a4c35d8c2da0d7c535bd"
ARG TOMCAT_URL="https://archive.apache.org/dist/tomcat/tomcat-11/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"

RUN curl -fL -o /tmp/apache-tomcat.tar.gz "${TOMCAT_URL}" \
    && echo "${TOMCAT_SHA}  /tmp/apache-tomcat.tar.gz" | sha512sum -c \
    && mkdir -p /usr/local/tomcat \
    && tar -xzf /tmp/apache-tomcat.tar.gz -C /usr/local/tomcat --strip-components=1 \
    && rm -rf /tmp/apache-tomcat.tar.gz /usr/local/tomcat/webapps/* \
    && sed -i '/Connector port="8080"/a URIEncoding="UTF-8" relaxedPathChars="[]|" relaxedQueryChars="[]|{}^&#x5c;&#x60;&quot;&lt;&gt;"' \
        /usr/local/tomcat/conf/server.xml \
    && touch /usr/local/tomcat/bin/setenv.sh \
    && chmod -R g+rwX /usr/local/tomcat

# Distribution layout expected by startup.sh / startup-init.sh
RUN mkdir -p /openmrs/distribution/openmrs_core \
    && cp -a /workspace/webapp/target/openmrs.war /openmrs/distribution/openmrs_core/openmrs.war \
    && cp -a /workspace/wait-for-it.sh /workspace/startup-init.sh /workspace/startup.sh /openmrs/ \
    && chmod +x /openmrs/wait-for-it.sh /openmrs/startup-init.sh /openmrs/startup.sh \
    && mkdir -p /openmrs/data/modules /openmrs/data/owa /openmrs/data/configuration \
        /openmrs/data/configuration_checksums /openmrs/data/complex_obs /openmrs/data/activemq-data \
    && cp -a /workspace/LICENSE /openmrs/LICENSE \
    && chmod -R g+rwX /openmrs

### Runtime stage
FROM amazoncorretto:21

# Application (non-root user 1001, group 0 so that OpenShift-style random UIDs also work)
COPY --from=builder --chown=1001:0 /usr/local/tomcat /usr/local/tomcat
COPY --from=builder --chown=1001:0 /openmrs /openmrs

# JVM settings for containers; OMRS_JAVA_MEMORY_OPTS is the variable startup.sh writes into
# Tomcat's CATALINA_OPTS, so it carries the same flags as JAVA_OPTS.
ENV JAVA_OPTS="-Xmx512m -Xms256m -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0" \
    OMRS_JAVA_MEMORY_OPTS="-XX:NewSize=128m -Xmx512m -Xms256m -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0" \
    TZ=UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    OMRS_HOME=/openmrs \
    CATALINA_HOME=/usr/local/tomcat

WORKDIR /openmrs

# Tomcat HTTP port (OpenMRS is served under /openmrs, health: /openmrs/health/alive and /openmrs/health/started)
EXPOSE 8080

USER 1001

# startup.sh waits for the database, writes Tomcat's setenv.sh and then exec's catalina.sh run,
# so that the JVM replaces the shell and receives the platform's SIGTERM for a graceful shutdown.
ENTRYPOINT ["/openmrs/startup.sh"]
